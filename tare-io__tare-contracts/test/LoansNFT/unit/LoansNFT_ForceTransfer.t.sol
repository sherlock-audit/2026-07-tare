// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansNFTTestBase} from "../setup/LoansNFTTestBase.t.sol";
import {ILoansNFT, ILockable} from "contracts/interfaces/ILoansNFT.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RevertingReceiverContract} from "test/mocks/RevertingReceiverContract.sol";

contract CompliantReceiver is IERC721Receiver {
  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }
}

contract LoansNFT_ForceTransferTest is LoansNFTTestBase {
  address internal newOwner = makeAddr("newOwner");

  function _newLoan() internal returns (uint64 id) {
    id = _createTestLoan(PRINCIPAL);
  }

  // ============ happy path ============

  function test_ForceTransfer_TransfersToken_WhenCallerIsGuardian() public {
    uint64 id = _newLoan();
    assertEq(loansNFT.ownerOf(id), investor);

    vm.prank(guardian);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));

    assertEq(loansNFT.ownerOf(id), newOwner);
  }

  function test_ForceTransfer_EmitsForceTransferAndTransferEvents() public {
    uint64 id = _newLoan();

    vm.expectEmit(true, true, true, false, address(loansNFT));
    emit IERC721.Transfer(investor, newOwner, uint256(id));
    vm.expectEmit(true, true, true, false, address(loansNFT));
    emit ILoansNFT.ForceTransfer(investor, newOwner, uint256(id));

    vm.prank(guardian);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));
  }

  function test_ForceTransfer_BypassesApproval() public {
    uint64 id = _newLoan();
    // No approval is granted to the guardian.

    vm.prank(guardian);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));

    assertEq(loansNFT.ownerOf(id), newOwner);
  }

  function test_ForceTransfer_BumpsOwnershipNonces() public {
    uint64 id = _newLoan();
    uint256 fromNonceBefore = loansNFT.ownershipNonce(investor);
    uint256 toNonceBefore = loansNFT.ownershipNonce(newOwner);

    vm.prank(guardian);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));

    assertEq(loansNFT.ownershipNonce(investor), fromNonceBefore + 1);
    assertEq(loansNFT.ownershipNonce(newOwner), toNonceBefore + 1);
  }

  // ============ locked-loan guard ============

  function test_ForceTransfer_Reverts_WhenTokenIsLocked() public {
    uint64 id = _newLoan();
    address unlocker = makeAddr("unlocker");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));
    assertEq(loansNFT.getLocked(uint256(id)), unlocker);

    vm.prank(guardian);
    vm.expectRevert(ILockable.TokenLocked.selector);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));

    assertEq(loansNFT.ownerOf(id), investor);
    assertEq(loansNFT.getLocked(uint256(id)), unlocker);
  }

  function test_ForceTransfer_TransfersAfterLockIsCleared() public {
    uint64 id = _newLoan();
    address unlocker = makeAddr("unlocker");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(id));

    vm.prank(unlocker);
    loansNFT.unlock(uint256(id));

    vm.prank(guardian);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));

    assertEq(loansNFT.ownerOf(id), newOwner);
    assertEq(loansNFT.getLocked(uint256(id)), address(0));
  }

  // ============ access control ============

  function test_ForceTransfer_Reverts_WhenCallerIsAdmin() public {
    uint64 id = _newLoan();

    vm.prank(admin);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));
  }

  function test_ForceTransfer_Reverts_WhenCallerIsTokenOwner() public {
    uint64 id = _newLoan();

    vm.prank(investor);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));
  }

  function test_ForceTransfer_Reverts_WhenCallerIsRandomUser() public {
    uint64 id = _newLoan();

    vm.prank(randomUser);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.forceTransfer(investor, newOwner, uint256(id));
  }

  // ============ input validation ============

  function test_ForceTransfer_Reverts_WhenTokenDoesNotExist() public {
    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(999)));
    loansNFT.forceTransfer(investor, newOwner, 999);
  }

  function test_ForceTransfer_Reverts_WhenFromDoesNotMatchOwner() public {
    uint64 id = _newLoan();

    vm.prank(guardian);
    vm.expectRevert(ILoansNFT.InvalidFrom.selector);
    loansNFT.forceTransfer(randomUser, newOwner, uint256(id));
  }

  function test_ForceTransfer_Reverts_WhenToIsZero() public {
    uint64 id = _newLoan();

    vm.prank(guardian);
    vm.expectRevert(ILoansNFT.InvalidTo.selector);
    loansNFT.forceTransfer(investor, address(0), uint256(id));
  }

  // ============ receiver check ============

  function test_ForceTransfer_ToCompliantReceiverContract_Succeeds() public {
    uint64 id = _newLoan();
    address receiver = address(new CompliantReceiver());

    vm.prank(guardian);
    loansNFT.forceTransfer(investor, receiver, uint256(id));

    assertEq(loansNFT.ownerOf(id), receiver);
  }

  function test_ForceTransfer_Reverts_WhenRecipientRejectsReceiverHook() public {
    uint64 id = _newLoan();
    address receiver = address(new RevertingReceiverContract());

    vm.prank(guardian);
    vm.expectRevert(RevertingReceiverContract.ReceiverHookInvoked.selector);
    loansNFT.forceTransfer(investor, receiver, uint256(id));

    assertEq(loansNFT.ownerOf(id), investor);
  }

  function test_ForceTransfer_Reverts_WhenRecipientIsNonReceiverContract() public {
    uint64 id = _newLoan();
    // The test contract does not implement `onERC721Received`.
    address receiver = address(this);

    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, receiver));
    loansNFT.forceTransfer(investor, receiver, uint256(id));

    assertEq(loansNFT.ownerOf(id), investor);
  }
}
