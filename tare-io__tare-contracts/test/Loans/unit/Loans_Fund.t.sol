// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Loans} from "contracts/Loans.sol";
import {LoansNFT} from "contracts/LoansNFT.sol";
import {Roles, Entry, LoanStatus, ILoans, LedgerEntryInput} from "contracts/interfaces/ILoans.sol";
import {
  ACC_CASH,
  ACC_BORROWER_PRINCIPAL_RECEIVABLE,
  ACC_INVESTOR_PRINCIPAL_PAYABLE,
  ACC_UNFUNDED_COMMITMENT
} from "contracts/interfaces/Accounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MaliciousToken} from "test/mocks/MaliciousToken.sol";
import {ENTRY_INVESTOR_CAPITAL_RECEIVED} from "contracts/interfaces/LedgerEntries.sol";

contract Loans_FundTest is LoansTestBase {
  uint256 constant FUND_AMOUNT = 10_000e6;
  int128 constant FUND_AMOUNT_INT = int128(int256(FUND_AMOUNT));
  uint256 constant INITIAL_INVESTOR_BALANCE = 100_000e6;
  bytes32 constant FUND_REF = bytes32("fund_ref");

  function setUp() public override {
    super.setUp();
    // Create loan with principal matching FUND_AMOUNT to allow funding
    loanId = _createTestLoan(FUND_AMOUNT_INT);
    // Mint and approve tokens for investor
    usdc.mint(investor, INITIAL_INVESTOR_BALANCE);
    vm.prank(investor);
    usdc.approve(address(loans), type(uint256).max);
  }

  // ============ Authorization Tests ============

  function test_Fund_RevertsWhenCalledByRandomUser() public {
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);
  }

  function test_Fund_RevertsWhenCalledByOtherRole() public {
    // Test borrower
    vm.prank(borrower);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);

    // Test servicer
    vm.prank(servicer);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);

    // Test originator
    vm.prank(originator);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);
  }

  function test_Fund_SucceedsWhenCalledByInvestor() public {
    vm.prank(investor);
    uint128 entryIndex = loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);

    assertGt(entryIndex, 0);
    assertEq(_loansContractBalance(), FUND_AMOUNT);
  }

  function test_Fund_SucceedsWhenCalledByAdmin() public {
    assertTrue(loans.hasRole(loans.ADMIN_ROLE(), admin));

    usdc.mint(admin, FUND_AMOUNT);
    vm.startPrank(admin);
    usdc.approve(address(loans), type(uint256).max);
    uint128 entryIndex = loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);
    vm.stopPrank();

    assertGt(entryIndex, 0);
    assertEq(_loansContractBalance(), FUND_AMOUNT);
  }

  // ============ Validation Tests ============

  function test_Fund_RevertsWithZeroAmount() public {
    vm.prank(investor);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.fund(loanId, 0, timeNow, FUND_REF);
  }

  function test_Fund_RevertsWithNegativeAmount() public {
    vm.prank(investor);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.fund(loanId, -1, timeNow, FUND_REF);
  }

  function test_Fund_RevertsForNonExistentLoan() public {
    uint64 invalidLoanId = 999;
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(invalidLoanId)));
    loans.fund(invalidLoanId, FUND_AMOUNT_INT, timeNow, FUND_REF);
  }

  // ============ State Change Tests ============

  function test_Fund_UpdatesLoanData() public {
    (LoanStatus initialStatus, , , , ) = loans.data(loanId);
    assertEq(uint8(initialStatus), uint8(LoanStatus.Created));

    uint48 timestamp = timeNow + 100;
    vm.prank(investor);
    loans.fund(loanId, FUND_AMOUNT_INT, timestamp, bytes32("fund_1"));

    int128 funded = -loans.getLoanAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_PAYABLE);
    (LoanStatus status, uint48 updatedAt, , , ) = loans.data(loanId);
    assertEq(funded, FUND_AMOUNT_INT);
    assertEq(uint8(status), uint8(LoanStatus.FullyFunded));
    assertEq(updatedAt, timestamp);
  }

  function test_Fund_RevertsWhenAmountBelowCommitment() public {
    vm.prank(investor);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.fund(loanId, FUND_AMOUNT_INT - 1, timeNow, FUND_REF);
  }

  function test_Fund_RevertsWhenAmountAboveCommitment() public {
    vm.prank(investor);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.fund(loanId, FUND_AMOUNT_INT + 1, timeNow, FUND_REF);
  }

  function test_Fund_RevertsWhenFundingAlreadyPerformed() public {
    vm.prank(investor);
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow, bytes32("first_fund"));

    vm.prank(investor);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow + 1, bytes32("second_fund"));
  }

  // ============ Ledger & Token Tests ============

  function test_Fund_CreatesCorrectLedgerEntry() public accountingEquationHolds {
    bytes32 fundRef = bytes32("fund_reference");
    uint48 timestamp = timeNow + 50;
    int128 amount = FUND_AMOUNT_INT;

    uint64 initialEntryCount = loans.entryCount(loanId);

    vm.prank(investor);
    uint128 entryIndex = loans.fund(loanId, amount, timestamp, fundRef);

    // Verify entry count increased
    assertEq(loans.entryCount(loanId), initialEntryCount + 1);

    // Verify entry index format
    assertEq(entryIndex, (uint128(loanId) << 64) | uint128(initialEntryCount + 1));

    // Verify entry details
    Entry memory entry = loans.getLoanEntry(loanId, initialEntryCount + 1);
    assertEq(entry.amount, amount);
    assertEq(entry.timestamp, timestamp);
    assertEq(uint8(entry.from), uint8(ACC_INVESTOR_PRINCIPAL_PAYABLE));
    assertEq(uint8(entry.to), uint8(ACC_CASH));
    assertEq(entry.entryType, ENTRY_INVESTOR_CAPITAL_RECEIVED);
    assertEq(entry.ref, fundRef);

    // Verify account balances
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_PAYABLE), -amount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), amount);
  }

  function test_Fund_TransfersTokensFromInvestor() public {
    uint256 initialInvestorBalance = usdc.balanceOf(investor);
    uint256 initialContractBalance = _loansContractBalance();

    vm.prank(investor);
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);

    assertEq(usdc.balanceOf(investor), initialInvestorBalance - FUND_AMOUNT);
    assertEq(_loansContractBalance(), initialContractBalance + FUND_AMOUNT);
  }

  function test_Fund_RevertsWithInsufficientAllowance() public {
    // Revoke investor's approval
    vm.prank(investor);
    usdc.approve(address(loans), 0);

    vm.prank(investor);
    vm.expectRevert(); // ERC20 will revert on insufficient allowance
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);
  }

  function test_Fund_EmitsEntryCreatedEvent() public {
    bytes32 fundRef = bytes32("fund_event_ref");
    uint48 timestamp = timeNow;
    int128 amount = FUND_AMOUNT_INT;

    uint64 expectedEntryNumber = loans.entryCount(loanId) + 1;
    uint128 expectedEntryIndex = (uint128(loanId) << 64) | uint128(expectedEntryNumber);

    vm.expectEmit(true, true, true, true);
    emit ILoans.EntryCreated(
      expectedEntryIndex,
      ACC_INVESTOR_PRINCIPAL_PAYABLE,
      ACC_CASH,
      amount,
      -amount,
      amount,
      ENTRY_INVESTOR_CAPITAL_RECEIVED,
      fundRef
    );

    vm.prank(investor);
    loans.fund(loanId, amount, timestamp, fundRef);
  }

  // ============ Reentrancy Test ============

  function test_Fund_ReentrancyProtection() public {
    // Deploy malicious token
    MaliciousToken maliciousToken = new MaliciousToken();

    // Create a new Loans contract with the malicious token
    Loans maliciousLoans = new Loans(IERC20(address(maliciousToken)), address(this), recoveryAddress);
    // forge-lint: disable-next-line(mixed-case-variable)
    LoansNFT maliciousLoansNFT = new LoansNFT(address(maliciousLoans), NFT_COLLECTION_NAME, "");
    maliciousLoans.setLoansNFT(address(maliciousLoansNFT));
    maliciousLoans.approveOriginator(originator);

    // Set up originator's address book
    vm.startPrank(originator);
    maliciousLoans.registerAddress(Roles.Borrower, borrower);
    maliciousLoans.registerAddress(Roles.Investor, investor);
    maliciousLoans.registerAddress(Roles.Servicer, servicer);
    vm.stopPrank();

    // Create a loan
    vm.prank(originator);
    uint64 maliciousLoanId = maliciousLoans.create(borrower, investor, servicer, originator, 100_000, timeNow);

    // Setup the malicious token to attempt reentrancy
    maliciousToken.setLoansContract(address(maliciousLoans));
    maliciousToken.setLoanId(maliciousLoanId);
    maliciousToken.mint(investor, INITIAL_INVESTOR_BALANCE);

    vm.startPrank(investor);
    maliciousToken.approve(address(maliciousLoans), type(uint256).max);

    // This should revert due to reentrancy guard
    vm.expectRevert();
    maliciousLoans.fund(maliciousLoanId, FUND_AMOUNT_INT, timeNow, bytes32("reentrant"));
    vm.stopPrank();
  }

  function test_Fund_RevertsOnCancelledLoan() public {
    uint64 cancelledLoanId = _createCancelledLoan();

    vm.prank(investor);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.fund(cancelledLoanId, FUND_AMOUNT_INT, timeNow, bytes32("fund_cancelled"));
  }

  function test_Fund_RevertsOnClosedLoan() public {
    uint64 closedLoanId = _createClosedLoan();

    vm.prank(investor);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.fund(closedLoanId, FUND_AMOUNT_INT, timeNow, bytes32("fund_closed"));
  }

  // Defense-in-depth: a servicer poisoning ACC_INVESTOR_PRINCIPAL_PAYABLE (flipping it positive,
  // so alreadyFunded = -balance is negative) must not allow funding.
  // The single-shot validation (`alreadyFunded == 0` and `amount == commitment`) rejects this.
  function test_Fund_Reverts_WhenInvestorPrincipalPayablePositive() public {
    // Move balance from BORROWER_PRINCIPAL_RECEIVABLE into INVESTOR_PRINCIPAL_PAYABLE
    // to push INVESTOR_PRINCIPAL_PAYABLE positive (alreadyFunded becomes negative).
    LedgerEntryInput[] memory entries = new LedgerEntryInput[](1);
    entries[0] = LedgerEntryInput({
      from: ACC_BORROWER_PRINCIPAL_RECEIVABLE,
      to: ACC_INVESTOR_PRINCIPAL_PAYABLE,
      amount: 1,
      entryType: 0,
      ref: bytes32("poison")
    });

    vm.prank(servicer);
    loans.createLedgerEntries(loanId, timeNow, entries);

    // Sanity: ACC_INVESTOR_PRINCIPAL_PAYABLE is now positive (alreadyFunded is negative)
    assertGt(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_PAYABLE), 0);

    vm.prank(investor);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.fund(loanId, FUND_AMOUNT_INT, timeNow, FUND_REF);
  }
}
