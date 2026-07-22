// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {TrustedSpender} from "../contracts/TrustedSpender.sol";
import {ITrustedSpender} from "../contracts/interfaces/ITrustedSpender.sol";
import {MockUSDC} from "../test/mocks/USDC.sol";
import {MockERC721} from "../test/mocks/MockERC721.sol";
import {NonReceiverAccount} from "../test/mocks/NonReceiverAccount.sol";
import {RescueTokensTestBase} from "./helpers/RescueTokensTestBase.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract TrustedSpenderTest is Test, RescueTokensTestBase {
  TrustedSpender public spender;
  MockUSDC public usdc;

  // guardian is the initial owner passed to the constructor
  address public guardian = makeAddr("guardian");
  address public safeAccount = address(0x1000);
  address public delegate1 = address(0x2000);
  address public delegate2 = address(0x3000);
  address public recipient = address(0x4000);
  address public payroll = address(0x5000);
  address public admin = address(0x6000);

  uint48 internal constant NO_EXPIRY = type(uint48).max;
  uint48 internal constant FUTURE = uint48(2_000_000_000); // ~2033
  uint48 internal timeNow;

  bytes32 internal guardianRole;

  function setUp() public {
    // Deploy contracts
    spender = new TrustedSpender(guardian, _recoveryAddress);
    usdc = new MockUSDC();
    timeNow = 1_700_000_000;
    vm.warp(uint256(timeNow));

    guardianRole = spender.GUARDIAN_ROLE();

    bytes32 adminRole = spender.ADMIN_ROLE();
    vm.prank(guardian);
    spender.grantRole(adminRole, admin);

    // Setup Safe account with USDC
    usdc.mint(safeAccount, 100000e6); // 100,000 USDC

    // Safe approves TrustedSpender to spend its USDC
    vm.prank(safeAccount);
    usdc.approve(address(spender), type(uint256).max);

    // Give delegates some ETH for gas
    vm.deal(delegate1, 1 ether);
    vm.deal(delegate2, 1 ether);
  }

  function test_AddDelegate() public {
    // Safe adds delegate
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    assertTrue(spender.isDelegate(safeAccount, delegate1));
    assertFalse(spender.isDelegate(safeAccount, delegate2));
  }

  function test_AddDelegateAsAdmin_Reverts() public {
    // Admin (non-guardian) cannot add delegate — restricted to safeOrGuardian
    vm.prank(admin);
    vm.expectRevert(ITrustedSpender.UnauthorizedCaller.selector);
    spender.addDelegate(safeAccount, delegate1);
  }

  function test_AddDelegateAsGuardian() public {
    // Guardian adds delegate for Safe
    vm.prank(guardian);
    spender.addDelegate(safeAccount, delegate1);

    assertTrue(spender.isDelegate(safeAccount, delegate1));
  }

  function test_RemoveDelegateByAdmin() public {
    // Admin can still remove delegates (defensive action)
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    assertTrue(spender.isDelegate(safeAccount, delegate1));

    vm.prank(admin);
    spender.removeDelegate(safeAccount, delegate1);
    assertFalse(spender.isDelegate(safeAccount, delegate1));
  }

  function test_SetAllowanceAsAdmin_Reverts() public {
    // Admin (non-guardian) cannot set allowance — restricted to safeOrGuardian
    vm.prank(admin);
    vm.expectRevert(ITrustedSpender.UnauthorizedCaller.selector);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);
  }

  function test_SetAllowanceAsGuardian() public {
    // Guardian can set allowance for a Safe
    vm.prank(guardian);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);

    (uint256 amount, uint48 validUntil) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, 1000e6);
    assertEq(validUntil, NO_EXPIRY);
  }

  function test_RemoveDelegate() public {
    // Add delegate
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    assertTrue(spender.isDelegate(safeAccount, delegate1));

    // Remove delegate
    vm.prank(safeAccount);
    spender.removeDelegate(safeAccount, delegate1);
    assertFalse(spender.isDelegate(safeAccount, delegate1));
  }

  function test_SetAllowance() public {
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);

    (uint256 amount, uint48 validUntil) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, 1000e6);
    assertEq(validUntil, NO_EXPIRY);
  }

  function test_SetUnlimitedAllowance() public {
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, type(uint208).max, NO_EXPIRY);

    (uint256 amount, uint48 validUntil) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, type(uint208).max);
    assertEq(validUntil, NO_EXPIRY);
  }

  function test_ExecuteTransfer(uint48 validUntil, uint208 transferAmount) public {
    validUntil = uint48(bound(validUntil, timeNow + 1, type(uint48).max));
    transferAmount = uint208(bound(transferAmount, 1, 1000e6));

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, validUntil);

    uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
    uint256 safeBalanceBefore = usdc.balanceOf(safeAccount);

    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, transferAmount);

    assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + transferAmount);
    assertEq(usdc.balanceOf(safeAccount), safeBalanceBefore - transferAmount);

    (uint256 remaining, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(remaining, 1000e6 - transferAmount);
  }

  function test_ExecuteTransferWithUnlimitedAllowance() public {
    // Setup: Add delegate and set unlimited allowance
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, type(uint208).max, NO_EXPIRY);

    // Execute multiple transfers
    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 1000e6);

    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 2000e6);

    // Allowance should still be max
    (uint256 amount, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, type(uint208).max);
  }

  function test_RevertExecuteTransferNotDelegate() public {
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);

    // Try to execute without being delegate
    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.NotADelegate.selector);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 100e6);
  }

  function test_RevertInsufficientAllowance(uint208 allowanceAmount, uint256 transferAmount) public {
    allowanceAmount = uint208(bound(allowanceAmount, 0, 99_999e6));
    transferAmount = bound(transferAmount, uint256(allowanceAmount) + 1, 100_000e6);

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, allowanceAmount, NO_EXPIRY);

    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.InsufficientAllowance.selector);
    spender.executeTransfer(address(usdc), safeAccount, recipient, transferAmount);
  }

  function test_MultipleDelegatesShareAllowance(uint48 validUntil) public {
    validUntil = uint48(bound(validUntil, timeNow + 1, type(uint48).max));

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate2);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, validUntil);

    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 400e6);

    vm.prank(delegate2);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 300e6);

    (uint256 remaining, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(remaining, 300e6);
  }

  function test_RouteIsolation(uint48 validUntil) public {
    validUntil = uint48(bound(validUntil, timeNow + 1, type(uint48).max));

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, validUntil);
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, payroll, 500e6, validUntil);

    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 300e6);

    (uint256 recipientAmount, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    (uint256 payrollAmount, ) = spender.getAllowance(address(usdc), safeAccount, payroll);
    assertEq(recipientAmount, 700e6);
    assertEq(payrollAmount, 500e6);
  }

  function test_Pause() public {
    // Setup
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);

    // Pause contract
    vm.prank(admin);
    spender.pause();
    assertTrue(spender.paused());

    // Try to execute transfer while paused
    vm.prank(delegate1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 100e6);

    // Unpause
    vm.prank(guardian);
    spender.unpause();
    assertFalse(spender.paused());

    // Now transfer should work
    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 100e6);
  }

  function test_SafeCanStillSetAllowanceWhilePaused() public {
    vm.prank(admin);
    spender.pause();

    // Safe can still set allowance
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);

    (uint256 amount, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, 1000e6);
  }

  function test_OnlyAdminCanPause() public {
    address randomUser = address(0x9999);

    vm.prank(randomUser);
    vm.expectRevert(); // Auth error
    spender.pause();
  }

  function test_OnlyGuardianCanUnpause() public {
    vm.prank(guardian);
    spender.pause();
    assertTrue(spender.paused());

    // Admin cannot unpause
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, guardianRole)
    );
    spender.unpause();

    // Random user cannot unpause
    address randomUser2 = address(0x9999);
    vm.prank(randomUser2);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser2, guardianRole)
    );
    spender.unpause();

    // Guardian can unpause
    vm.prank(guardian);
    spender.unpause();
    assertFalse(spender.paused());
  }

  function test_UnauthorizedCannotAddDelegate() public {
    address randomUser = address(0x9999);

    vm.prank(randomUser);
    vm.expectRevert(ITrustedSpender.UnauthorizedCaller.selector);
    spender.addDelegate(safeAccount, delegate1);
  }

  function test_UnauthorizedCannotSetAllowance() public {
    address randomUser = address(0x9999);

    vm.prank(randomUser);
    vm.expectRevert(ITrustedSpender.UnauthorizedCaller.selector);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);
  }

  function test_AllowZeroAmountTransfer() public {
    // Setup: Add delegate and set allowance
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);

    // Execute zero transfer - should succeed
    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 0);

    // Allowance should remain unchanged
    (uint256 amount, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, 1000e6);
  }

  function test_RevertZeroAddresses() public {
    // Use guardian (who passes onlyAdmin) to test zero address validation
    vm.expectRevert(ITrustedSpender.ZeroAddress.selector);
    vm.prank(guardian);
    spender.setAllowance(address(0), safeAccount, recipient, 1000e6, NO_EXPIRY);

    vm.expectRevert(ITrustedSpender.ZeroAddress.selector);
    vm.prank(guardian);
    spender.setAllowance(address(usdc), address(0), recipient, 1000e6, NO_EXPIRY);

    vm.expectRevert(ITrustedSpender.ZeroAddress.selector);
    vm.prank(guardian);
    spender.setAllowance(address(usdc), safeAccount, address(0), 1000e6, NO_EXPIRY);
  }

  function test_RevokeAllowanceBySettingToZero() public {
    // Setup delegate
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    // Set allowance to max
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, type(uint208).max, NO_EXPIRY);

    // Transfer should work
    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 100e6);

    // Revoke allowance by setting to zero
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 0, NO_EXPIRY);
    (uint256 amount, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, 0);

    // Transfer should now fail
    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.InsufficientAllowance.selector);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 100e6);
  }

  // ============================================
  // Pause Tests
  // ============================================

  function test_Pause_EmitsEvent() public {
    vm.prank(admin);
    vm.expectEmit(true, false, false, true);
    emit Paused(admin);
    spender.pause();
  }

  function test_Unpause_EmitsEvent() public {
    vm.prank(admin);
    spender.pause();

    vm.prank(guardian);
    vm.expectEmit(true, false, false, true);
    emit Unpaused(guardian);
    spender.unpause();
  }

  function test_GuardianCanPause() public {
    vm.prank(guardian);
    spender.pause();
    assertTrue(spender.paused());
  }

  function test_AddDelegate_WorksWhilePaused() public {
    vm.prank(admin);
    spender.pause();

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    assertTrue(spender.isDelegate(safeAccount, delegate1));
  }

  function test_RemoveDelegate_WorksWhilePaused() public {
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(admin);
    spender.pause();

    vm.prank(safeAccount);
    spender.removeDelegate(safeAccount, delegate1);
    assertFalse(spender.isDelegate(safeAccount, delegate1));
  }

  function test_Pause_RevertsWhenAlreadyPaused() public {
    vm.prank(admin);
    spender.pause();

    vm.prank(admin);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    spender.pause();
  }

  function test_Unpause_RevertsWhenNotPaused() public {
    vm.prank(guardian);
    vm.expectRevert(Pausable.ExpectedPause.selector);
    spender.unpause();
  }

  event Paused(address account);
  event Unpaused(address account);

  // ============================================
  // Validity (validUntil) Tests
  // ============================================

  function test_SetAllowanceWithValidUntil() public {
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, FUTURE);

    (uint256 amount, uint48 validUntil) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, 1000e6);
    assertEq(validUntil, FUTURE);
  }

  function test_RevertSetAllowanceZeroValidUntil() public {
    vm.prank(safeAccount);
    vm.expectRevert(ITrustedSpender.InvalidAllowanceDeadline.selector);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, 0);
  }

  function test_RevertSetAllowancePastValidUntil() public {
    vm.prank(safeAccount);
    vm.expectRevert(ITrustedSpender.InvalidAllowanceDeadline.selector);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, timeNow - 1);
  }

  function test_RevertSetAllowanceCurrentTimestampValidUntil() public {
    vm.prank(safeAccount);
    vm.expectRevert(ITrustedSpender.InvalidAllowanceDeadline.selector);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, timeNow);
  }

  function test_ExecuteTransferBeforeExpiry() public {
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, FUTURE);

    // Warp to the expiry
    vm.warp(FUTURE);

    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 100e6);

    (uint256 remaining, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(remaining, 900e6);
  }

  function test_RevertExecuteTransferExpiredAllowance() public {
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, FUTURE);

    // Warp past expiry
    vm.warp(uint256(FUTURE) + 1);

    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.AllowanceExpired.selector);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 100e6);
  }

  function test_NoExpiryAllowance() public {
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, NO_EXPIRY);

    // Warp far into the future
    vm.warp(type(uint48).max);

    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 100e6);

    (uint256 remaining, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(remaining, 900e6);
  }

  function test_UnlimitedAmountWithValidUntil() public {
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, type(uint208).max, FUTURE);

    vm.prank(delegate1);
    spender.executeTransfer(address(usdc), safeAccount, recipient, 5000e6);

    (uint256 amount, ) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, type(uint208).max);
  }

  function test_SetAllowanceOverwritesPreviousValidUntil() public {
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 1000e6, FUTURE);

    // Overwrite with different amount and validUntil
    uint48 newValidUntil = FUTURE + 1_000_000;
    vm.prank(safeAccount);
    spender.setAllowance(address(usdc), safeAccount, recipient, 2000e6, newValidUntil);

    (uint256 amount, uint48 validUntil) = spender.getAllowance(address(usdc), safeAccount, recipient);
    assertEq(amount, 2000e6);
    assertEq(validUntil, newValidUntil);
  }

  // ============================================
  // Rescue Token Tests
  // ============================================

  function test_rescueERC20Tokens_Success() public {
    _testRescueERC20TokensSuccess(address(spender), guardian);
  }

  function test_rescueERC20Tokens_RevertsIfNotGuardian() public {
    _testRescueERC20TokensRevertsIfNotGuardian(address(spender), delegate1, guardianRole);
  }

  function test_rescueERC20Tokens_ZeroBalance() public {
    _testRescueERC20TokensZeroBalance(address(spender), guardian);
  }

  function test_rescueERC20Tokens_RevertsIfAdminNotGuardian() public {
    _testRescueERC20TokensRevertsIfAdminNotGuardian(address(spender), admin, guardianRole);
  }

  function test_rescueERC20Tokens_PartialAmount() public {
    _testRescueERC20TokensPartialAmount(address(spender), guardian);
  }

  function test_rescueERC20Tokens_ExceedsBalance() public {
    _testRescueERC20TokensExceedsBalance(address(spender), guardian);
  }

  function test_rescueERC20Tokens_ZeroAmount() public {
    _testRescueERC20TokensZeroAmount(address(spender), guardian);
  }

  function test_rescueERC20Tokens_MultipleRescues() public {
    _testRescueERC20TokensMultipleRescues(address(spender), guardian);
  }

  function test_rescueERC721Tokens_Success() public {
    _testRescueERC721TokensSuccess(address(spender), guardian);
  }

  function test_rescueERC721Tokens_RevertsIfNotGuardian() public {
    _testRescueERC721TokensRevertsIfNotGuardian(address(spender), delegate1, guardianRole);
  }

  function test_rescueERC721Tokens_RevertsIfAdminNotGuardian() public {
    _testRescueERC721TokensRevertsIfAdminNotGuardian(address(spender), admin, guardianRole);
  }

  function test_rescueERC721Tokens_Multiple() public {
    _testRescueERC721TokensMultiple(address(spender), guardian);
  }

  function test_rescueERC20Tokens_RevertsWhenPaused() public {
    vm.prank(admin);
    spender.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    spender.rescueERC20Tokens(address(1), 1);
  }

  function test_rescueERC721Tokens_RevertsWhenPaused() public {
    vm.prank(admin);
    spender.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    spender.rescueERC721Tokens(address(1), 1);
  }

  function test_setRecoveryAddress_Success() public {
    _testSetRecoveryAddressSuccess(address(spender), guardian);
  }

  function test_setRecoveryAddress_RevertsIfNotGuardian() public {
    _testSetRecoveryAddressRevertsIfNotGuardian(address(spender), delegate1, guardianRole);
  }

  function test_setRecoveryAddress_RevertsIfZeroAddress() public {
    _testSetRecoveryAddressRevertsIfZeroAddress(address(spender), guardian);
  }

  // ============================================
  // NFT Allowance Tests
  // ============================================

  MockERC721 internal nft;

  function _setUpNft() internal returns (uint256 tokenId) {
    nft = new MockERC721();
    tokenId = 1;
    nft.mint(safeAccount, tokenId);
    vm.prank(safeAccount);
    nft.setApprovalForAll(address(spender), true);
  }

  function test_SetNFTAllowance_AsSafe() public {
    _setUpNft();
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);

    (bool allowed, uint48 validUntil) = spender.getNFTAllowance(address(nft), safeAccount, recipient);
    assertTrue(allowed);
    assertEq(validUntil, NO_EXPIRY);
    assertTrue(spender.isNFTTransferAllowed(address(nft), safeAccount, recipient));
  }

  function test_SetNFTAllowance_AsGuardian() public {
    _setUpNft();
    vm.prank(guardian);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);

    (bool allowed, ) = spender.getNFTAllowance(address(nft), safeAccount, recipient);
    assertTrue(allowed);
  }

  function test_SetNFTAllowance_AsAdmin_Reverts() public {
    _setUpNft();
    vm.prank(admin);
    vm.expectRevert(ITrustedSpender.UnauthorizedCaller.selector);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);
  }

  function test_SetNFTAllowance_AsEOA_Reverts() public {
    _setUpNft();
    address randomUser = address(0x9999);
    vm.prank(randomUser);
    vm.expectRevert(ITrustedSpender.UnauthorizedCaller.selector);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);
  }

  function test_SetNFTAllowance_ZeroFrom_Reverts() public {
    _setUpNft();
    vm.prank(guardian);
    vm.expectRevert(ITrustedSpender.ZeroAddress.selector);
    spender.setNFTAllowance(address(nft), address(0), recipient, true, NO_EXPIRY);
  }

  function test_SetNFTAllowance_ZeroCollection_Reverts() public {
    _setUpNft();
    vm.prank(guardian);
    vm.expectRevert(ITrustedSpender.ZeroAddress.selector);
    spender.setNFTAllowance(address(0), safeAccount, recipient, true, NO_EXPIRY);
  }

  function test_SetNFTAllowance_ZeroTo_Reverts() public {
    _setUpNft();
    vm.prank(guardian);
    vm.expectRevert(ITrustedSpender.ZeroAddress.selector);
    spender.setNFTAllowance(address(nft), safeAccount, address(0), true, NO_EXPIRY);
  }

  function test_SetNFTAllowance_ZeroValidUntil_Reverts() public {
    _setUpNft();
    vm.prank(safeAccount);
    vm.expectRevert(ITrustedSpender.InvalidAllowanceDeadline.selector);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, 0);
  }

  function test_SetNFTAllowance_PastValidUntil_Reverts() public {
    _setUpNft();
    vm.prank(safeAccount);
    vm.expectRevert(ITrustedSpender.InvalidAllowanceDeadline.selector);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, timeNow - 1);
  }

  function test_SetNFTAllowance_CurrentTimestampValidUntil_Reverts() public {
    _setUpNft();
    vm.prank(safeAccount);
    vm.expectRevert(ITrustedSpender.InvalidAllowanceDeadline.selector);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, timeNow);
  }

  function test_ExecuteNFTTransfer_HappyPath() public {
    uint256 tokenId = _setUpNft();

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);

    vm.prank(delegate1);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, tokenId);

    assertEq(nft.ownerOf(tokenId), recipient);
  }

  /// A Safe account does not implement `onERC721Received`; `transferFrom` must still deliver.
  function test_ExecuteNFTTransfer_ToNonReceiverContract() public {
    uint256 tokenId = _setUpNft();
    address nonReceiver = address(new NonReceiverAccount());

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, nonReceiver, true, NO_EXPIRY);

    vm.prank(delegate1);
    spender.executeNFTTransfer(address(nft), safeAccount, nonReceiver, tokenId);

    assertEq(nft.ownerOf(tokenId), nonReceiver);
  }

  function test_ExecuteNFTTransfer_AnyTokenId_BlanketAllowance() public {
    _setUpNft();
    nft.mint(safeAccount, 2);
    nft.mint(safeAccount, 3);

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);

    vm.prank(delegate1);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, 2);
    vm.prank(delegate1);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, 3);

    assertEq(nft.ownerOf(2), recipient);
    assertEq(nft.ownerOf(3), recipient);
  }

  function test_ExecuteNFTTransfer_NotDelegate_Reverts() public {
    uint256 tokenId = _setUpNft();
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);

    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.NotADelegate.selector);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, tokenId);
  }

  function test_ExecuteNFTTransfer_NotAllowed_Reverts() public {
    uint256 tokenId = _setUpNft();
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);

    // No allowance set
    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.NFTTransferNotAllowed.selector);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, tokenId);
  }

  function test_ExecuteNFTTransfer_AllowedFalse_Reverts() public {
    uint256 tokenId = _setUpNft();
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, false, NO_EXPIRY);

    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.NFTTransferNotAllowed.selector);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, tokenId);
  }

  function test_ExecuteNFTTransfer_Expired_Reverts() public {
    uint256 tokenId = _setUpNft();
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, FUTURE);

    vm.warp(uint256(FUTURE) + 1);
    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.AllowanceExpired.selector);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, tokenId);
  }

  function test_ExecuteNFTTransfer_NoApprovalForAll_Reverts() public {
    nft = new MockERC721();
    uint256 tokenId = 1;
    nft.mint(safeAccount, tokenId);
    // Note: safeAccount has NOT called setApprovalForAll

    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);

    vm.prank(delegate1);
    vm.expectRevert(); // ERC721InsufficientApproval
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, tokenId);
  }

  function test_ExecuteNFTTransfer_Paused_Reverts() public {
    uint256 tokenId = _setUpNft();
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);

    vm.prank(admin);
    spender.pause();

    vm.prank(delegate1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, tokenId);
  }

  function test_SetNFTAllowance_CanRevoke() public {
    uint256 tokenId = _setUpNft();
    vm.prank(safeAccount);
    spender.addDelegate(safeAccount, delegate1);
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, NO_EXPIRY);

    // Revoke by setting allowed=false
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, false, NO_EXPIRY);
    assertFalse(spender.isNFTTransferAllowed(address(nft), safeAccount, recipient));

    vm.prank(delegate1);
    vm.expectRevert(ITrustedSpender.NFTTransferNotAllowed.selector);
    spender.executeNFTTransfer(address(nft), safeAccount, recipient, tokenId);
  }

  function test_IsNFTTransferAllowed_FalseWhenExpired() public {
    _setUpNft();
    vm.prank(safeAccount);
    spender.setNFTAllowance(address(nft), safeAccount, recipient, true, FUTURE);

    vm.warp(uint256(FUTURE) + 1);
    assertFalse(spender.isNFTTransferAllowed(address(nft), safeAccount, recipient));
  }
}
