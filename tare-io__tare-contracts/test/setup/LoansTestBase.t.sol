// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Loans} from "contracts/Loans.sol";
import {LoansNFT} from "contracts/LoansNFT.sol";
import {Roles} from "contracts/interfaces/ILoans.sol";
import {LoanStatus} from "contracts/interfaces/ILoans.sol";
import {
  ACC_BORROWER_INTEREST_PAID,
  ACC_BORROWER_MISC_FEE_PAID,
  ACC_BORROWER_MISC_FEE_RECEIVABLE,
  ACC_BORROWER_PAYMENT_CLEARING,
  ACC_BORROWER_INTEREST_RECEIVABLE,
  ACC_BORROWER_PRINCIPAL_RECEIVABLE,
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_CASH,
  ACC_INVESTOR_INTEREST_PAID,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_REPAID,
  ACC_ORIGINATOR_FEE_PAID,
  ACC_ORIGINATOR_FEE_PAYABLE,
  ACC_SERVICER_ADJUSTMENT,
  ACC_SERVICER_FEE_PAID,
  ACC_SERVICER_FEE_PAYABLE,
  ACC_SERVICER_MISC_FEE_PAID,
  ACC_SERVICER_MISC_FEE_PAYABLE,
  ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
  ACC_UNFUNDED_COMMITMENT
} from "contracts/interfaces/Accounts.sol";
import {MockUSDC} from "../mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract LoansTestBase is Test {
  Loans public loans;
  // forge-lint: disable-next-line(mixed-case-variable)
  LoansNFT public loansNFT;
  MockUSDC public usdc;
  uint64 public loanId;
  string constant NFT_COLLECTION_NAME = "Tare Loans (testing)";
  string constant BASE_URI = "https://tare.live/nft/";
  bytes32 offchainRef = bytes32("foobar");
  address public borrower = makeAddr("borrower");
  address public servicer = makeAddr("servicer");
  address public investor = makeAddr("investor");
  address public originator = makeAddr("originator");
  address public randomUser = makeAddr("randomUser");
  address public guardian = makeAddr("guardian");
  address public admin = makeAddr("admin");
  address public recoveryAddress = makeAddr("recoveryAddress");

  uint64[] internal testLoanIds;
  uint48 internal timeNow;

  int128 internal constant DEFAULT_TEST_PRINCIPAL = 10_000e6;
  int128 internal constant DEFAULT_ACCRUAL_AMOUNT = 100e6;
  int128 internal constant DEFAULT_PAYMENT_AMOUNT = 600e6;
  int128 internal constant DEFAULT_SERVICER_FEE = 10e6;
  int128 internal constant DEFAULT_INVESTOR_INTEREST = 90e6;
  int128 internal constant DEFAULT_PRINCIPAL_REPAYMENT = 500e6;
  uint32 internal constant DEFAULT_INTEREST_RATE = 1200; // 12.00% annual (30/360)
  int128 internal constant DEFAULT_EXPECTED_MONTHLY_PAYMENT = DEFAULT_PAYMENT_AMOUNT;

  function setUp() public virtual {
    usdc = new MockUSDC();
    loans = new Loans(IERC20(address(usdc)), guardian, recoveryAddress);
    bytes32 adminRole = loans.ADMIN_ROLE();
    vm.prank(guardian);
    loans.grantRole(adminRole, admin);
    loansNFT = new LoansNFT(address(loans), NFT_COLLECTION_NAME, BASE_URI);
    vm.prank(admin);
    loans.setLoansNFT(address(loansNFT));

    // Add originator to the address book and approve them so they can create loans in tests
    vm.prank(guardian);
    loans.approveOriginator(originator);

    _registerAddressesForLoan(loans, originator, borrower, investor, servicer);

    usdc.mint(address(this), 1_000_000e6);
    usdc.approve(address(loans), type(uint256).max);

    // Fund the loan from investor
    usdc.mint(investor, asUint(100_000_000e6));
    vm.prank(investor);
    usdc.approve(address(loans), type(uint256).max);

    timeNow = 1_700_000_000;
    vm.warp(uint256(timeNow));
  }

  int128 public constant DEFAULT_PRINCIPAL_AMOUNT = 100_000e6;

  function _createTestLoan() internal returns (uint64 loanId_) {
    return _createTestLoan(DEFAULT_PRINCIPAL_AMOUNT);
  }

  // Overloaded to allow custom principal amounts
  function _createTestLoan(int128 principalAmount) internal returns (uint64 loanId_) {
    vm.prank(originator);
    return loans.create(borrower, investor, servicer, originator, principalAmount, timeNow);
  }

  function _registerAddressesForLoan(
    Loans loansContract,
    address bookOwner,
    address borrowerAddr,
    address investorAddr,
    address servicerAddr
  ) internal {
    vm.startPrank(bookOwner);
    loansContract.registerAddress(Roles.Borrower, borrowerAddr);
    loansContract.registerAddress(Roles.Investor, investorAddr);
    loansContract.registerAddress(Roles.Servicer, servicerAddr);
    vm.stopPrank();
  }

  function _createFullyFundedLoan(int128 principalAmount) internal returns (uint64 loanId_) {
    loanId_ = _createTestLoan(principalAmount);
    vm.prank(investor);
    loans.fund(loanId_, principalAmount, timeNow, bytes32("fund_ref"));
  }

  function _createActiveLoan(int128 principalAmount) internal returns (uint64 loanId_) {
    loanId_ = _createFullyFundedLoan(principalAmount);
    vm.prank(originator);
    loans.disburse(
      loanId_,
      principalAmount,
      0, // no origination fee
      timeNow,
      timeNow + 30 days,
      timeNow + 365 days,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      bytes32("disburse_ref")
    );
  }

  function _createActiveLoanForInvestor(
    address investorAddr,
    int128 principalAmount
  ) internal returns (uint64 loanId_) {
    usdc.mint(investorAddr, uint256(uint128(principalAmount)));
    vm.prank(investorAddr);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(originator);
    loanId_ = loans.create(borrower, investorAddr, servicer, originator, principalAmount, timeNow);

    vm.prank(investorAddr);
    loans.fund(loanId_, principalAmount, timeNow, bytes32("fund_ref"));

    vm.prank(originator);
    loans.disburse(
      loanId_,
      principalAmount,
      0,
      timeNow,
      timeNow + 30 days,
      timeNow + 365 days,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      bytes32("disburse_ref")
    );
  }

  function _createActiveLoanWithOriginationFee(
    int128 principalAmount,
    int128 originationFee
  ) internal returns (uint64 loanId_) {
    loanId_ = _createFullyFundedLoan(principalAmount);
    vm.prank(originator);
    loans.disburse(
      loanId_,
      principalAmount - originationFee,
      originationFee,
      timeNow,
      timeNow + 30 days,
      timeNow + 365 days,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      bytes32("disburse_ref")
    );
  }

  function _createLoanWithInvestorCashflow(int128 principal, bytes32 ref) internal returns (uint64 id) {
    id = _createActiveLoan(principal);

    vm.prank(servicer);
    loans.accrue(id, DEFAULT_ACCRUAL_AMOUNT, timeNow, ref);

    usdc.mint(borrower, asUint(DEFAULT_PAYMENT_AMOUNT));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(borrower);
    loans.pay(id, DEFAULT_PAYMENT_AMOUNT, timeNow, ref);

    vm.prank(servicer);
    loans.applyWaterfall(
      id,
      0, // no misc fees
      DEFAULT_SERVICER_FEE,
      DEFAULT_INVESTOR_INTEREST,
      DEFAULT_PRINCIPAL_REPAYMENT,
      0, // no nextDueDate change
      timeNow,
      ref
    );
  }

  function _createLoansWithInvestorCashflow(uint256 count) internal {
    _createLoansWithInvestorCashflow(count, DEFAULT_TEST_PRINCIPAL);
  }

  function _createLoansWithInvestorCashflow(uint256 count, int128 principal) internal {
    for (uint256 i = 0; i < count; i++) {
      testLoanIds.push(_createLoanWithInvestorCashflow(principal, bytes32(i)));
    }
    loanId = testLoanIds[0];
  }

  function _createCancelledLoan() internal returns (uint64 loanId_) {
    loanId_ = _createTestLoan();
    vm.prank(servicer);
    loans.updateLoanData(loanId_, LoanStatus.Cancelled, 0, 0, timeNow);
  }

  function _createClosedLoan() internal returns (uint64 loanId_) {
    loanId_ = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
    vm.prank(servicer);
    loans.updateLoanData(loanId_, LoanStatus.Closed, 0, 0, timeNow);
  }

  function _getTestLoanIdArray(uint256 count) internal view returns (uint64[] memory) {
    uint64[] memory ids = new uint64[](count);
    for (uint256 i = 0; i < count; i++) {
      ids[i] = testLoanIds[i];
    }
    return ids;
  }

  modifier accountingEquationHolds() {
    _;
    assertEq(_getLoanTotalBalance(loanId), 0, "Accounting equation violated");
  }

  function _loansContractBalance() internal view returns (uint256) {
    return usdc.balanceOf(address(loans));
  }

  function _getLoanTotalBalance(uint64 loanId_) internal view returns (int128) {
    uint8[21] memory allAccounts = [
      ACC_CASH,
      ACC_BORROWER_PRINCIPAL_RECEIVABLE,
      ACC_BORROWER_INTEREST_RECEIVABLE,
      ACC_BORROWER_MISC_FEE_RECEIVABLE,
      ACC_INVESTOR_PRINCIPAL_REPAID,
      ACC_INVESTOR_INTEREST_PAID,
      ACC_SERVICER_FEE_PAID,
      ACC_ORIGINATOR_FEE_PAID,
      ACC_SERVICER_MISC_FEE_PAID,
      ACC_UNFUNDED_COMMITMENT,
      ACC_BORROWER_PAYMENT_CLEARING,
      ACC_INVESTOR_PRINCIPAL_PAYABLE,
      ACC_INVESTOR_INTEREST_PAYABLE,
      ACC_SERVICER_FEE_PAYABLE,
      ACC_ORIGINATOR_FEE_PAYABLE,
      ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      ACC_SERVICER_MISC_FEE_PAYABLE,
      ACC_SERVICER_ADJUSTMENT,
      ACC_BORROWER_PRINCIPAL_REPAID,
      ACC_BORROWER_INTEREST_PAID,
      ACC_BORROWER_MISC_FEE_PAID
    ];
    int128 totalBalance = 0;
    for (uint256 i = 0; i < allAccounts.length; i++) {
      totalBalance += loans.getLoanAccountBalance(loanId_, allAccounts[i]);
    }
    return totalBalance;
  }
}
