// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {IERC7540Redeem} from "forge-std/interfaces/IERC7540.sol";
import {IERC7575} from "forge-std/interfaces/IERC7575.sol";
import {stdError} from "forge-std/StdError.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract Vault_AsyncRedeemTest is VaultTestBase {
  // ──────── Helpers ────────

  /** @notice Convenience overload using fixed DEFAULT_DEPOSIT_AMOUNT and default loan valuation */
  function _setupShareholderWithShares() internal returns (uint256 shares) {
    return _setupShareholderWithShares(shareholder1, DEFAULT_DEPOSIT_AMOUNT, DEFAULT_LOAN_VALUATION);
  }

  // ──────── Full Happy Path: request → approve → claim ────────

  function test_AsyncRedeem_FullHappyPath(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, loanValuation);

    // Step 1: Request redeem
    vm.prank(shareholder1);
    uint256 requestId = vault.requestRedeem(shares, shareholder1, shareholder1);
    assertEq(requestId, 0, "requestId should be 0");
    assertEq(vault.pendingRedeemShares(shareholder1), shares, "pending redeem shares mismatch");
    assertEq(shareToken.balanceOf(shareholder1), 0, "shares should be locked in vault");
    assertEq(shareToken.balanceOf(address(vault)), shares, "vault should hold locked shares");

    // Step 2: Manager approves redemption
    uint256 navAtApproval = vault.lastNav();
    uint256 supplyAtApproval = shareToken.totalSupply();
    uint256 expectedAssets = (shares * navAtApproval) / supplyAtApproval;

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);
    uint256 claimableShares = vault.maxRedeem(shareholder1);
    assertEq(claimableAssets, expectedAssets, "claimable assets mismatch");
    assertEq(claimableShares, shares, "claimable shares should equal requested");
    assertEq(vault.pendingRedeemShares(shareholder1), 0, "pending should be cleared");

    // Step 3: Shareholder claims redemption
    uint256 usdcBefore = usdc.balanceOf(shareholder1);
    vm.prank(shareholder1);
    uint256 receivedAssets = vault.redeem(claimableShares, shareholder1, shareholder1);

    assertEq(receivedAssets, claimableAssets, "received assets mismatch");
    assertEq(usdc.balanceOf(shareholder1), usdcBefore + receivedAssets, "USDC balance mismatch");
    assertEq(vault.claimableRedeemShares(shareholder1), 0, "claimable shares should be cleared");
    assertEq(vault.claimableRedeemAssets(shareholder1), 0, "claimable assets should be cleared");
  }

  // ──────── requestRedeem ────────

  function test_RequestRedeem_LocksSharesInVault(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, loanValuation);
    uint256 vaultSharesBefore = shareToken.balanceOf(address(vault));

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    assertEq(shareToken.balanceOf(shareholder1), 0, "shareholder1 should have no shares");
    assertEq(shareToken.balanceOf(address(vault)), vaultSharesBefore + shares, "vault should hold locked shares");
    assertEq(vault.pendingRedeemShares(shareholder1), shares, "pending should track locked shares");
  }

  function test_RequestRedeem_EmitsRedeemRequestEvent() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vm.expectEmit(true, true, true, true);
    emit IERC7540Redeem.RedeemRequest(shareholder1, shareholder1, 0, shareholder1, shares);
    vault.requestRedeem(shares, shareholder1, shareholder1);
  }

  function test_RequestRedeem_IsAdditive(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, loanValuation);
    uint256 firstRedeem = shares / 3;
    uint256 secondRedeem = shares / 3;
    vm.assume(firstRedeem > 0 && secondRedeem > 0);

    vm.prank(shareholder1);
    vault.requestRedeem(firstRedeem, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vault.requestRedeem(secondRedeem, shareholder1, shareholder1);

    assertEq(vault.pendingRedeemShares(shareholder1), firstRedeem + secondRedeem);
  }

  function test_RequestRedeem_ControllerDifferentFromOwner() public {
    uint256 shares = _setupShareholderWithShares();

    // shareholder1 (owner) requests redeem with shareholder2 as controller
    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder2, shareholder1);

    assertEq(shareToken.balanceOf(shareholder1), 0, "owner shares should be locked");
    assertEq(vault.pendingRedeemShares(shareholder2), shares, "pending tracked under controller");
    assertEq(vault.pendingRedeemShares(shareholder1), 0, "owner should have no pending");
  }

  function test_RequestRedeem_AllowedByOperator() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, true);

    vm.prank(operatorAddr);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    assertEq(vault.pendingRedeemShares(shareholder1), shares);
  }

  function test_RequestRedeem_Reverts_WhenZeroAmount() public {
    _setupShareholderWithShares();

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ZeroAmount.selector));
    vault.requestRedeem(0, shareholder1, shareholder1);
  }

  function test_RequestRedeem_Reverts_WhenUnauthorized() public {
    _setupShareholderWithShares();

    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.Unauthorized.selector));
    vault.requestRedeem(DEFAULT_REDEEM_SHARES, shareholder1, shareholder1);
  }

  function test_RequestRedeem_Reverts_WhenInsufficientShares() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, shareholder1, shares, shares + 1)
    );
    vault.requestRedeem(shares + 1, shareholder1, shareholder1);
  }

  function test_RequestRedeem_Reverts_WhenControllerNotShareholder() public {
    uint256 shares = _setupShareholderWithShares();
    address nonShareholder = makeAddr("nonShareholder");

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.requestRedeem(shares, nonShareholder, shareholder1);
  }

  function test_RequestRedeem_Reverts_WhenControllerIsVault() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InvalidController.selector));
    vault.requestRedeem(shares, address(vault), shareholder1);
  }

  // ──────── approveRedemption ────────

  function test_ApproveRedemption_CalculatesAssetsAtCurrentPrice(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, loanValuation);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    uint256 navBefore = vault.lastNav();
    uint256 totalSupplyBefore = shareToken.totalSupply();
    uint256 expectedAssets = (shares * navBefore) / totalSupplyBefore;

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    assertEq(vault.claimableRedeemAssets(shareholder1), expectedAssets, "assets mismatch");
    assertEq(vault.claimableRedeemShares(shareholder1), shares, "shares mismatch");
    assertEq(vault.pendingRedeemShares(shareholder1), 0, "pending not cleared");
  }

  function test_ApproveRedemption_EmitsRedeemApprovedEvent() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    uint256 navBefore = vault.lastNav();
    uint256 totalSupplyBefore = shareToken.totalSupply();
    uint256 expectedAssets = (shares * navBefore) / totalSupplyBefore;

    vm.prank(manager);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.RedeemApproved(shareholder1, shares, expectedAssets);
    vault.approveRedemption(shareholder1, shares);
  }

  function test_ApproveRedemption_PartialApproval(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, loanValuation);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    uint256 halfShares = shares / 2;
    vm.assume(halfShares > 0);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, halfShares);

    assertEq(vault.claimableRedeemShares(shareholder1), halfShares, "claimable should equal approved");
    assertEq(vault.pendingRedeemShares(shareholder1), shares - halfShares, "remaining should stay pending");
  }

  function test_ApproveRedemption_UpdatesTotalClaimableRedeemAssets() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    uint256 totalBefore = vault.totalClaimableRedeemAssets();

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);
    assertEq(vault.totalClaimableRedeemAssets(), totalBefore + claimableAssets, "global counter mismatch");
  }

  function test_NavDeductsClaimableRedeemAssets() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    uint256 navAfterRequest = vault.lastNav();

    // Approve — now totalClaimableRedeemAssets increases
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);

    // Recompute NAV — should be reduced by claimableRedeemAssets
    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    vm.prank(manager);
    vault.updateNav(NAV_BATCH_SIZE);

    assertEq(vault.lastNav(), navAfterRequest - claimableAssets, "NAV should deduct claimable redeem assets");
  }

  function test_ApproveRedemption_Reverts_WhenNoPending() public {
    _setupInitialNav();

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NoPendingRedeem.selector));
    vault.approveRedemption(shareholder1, DEFAULT_REDEEM_SHARES);
  }

  function test_ApproveRedemption_Reverts_WhenExceedsPending() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsPending.selector));
    vault.approveRedemption(shareholder1, shares + 1);
  }

  function test_ApproveRedemption_Reverts_WhenZeroShares() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ZeroAmount.selector));
    vault.approveRedemption(shareholder1, 0);
  }

  function test_ApproveRedemption_Reverts_WhenStaleNav() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    timeNow += uint48(MAX_NAV_AGE + 1);
    vm.warp(uint256(timeNow));

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.StaleNav.selector));
    vault.approveRedemption(shareholder1, shares);
  }

  function test_ApproveRedemption_Reverts_WhenNotManager() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        shareholder1,
        investorManagerRole
      )
    );
    vault.approveRedemption(shareholder1, shares);
  }

  // ──────── redeem (claim by shares) ────────

  function test_Redeem_BurnsSharesAndTransfersAssets() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    uint256 totalSupplyBeforeApproval = shareToken.totalSupply();

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    // Shares are burned at approval time
    assertEq(shareToken.totalSupply(), totalSupplyBeforeApproval - shares, "shares should be burned at approval");

    uint256 claimableShares = vault.maxRedeem(shareholder1);
    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);
    uint256 usdcBefore = usdc.balanceOf(shareholder1);

    vm.prank(shareholder1);
    uint256 assets = vault.redeem(claimableShares, shareholder1, shareholder1);

    // Claim only transfers assets, no further totalSupply change
    assertEq(shareToken.totalSupply(), totalSupplyBeforeApproval - shares, "totalSupply unchanged during claim");
    assertEq(usdc.balanceOf(shareholder1), usdcBefore + assets, "USDC should be transferred");
    assertEq(assets, claimableAssets, "assets should equal full claimable amount");
  }

  function test_Redeem_EmitsWithdrawEvent() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);
    uint256 expectedAssets = vault.claimableRedeemAssets(shareholder1);

    vm.prank(shareholder1);
    vm.expectEmit(true, true, true, true);
    emit IERC7575.Withdraw(shareholder1, shareholder1, shareholder1, expectedAssets, claimableShares);
    vault.redeem(claimableShares, shareholder1, shareholder1);
  }

  function test_Redeem_WithdrawEvent_SenderIsMsgSender() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, true);

    uint256 claimableShares = vault.maxRedeem(shareholder1);
    uint256 expectedAssets = vault.claimableRedeemAssets(shareholder1);

    // Operator claims — sender is msg.sender (operatorAddr)
    vm.prank(operatorAddr);
    vm.expectEmit(true, true, true, true);
    emit IERC7575.Withdraw(operatorAddr, shareholder1, shareholder1, expectedAssets, claimableShares);
    vault.redeem(claimableShares, shareholder1, shareholder1);
  }

  function test_Redeem_PartialClaim(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, loanValuation);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);
    vm.assume(claimableShares >= 2);
    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);
    uint256 halfShares = claimableShares / 2;
    uint256 expectedAssetsClaimed = (halfShares * claimableAssets) / claimableShares;

    // Claim half
    vm.prank(shareholder1);
    uint256 assetsClaimed = vault.redeem(halfShares, shareholder1, shareholder1);

    assertEq(assetsClaimed, expectedAssetsClaimed, "assets claimed mismatch");
    assertEq(vault.maxRedeem(shareholder1), claimableShares - halfShares, "remaining shares mismatch");
    assertEq(
      vault.claimableRedeemAssets(shareholder1),
      claimableAssets - expectedAssetsClaimed,
      "remaining assets mismatch"
    );
  }

  function test_Redeem_FullClaim_LeavesNoDust() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);

    // Claim in 3 chunks: should leave no dust
    uint256 chunk = claimableShares / 3;
    vm.prank(shareholder1);
    vault.redeem(chunk, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vault.redeem(chunk, shareholder1, shareholder1);

    uint256 remaining = vault.maxRedeem(shareholder1);
    vm.prank(shareholder1);
    vault.redeem(remaining, shareholder1, shareholder1);

    assertEq(vault.claimableRedeemShares(shareholder1), 0, "claimable shares should be 0");
    assertEq(vault.claimableRedeemAssets(shareholder1), 0, "claimable assets should be 0");
  }

  function test_Redeem_DecrementsTotalClaimableRedeemAssets() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 totalBefore = vault.totalClaimableRedeemAssets();
    uint256 claimableShares = vault.maxRedeem(shareholder1);

    vm.prank(shareholder1);
    uint256 assets = vault.redeem(claimableShares, shareholder1, shareholder1);

    assertEq(vault.totalClaimableRedeemAssets(), totalBefore - assets, "global counter not decremented");
  }

  function test_Redeem_SendsToReceiver_WhenDifferentFromController() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);
    uint256 usdc2Before = usdc.balanceOf(shareholder2);

    vm.prank(shareholder1);
    uint256 assets = vault.redeem(claimableShares, shareholder2, shareholder1);

    assertEq(usdc.balanceOf(shareholder2), usdc2Before + assets, "USDC should go to receiver");
  }

  function test_Redeem_AllowedByOperator() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, true);

    uint256 claimableShares = vault.maxRedeem(shareholder1);
    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);

    vm.prank(operatorAddr);
    uint256 assets = vault.redeem(claimableShares, shareholder1, shareholder1);
    assertEq(assets, claimableAssets, "operator should receive all claimable assets");
  }

  function test_Redeem_AlwaysAvailable_EvenDuringNavComputation() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    // Start a new NAV computation
    uint64 id2 = _createActiveLoan(25_000e6);
    _transferLoanToVault(id2);

    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    vm.prank(manager);
    vault.updateNav(1);
    assertTrue(vault.navStart() > 0, "NAV computation should be in progress");

    // Claim should still work — price was locked at approval time
    uint256 claimableShares = vault.maxRedeem(shareholder1);
    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);
    vm.prank(shareholder1);
    uint256 assets = vault.redeem(claimableShares, shareholder1, shareholder1);
    assertEq(assets, claimableAssets, "claim should succeed during NAV computation");
  }

  function test_Redeem_Reverts_WhenNoClaimable() public {
    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NoClaimableRedeem.selector));
    vault.redeem(DEFAULT_REDEEM_SHARES, shareholder1, shareholder1);
  }

  function test_Redeem_Reverts_WhenExceedsClaimable() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsClaimable.selector));
    vault.redeem(claimableShares + 1, shareholder1, shareholder1);
  }

  function test_Redeem_Reverts_WhenUnauthorized() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);

    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.Unauthorized.selector));
    vault.redeem(claimableShares, shareholder1, shareholder1);
  }

  function test_Redeem_Reverts_WhenControllerNotShareholder() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);

    // Revoke shareholder1 role after approval
    shareToken.revokeRole(shareToken.SHAREHOLDER_ROLE(), shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.redeem(claimableShares, shareholder1, shareholder1);
  }

  function test_Redeem_Reverts_WhenReceiverNotShareholder() public {
    uint256 shares = _setupShareholderWithShares();
    address nonShareholder = makeAddr("nonShareholder");

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.redeem(claimableShares, nonShareholder, shareholder1);
  }

  function test_Redeem_Reverts_WhenReceiverIsVault() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.maxRedeem(shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InvalidReceiver.selector));
    vault.redeem(claimableShares, address(vault), shareholder1);
  }

  function test_Redeem_Reverts_WhenInsufficientVaultUSDC() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    // Drain the vault's USDC (simulate all cash deployed into loans)
    uint256 vaultUsdcBalance = usdc.balanceOf(address(vault));
    vm.prank(address(vault));
    usdc.transfer(address(1), vaultUsdcBalance);

    uint256 claimableShares = vault.maxRedeem(shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(stdError.arithmeticError);
    vault.redeem(claimableShares, shareholder1, shareholder1);
  }

  // ──────── cancelRedeemRequest ────────

  function test_CancelRedeem_ReturnsSharesToReceiver() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    assertEq(shareToken.balanceOf(shareholder1), 0, "shares should be locked");

    vm.prank(shareholder1);
    uint256 returned = vault.cancelRedeemRequest(shareholder1, shareholder1);

    assertEq(returned, shares, "returned amount mismatch");
    assertEq(shareToken.balanceOf(shareholder1), shares, "shares not returned");
    assertEq(vault.pendingRedeemShares(shareholder1), 0, "pending should be cleared");
  }

  function test_CancelRedeem_EmitsEvent() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.RedeemRequestCancelled(shareholder1, shareholder1, shares);
    vault.cancelRedeemRequest(shareholder1, shareholder1);
  }

  function test_CancelRedeem_SendsToReceiver_WhenDifferentFromController() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(shareholder1);
    uint256 returned = vault.cancelRedeemRequest(shareholder1, shareholder2);

    assertEq(returned, shares);
    assertEq(shareToken.balanceOf(shareholder2), shares, "shares should go to receiver");
    assertEq(shareToken.balanceOf(shareholder1), 0, "controller should have no shares");
  }

  function test_CancelRedeem_AfterPartialApproval() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    uint256 halfShares = shares / 2;

    // Approve half
    uint256 navAtApproval = vault.lastNav();
    uint256 supplyAtApproval = shareToken.totalSupply();
    vm.prank(manager);
    vault.approveRedemption(shareholder1, halfShares);

    uint256 remainingPending = vault.pendingRedeemShares(shareholder1);
    assertTrue(remainingPending > 0, "should have remaining pending");

    // Cancel the remaining pending
    vm.prank(shareholder1);
    uint256 returned = vault.cancelRedeemRequest(shareholder1, shareholder1);

    assertEq(returned, remainingPending, "returned mismatch");
    assertEq(vault.pendingRedeemShares(shareholder1), 0, "pending should be cleared");

    // Claimable from first approval should be untouched
    uint256 expectedClaimableAssets = vault.claimableRedeemAssets(shareholder1);
    assertEq(vault.claimableRedeemShares(shareholder1), halfShares, "claimable shares should remain");
    assertEq(
      expectedClaimableAssets,
      (halfShares * navAtApproval) / supplyAtApproval,
      "claimable assets should remain"
    );
  }

  function test_CancelRedeem_AllowedByOperator() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, true);

    vm.prank(operatorAddr);
    uint256 returned = vault.cancelRedeemRequest(shareholder1, shareholder1);
    assertEq(returned, shares);
  }

  function test_CancelRedeem_AlwaysAvailable_EvenDuringNavComputation() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // Start a NAV computation that doesn't finalize
    uint64 id2 = _createActiveLoan(25_000e6);
    _transferLoanToVault(id2);

    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    vm.prank(manager);
    vault.updateNav(1);
    assertTrue(vault.navStart() > 0, "NAV computation should be in progress");

    vm.prank(shareholder1);
    uint256 returned = vault.cancelRedeemRequest(shareholder1, shareholder1);
    assertEq(returned, shares);
  }

  function test_CancelRedeem_Reverts_WhenNoPending() public {
    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NoPendingRedeem.selector));
    vault.cancelRedeemRequest(shareholder1, shareholder1);
  }

  function test_CancelRedeem_Reverts_WhenUnauthorized() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.Unauthorized.selector));
    vault.cancelRedeemRequest(shareholder1, shareholder1);
  }

  function test_CancelRedeem_Reverts_WhenControllerNotShareholder() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // Revoke shareholder1 role after request
    shareToken.revokeRole(shareToken.SHAREHOLDER_ROLE(), shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.cancelRedeemRequest(shareholder1, shareholder1);
  }

  function test_CancelRedeem_Reverts_WhenReceiverIsVault() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InvalidReceiver.selector));
    vault.cancelRedeemRequest(shareholder1, address(vault));
  }

  // ──────── Multiple Controllers ────────

  function test_MultipleControllers_IndependentRedeems(uint256 amount1, uint256 amount2, uint256 loanValuation) public {
    amount1 = bound(amount1, 1e6, MAX_FUZZ_AMOUNT / 2);
    amount2 = bound(amount2, 1e6, MAX_FUZZ_AMOUNT / 2);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(amount1);
    _assumeNonZeroShares(amount2);
    _fundShareholder(shareholder1, amount1);
    _fundShareholder(shareholder2, amount2);

    uint256 shares1 = _depositAndClaim(shareholder1, amount1);
    uint256 shares2 = _depositAndClaim(shareholder2, amount2);

    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);
    vm.prank(shareholder2);
    shareToken.approve(address(vault), type(uint256).max);

    vm.prank(shareholder1);
    vault.requestRedeem(shares1, shareholder1, shareholder1);

    vm.prank(shareholder2);
    vault.requestRedeem(shares2, shareholder2, shareholder2);

    assertEq(vault.pendingRedeemShares(shareholder1), shares1);
    assertEq(vault.pendingRedeemShares(shareholder2), shares2);

    uint256 nav1 = vault.lastNav();
    uint256 supply1 = shareToken.totalSupply();
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares1);
    uint256 expectedAssets1 = (shares1 * nav1) / supply1;

    uint256 nav2 = vault.lastNav();
    uint256 supply2 = shareToken.totalSupply();
    vm.prank(manager);
    vault.approveRedemption(shareholder2, shares2);
    uint256 expectedAssets2 = (shares2 * nav2) / supply2;

    assertEq(vault.claimableRedeemAssets(shareholder1), expectedAssets1, "shareholder1 assets mismatch");
    assertEq(vault.claimableRedeemAssets(shareholder2), expectedAssets2, "shareholder2 assets mismatch");
  }

  // ──────── View Functions ────────

  function test_PendingRedeemRequest_ReturnsCorrectValue() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    assertEq(vault.pendingRedeemRequest(0, shareholder1), shares);
  }

  function test_ClaimableRedeemRequest_ReturnsCorrectValue() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimable = vault.claimableRedeemRequest(0, shareholder1);
    assertEq(claimable, shares, "claimableRedeemRequest should return maxRedeem");
  }

  function test_MaxRedeem_ReturnsZero_WhenNoClaimable() public view {
    assertEq(vault.maxRedeem(shareholder1), 0);
  }

  function test_MaxRedeem_ReturnsClaimableShares() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    assertEq(vault.maxRedeem(shareholder1), shares);
  }
}
