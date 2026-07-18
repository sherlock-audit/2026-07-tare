// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LoansNFT_LoansIntegrationTest is LoansTestBase {
  int128 constant PRINCIPAL = 100_000e6;

  function test_Create_MintsNFTToInvestor() public {
    uint64 id = _createTestLoan(PRINCIPAL);
    assertEq(loansNFT.ownerOf(uint256(id)), investor);
  }

  function test_Create_BalanceOfInvestorIncrements() public {
    assertEq(loansNFT.balanceOf(investor), 0);

    _createTestLoan(PRINCIPAL);
    assertEq(loansNFT.balanceOf(investor), 1);

    _createTestLoan(PRINCIPAL);
    assertEq(loansNFT.balanceOf(investor), 2);
  }

  function test_Create_EmitsTransferEvent() public {
    uint64 nextId = loans.loanCount() + 1;
    vm.expectEmit(true, true, true, true);
    emit IERC721.Transfer(address(0), investor, uint256(nextId));
    vm.prank(originator);
    loans.create(borrower, investor, servicer, originator, PRINCIPAL, timeNow);
  }

  function test_InvestorsWrapper_ReturnsOwner() public {
    uint64 id = _createTestLoan(PRINCIPAL);

    assertEq(loansNFT.ownerOf(uint256(id)), investor);
  }

  function test_Enumerable_TotalSupply() public {
    assertEq(loansNFT.totalSupply(), 0);
    _createTestLoan(PRINCIPAL);
    assertEq(loansNFT.totalSupply(), 1);
    _createTestLoan(PRINCIPAL);
    assertEq(loansNFT.totalSupply(), 2);
  }

  function test_Enumerable_TokenByIndex() public {
    uint64 id1 = _createTestLoan(PRINCIPAL);
    uint64 id2 = _createTestLoan(PRINCIPAL);
    assertEq(loansNFT.tokenByIndex(0), uint256(id1));
    assertEq(loansNFT.tokenByIndex(1), uint256(id2));
  }

  function test_Enumerable_TokenOfOwnerByIndex() public {
    uint64 id1 = _createTestLoan(PRINCIPAL);
    uint64 id2 = _createTestLoan(PRINCIPAL);
    assertEq(loansNFT.tokenOfOwnerByIndex(investor, 0), uint256(id1));
    assertEq(loansNFT.tokenOfOwnerByIndex(investor, 1), uint256(id2));
  }

  function test_Enumerable_TokenByIndex_RevertsWhenOutOfBounds() public {
    _createTestLoan(PRINCIPAL);
    vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, address(0), 1));
    loansNFT.tokenByIndex(1);
  }

  function test_Enumerable_TokenOfOwnerByIndex_RevertsWhenOutOfBounds() public {
    _createTestLoan(PRINCIPAL);
    vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, investor, 1));
    loansNFT.tokenOfOwnerByIndex(investor, 1);
  }

  function test_Enumerable_MultiOwner_TracksTokensPerOwner() public {
    address investor2 = makeAddr("investor2");
    _registerAddressesForLoan(loans, originator, borrower, investor2, servicer);

    uint64 id1 = _createTestLoan(PRINCIPAL);

    vm.prank(originator);
    uint64 id2 = loans.create(borrower, investor2, servicer, originator, PRINCIPAL, timeNow);

    assertEq(loansNFT.balanceOf(investor), 1);
    assertEq(loansNFT.balanceOf(investor2), 1);
    assertEq(loansNFT.tokenOfOwnerByIndex(investor, 0), uint256(id1));
    assertEq(loansNFT.tokenOfOwnerByIndex(investor2, 0), uint256(id2));
  }

  function test_Transfer_UpdatesInvestorRole() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    address newInvestor = makeAddr("newInvestor");

    vm.prank(investor);
    loansNFT.transferFrom(investor, newInvestor, uint256(id));

    assertEq(loansNFT.ownerOf(uint256(id)), newInvestor);
  }

  function test_Transfer_NewOwnerCanWithdraw() public {
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("ref"));
    address newInvestor = makeAddr("newInvestor");

    vm.prank(investor);
    loansNFT.transferFrom(investor, newInvestor, uint256(id));

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = id;

    vm.prank(newInvestor);
    loans.investorWithdraw(loanIds, timeNow, bytes32("withdraw"));
  }

  function test_Transfer_OldOwnerCannotWithdraw() public {
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("ref"));
    address newInvestor = makeAddr("newInvestor");

    vm.prank(investor);
    loansNFT.transferFrom(investor, newInvestor, uint256(id));

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = id;

    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(loanIds, timeNow, bytes32("withdraw"));
  }

  function test_Transfer_UpdatesEnumeration() public {
    uint64 id1 = _createTestLoan(PRINCIPAL);
    uint64 id2 = _createTestLoan(PRINCIPAL);
    address newInvestor = makeAddr("newInvestor");

    vm.prank(investor);
    loansNFT.transferFrom(investor, newInvestor, uint256(id1));

    assertEq(loansNFT.tokenOfOwnerByIndex(newInvestor, 0), uint256(id1));
    assertEq(loansNFT.tokenOfOwnerByIndex(investor, 0), uint256(id2));
  }

  function test_Transfer_UpdatesBalanceOfBothParties() public {
    uint64 id = _createTestLoan(PRINCIPAL);
    address newInvestor = makeAddr("newInvestor");

    assertEq(loansNFT.balanceOf(investor), 1);
    assertEq(loansNFT.balanceOf(newInvestor), 0);

    vm.prank(investor);
    loansNFT.transferFrom(investor, newInvestor, uint256(id));

    assertEq(loansNFT.balanceOf(investor), 0);
    assertEq(loansNFT.balanceOf(newInvestor), 1);
  }

  function test_Transfer_TotalSupplyUnchanged() public {
    uint64 id = _createTestLoan(PRINCIPAL);
    address newInvestor = makeAddr("newInvestor");

    assertEq(loansNFT.totalSupply(), 1);

    vm.prank(investor);
    loansNFT.transferFrom(investor, newInvestor, uint256(id));

    assertEq(loansNFT.totalSupply(), 1);
  }

  function test_Transfer_RevertsIfNotOwnerOrApproved() public {
    uint64 id = _createTestLoan(PRINCIPAL);
    address newInvestor = makeAddr("newInvestor");

    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, randomUser, uint256(id)));
    loansNFT.transferFrom(investor, newInvestor, uint256(id));
  }

  function test_Approve_AllowsTransfer() public {
    uint64 id = _createTestLoan(PRINCIPAL);
    address approvedOperator = makeAddr("approved");
    address newInvestor = makeAddr("newInvestor");

    vm.prank(investor);
    loansNFT.approve(approvedOperator, uint256(id));

    vm.prank(approvedOperator);
    loansNFT.transferFrom(investor, newInvestor, uint256(id));

    assertEq(loansNFT.ownerOf(uint256(id)), newInvestor);
  }

  function test_SetApprovalForAll_AllowsTransfer() public {
    uint64 id = _createTestLoan(PRINCIPAL);
    address operator = makeAddr("operator");
    address newInvestor = makeAddr("newInvestor");

    vm.prank(investor);
    loansNFT.setApprovalForAll(operator, true);

    vm.prank(operator);
    loansNFT.transferFrom(investor, newInvestor, uint256(id));

    assertEq(loansNFT.ownerOf(uint256(id)), newInvestor);
  }

  function test_Fund_InvestorResolvedViaOwnerOf() public {
    uint64 id = _createTestLoan(PRINCIPAL);
    address newInvestor = makeAddr("newInvestor");

    vm.prank(investor);
    loansNFT.transferFrom(investor, newInvestor, uint256(id));

    usdc.mint(newInvestor, uint256(int256(PRINCIPAL)));
    vm.prank(newInvestor);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(newInvestor);
    loans.fund(id, PRINCIPAL, timeNow, bytes32("fund"));
  }
}
