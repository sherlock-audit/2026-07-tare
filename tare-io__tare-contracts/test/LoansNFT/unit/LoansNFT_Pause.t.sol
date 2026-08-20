// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {ILockable} from "contracts/interfaces/ILoansNFT.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract LoansNFT_PauseTest is LoansTestBase {
  int128 constant PRINCIPAL = 100_000e6;
  address unlocker = makeAddr("unlocker");
  address recipient = makeAddr("recipient");
  address pauser = makeAddr("pauser");
  uint64 id;

  function setUp() public override {
    super.setUp();
    id = _createTestLoan(PRINCIPAL);

    bytes32 pauserRole = loans.PAUSER_ROLE();
    vm.prank(guardian);
    loans.grantRole(pauserRole, pauser);
  }

  // ============ pause access control ============

  function test_Pause_ByAdmin() public {
    vm.prank(admin);
    loansNFT.pause();

    assertTrue(loansNFT.paused());
  }

  function test_Pause_ByGuardian() public {
    vm.prank(guardian);
    loansNFT.pause();

    assertTrue(loansNFT.paused());
  }

  function test_Pause_ByPauser() public {
    vm.prank(pauser);
    loansNFT.pause();

    assertTrue(loansNFT.paused());
  }

  function test_Pause_EmitsPausedEvent() public {
    vm.expectEmit(false, false, false, true);
    emit Pausable.Paused(guardian);

    vm.prank(guardian);
    loansNFT.pause();
  }

  function test_Pause_Reverts_WhenCallerIsUnauthorized() public {
    vm.prank(randomUser);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.pause();
  }

  function test_Pause_Reverts_WhenAlreadyPaused() public {
    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loansNFT.pause();
  }

  // ============ unpause access control ============

  function test_Unpause_ByGuardian() public {
    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(guardian);
    loansNFT.unpause();

    assertFalse(loansNFT.paused());
  }

  function test_Unpause_Reverts_WhenCallerIsAdmin() public {
    vm.prank(admin);
    loansNFT.pause();

    vm.prank(admin);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.unpause();
  }

  function test_Unpause_Reverts_WhenCallerIsPauser() public {
    vm.prank(pauser);
    loansNFT.pause();

    vm.prank(pauser);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.unpause();
  }

  // ============ functions blocked while paused ============

  function test_TransferFrom_Reverts_WhenPaused() public {
    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(investor);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loansNFT.transferFrom(investor, recipient, uint256(id));
  }

  function test_SafeTransferFrom_Reverts_WhenPaused() public {
    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(investor);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loansNFT.safeTransferFrom(investor, recipient, uint256(id));
  }

  function test_TransferFrom_Reverts_ForApprovedOperator_WhenPaused() public {
    address operator = makeAddr("operator");
    vm.prank(investor);
    loansNFT.setApprovalForAll(operator, true);

    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(operator);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loansNFT.transferFrom(investor, operator, uint256(id));
  }

  function test_Approve_Reverts_WhenPaused() public {
    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(investor);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loansNFT.approve(recipient, uint256(id));
  }

  function test_SetApprovalForAll_Reverts_WhenPaused() public {
    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(investor);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loansNFT.setApprovalForAll(recipient, true);
  }

  function test_Lock_Reverts_WhenPaused() public {
    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(investor);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loansNFT.lock(unlocker, uint256(id));
  }

  // ============ functions live while paused ============

  function test_Unlock_Works_WhenPaused() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(unlocker);
    loansNFT.unlock(uint256(id));

    assertEq(loansNFT.getLocked(uint256(id)), address(0));
  }

  function test_ForceTransfer_Works_WhenPaused() public {
    vm.prank(guardian);
    loansNFT.pause();

    vm.prank(guardian);
    loansNFT.forceTransfer(investor, recipient, uint256(id));

    assertEq(loansNFT.ownerOf(uint256(id)), recipient);
  }

  function test_Mint_Works_WhenPaused() public {
    vm.prank(guardian);
    loansNFT.pause();

    uint64 newId = _createTestLoan(PRINCIPAL);

    assertEq(loansNFT.ownerOf(uint256(newId)), investor);
  }

  // ============ resume after unpause ============

  function test_TransferFrom_Works_AfterUnpause() public {
    vm.prank(guardian);
    loansNFT.pause();
    vm.prank(guardian);
    loansNFT.unpause();

    vm.prank(investor);
    loansNFT.transferFrom(investor, recipient, uint256(id));

    assertEq(loansNFT.ownerOf(uint256(id)), recipient);
  }

  function test_Lock_Works_AfterUnpause() public {
    vm.prank(guardian);
    loansNFT.pause();
    vm.prank(guardian);
    loansNFT.unpause();

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    assertEq(loansNFT.getLocked(uint256(id)), unlocker);
  }

  // ============ pause state independence ============

  function test_LoansPause_DoesNotPauseLoansNFT() public {
    vm.prank(guardian);
    loans.pause();

    assertFalse(loansNFT.paused());

    vm.prank(investor);
    loansNFT.transferFrom(investor, recipient, uint256(id));

    assertEq(loansNFT.ownerOf(uint256(id)), recipient);
  }

  function test_LoansNFTPause_DoesNotPauseLoans() public {
    vm.prank(guardian);
    loansNFT.pause();

    assertFalse(loans.paused());
  }
}
