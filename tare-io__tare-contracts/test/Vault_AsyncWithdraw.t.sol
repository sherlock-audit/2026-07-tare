// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";

contract Vault_AsyncWithdrawTest is VaultTestBase {
  // ──────── Helpers ────────

  /** @notice Convenience overload using fixed DEFAULT_DEPOSIT_AMOUNT and default loan valuation */
  function _setupShareholderWithShares() internal returns (uint256 shares) {
    return _setupShareholderWithShares(shareholder1, DEFAULT_DEPOSIT_AMOUNT, DEFAULT_LOAN_VALUATION);
  }

  // ──────── withdraw (claim by assets) ────────

  function test_Withdraw_Reverts_WhenControllerNotShareholder() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableAssets = vault.maxWithdraw(shareholder1);

    // Revoke shareholder1 role after approval
    shareToken.revokeRole(shareToken.SHAREHOLDER_ROLE(), shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.withdraw(claimableAssets, shareholder1, shareholder1);
  }

  function test_Withdraw_Reverts_WhenReceiverNotShareholder() public {
    uint256 shares = _setupShareholderWithShares();
    address nonShareholder = makeAddr("nonShareholder");

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableAssets = vault.maxWithdraw(shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.withdraw(claimableAssets, nonShareholder, shareholder1);
  }

  function test_Withdraw_Reverts_WhenReceiverIsVault() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableAssets = vault.maxWithdraw(shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InvalidReceiver.selector));
    vault.withdraw(claimableAssets, address(vault), shareholder1);
  }

  // ──────── approveRedemption liquidity guard ────────

  function testFuzz_ApproveRedemption_Reverts_WhenIdleBelowRequired(uint256 drainSeed) public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // Rescue does not invalidate cached NAV, so share price (and `assets`) stays constant
    // across any drain amount; only `idleLiquidity()` changes.
    uint256 expectedAssets = (shares * vault.lastNav()) / shareToken.totalSupply();
    uint256 vaultBalance = usdc.balanceOf(address(vault));
    uint256 minDrain = vaultBalance - expectedAssets + 1; // idle becomes expectedAssets - 1
    uint256 drainAmount = bound(drainSeed, minDrain, vaultBalance);

    vm.prank(guardian);
    vault.rescueERC20Tokens(address(usdc), drainAmount);

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InsufficientLiquidity.selector));
    vault.approveRedemption(shareholder1, shares);
  }

  function test_ApproveRedemption_Reverts_WhenSecondApprovalExceedsRemainingLiquidity() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // Approve the first half successfully — this reserves assets in totalClaimableRedeemAssets
    uint256 firstShares = shares / 2;
    vm.prank(manager);
    vault.approveRedemption(shareholder1, firstShares);

    // Compute the remaining redemption value at the (now updated) share price
    uint256 remainingShares = shares - firstShares;
    uint256 remainingAssets = (remainingShares * vault.lastNav()) / shareToken.totalSupply();

    // Drain so idle liquidity = remainingAssets - 1 (one wei short)
    uint256 targetBalance = vault.totalClaimableRedeemAssets() + remainingAssets - 1;
    uint256 drainAmount = usdc.balanceOf(address(vault)) - targetBalance;
    vm.prank(guardian);
    vault.rescueERC20Tokens(address(usdc), drainAmount);

    assertEq(vault.idleLiquidity(), remainingAssets - 1, "idle should be one wei short of remaining");

    // Second approval must check against idleLiquidity (which excludes the prior reservation)
    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InsufficientLiquidity.selector));
    vault.approveRedemption(shareholder1, remainingShares);
  }

  function test_ApproveRedemption_Succeeds_AtExactIdleLiquidity() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // Drain USDC down to exactly the redemption value.
    uint256 expectedAssets = (shares * vault.lastNav()) / shareToken.totalSupply();
    uint256 drainAmount = usdc.balanceOf(address(vault)) - expectedAssets;
    vm.prank(guardian);
    vault.rescueERC20Tokens(address(usdc), drainAmount);

    assertEq(vault.idleLiquidity(), expectedAssets, "idle liquidity should equal required assets");

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    assertEq(vault.claimableRedeemShares(shareholder1), shares);
    assertEq(vault.claimableRedeemAssets(shareholder1), expectedAssets);
    assertEq(vault.totalClaimableRedeemAssets(), expectedAssets);

    // Boundary check: NAV finalization must not underflow when balance == totalClaimableRedeemAssets.
    _refreshNav();
    assertGt(vault.lastNavUpdate(), 0, "NAV should have finalized");
  }

  function test_Redeem_Succeeds_AfterApprovalAtExactIdleLiquidity() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // Drain USDC down to exactly the redemption value so the boundary approval is fundable
    uint256 expectedAssets = (shares * vault.lastNav()) / shareToken.totalSupply();
    uint256 drainAmount = usdc.balanceOf(address(vault)) - expectedAssets;
    vm.prank(guardian);
    vault.rescueERC20Tokens(address(usdc), drainAmount);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    // Claim — proves "approved ⇒ fundable": vault holds exactly enough to settle
    uint256 receiverBalanceBefore = usdc.balanceOf(shareholder1);
    vm.prank(shareholder1);
    uint256 assetsOut = vault.redeem(shares, shareholder1, shareholder1);

    assertEq(assetsOut, expectedAssets, "redeem should return expected assets");
    assertEq(usdc.balanceOf(shareholder1) - receiverBalanceBefore, expectedAssets, "receiver should get assets");
    assertEq(vault.claimableRedeemShares(shareholder1), 0);
    assertEq(vault.claimableRedeemAssets(shareholder1), 0);
    assertEq(vault.totalClaimableRedeemAssets(), 0);
  }
}
