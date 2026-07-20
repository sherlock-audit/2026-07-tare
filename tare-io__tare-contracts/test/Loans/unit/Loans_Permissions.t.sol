// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, Roles, ILoans, LoanStatus} from "contracts/interfaces/ILoans.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ENTRY_INTEREST_ACCRUAL} from "contracts/interfaces/LedgerEntries.sol";
import {ILoansAuth} from "contracts/misc/interfaces/ILoansAuth.sol";

contract LoanPermissionsTests is LoansTestBase {
  int128 public principalAmount = 100000;

  function setUp() public override {
    super.setUp();
    loanId = _createTestLoan();
  }

  function test_CreateLoanSetsRoles() public {
    vm.prank(originator);
    uint64 createdLoanId = loans.create(borrower, investor, servicer, originator, principalAmount, timeNow);

    assertEq(loans.borrowers(createdLoanId), borrower);
    assertEq(loansNFT.ownerOf(uint256(createdLoanId)), investor);
    assertEq(loans.servicers(createdLoanId), servicer);
    assertEq(loans.originators(createdLoanId), originator);
  }

  function test_CreateLoan_OriginatorIsAlwaysMsgSender() public {
    address originatorB = makeAddr("originatorB");
    vm.prank(guardian);
    loans.approveOriginator(originatorB);

    // Register addresses in originatorB's address book
    _registerAddressesForLoan(loans, originatorB, borrower, investor, servicer);

    vm.prank(originatorB);
    uint64 createdLoanId = loans.create(borrower, investor, servicer, originatorB, principalAmount, timeNow);

    assertEq(loans.originators(createdLoanId), originatorB);
  }

  function test_UpdateBorrower_AsServicer() public {
    address newBorrower = address(0xB11);

    // Register newBorrower in servicer's address book
    vm.prank(servicer);
    loans.registerAddress(Roles.Borrower, newBorrower);

    vm.prank(servicer);
    loans.updateBorrower(loanId, newBorrower);

    assertEq(loans.borrowers(loanId), newBorrower);
  }

  function test_UpdateBorrower_AsAdmin() public {
    address newBorrower = address(0xB11);

    // Admin can update borrower, but address must still be in servicer's book
    vm.prank(servicer);
    loans.registerAddress(Roles.Borrower, newBorrower);

    vm.prank(admin);
    loans.updateBorrower(loanId, newBorrower);

    assertEq(loans.borrowers(loanId), newBorrower);
  }

  function test_UpdateBorrower_RevertsWithZeroAddress() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.ZeroAddress.selector);
    loans.updateBorrower(loanId, address(0));
  }

  function test_UpdateBorrower_RevertsWhenCalledByUnauthorized() public {
    address nonAuthorizedUser = address(0x888);

    vm.prank(nonAuthorizedUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.updateBorrower(loanId, address(0xB11));
  }

  function test_UpdateBorrower_RevertsWhenCalledByBorrower() public {
    vm.prank(borrower);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.updateBorrower(loanId, address(0xB11));
  }

  function test_UpdateBorrower_RevertsWhenCalledByInvestor() public {
    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.updateBorrower(loanId, address(0xB11));
  }

  function test_UpdateServicer() public {
    address newServicer = address(0x5E12);

    // New servicer must be approved at protocol level
    vm.prank(guardian);
    loans.approveServicer(newServicer);

    vm.prank(guardian);
    loans.updateServicer(loanId, newServicer);

    assertEq(loans.servicers(loanId), newServicer);
  }

  function test_UpdateServicer_RevertsWithZeroAddress() public {
    vm.prank(guardian);
    vm.expectRevert(ILoans.ZeroAddress.selector);
    loans.updateServicer(loanId, address(0));
  }

  function test_CannotCreateLoanWithZeroAddressAsBorrower() public {
    vm.expectRevert(ILoans.ZeroAddress.selector);
    vm.prank(originator);
    loans.create(address(0), investor, servicer, originator, principalAmount, timeNow);
  }

  function test_CannotCreateLoanWithZeroAddressAsInvestor() public {
    vm.expectRevert(ILoans.ZeroAddress.selector);
    vm.prank(originator);
    loans.create(borrower, address(0), servicer, originator, principalAmount, timeNow);
  }

  function test_CannotCreateLoanWithZeroAddressAsServicer() public {
    vm.expectRevert(ILoans.ZeroAddress.selector);
    vm.prank(originator);
    loans.create(borrower, investor, address(0), originator, principalAmount, timeNow);
  }

  function test_OnlyGuardianCanUpdateServicer() public {
    address nonAuthorizedUser = address(0x888);

    bytes32 guardianRole = loans.GUARDIAN_ROLE();
    vm.prank(nonAuthorizedUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAuthorizedUser, guardianRole)
    );
    loans.updateServicer(loanId, servicer);
  }

  // ========== Accrue Permission Tests ==========

  function test_Accrue_RevertWhenCalledByNonServicerAccount() public {
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.accrue(loanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_RevertWhenCalledByBorrower() public {
    vm.prank(borrower);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.accrue(loanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_RevertWhenCalledByInvestor() public {
    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.accrue(loanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_IsCallableAsServicer() public {
    int128 amount = 839482;

    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.Active, 0, 0, timeNow);

    vm.prank(servicer);
    loans.accrue(loanId, amount, timeNow, offchainRef);

    uint64 lastEntry = loans.entryCount(loanId);
    Entry memory entry = loans.getLoanEntry(loanId, lastEntry);
    assertTrue(entry.entryType == ENTRY_INTEREST_ACCRUAL);
    assertEq(entry.amount, amount);
    assertEq(entry.timestamp, timeNow);
  }

  function test_Accrue_IsCallableAsAdmin() public {
    int128 amount = 839483;

    vm.prank(admin);
    loans.updateLoanData(loanId, LoanStatus.Active, 0, 0, timeNow);

    vm.prank(admin);
    loans.accrue(loanId, amount, timeNow, offchainRef);

    uint64 lastEntry = loans.entryCount(loanId);
    Entry memory entry = loans.getLoanEntry(loanId, lastEntry);
    assertTrue(entry.entryType == ENTRY_INTEREST_ACCRUAL);
    assertEq(entry.amount, amount);
    assertEq(entry.timestamp, timeNow);
  }

  // ========== Address Book Validation Tests ==========

  function test_CreateLoan_RevertsWhenBorrowerNotRegistered() public {
    address unregisteredBorrower = makeAddr("unregisteredBorrower");

    vm.prank(originator);
    vm.expectRevert(abi.encodeWithSelector(ILoansAuth.UnregisteredAddress.selector, unregisteredBorrower));
    loans.create(unregisteredBorrower, investor, servicer, originator, principalAmount, timeNow);
  }

  function test_CreateLoan_RevertsWhenInvestorNotRegistered() public {
    address unregisteredInvestor = makeAddr("unregisteredInvestor");

    vm.prank(originator);
    vm.expectRevert(abi.encodeWithSelector(ILoansAuth.UnregisteredAddress.selector, unregisteredInvestor));
    loans.create(borrower, unregisteredInvestor, servicer, originator, principalAmount, timeNow);
  }

  function test_CreateLoan_RevertsWhenServicerNotRegistered() public {
    address unregisteredServicer = makeAddr("unregisteredServicer");

    vm.prank(originator);
    vm.expectRevert(abi.encodeWithSelector(ILoansAuth.UnregisteredAddress.selector, unregisteredServicer));
    loans.create(borrower, investor, unregisteredServicer, originator, principalAmount, timeNow);
  }

  function test_UpdateBorrower_RevertsWhenNotInServicersBook() public {
    address newBorrower = makeAddr("newBorrower");

    // Register in originator's book but NOT in servicer's book
    vm.prank(originator);
    loans.registerAddress(Roles.Borrower, newBorrower);

    // Should fail because newBorrower is not in servicer's address book
    vm.prank(servicer);
    vm.expectRevert(abi.encodeWithSelector(ILoansAuth.UnregisteredAddress.selector, newBorrower));
    loans.updateBorrower(loanId, newBorrower);
  }

  // ========== Cancelled/Closed Loan Tests ==========

  function test_UpdateBorrower_RevertsOnCancelledLoan() public {
    uint64 cancelledLoanId = _createCancelledLoan();

    address newBorrower = makeAddr("newBorrower");
    vm.prank(servicer);
    loans.registerAddress(Roles.Borrower, newBorrower);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.updateBorrower(cancelledLoanId, newBorrower);
  }

  function test_UpdateBorrower_RevertsOnClosedLoan() public {
    uint64 closedLoanId = _createClosedLoan();

    address newBorrower = makeAddr("newBorrower");
    vm.prank(servicer);
    loans.registerAddress(Roles.Borrower, newBorrower);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.updateBorrower(closedLoanId, newBorrower);
  }

  function test_UpdateServicer_RevertsOnCancelledLoan() public {
    uint64 cancelledLoanId = _createCancelledLoan();

    address newServicer = makeAddr("newServicer");
    vm.prank(guardian);
    loans.approveServicer(newServicer);

    vm.prank(guardian);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.updateServicer(cancelledLoanId, newServicer);
  }

  function test_UpdateServicer_RevertsOnClosedLoan() public {
    uint64 closedLoanId = _createClosedLoan();

    address newServicer = makeAddr("newServicer");
    vm.prank(guardian);
    loans.approveServicer(newServicer);

    vm.prank(guardian);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.updateServicer(closedLoanId, newServicer);
  }

  function test_Accrue_RevertsOnCancelledLoan() public {
    uint64 cancelledLoanId = _createCancelledLoan();

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.accrue(cancelledLoanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_RevertsOnClosedLoan() public {
    uint64 closedLoanId = _createClosedLoan();

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.accrue(closedLoanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_Reverts_WhenStatusCreated() public {
    uint64 createdLoanId = _createTestLoan(10_000e6);
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.accrue(createdLoanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_Reverts_WhenStatusFullyFunded() public {
    uint64 fullyFundedLoanId = _createFullyFundedLoan(10_000e6);
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.accrue(fullyFundedLoanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_Reverts_WhenStatusFullyPaid() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.FullyPaid, 0, 0, timeNow);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.accrue(loanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_Succeeds_WhenStatusChargedOff() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.ChargedOff, 0, 0, timeNow);

    vm.prank(servicer);
    loans.accrue(loanId, 100, timeNow, offchainRef);
  }

  function test_Accrue_Reverts_WhenLoanDoesNotExist() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.accrue(999, 100, timeNow, offchainRef);
  }

  function test_UpdateBorrower_RevertsOnNonexistentLoan() public {
    address newBorrower = makeAddr("newBorrower");
    vm.prank(admin);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.updateBorrower(999, newBorrower);
  }

  function test_UpdateServicer_RevertsOnNonexistentLoan() public {
    address newServicer = makeAddr("newServicer");
    vm.prank(guardian);
    loans.approveServicer(newServicer);

    vm.prank(guardian);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.updateServicer(999, newServicer);
  }
}
