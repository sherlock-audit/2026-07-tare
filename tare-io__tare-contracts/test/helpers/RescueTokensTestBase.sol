// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../mocks/USDC.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IRescuable} from "src/misc/interfaces/IRescuable.sol";

/// @title RescueTokensTestBase
/// @notice Base contract providing parameterized rescue test helpers for ERC20, ERC721, and recovery wallet
abstract contract RescueTokensTestBase is Test {
  address internal _recoveryAddress = makeAddr("recoveryAddress");

  // ========== Recovery Wallet Helpers ==========

  /// @notice Tests successful setRecoveryAddress by guardian
  function _testSetRecoveryAddressSuccess(address contractAddr, address guardian) internal {
    address newRecoveryAddress = makeAddr("newRecoveryAddress");
    vm.prank(guardian);
    vm.expectEmit(true, false, false, false, contractAddr);
    emit IRescuable.RecoveryAddressSet(newRecoveryAddress);
    IRescuable(contractAddr).setRecoveryAddress(newRecoveryAddress);
    assertEq(IRescuable(contractAddr).recoveryAddress(), newRecoveryAddress, "recovery address not updated");
  }

  /// @notice Tests that setRecoveryAddress reverts for non-guardian
  function _testSetRecoveryAddressRevertsIfNotGuardian(
    address contractAddr,
    address nonGuardian,
    bytes32 guardianRole
  ) internal {
    vm.prank(nonGuardian);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonGuardian, guardianRole)
    );
    IRescuable(contractAddr).setRecoveryAddress(makeAddr("newRecoveryAddress"));
  }

  /// @notice Tests that setRecoveryAddress reverts for zero address
  function _testSetRecoveryAddressRevertsIfZeroAddress(address contractAddr, address guardian) internal {
    vm.prank(guardian);
    vm.expectRevert(IRescuable.InvalidRecoveryAddress.selector);
    IRescuable(contractAddr).setRecoveryAddress(address(0));
  }

  // ========== ERC20 Rescue Helpers ==========

  /// @notice Tests successful ERC20 token rescue by guardian
  function _testRescueERC20TokensSuccess(address contractAddr, address guardian) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    uint256 wronglySentAmount = 1000e6;
    tokenToRescue.mint(contractAddr, wronglySentAmount);

    address recoveryAddress = IRescuable(contractAddr).recoveryAddress();
    uint256 walletBalanceBefore = tokenToRescue.balanceOf(recoveryAddress);

    vm.prank(guardian);
    uint256 rescued = IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), wronglySentAmount);

    assertEq(rescued, wronglySentAmount, "rescued amount mismatch");
    assertEq(tokenToRescue.balanceOf(contractAddr), 0, "contract balance not zero");
    assertEq(
      tokenToRescue.balanceOf(recoveryAddress),
      walletBalanceBefore + wronglySentAmount,
      "wallet balance mismatch"
    );
  }

  /// @notice Tests that non-guardian cannot rescue ERC20 tokens
  function _testRescueERC20TokensRevertsIfNotGuardian(
    address contractAddr,
    address nonGuardian,
    bytes32 guardianRole
  ) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    tokenToRescue.mint(contractAddr, 1000e6);

    vm.prank(nonGuardian);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonGuardian, guardianRole)
    );
    IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), 1000e6);
  }

  /// @notice Tests rescue with zero balance returns 0
  function _testRescueERC20TokensZeroBalance(address contractAddr, address guardian) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    assertEq(tokenToRescue.balanceOf(contractAddr), 0, "setup: should have zero balance");

    address recoveryAddress = IRescuable(contractAddr).recoveryAddress();
    uint256 walletBalanceBefore = tokenToRescue.balanceOf(recoveryAddress);

    vm.prank(guardian);
    uint256 rescued = IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), 1000e6);
    assertEq(rescued, 0, "should return 0 when no tokens to rescue");
    assertEq(tokenToRescue.balanceOf(recoveryAddress), walletBalanceBefore, "wallet balance should not change");
  }

  /// @notice Tests rescuing a partial amount of tokens
  function _testRescueERC20TokensPartialAmount(address contractAddr, address guardian) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    uint256 totalAmount = 1000e6;
    uint256 rescueAmount = 400e6;
    tokenToRescue.mint(contractAddr, totalAmount);

    address recoveryAddress = IRescuable(contractAddr).recoveryAddress();
    uint256 walletBalanceBefore = tokenToRescue.balanceOf(recoveryAddress);

    vm.prank(guardian);
    uint256 rescued = IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), rescueAmount);

    assertEq(rescued, rescueAmount, "rescued amount mismatch");
    assertEq(tokenToRescue.balanceOf(contractAddr), totalAmount - rescueAmount, "contract balance mismatch");
    assertEq(tokenToRescue.balanceOf(recoveryAddress), walletBalanceBefore + rescueAmount, "wallet balance mismatch");
  }

  /// @notice Tests that requesting more than balance rescues full balance
  function _testRescueERC20TokensExceedsBalance(address contractAddr, address guardian) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    uint256 totalAmount = 1000e6;
    uint256 requestedAmount = 2000e6;
    tokenToRescue.mint(contractAddr, totalAmount);

    address recoveryAddress = IRescuable(contractAddr).recoveryAddress();
    uint256 walletBalanceBefore = tokenToRescue.balanceOf(recoveryAddress);

    vm.prank(guardian);
    uint256 rescued = IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), requestedAmount);

    assertEq(rescued, totalAmount, "should rescue full balance when amount exceeds");
    assertEq(tokenToRescue.balanceOf(contractAddr), 0, "contract balance should be zero");
    assertEq(tokenToRescue.balanceOf(recoveryAddress), walletBalanceBefore + totalAmount, "wallet balance mismatch");
  }

  /// @notice Tests that an admin (non-guardian) cannot rescue tokens
  function _testRescueERC20TokensRevertsIfAdminNotGuardian(
    address contractAddr,
    address adminAddr,
    bytes32 guardianRole
  ) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    tokenToRescue.mint(contractAddr, 1000e6);

    vm.prank(adminAddr);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, adminAddr, guardianRole)
    );
    IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), 1000e6);
  }

  /// @notice Tests requesting zero amount returns 0 and transfers nothing
  function _testRescueERC20TokensZeroAmount(address contractAddr, address guardian) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    uint256 totalAmount = 1000e6;
    tokenToRescue.mint(contractAddr, totalAmount);

    address wallet = IRescuable(contractAddr).recoveryAddress();
    uint256 walletBalanceBefore = tokenToRescue.balanceOf(wallet);

    vm.prank(guardian);
    uint256 rescued = IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), 0);

    assertEq(rescued, 0, "should return 0 when requesting 0");
    assertEq(tokenToRescue.balanceOf(contractAddr), totalAmount, "contract balance should be unchanged");
    assertEq(tokenToRescue.balanceOf(wallet), walletBalanceBefore, "wallet balance should not change");
  }

  /// @notice Tests multiple sequential partial rescues
  function _testRescueERC20TokensMultipleRescues(address contractAddr, address guardian) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    uint256 totalAmount = 1000e6;
    tokenToRescue.mint(contractAddr, totalAmount);

    address wallet = IRescuable(contractAddr).recoveryAddress();
    uint256 walletBalanceBefore = tokenToRescue.balanceOf(wallet);

    vm.prank(guardian);
    uint256 rescued1 = IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), 300e6);
    assertEq(rescued1, 300e6, "first rescue amount mismatch");

    vm.prank(guardian);
    uint256 rescued2 = IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), 500e6);
    assertEq(rescued2, 500e6, "second rescue amount mismatch");

    assertEq(tokenToRescue.balanceOf(contractAddr), 200e6, "contract should have remaining balance");
    assertEq(tokenToRescue.balanceOf(wallet), walletBalanceBefore + 800e6, "wallet should have received both rescues");
  }

  /// @notice Tests ERC20 rescue reverts when recovery wallet is not set
  function _testRescueERC20TokensRevertsIfRecoveryAddressNotSet(address contractAddr, address guardian) internal {
    MockUSDC tokenToRescue = new MockUSDC();
    tokenToRescue.mint(contractAddr, 1000e6);

    // Overwrite recoveryAddress storage slot to address(0) for this test
    // slot 0 in Rescuable is recoveryAddress (after AccessControl storage)
    // Instead, we test with a fresh contract that hasn't had recoveryAddress set
    // This helper should be called on a contract where recoveryAddress == address(0)
    vm.prank(guardian);
    vm.expectRevert(IRescuable.RecoveryAddressNotSet.selector);
    IRescuable(contractAddr).rescueERC20Tokens(address(tokenToRescue), 1000e6);
  }

  // ========== ERC721 Rescue Helpers ==========

  /// @notice Tests successful ERC721 token rescue by guardian
  function _testRescueERC721TokensSuccess(address contractAddr, address guardian) internal {
    MockERC721 nft = new MockERC721();
    uint256 tokenId = 42;
    nft.mint(contractAddr, tokenId);

    address wallet = IRescuable(contractAddr).recoveryAddress();

    vm.prank(guardian);
    vm.expectEmit(true, true, true, false, contractAddr);
    emit IRescuable.ERC721TokensRescued(address(nft), tokenId, wallet);
    IRescuable(contractAddr).rescueERC721Tokens(address(nft), tokenId);

    assertEq(nft.ownerOf(tokenId), wallet, "NFT not sent to recovery wallet");
  }

  /// @notice Tests that non-guardian cannot rescue ERC721 tokens
  function _testRescueERC721TokensRevertsIfNotGuardian(
    address contractAddr,
    address nonGuardian,
    bytes32 guardianRole
  ) internal {
    MockERC721 nft = new MockERC721();
    uint256 tokenId = 42;
    nft.mint(contractAddr, tokenId);

    vm.prank(nonGuardian);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonGuardian, guardianRole)
    );
    IRescuable(contractAddr).rescueERC721Tokens(address(nft), tokenId);
  }

  /// @notice Tests ERC721 rescue reverts when recovery wallet is not set
  function _testRescueERC721TokensRevertsIfRecoveryAddressNotSet(address contractAddr, address guardian) internal {
    MockERC721 nft = new MockERC721();
    uint256 tokenId = 42;
    nft.mint(contractAddr, tokenId);

    vm.prank(guardian);
    vm.expectRevert(IRescuable.RecoveryAddressNotSet.selector);
    IRescuable(contractAddr).rescueERC721Tokens(address(nft), tokenId);
  }

  /// @notice Tests rescuing multiple ERC721 tokens sequentially
  function _testRescueERC721TokensMultiple(address contractAddr, address guardian) internal {
    MockERC721 nft = new MockERC721();
    nft.mint(contractAddr, 1);
    nft.mint(contractAddr, 2);
    nft.mint(contractAddr, 3);

    address wallet = IRescuable(contractAddr).recoveryAddress();

    vm.startPrank(guardian);
    IRescuable(contractAddr).rescueERC721Tokens(address(nft), 1);
    IRescuable(contractAddr).rescueERC721Tokens(address(nft), 2);
    IRescuable(contractAddr).rescueERC721Tokens(address(nft), 3);
    vm.stopPrank();

    assertEq(nft.ownerOf(1), wallet, "NFT 1 not rescued");
    assertEq(nft.ownerOf(2), wallet, "NFT 2 not rescued");
    assertEq(nft.ownerOf(3), wallet, "NFT 3 not rescued");
  }

  /// @notice Tests that admin (non-guardian) cannot rescue ERC721 tokens
  function _testRescueERC721TokensRevertsIfAdminNotGuardian(
    address contractAddr,
    address adminAddr,
    bytes32 guardianRole
  ) internal {
    MockERC721 nft = new MockERC721();
    uint256 tokenId = 42;
    nft.mint(contractAddr, tokenId);

    vm.prank(adminAddr);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, adminAddr, guardianRole)
    );
    IRescuable(contractAddr).rescueERC721Tokens(address(nft), tokenId);
  }
}
