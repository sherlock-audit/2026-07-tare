// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {ILoansNFT, ILockable} from "contracts/interfaces/ILoansNFT.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract LoansNFT_LockableTest is LoansTestBase {
  int128 constant PRINCIPAL = 100_000e6;
  address unlocker = makeAddr("unlocker");
  uint64 id;

  function setUp() public override {
    super.setUp();
    id = _createTestLoan(PRINCIPAL);
  }

  // ============ lock ============

  function test_Lock_SetsUnlocker() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    assertEq(loansNFT.getLocked(uint256(id)), unlocker);
  }

  function test_Lock_EmitsLockEvent() public {
    vm.expectEmit(true, true, false, false);
    emit ILockable.Lock(unlocker, uint256(id));

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));
  }

  function test_Lock_ClearsApproval() public {
    address approved = makeAddr("approved");

    vm.prank(investor);
    loansNFT.approve(approved, uint256(id));
    assertEq(loansNFT.getApproved(uint256(id)), approved);

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    // getApproved returns unlocker when locked
    assertEq(loansNFT.getApproved(uint256(id)), unlocker);
  }

  function test_Lock_Reverts_WhenNotOwnerOrApproved() public {
    vm.prank(randomUser);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.lock(unlocker, uint256(id));
  }

  function test_Lock_Reverts_WhenAlreadyLocked() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.prank(investor);
    vm.expectRevert(ILockable.AlreadyLocked.selector);
    loansNFT.lock(unlocker, uint256(id));
  }

  function test_Lock_Reverts_WhenUnlockerIsZero() public {
    vm.prank(investor);
    vm.expectRevert(ILockable.InvalidUnlocker.selector);
    loansNFT.lock(address(0), uint256(id));
  }

  function test_Lock_SucceedsWhenCalledByApprovedOperator() public {
    address operator = makeAddr("operator");

    vm.prank(investor);
    loansNFT.setApprovalForAll(operator, true);

    vm.prank(operator);
    loansNFT.lock(unlocker, uint256(id));

    assertEq(loansNFT.getLocked(uint256(id)), unlocker);
  }

  // ============ unlock ============

  function test_Unlock_ClearsLock() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.prank(unlocker);
    loansNFT.unlock(uint256(id));

    assertEq(loansNFT.getLocked(uint256(id)), address(0));
  }

  function test_Unlock_EmitsUnlockEvent() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.expectEmit(true, false, false, false);
    emit ILockable.Unlock(uint256(id));

    vm.prank(unlocker);
    loansNFT.unlock(uint256(id));
  }

  function test_Unlock_Reverts_WhenNotUnlocker() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    // Owner cannot unlock
    vm.prank(investor);
    vm.expectRevert(ILockable.NotUnlocker.selector);
    loansNFT.unlock(uint256(id));

    // Random user cannot unlock
    vm.prank(randomUser);
    vm.expectRevert(ILockable.NotUnlocker.selector);
    loansNFT.unlock(uint256(id));
  }

  // ============ getLocked ============

  function test_GetLocked_ReturnsZeroWhenUnlocked() public view {
    assertEq(loansNFT.getLocked(uint256(id)), address(0));
  }

  function test_GetLocked_ReturnsUnlockerWhenLocked() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    assertEq(loansNFT.getLocked(uint256(id)), unlocker);
  }

  function test_GetLocked_Reverts_WhenNonExistentToken() public {
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(999)));
    loansNFT.getLocked(999);
  }

  // ============ transfer while locked ============

  function test_Transfer_Reverts_WhenLockedAndNotUnlocker() public {
    address newOwner = makeAddr("newOwner");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    // Owner cannot transfer
    vm.prank(investor);
    vm.expectRevert(ILockable.TokenLocked.selector);
    loansNFT.transferFrom(investor, newOwner, uint256(id));
  }

  function test_Transfer_Succeeds_WhenLockedByUnlocker() public {
    address newOwner = makeAddr("newOwner");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.prank(unlocker);
    loansNFT.transferFrom(investor, newOwner, uint256(id));

    assertEq(loansNFT.ownerOf(uint256(id)), newOwner);
  }

  function test_Transfer_AutoClearsLock() public {
    address newOwner = makeAddr("newOwner");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.prank(unlocker);
    loansNFT.transferFrom(investor, newOwner, uint256(id));

    assertEq(loansNFT.getLocked(uint256(id)), address(0));
  }

  function test_Transfer_EmitsUnlockOnLockedTransfer() public {
    address newOwner = makeAddr("newOwner");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.expectEmit(true, false, false, false);
    emit ILockable.Unlock(uint256(id));

    vm.prank(unlocker);
    loansNFT.transferFrom(investor, newOwner, uint256(id));
  }

  // ============ approve while locked ============

  function test_Approve_Reverts_WhenLocked() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.prank(investor);
    vm.expectRevert(ILockable.TokenLocked.selector);
    loansNFT.approve(makeAddr("someone"), uint256(id));
  }

  // ============ getApproved while locked ============

  function test_GetApproved_ReturnsUnlockerWhenLocked() public {
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    assertEq(loansNFT.getApproved(uint256(id)), unlocker);
  }

  // ============ supportsInterface ============

  function test_SupportsInterface_ILockable() public view {
    assertTrue(loansNFT.supportsInterface(type(ILockable).interfaceId));
  }
}
