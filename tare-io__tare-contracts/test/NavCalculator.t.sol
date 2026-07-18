// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "./setup/LoansTestBase.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {NavCalculator} from "contracts/NavCalculator.sol";
import {ILoans, LoanStatus, LoanValue} from "contracts/interfaces/ILoans.sol";
import {INavCalculator, ValuationBucket} from "contracts/interfaces/INavCalculator.sol";
import {asUint} from "test/helpers/Int128Utils.sol";
import {splitLoanValue} from "test/helpers/NavMath.sol";

contract NavCalculator_GetLoansValueTest is LoansTestBase {
  uint256 internal constant WAD = 1e18;

  NavCalculator public calculator;

  uint256 constant FACTOR_CURRENT = 1e18; // 100%
  uint256 constant FACTOR_DQ30 = 0.75e18; // 75%
  uint256 constant FACTOR_DQ60 = 0.40e18; // 40%
  uint256 constant FACTOR_DQ90 = 0.25e18; // 25%
  uint256 constant FACTOR_DQ120 = 0.15e18; // 15%
  uint256 constant FACTOR_CHARGED_OFF = 0.10e18; // 10%
  uint256 constant FACTOR_CLOSED = 0.50e18; // 50%
  uint256 constant FACTOR_CANCELLED = 0.20e18; // 20%

  int128 constant PRINCIPAL = 100_000e6;

  function setUp() public override {
    super.setUp();

    uint256[8] memory factors = [
      FACTOR_CURRENT,
      FACTOR_DQ30,
      FACTOR_DQ60,
      FACTOR_DQ90,
      FACTOR_DQ120,
      FACTOR_CHARGED_OFF,
      FACTOR_CLOSED,
      FACTOR_CANCELLED
    ];

    calculator = new NavCalculator(address(this), factors);
  }

  /// @notice Helper: computes the expected NAV contribution for a single loan under the
  /// formula `unreturnedInvestorPrincipal * bucketFactor + collectedCash`, where
  /// collectedCash (withdrawable principal + waterfall-allocated interest) is at par.
  function _expectedLoanValue(uint64 id, uint256 factor) internal view returns (uint256) {
    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    (uint256 principal, uint256 cash) = splitLoanValue(loans.getLoanValues(ids)[0]);
    return (principal * factor) / WAD + cash;
  }

  /// @notice Helper: returns the unreturned investor principal for a loan (the credit-exposed amount).
  function _unreturnedInvestorPrincipal(uint64 id) internal view returns (uint256 principal) {
    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    (principal, ) = splitLoanValue(loans.getLoanValues(ids)[0]);
  }

  /// @notice Helper: returns the collected cash (par) for a loan.
  function _collectedCash(uint64 id) internal view returns (uint256 cash) {
    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    (, cash) = splitLoanValue(loans.getLoanValues(ids)[0]);
  }

  // ──────────────────────────── Tests ─────────────────────────────

  function test_GetLoansValue_AppliesDpdDiscount_WhenActiveLoanIsDelinquent() public {
    // Create loan with full cashflow cycle so investor has principal + interest exposure
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("ref1"));
    assertTrue(_unreturnedInvestorPrincipal(id) > 0, "unreturned principal should be positive");

    // Warp 61 days past nextDueDate to land in DQ60 bucket (dpd > 60)
    (, , , uint48 nextDueDate, ) = loans.data(id);
    vm.warp(uint256(nextDueDate) + 61 days);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 result = calculator.getLoansValue(ILoans(address(loans)), ids);
    uint256 expected = _expectedLoanValue(id, FACTOR_DQ60);

    assertEq(result, expected, "DQ60 discount not applied correctly");
  }

  function test_GetLoansValue_AppliesDQ30Discount_WhenDpdBetween31And60() public {
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("ref-dq30"));

    // Warp 31 days past nextDueDate to land in DQ30 bucket (30 < dpd <= 60)
    (, , , uint48 nextDueDate, ) = loans.data(id);
    vm.warp(uint256(nextDueDate) + 31 days);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 result = calculator.getLoansValue(ILoans(address(loans)), ids);
    uint256 expected = _expectedLoanValue(id, FACTOR_DQ30);

    assertEq(result, expected, "DQ30 discount not applied correctly");
  }

  function test_GetLoansValue_UsesChargedOffFactor_WhenLoanIsChargedOff() public {
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("ref2"));

    // Charge off the loan via updateLoanData
    vm.prank(servicer);
    loans.updateLoanData({
      loanId: id,
      status: LoanStatus.ChargedOff,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 result = calculator.getLoansValue(ILoans(address(loans)), ids);
    uint256 expected = _expectedLoanValue(id, FACTOR_CHARGED_OFF);

    assertEq(result, expected, "ChargedOff factor not applied correctly");
  }

  function test_GetLoansValue_AggregatesMixedPortfolio() public {
    // Loan A: Active with investor cashflow
    uint64 idA = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("refA"));

    // Loan B: Active with investor cashflow (will become delinquent)
    uint64 idB = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("refB"));

    // Loan C: FullyPaid (has investor exposure but no discount)
    uint64 idC = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("refC"));
    vm.prank(servicer);
    loans.updateLoanData({
      loanId: idC,
      status: LoanStatus.FullyPaid,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });

    // Read expected values before warping (values don't change with time)
    uint256 expectedA;
    uint256 expectedB;
    uint256 expectedC = _expectedLoanValue(idC, WAD); // FullyPaid → factor 1.0

    // Warp 91 days past due dates to put active loans in DQ90
    // All loans have the same nextDueDate since they were created at the same timeNow
    (, , , uint48 nextDueDateB, ) = loans.data(idB);
    vm.warp(uint256(nextDueDateB) + 91 days);

    // Compute DQ90 expectations after the warp (values don't change but call after warp for clarity)
    expectedA = _expectedLoanValue(idA, FACTOR_DQ90);
    expectedB = _expectedLoanValue(idB, FACTOR_DQ90);

    // Loan D: non-existent ID → skipped
    uint64 idD = 9999;

    uint64[] memory ids = new uint64[](4);
    ids[0] = idA;
    ids[1] = idB;
    ids[2] = idC;
    ids[3] = idD;

    uint256 result = calculator.getLoansValue(ILoans(address(loans)), ids);

    uint256 expected = expectedA + expectedB + expectedC;
    assertEq(result, expected, "Mixed portfolio aggregate incorrect");
  }

  function test_GetLoansValue_SkipsCreatedLoan() public {
    // Vault owns the NFT from create() until fund() runs (fund() requires owner=msg.sender).
    // During that window the investor's capital is still idle cash in the vault, so the loan
    // must contribute 0 to NAV; otherwise NAV would double-count the principal.
    uint64 id = _createTestLoan(PRINCIPAL);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    assertEq(calculator.getLoansValue(ILoans(address(loans)), ids), 0, "Created loan must not contribute to NAV");
  }

  function test_GetLoansValue_AppliesClosedFactor_WhenLoanIsClosed() public {
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("refClosed"));

    vm.prank(servicer);
    loans.updateLoanData({loanId: id, status: LoanStatus.Closed, nextDueDate: 0, maturityDate: 0, timestamp: timeNow});

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 result = calculator.getLoansValue(ILoans(address(loans)), ids);
    uint256 expected = _expectedLoanValue(id, FACTOR_CLOSED);

    assertEq(result, expected, "Closed factor not applied correctly");
  }

  function test_GetLoansValue_AppliesCancelledFactor_WhenLoanIsCancelled() public {
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("refCancelled"));

    vm.prank(servicer);
    loans.updateLoanData({
      loanId: id,
      status: LoanStatus.Cancelled,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 result = calculator.getLoansValue(ILoans(address(loans)), ids);
    uint256 expected = _expectedLoanValue(id, FACTOR_CANCELLED);

    assertEq(result, expected, "Cancelled factor not applied correctly");
  }

  function test_GetLoansValue_ReturnsCollectedCash_WhenClosedFactorIsZero() public {
    uint256[8] memory zeroTerminalFactors = [WAD, WAD, WAD, WAD, WAD, WAD, uint256(0), 0];
    NavCalculator zeroCalculator = new NavCalculator(address(this), zeroTerminalFactors);

    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("refClosedZero"));
    uint256 cash = _collectedCash(id);
    assertTrue(cash > 0, "collected cash should be positive");

    vm.prank(servicer);
    loans.updateLoanData({loanId: id, status: LoanStatus.Closed, nextDueDate: 0, maturityDate: 0, timestamp: timeNow});

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    // With factor=0 the unreturned principal is fully written off, but cash already held in Loans
    // for the investor is still real and contributes at par.
    assertEq(
      zeroCalculator.getLoansValue(ILoans(address(loans)), ids),
      cash,
      "Closed at factor 0 must still return collected cash"
    );
  }

  function test_GetLoansValue_ReturnsCollectedCash_WhenCancelledFactorIsZero() public {
    uint256[8] memory zeroTerminalFactors = [WAD, WAD, WAD, WAD, WAD, WAD, uint256(0), 0];
    NavCalculator zeroCalculator = new NavCalculator(address(this), zeroTerminalFactors);

    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("refCancelledZero"));
    uint256 cash = _collectedCash(id);
    assertTrue(cash > 0, "collected cash should be positive");

    vm.prank(servicer);
    loans.updateLoanData({
      loanId: id,
      status: LoanStatus.Cancelled,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    assertEq(
      zeroCalculator.getLoansValue(ILoans(address(loans)), ids),
      cash,
      "Cancelled at factor 0 must still return collected cash"
    );
  }

  function test_GetLoansValue_AggregatesAllStatusBranches() public {
    // Active (DQ90), ChargedOff, Closed, Cancelled, FullyPaid in a single call.
    uint64 idActive = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("aggActive"));
    uint64 idChargedOff = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("aggCharged"));
    uint64 idClosed = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("aggClosed"));
    uint64 idCancelled = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("aggCancelled"));
    uint64 idFullyPaid = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("aggFullyPaid"));

    vm.startPrank(servicer);
    loans.updateLoanData({
      loanId: idChargedOff,
      status: LoanStatus.ChargedOff,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });
    loans.updateLoanData({
      loanId: idClosed,
      status: LoanStatus.Closed,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });
    loans.updateLoanData({
      loanId: idCancelled,
      status: LoanStatus.Cancelled,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });
    loans.updateLoanData({
      loanId: idFullyPaid,
      status: LoanStatus.FullyPaid,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });
    vm.stopPrank();

    (, , , uint48 nextDueDate, ) = loans.data(idActive);
    vm.warp(uint256(nextDueDate) + 91 days);

    uint64[] memory ids = new uint64[](5);
    ids[0] = idActive;
    ids[1] = idChargedOff;
    ids[2] = idClosed;
    ids[3] = idCancelled;
    ids[4] = idFullyPaid;

    uint256 expected = _expectedLoanValue(idActive, FACTOR_DQ90) +
      _expectedLoanValue(idChargedOff, FACTOR_CHARGED_OFF) +
      _expectedLoanValue(idClosed, FACTOR_CLOSED) +
      _expectedLoanValue(idCancelled, FACTOR_CANCELLED) +
      _expectedLoanValue(idFullyPaid, WAD);

    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      expected,
      "Aggregate across all status branches incorrect"
    );
  }

  function test_GetLoansValue_ReturnsRawFaceValue_WhenLoanIsFullyFunded() public {
    uint64 id = _createFullyFundedLoan(PRINCIPAL);
    uint256 expected = _expectedLoanValue(id, WAD);
    assertTrue(expected > 0, "FullyFunded value should be positive");

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    assertEq(calculator.getLoansValue(ILoans(address(loans)), ids), expected, "FullyFunded must not be discounted");
  }

  // ---------------------------------------------------------------------------
  // Regression tests for the "value cash at par, factor only unreturned principal" model.
  // Pre-refactor, the bucket factor was applied to the full face value, so collected cash
  // was unfairly discounted alongside the credit-exposed principal. These pin the new behavior.
  // ---------------------------------------------------------------------------

  function test_GetLoansValue_DoesNotDiscountWithdrawablePrincipal_OnDelinquentLoan() public {
    // 100k loan, borrower repaid 30k principal not yet withdrawn by investor, then warp to DQ90.
    // Expected NAV = 70k * 0.25 + 30k = 47_500e6.
    // Pre-refactor: (70k + 30k) * 0.25 = 25_000e6.
    uint64 id = _createActiveLoan(PRINCIPAL);

    int128 principalRepayment = 30_000e6;
    uint256 outstandingPrincipal = 70_000e6; // PRINCIPAL - principalRepayment
    vm.prank(servicer);
    loans.accrue(id, principalRepayment, timeNow, bytes32("regr1"));

    usdc.mint(borrower, uint256(uint128(principalRepayment)));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);
    vm.prank(borrower);
    loans.pay(id, principalRepayment, timeNow, bytes32("regr1"));

    vm.prank(servicer);
    loans.applyWaterfall(id, 0, 0, 0, principalRepayment, 0, timeNow, bytes32("regr1"));

    (, , , uint48 nextDueDate, ) = loans.data(id);
    vm.warp(uint256(nextDueDate) + 91 days);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 unreturned = _unreturnedInvestorPrincipal(id);
    uint256 cash = _collectedCash(id);
    assertEq(unreturned, outstandingPrincipal, "unreturned principal mismatch");
    assertEq(cash, 30_000e6, "collected cash mismatch");

    uint256 expected = (outstandingPrincipal * FACTOR_DQ90) / WAD + cash;
    assertEq(expected, 47_500e6, "sanity: NAV should be 47.5k");
    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      expected,
      "NAV must value collected principal at par"
    );
  }

  function test_GetLoansValue_HonorsInvestorInterestAtPar_OnDelinquentLoan() public {
    // 100k loan, 90e6 investor interest allocated and not withdrawn, no principal repaid,
    // then warp to DQ90. Interest should not be discounted by the bucket factor.
    uint64 id = _createActiveLoan(PRINCIPAL);

    int128 interestPayment = 90e6;
    vm.prank(servicer);
    loans.accrue(id, interestPayment, timeNow, bytes32("regr2"));

    usdc.mint(borrower, uint256(uint128(interestPayment)));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);
    vm.prank(borrower);
    loans.pay(id, interestPayment, timeNow, bytes32("regr2"));

    vm.prank(servicer);
    loans.applyWaterfall(id, 0, 0, interestPayment, 0, 0, timeNow, bytes32("regr2"));

    (, , , uint48 nextDueDate, ) = loans.data(id);
    vm.warp(uint256(nextDueDate) + 91 days);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 unreturned = _unreturnedInvestorPrincipal(id);
    uint256 cash = _collectedCash(id);
    assertEq(unreturned, uint128(PRINCIPAL), "full principal still outstanding");
    assertEq(cash, 90e6, "only interest is withdrawable");

    uint256 expected = (uint128(PRINCIPAL) * FACTOR_DQ90) / WAD + 90e6;
    assertEq(calculator.getLoansValue(ILoans(address(loans)), ids), expected, "Interest must contribute at par");
  }

  function test_GetLoansValue_HonorsUnWithdrawnCashOnClosedLoan() public {
    // Closed loan with leftover cash that the investor hasn't withdrawn yet.
    // Even at the default Closed factor, the cash must contribute at par.
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("regr3"));

    vm.prank(servicer);
    loans.updateLoanData({loanId: id, status: LoanStatus.Closed, nextDueDate: 0, maturityDate: 0, timestamp: timeNow});

    uint256 unreturned = _unreturnedInvestorPrincipal(id);
    uint256 cash = _collectedCash(id);
    assertTrue(cash > 0, "loan should have un-withdrawn cash");

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 expected = (unreturned * FACTOR_CLOSED) / WAD + cash;
    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      expected,
      "Closed loan must add un-withdrawn cash at par"
    );
  }

  function test_GetLoansValue_AppliesClosedFactor_ToResidualPrincipal_WhenNoCashCollected() public {
    // Servicer flips a freshly-disbursed loan to Closed with no payments made.
    // outstandingInvestorPrincipal = PRINCIPAL, collectedCash = 0.
    // NAV must equal PRINCIPAL * closedFactor.
    uint64 id = _createActiveLoan(PRINCIPAL);

    vm.prank(servicer);
    loans.updateLoanData({loanId: id, status: LoanStatus.Closed, nextDueDate: 0, maturityDate: 0, timestamp: timeNow});

    uint256 unreturned = _unreturnedInvestorPrincipal(id);
    uint256 cash = _collectedCash(id);
    assertEq(unreturned, uint128(PRINCIPAL), "all principal should still be outstanding");
    assertEq(cash, 0, "no cash should be collected");

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 expected = (uint128(PRINCIPAL) * FACTOR_CLOSED) / WAD;
    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      expected,
      "Residual principal must be discounted by Closed factor"
    );
  }

  function test_GetLoansValue_UsesFullPar_WhenLoanIsFullyPaid() public {
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("fullyPaid"));

    vm.prank(servicer);
    loans.updateLoanData({
      loanId: id,
      status: LoanStatus.FullyPaid,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    uint256 expected = _expectedLoanValue(id, WAD);
    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      expected,
      "FullyPaid must contribute at par (factor = WAD)"
    );
  }

  function test_GetLoansValue_UsesCurrentFactor_WhenActiveLoanHasZeroNextDueDate() public {
    // Active loans normally always carry a nextDueDate, but the DPD branch is guarded by
    // `nextDueDate != 0`. Mock the Loans response to exercise that fall-through and confirm
    // the loan is bucketed as Current rather than reverting on an unsigned-subtraction underflow.
    uint64[] memory ids = new uint64[](1);
    ids[0] = 42;

    LoanValue[] memory mocked = new LoanValue[](1);
    mocked[0] = LoanValue({
      outstandingInvestorPrincipal: PRINCIPAL,
      investorPrincipalWithdrawable: 0,
      investorInterestWithdrawable: 0,
      status: LoanStatus.Active,
      nextDueDate: 0
    });

    vm.mockCall(address(loans), abi.encodeWithSelector(loans.getLoanValues.selector, ids), abi.encode(mocked));

    // Warp far into the future to prove time doesn't matter when nextDueDate is unset.
    vm.warp(block.timestamp + 365 days);

    uint256 expected = (uint128(PRINCIPAL) * FACTOR_CURRENT) / WAD;
    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      expected,
      "Active with nextDueDate=0 must use Current factor"
    );
  }

  function test_GetLoansValue_ClampsNegativeCollectedCash_ToZero() public {
    // Defensive clamp: collectedCash = principalWithdrawable + interestWithdrawable; if the
    // ledger ever produces a net-negative sum, NAV must treat it as 0 rather than wrapping.
    uint64[] memory ids = new uint64[](1);
    ids[0] = 7;

    LoanValue[] memory mocked = new LoanValue[](1);
    mocked[0] = LoanValue({
      outstandingInvestorPrincipal: 100_000e6,
      investorPrincipalWithdrawable: -40_000e6,
      investorInterestWithdrawable: -10_000e6,
      status: LoanStatus.Active,
      nextDueDate: uint48(block.timestamp + 30 days)
    });

    vm.mockCall(address(loans), abi.encodeWithSelector(loans.getLoanValues.selector, ids), abi.encode(mocked));

    // unreturnedInvestorPrincipal = 100k - (-40k) = 140k
    // collectedCash = -40k + -10k = -50k → clamped to 0
    // expected = 140k * 1.0 + 0
    uint256 expected = 140_000e6;
    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      expected,
      "Negative collected cash must clamp to zero"
    );
  }

  function test_GetLoansValue_ClampsNegativeUnreturnedPrincipal_ToZero() public {
    // Defensive clamp: unreturned = outstandingInvestorPrincipal - principalWithdrawable; if the
    // withdrawable exceeds the outstanding (e.g. borrower overpayment allocated as principal),
    // the difference must be clamped to 0 rather than wrapping under uint cast.
    uint64[] memory ids = new uint64[](1);
    ids[0] = 8;

    LoanValue[] memory mocked = new LoanValue[](1);
    mocked[0] = LoanValue({
      outstandingInvestorPrincipal: 10_000e6,
      investorPrincipalWithdrawable: 30_000e6,
      investorInterestWithdrawable: 5_000e6,
      status: LoanStatus.Active,
      nextDueDate: uint48(block.timestamp + 30 days)
    });

    vm.mockCall(address(loans), abi.encodeWithSelector(loans.getLoanValues.selector, ids), abi.encode(mocked));

    // unreturned = 10k - 30k = -20k → clamped to 0
    // collectedCash = 30k + 5k = 35k
    // expected = 0 * 1.0 + 35k
    uint256 expected = 35_000e6;
    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      expected,
      "Negative unreturned principal must clamp to zero"
    );
  }
}

contract NavCalculator_ConstructorTest is LoansTestBase {
  uint256 internal constant WAD = 1e18;

  function test_Constructor_Reverts_WhenClosedFactorExceedsWad() public {
    uint256[8] memory factors = [WAD, WAD, WAD, WAD, WAD, WAD, WAD + 1, uint256(0)];
    vm.expectRevert(INavCalculator.FactorExceedsWad.selector);
    new NavCalculator(address(this), factors);
  }

  function test_Constructor_Reverts_WhenCancelledFactorExceedsWad() public {
    uint256[8] memory factors = [WAD, WAD, WAD, WAD, WAD, WAD, uint256(0), WAD + 1];
    vm.expectRevert(INavCalculator.FactorExceedsWad.selector);
    new NavCalculator(address(this), factors);
  }

  function test_Constructor_StoresClosedAndCancelledFactors() public {
    uint256 closedFactor = 0.6e18;
    uint256 cancelledFactor = 0.3e18;
    uint256[8] memory factors = [WAD, WAD, WAD, WAD, WAD, WAD, closedFactor, cancelledFactor];

    NavCalculator nav = new NavCalculator(address(this), factors);

    assertEq(nav.getDiscountFactor(ValuationBucket.Closed), closedFactor);
    assertEq(nav.getDiscountFactor(ValuationBucket.Cancelled), cancelledFactor);
  }
}

contract NavCalculator_SetDiscountFactorTest is LoansTestBase {
  uint256 internal constant WAD = 1e18;

  NavCalculator public calculator;
  address public calculatingAgent = makeAddr("calculatingAgent");

  function setUp() public override {
    super.setUp();
    uint256[8] memory factors = [WAD, WAD, WAD, WAD, WAD, WAD, uint256(0), uint256(0)];
    calculator = new NavCalculator(address(this), factors);
    calculator.grantRole(calculator.CALCULATING_AGENT(), calculatingAgent);
  }

  function test_SetDiscountFactor_UpdatesClosedBucket_AndEmits() public {
    uint256 newFactor = 0.55e18;

    vm.expectEmit(true, true, true, true);
    emit INavCalculator.DiscountFactorUpdated(ValuationBucket.Closed, newFactor);

    vm.prank(calculatingAgent);
    calculator.setDiscountFactor(ValuationBucket.Closed, newFactor);

    assertEq(calculator.getDiscountFactor(ValuationBucket.Closed), newFactor);
  }

  function test_SetDiscountFactor_UpdatesCancelledBucket_AndEmits() public {
    uint256 newFactor = 0.25e18;

    vm.expectEmit(true, true, true, true);
    emit INavCalculator.DiscountFactorUpdated(ValuationBucket.Cancelled, newFactor);

    vm.prank(calculatingAgent);
    calculator.setDiscountFactor(ValuationBucket.Cancelled, newFactor);

    assertEq(calculator.getDiscountFactor(ValuationBucket.Cancelled), newFactor);
  }

  function test_SetDiscountFactor_AffectsSubsequentValuation_ForClosedLoan() public {
    int128 loanPrincipal = 100_000e6;
    uint64 id = _createLoanWithInvestorCashflow(loanPrincipal, bytes32("setClosed"));

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    (uint256 principal, uint256 cash) = splitLoanValue(loans.getLoanValues(ids)[0]);

    vm.prank(servicer);
    loans.updateLoanData({loanId: id, status: LoanStatus.Closed, nextDueDate: 0, maturityDate: 0, timestamp: timeNow});

    // Initially Closed factor=0 → unreturned principal fully written off, but collected cash contributes at par.
    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      cash,
      "Closed at factor 0 should equal collected cash"
    );

    uint256 newFactor = 0.4e18;
    vm.prank(calculatingAgent);
    calculator.setDiscountFactor(ValuationBucket.Closed, newFactor);

    assertEq(
      calculator.getLoansValue(ILoans(address(loans)), ids),
      (principal * newFactor) / WAD + cash,
      "Updated Closed factor not reflected in valuation"
    );
  }

  function test_SetDiscountFactor_Reverts_WhenFactorExceedsWad() public {
    vm.prank(calculatingAgent);
    vm.expectRevert(INavCalculator.FactorExceedsWad.selector);
    calculator.setDiscountFactor(ValuationBucket.Closed, WAD + 1);
  }

  function test_SetDiscountFactor_Reverts_ForNonCalculatingAgent() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        randomUser,
        calculator.CALCULATING_AGENT()
      )
    );
    vm.prank(randomUser);
    calculator.setDiscountFactor(ValuationBucket.Cancelled, 0.5e18);
  }
}

contract NavCalculator_PortfolioFactorTest is LoansTestBase {
  uint256 internal constant WAD = 1e18;
  uint256 internal constant DEFAULT_MAX_PORTFOLIO_FACTOR = 2e18;
  uint256 internal constant RAISED_MAX_PORTFOLIO_FACTOR = 5e18;
  uint256 internal constant RAISED_PORTFOLIO_FACTOR = 4e18;
  uint256 internal constant LOWERED_MAX_PORTFOLIO_FACTOR = 1.5e18;
  uint256 internal constant CURRENT_PORTFOLIO_FACTOR = 1.8e18;

  NavCalculator public calculator;
  address public calculatingAgent = makeAddr("calculatingAgent");

  function setUp() public override {
    super.setUp();

    uint256[8] memory factors = [WAD, WAD, WAD, WAD, WAD, WAD, WAD, WAD];
    calculator = new NavCalculator(address(this), factors);
    calculator.grantRole(calculator.CALCULATING_AGENT(), calculatingAgent);
  }

  function test_PortfolioFactor_DefaultsToWad() public view {
    assertEq(calculator.portfolioFactor(), WAD);
  }

  function test_ApplyPortfolioAdjustment_ReturnsSameValue_ByDefault() public view {
    assertEq(calculator.applyPortfolioAdjustment(1_000_000e6), 1_000_000e6);
  }

  function test_ApplyPortfolioAdjustment_AppliesDiscount_WhenFactorBelowWad() public {
    vm.prank(calculatingAgent);
    calculator.setPortfolioFactor(0.95e18);

    assertEq(calculator.applyPortfolioAdjustment(1_000_000e6), 950_000e6);
  }

  function test_ApplyPortfolioAdjustment_AppliesPremium_WhenFactorAboveWad() public {
    vm.prank(calculatingAgent);
    calculator.setPortfolioFactor(1.02e18);

    assertEq(calculator.applyPortfolioAdjustment(1_000_000e6), 1_020_000e6);
  }

  function test_SetPortfolioFactor_EmitsEvent() public {
    vm.prank(calculatingAgent);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.PortfolioFactorUpdated(1.05e18);
    calculator.setPortfolioFactor(1.05e18);
  }

  function test_SetPortfolioFactor_RevertsAboveCap() public {
    vm.prank(calculatingAgent);
    vm.expectRevert(INavCalculator.FactorExceedsCap.selector);
    calculator.setPortfolioFactor(DEFAULT_MAX_PORTFOLIO_FACTOR + 1);
  }

  function test_MaxPortfolioFactor_DefaultsTo2Wad() public view {
    assertEq(calculator.maxPortfolioFactor(), DEFAULT_MAX_PORTFOLIO_FACTOR);
  }

  function test_SetMaxPortfolioFactor_RaisesCap_AllowsHigherFactor() public {
    calculator.setMaxPortfolioFactor(RAISED_MAX_PORTFOLIO_FACTOR);
    assertEq(calculator.maxPortfolioFactor(), RAISED_MAX_PORTFOLIO_FACTOR);

    vm.prank(calculatingAgent);
    calculator.setPortfolioFactor(RAISED_PORTFOLIO_FACTOR);
    assertEq(calculator.portfolioFactor(), RAISED_PORTFOLIO_FACTOR);
  }

  function test_SetMaxPortfolioFactor_EmitsEvent() public {
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.MaxPortfolioFactorUpdated(RAISED_MAX_PORTFOLIO_FACTOR);
    calculator.setMaxPortfolioFactor(RAISED_MAX_PORTFOLIO_FACTOR);
  }

  function test_SetMaxPortfolioFactor_LoweringClampsCurrentFactor() public {
    vm.prank(calculatingAgent);
    calculator.setPortfolioFactor(CURRENT_PORTFOLIO_FACTOR);

    vm.expectEmit(true, true, true, true);
    emit INavCalculator.MaxPortfolioFactorUpdated(LOWERED_MAX_PORTFOLIO_FACTOR);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.PortfolioFactorUpdated(LOWERED_MAX_PORTFOLIO_FACTOR);
    calculator.setMaxPortfolioFactor(LOWERED_MAX_PORTFOLIO_FACTOR);

    assertEq(calculator.maxPortfolioFactor(), LOWERED_MAX_PORTFOLIO_FACTOR);
    assertEq(calculator.portfolioFactor(), LOWERED_MAX_PORTFOLIO_FACTOR);
  }

  function test_SetMaxPortfolioFactor_RevertsForNonGuardian() public {
    bytes32 guardianRole = calculator.GUARDIAN_ROLE();
    vm.prank(calculatingAgent);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, calculatingAgent, guardianRole)
    );
    calculator.setMaxPortfolioFactor(RAISED_MAX_PORTFOLIO_FACTOR);
  }

  function test_SetPortfolioFactor_RevertsForNonCalculatingAgent() public {
    vm.expectRevert();
    calculator.setPortfolioFactor(0.9e18);
  }

  function test_GetLoansValueAndAdjust_ComposesDpdWithPortfolioFactor() public {
    uint256 FACTOR_DQ60 = 0.40e18;
    uint256 PORTFOLIO_FACTOR = 0.95e18;

    uint256[8] memory factors = [WAD, WAD, FACTOR_DQ60, WAD, WAD, WAD, WAD, WAD];
    NavCalculator realCalculator = new NavCalculator(address(this), factors);
    realCalculator.grantRole(realCalculator.CALCULATING_AGENT(), calculatingAgent);

    vm.prank(calculatingAgent);
    realCalculator.setPortfolioFactor(PORTFOLIO_FACTOR);

    int128 PRINCIPAL = 100_000e6;
    uint64 id = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("compose"));

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    (uint256 principal, uint256 cash) = splitLoanValue(loans.getLoanValues(ids)[0]);
    assertTrue(principal > 0, "unreturned principal should be positive");

    (, , , uint48 nextDueDate, ) = loans.data(id);
    vm.warp(uint256(nextDueDate) + 61 days);

    uint256 expectedDpd = (principal * FACTOR_DQ60) / WAD + cash;
    uint256 expectedFinal = (expectedDpd * PORTFOLIO_FACTOR) / WAD;

    uint256 dpdDiscounted = realCalculator.getLoansValue(ILoans(address(loans)), ids);
    uint256 finalValue = realCalculator.applyPortfolioAdjustment(dpdDiscounted);

    assertEq(dpdDiscounted, expectedDpd, "DPD discount incorrect");
    assertEq(finalValue, expectedFinal, "Composed factor incorrect");
  }

  function test_GetLoansValueAndAdjust_ComposesClosedAndCancelledWithPortfolioFactor() public {
    uint256 FACTOR_CLOSED = 0.50e18;
    uint256 FACTOR_CANCELLED = 0.20e18;
    uint256 PORTFOLIO_FACTOR = 0.90e18;

    uint256[8] memory factors = [WAD, WAD, WAD, WAD, WAD, WAD, FACTOR_CLOSED, FACTOR_CANCELLED];
    NavCalculator realCalculator = new NavCalculator(address(this), factors);
    realCalculator.grantRole(realCalculator.CALCULATING_AGENT(), calculatingAgent);

    vm.prank(calculatingAgent);
    realCalculator.setPortfolioFactor(PORTFOLIO_FACTOR);

    int128 PRINCIPAL = 100_000e6;
    uint64 idClosed = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("composeClosed"));
    uint64 idCancelled = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("composeCancelled"));

    uint64[] memory faceIds = new uint64[](2);
    faceIds[0] = idClosed;
    faceIds[1] = idCancelled;
    LoanValue[] memory loanValues = loans.getLoanValues(faceIds);

    (uint256 principalClosed, uint256 cashClosed) = splitLoanValue(loanValues[0]);
    (uint256 principalCancelled, uint256 cashCancelled) = splitLoanValue(loanValues[1]);

    vm.startPrank(servicer);
    loans.updateLoanData({
      loanId: idClosed,
      status: LoanStatus.Closed,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });
    loans.updateLoanData({
      loanId: idCancelled,
      status: LoanStatus.Cancelled,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });
    vm.stopPrank();

    uint256 expectedBucketed = (principalClosed * FACTOR_CLOSED) /
      WAD +
      cashClosed +
      (principalCancelled * FACTOR_CANCELLED) /
      WAD +
      cashCancelled;
    uint256 expectedFinal = (expectedBucketed * PORTFOLIO_FACTOR) / WAD;

    uint256 bucketed = realCalculator.getLoansValue(ILoans(address(loans)), faceIds);
    assertEq(bucketed, expectedBucketed, "Terminal bucket discount incorrect");
    assertEq(realCalculator.applyPortfolioAdjustment(bucketed), expectedFinal, "Composed terminal factor incorrect");
  }
}

contract NavCalculator_ConfigurationVersionTest is LoansTestBase {
  uint256 internal constant WAD = 1e18;

  NavCalculator public calculator;
  address public calculatingAgent = makeAddr("calculatingAgent");

  function setUp() public override {
    super.setUp();

    uint256[8] memory initialFactors = [WAD, WAD, WAD, WAD, WAD, WAD, 0, 0];
    calculator = new NavCalculator(address(this), initialFactors);
    calculator.grantRole(calculator.CALCULATING_AGENT(), calculatingAgent);
  }

  function test_ConfigurationVersion_DefaultsToOne() public view {
    assertEq(calculator.configurationVersion(), 1);
  }

  function test_SetDiscountFactor_BumpsVersionAndEmits() public {
    uint256 before = calculator.configurationVersion();

    vm.prank(calculatingAgent);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.DiscountFactorUpdated(ValuationBucket.DQ30, 0.9e18);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.ConfigurationVersionBumped(before + 1);
    calculator.setDiscountFactor(ValuationBucket.DQ30, 0.9e18);

    assertEq(calculator.configurationVersion(), before + 1);
  }

  function test_SetPortfolioFactor_BumpsVersion() public {
    uint256 before = calculator.configurationVersion();

    vm.prank(calculatingAgent);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.PortfolioFactorUpdated(0.95e18);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.ConfigurationVersionBumped(before + 1);
    calculator.setPortfolioFactor(0.95e18);

    assertEq(calculator.configurationVersion(), before + 1);
  }

  function test_SetMaxPortfolioFactor_DoesNotBump_WhenNoClamp() public {
    uint256 before = calculator.configurationVersion();

    calculator.setMaxPortfolioFactor(3e18);

    assertEq(calculator.configurationVersion(), before, "no clamp must not bump version");
  }

  function test_SetMaxPortfolioFactor_BumpsVersion_WhenClamping() public {
    vm.prank(calculatingAgent);
    calculator.setPortfolioFactor(1.8e18);
    uint256 before = calculator.configurationVersion();

    vm.expectEmit(true, true, true, true);
    emit INavCalculator.MaxPortfolioFactorUpdated(1.5e18);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.ConfigurationVersionBumped(before + 1);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.PortfolioFactorUpdated(1.5e18);
    calculator.setMaxPortfolioFactor(1.5e18);

    assertEq(calculator.configurationVersion(), before + 1);
  }

  function test_MultipleBumps_IncreaseMonotonically() public {
    uint256 before = calculator.configurationVersion();

    vm.startPrank(calculatingAgent);

    vm.expectEmit(true, true, true, true);
    emit INavCalculator.DiscountFactorUpdated(ValuationBucket.Current, 0.99e18);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.ConfigurationVersionBumped(before + 1);
    calculator.setDiscountFactor(ValuationBucket.Current, 0.99e18);

    vm.expectEmit(true, true, true, true);
    emit INavCalculator.PortfolioFactorUpdated(0.9e18);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.ConfigurationVersionBumped(before + 2);
    calculator.setPortfolioFactor(0.9e18);

    vm.expectEmit(true, true, true, true);
    emit INavCalculator.DiscountFactorUpdated(ValuationBucket.DQ60, 0.5e18);
    vm.expectEmit(true, true, true, true);
    emit INavCalculator.ConfigurationVersionBumped(before + 3);
    calculator.setDiscountFactor(ValuationBucket.DQ60, 0.5e18);

    vm.stopPrank();

    assertEq(calculator.configurationVersion(), before + 3);
  }
}
