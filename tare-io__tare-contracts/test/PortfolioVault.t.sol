// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {PortfolioVault} from "contracts/PortfolioVault.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockNavCalculator} from "test/lib/MockNavCalculator.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";
import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";
import {ILoansExchange} from "contracts/interfaces/ILoansExchange.sol";
import {IVaultShareToken} from "contracts/interfaces/IVaultShareToken.sol";
import {INavCalculator} from "contracts/interfaces/INavCalculator.sol";
import {LoansExchange} from "contracts/LoansExchange.sol";
import {Loans} from "contracts/Loans.sol";
import {LoansNFT} from "contracts/LoansNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PortfolioVault_UpdateNavTest is VaultTestBase {
  int128 constant PRINCIPAL = 25_000e6;

  function setUp() public override {
    super.setUp();

    // Also grant PORTFOLIO_MANAGER (base grants INVESTOR_MANAGER)
    bytes32 pm = vault.PORTFOLIO_MANAGER();
    vm.prank(guardian);
    vault.grantRole(pm, manager);
  }

  // ──────────────────────────── Tests ─────────────────────────────

  function test_UpdateNav_FinalizesNav_WhenSingleBatchCoversPortfolio() public {
    // Create 2 loans owned by investor, then transfer NFTs to vault
    uint64 idA = _createActiveLoan(PRINCIPAL);
    uint64 idB = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);

    // Seed vault with some USDC (idle cash)
    uint256 idleCash = 10_000e6;
    usdc.mint(address(vault), idleCash);

    // Configure mock calculator to return a specific total (mock value indepedent of loan Ids received)
    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);

    // Single batch large enough to cover all loans
    vm.prank(manager);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavUpdated(idleCash + DEFAULT_LOAN_VALUATION, timeNow);
    vault.updateNav(NAV_BATCH_SIZE);

    assertEq(vault.lastNav(), idleCash + DEFAULT_LOAN_VALUATION, "NAV incorrect");
    assertEq(vault.lastNavUpdate(), timeNow, "lastNavUpdate not set");
    assertEq(vault.navCursor(), 0, "cursor not reset");
    assertEq(vault.navStart(), 0, "navStart not reset");
  }

  function test_UpdateNav_AccumulatesPendingNav_WhenMultipleBatchesNeeded() public {
    // Create 3 loans and transfer to vault
    uint64 idA = _createActiveLoan(PRINCIPAL);
    uint64 idB = _createActiveLoan(PRINCIPAL);
    uint64 idC = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);
    _transferLoanToVault(idC);

    uint256 idleCash = 5_000e6;
    usdc.mint(address(vault), idleCash);

    uint256 batchValue = 20_000e6;
    mockCalculator.setNextValuation(batchValue);

    // First batch: process 2 of 3 loans — should NOT finalize
    vm.prank(manager);
    vault.updateNav(2);

    assertEq(vault.navCursor(), 2, "cursor should be at 2 after first batch");
    assertEq(vault.pendingNav(), batchValue, "pendingNav should accumulate first batch");
    assertEq(vault.lastNav(), 0, "NAV should not be finalized yet");
    assertTrue(vault.navStart() > 0, "navStart should be set during computation");

    // Second batch: process remaining 1 loan — should finalize
    mockCalculator.setNextValuation(batchValue);
    vm.prank(manager);
    vault.updateNav(2);

    uint256 expectedNav = idleCash + batchValue + batchValue;
    assertEq(vault.lastNav(), expectedNav, "finalized NAV incorrect");
    assertEq(vault.navCursor(), 0, "cursor not reset after finalization");
    assertEq(vault.navStart(), 0, "navStart not reset after finalization");
  }

  function test_UpdateNav_RestartsComputation_WhenTimedOut() public {
    uint64 idA = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);

    // Need at least 2 loans so first batch doesn't finalize
    uint64 idB = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idB);

    uint256 firstBatchMockValue = 10_000e6;
    uint256 secondBatchMockValue = 77_777e6;
    mockCalculator.setNextValuation(firstBatchMockValue);

    // Start a partial computation (process 1 of 2)
    vm.prank(manager);
    vault.updateNav(1);

    uint256 pendingNavBefore = vault.pendingNav();
    assertEq(pendingNavBefore, firstBatchMockValue, "pendingNav should reflect stale batch");

    // Warp past maxNavComputationTime
    timeNow += uint48(MAX_NAV_COMPUTATION_TIME + 1);
    vm.warp(uint256(timeNow));

    // Update calculator to return a different value — proves the restart uses fresh data
    mockCalculator.setNextValuation(secondBatchMockValue);

    // Next call should restart: cursor and pendingNav reset
    vm.prank(manager);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavComputationStarted(timeNow);
    vault.updateNav(1);

    // The computation restarted — pendingNav should reflect only the fresh batch, not the stale one
    assertEq(vault.pendingNav(), secondBatchMockValue, "pendingNav should reflect only fresh batch after restart");
    assertEq(vault.navCursor(), 1, "cursor should be 1 after restart + 1 batch");
  }

  function test_UpdateNav_AppliesPortfolioAdjustment_WhenFinalized() public {
    uint64 idA = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);

    uint256 idleCash = 10_000e6;
    usdc.mint(address(vault), idleCash);

    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    mockCalculator.setPortfolioFactor(0.95e18);

    vm.prank(manager);
    vault.updateNav(NAV_BATCH_SIZE);

    uint256 adjustedLoanValue = (DEFAULT_LOAN_VALUATION * 0.95e18) / WAD;
    assertEq(vault.lastNav(), idleCash + adjustedLoanValue, "NAV should reflect portfolio adjustment");
  }

  function test_UpdateNav_AppliesPortfolioPremium_WhenFactorAboveWad() public {
    uint64 idA = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);

    uint256 idleCash = 10_000e6;
    usdc.mint(address(vault), idleCash);

    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    mockCalculator.setPortfolioFactor(1.02e18);

    vm.prank(manager);
    vault.updateNav(NAV_BATCH_SIZE);

    uint256 adjustedLoanValue = (DEFAULT_LOAN_VALUATION * 1.02e18) / WAD;
    assertEq(vault.lastNav(), idleCash + adjustedLoanValue, "NAV should reflect portfolio premium");
  }

  function test_UpdateNav_Reverts_WhenBatchSizeIsZero() public {
    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.ZeroAmount.selector);
    vault.updateNav(0);
  }

  // ──────────── Ownership-nonce restart invariant ──────────────

  function test_UpdateNav_RestartsComputation_WhenNftLeavesVaultMidCycle() public {
    // Create 3 loans so we need multiple batches
    uint64 idA = _createActiveLoan(PRINCIPAL);
    uint64 idB = _createActiveLoan(PRINCIPAL);
    uint64 idC = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);
    _transferLoanToVault(idC);

    uint256 firstBatchValue = 10_000e6;
    mockCalculator.setNextValuation(firstBatchValue);

    // Process 1 of 3
    vm.prank(manager);
    vault.updateNav(1);
    assertEq(vault.navCursor(), 1, "cursor advanced after first batch");
    assertEq(vault.pendingNav(), firstBatchValue, "pendingNav set after first batch");

    // Simulate an exchange-driven transfer: NFT leaves the vault between batches.
    vm.prank(address(vault));
    loansNFT.transferFrom(address(vault), loanBuyer, uint256(idC));

    // Next batch must restart: pendingNav cleared, cursor reset, fresh start emitted.
    uint256 freshBatchValue = 50_000e6;
    mockCalculator.setNextValuation(freshBatchValue);

    vm.prank(manager);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavComputationStarted(timeNow);
    vault.updateNav(1);

    assertEq(vault.pendingNav(), freshBatchValue, "pendingNav should reflect only the fresh batch after restart");
    assertEq(vault.navCursor(), 1, "cursor should be 1 after restart + 1 batch");
  }

  function test_UpdateNav_RestartsComputation_WhenNftEntersVaultMidCycle() public {
    uint64 idA = _createActiveLoan(PRINCIPAL);
    uint64 idB = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);

    uint256 firstBatchValue = 10_000e6;
    mockCalculator.setNextValuation(firstBatchValue);

    vm.prank(manager);
    vault.updateNav(1);
    assertEq(vault.navCursor(), 1);
    assertEq(vault.pendingNav(), firstBatchValue);

    // A new loan NFT is transferred into the vault mid-cycle. We do it raw
    // (without `addLoansToNav`, which would revert during a NAV cycle) to
    // simulate an unsolicited transfer that bumps the ownership nonce.
    uint64 idC = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(idC));

    uint256 freshBatchValue = 33_000e6;
    mockCalculator.setNextValuation(freshBatchValue);

    vm.prank(manager);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavComputationStarted(timeNow);
    vault.updateNav(1);

    assertEq(vault.pendingNav(), freshBatchValue, "pendingNav should reflect only the fresh batch after restart");
    assertEq(vault.navCursor(), 1, "cursor should be 1 after restart + 1 batch");
  }

  function test_UpdateNav_FinalizesCorrectNav_AfterMidCycleNftExit() public {
    // Race scenario: loan exits during NAV cycle, sale proceeds land in vault as USDC.
    // After the forced restart, the finalized NAV must reflect the post-transfer
    // portfolio (2 loans) plus the cash, with no double counting.
    uint64 idA = _createActiveLoan(PRINCIPAL);
    uint64 idB = _createActiveLoan(PRINCIPAL);
    uint64 idC = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);
    _transferLoanToVault(idC);

    uint256 idleCash = 5_000e6;
    usdc.mint(address(vault), idleCash);

    uint256 perLoanValue = 10_000e6;
    mockCalculator.setNextValuation(perLoanValue);

    // First batch: process 1 of 3
    vm.prank(manager);
    vault.updateNav(1);

    // Mid-cycle: NFT idC sold, sale proceeds (saleProceeds USDC) land in vault.
    vm.prank(address(vault));
    loansNFT.transferFrom(address(vault), loanBuyer, uint256(idC));
    uint256 saleProceeds = 9_000e6;
    usdc.mint(address(vault), saleProceeds);

    // Configure post-restart valuation: 2 remaining loans valued at perLoanValue each.
    uint256 postRestartLoansValue = 2 * perLoanValue;
    mockCalculator.setNextValuation(postRestartLoansValue);

    // Single batch large enough to finalize the restarted cycle.
    vm.prank(manager);
    vault.updateNav(NAV_BATCH_SIZE);

    uint256 expectedNav = idleCash + saleProceeds + postRestartLoansValue;
    assertEq(vault.lastNav(), expectedNav, "finalized NAV should not double-count the sold loan");
    assertEq(vault.navCursor(), 0, "cursor reset");
    assertEq(vault.navStart(), 0, "navStart reset");
  }

  function test_UpdateNav_DropsLoan_WhenOwnerOfReverts() public {
    // Simulates a burned/nonexistent NFT in the curated list: `ownerOf` reverts.
    // The loop must self-heal by dropping the entry, not brick NAV computation.
    uint64 idA = _createActiveLoan(PRINCIPAL);
    uint64 idB = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);

    uint256 countBefore = vault.navLoanCount();
    assertEq(countBefore, 2, "both loans in NAV list");

    // Make `ownerOf(idA)` revert as if the token were burned.
    vm.mockCallRevert(address(loansNFT), abi.encodeWithSignature("ownerOf(uint256)", uint256(idA)), "NOT_MINTED");

    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);

    vm.prank(manager);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanRemovedFromNav(idA);
    vault.updateNav(NAV_BATCH_SIZE);

    assertFalse(vault.isInNav(idA), "reverting loan should be dropped from list");
    assertTrue(vault.isInNav(idB), "healthy loan should remain");
    assertEq(vault.navLoanCount(), 1, "list should have shrunk by one");
    assertEq(vault.lastNav(), DEFAULT_LOAN_VALUATION, "NAV finalized using remaining loan");
    assertEq(vault.navStart(), 0, "navStart reset after finalization");
  }
}

contract PortfolioVault_SettersTest is VaultTestBase {
  address public vaultAdmin = makeAddr("vaultAdmin");

  function setUp() public override {
    super.setUp();

    vm.prank(guardian);
    vault.grantRole(adminRole, vaultAdmin);
  }

  function _startNavComputation() internal {
    uint64 idA = _createActiveLoan(25_000e6);
    uint64 idB = _createActiveLoan(25_000e6);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);

    bytes32 pm = vault.PORTFOLIO_MANAGER();
    vm.prank(guardian);
    vault.grantRole(pm, address(this));
    vault.updateNav(1);
    assertTrue(vault.navStart() > 0);
  }

  // ──────────────── setCalculator (guardian-only) ─────────────────

  function test_SetCalculator_UpdatesCalculator() public {
    MockNavCalculator newCalc = new MockNavCalculator();
    vm.prank(guardian);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.CalculatorUpdated(address(newCalc));
    vault.setCalculator(address(newCalc));
    assertEq(address(vault.calculator()), address(newCalc));
  }

  function test_SetCalculator_RevertsIfNotGuardian() public {
    vm.prank(vaultAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, vaultAdmin, guardianRole)
    );
    vault.setCalculator(makeAddr("newCalc"));
  }

  function test_SetCalculator_RevertsIfZeroAddress() public {
    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.ZeroAddress.selector);
    vault.setCalculator(address(0));
  }

  function test_SetCalculator_RevertsIfNavInProgress() public {
    _startNavComputation();

    MockNavCalculator newCalc = new MockNavCalculator();
    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.setCalculator(address(newCalc));
  }

  // ──────────────── setLoans (guardian-only) ─────────────────────

  function _deployCompatibleLoansPair() internal returns (Loans newLoans, LoansNFT newLoansNFT) {
    newLoans = new Loans(IERC20(address(usdc)), guardian, recoveryAddress);
    newLoansNFT = new LoansNFT(address(newLoans), "TestPair", "");
    vm.prank(guardian);
    newLoans.setLoansNFT(address(newLoansNFT));
  }

  function test_SetLoans_UpdatesBothPointers() public {
    (Loans newLoans, LoansNFT newLoansNFT) = _deployCompatibleLoansPair();

    vm.prank(guardian);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoansUpdated(address(newLoans), address(newLoansNFT));
    vault.setLoans(address(newLoans), address(newLoansNFT));

    assertEq(address(vault.loans()), address(newLoans), "loans pointer not updated");
    assertEq(address(vault.loansNFT()), address(newLoansNFT), "loansNFT pointer not updated");
  }

  function test_SetLoans_RevertsIfNotGuardian() public {
    (Loans newLoans, LoansNFT newLoansNFT) = _deployCompatibleLoansPair();

    vm.prank(vaultAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, vaultAdmin, guardianRole)
    );
    vault.setLoans(address(newLoans), address(newLoansNFT));
  }

  function test_SetLoans_RevertsIfZeroLoans() public {
    (, LoansNFT newLoansNFT) = _deployCompatibleLoansPair();

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.ZeroAddress.selector);
    vault.setLoans(address(0), address(newLoansNFT));
  }

  function test_SetLoans_RevertsIfZeroLoansNFT() public {
    (Loans newLoans, ) = _deployCompatibleLoansPair();

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.ZeroAddress.selector);
    vault.setLoans(address(newLoans), address(0));
  }

  function test_SetLoans_RevertsIfAssetMismatch() public {
    // Loans deployed against a different currency than the vault's `assetToken`.
    IERC20 otherCurrency = IERC20(makeAddr("otherUsdc"));
    Loans wrongCurrencyLoans = new Loans(otherCurrency, guardian, recoveryAddress);
    LoansNFT pairedNFT = new LoansNFT(address(wrongCurrencyLoans), "Wrong", "");
    vm.prank(guardian);
    wrongCurrencyLoans.setLoansNFT(address(pairedNFT));

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.AssetMismatch.selector);
    vault.setLoans(address(wrongCurrencyLoans), address(pairedNFT));
  }

  function test_SetLoans_RevertsIfReversePointerMismatch() public {
    // Two unrelated Loans/LoansNFT deployments — the NFT's LOANS_CONTRACT
    // doesn't point back at the loans address being installed.
    (Loans newLoans, ) = _deployCompatibleLoansPair();
    (, LoansNFT mismatchedNFT) = _deployCompatibleLoansPair();

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.ReversePointerMismatch.selector);
    vault.setLoans(address(newLoans), address(mismatchedNFT));
  }

  function test_SetLoans_RevertsIfNavInProgress() public {
    (Loans newLoans, LoansNFT newLoansNFT) = _deployCompatibleLoansPair();
    _startNavComputation();

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.setLoans(address(newLoans), address(newLoansNFT));
  }

  /// @dev Repointing either pointer leaves the cached NAV computed against the
  /// previous ledger/NFT pair; `setLoans` must clear `lastNavUpdate` so the
  /// next share-price-sensitive operation waits for a fresh `updateNav`.
  function test_SetLoans_InvalidatesNav() public {
    (Loans newLoans, LoansNFT newLoansNFT) = _deployCompatibleLoansPair();
    _setupInitialNav();
    assertGt(vault.lastNavUpdate(), 0, "NAV must be fresh before the call");

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavInvalidated();
    vm.prank(guardian);
    vault.setLoans(address(newLoans), address(newLoansNFT));

    assertEq(vault.lastNavUpdate(), 0, "setLoans must zero lastNavUpdate");
  }

  /// @dev Curated loanIds reference the old NFT collection's tokenIds and would
  /// be meaningless under the new pair. `setLoans` must clear `_navLoanIds` and
  /// the `_navLoanIndex` map so re-admission of any colliding id is possible.
  function test_SetLoans_ClearsCuratedNavList() public {
    uint64 idA = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
    uint64 idB = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);
    assertEq(vault.navLoanCount(), 2, "baseline: two loans curated");
    assertTrue(vault.isInNav(idA), "idA admitted");
    assertTrue(vault.isInNav(idB), "idB admitted");

    (Loans newLoans, LoansNFT newLoansNFT) = _deployCompatibleLoansPair();

    // Expect a removal event per curated id (helper pops from the end).
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanRemovedFromNav(idB);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanRemovedFromNav(idA);

    vm.prank(guardian);
    vault.setLoans(address(newLoans), address(newLoansNFT));

    assertEq(vault.navLoanCount(), 0, "curated list must be empty after setLoans");
    assertFalse(vault.isInNav(idA), "_navLoanIndex must be cleared for idA");
    assertFalse(vault.isInNav(idB), "_navLoanIndex must be cleared for idB");
  }

  // ──────────────── setExchange (guardian-only) ───────────────────

  function test_SetExchange_UpdatesExchange() public {
    LoansExchange newExchange_ = new LoansExchange(
      ILoansNFT(address(loansNFT)),
      ILoans(address(loans)),
      address(this),
      recoveryAddress
    );
    address newExchange = address(newExchange_);
    vm.prank(guardian);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.ExchangeUpdated(newExchange);
    vault.setExchange(newExchange);
    assertEq(address(vault.exchange()), newExchange);
  }

  function test_SetExchange_RevertsIfNotGuardian() public {
    vm.prank(vaultAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, vaultAdmin, guardianRole)
    );
    vault.setExchange(makeAddr("newExchange"));
  }

  function test_SetExchange_RevertsIfZeroAddress() public {
    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.ZeroAddress.selector);
    vault.setExchange(address(0));
  }

  function test_SetExchange_RevertsIfNavInProgress() public {
    _startNavComputation();

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.setExchange(makeAddr("newExchange"));
  }

  function test_SetExchange_RevertsIfLoansMismatch() public {
    // Build a LoansExchange whose immutable LOANS pointer doesn't match the
    // vault's loans contract. LOANS_NFT still matches so only the LOANS check
    // can trip.
    Loans foreignLoans = new Loans(IERC20(address(usdc)), guardian, recoveryAddress);
    LoansExchange mismatched = new LoansExchange(
      ILoansNFT(address(loansNFT)),
      ILoans(address(foreignLoans)),
      address(this),
      recoveryAddress
    );

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.InvalidExchange.selector);
    vault.setExchange(address(mismatched));
  }

  function test_SetExchange_RevertsIfLoansNFTMismatch() public {
    // Build a LoansExchange whose immutable LOANS_NFT pointer doesn't match the
    // vault's loansNFT contract. LOANS still matches so only the LOANS_NFT
    // check can trip.
    LoansNFT foreignLoansNFT = new LoansNFT(address(loans), "Foreign", "");
    LoansExchange mismatched = new LoansExchange(
      ILoansNFT(address(foreignLoansNFT)),
      ILoans(address(loans)),
      address(this),
      recoveryAddress
    );

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.InvalidExchange.selector);
    vault.setExchange(address(mismatched));
  }

  function test_SetExchange_RevertsIfCurrencyMismatch() public {
    // Canonical LoansExchange ties CURRENCY to LOANS().currency() in its
    // constructor, so a non-canonical / forked exchange is the realistic
    // attack surface. Build a valid exchange (LOANS + LOANS_NFT match), then
    // override only the CURRENCY() view to simulate that drift.
    LoansExchange goodExchange = new LoansExchange(
      ILoansNFT(address(loansNFT)),
      ILoans(address(loans)),
      address(this),
      recoveryAddress
    );
    address foreignCurrency = makeAddr("foreignCurrency");
    vm.mockCall(address(goodExchange), abi.encodeWithSignature("CURRENCY()"), abi.encode(foreignCurrency));

    vm.prank(guardian);
    vm.expectRevert(IPortfolioVault.InvalidExchange.selector);
    vault.setExchange(address(goodExchange));
  }

  // ──────────────── setMaxNavAge (admin-only) ────────────────────

  function test_SetMaxNavAge_UpdatesMaxNavAge() public {
    uint256 newAge = 2 hours;
    vm.prank(vaultAdmin);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.MaxNavAgeUpdated(newAge);
    vault.setMaxNavAge(newAge);
    assertEq(vault.maxNavAge(), newAge);
  }

  function test_SetMaxNavAge_RevertsIfNotAdmin() public {
    address nobody = makeAddr("nobody");
    vm.prank(nobody);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, adminRole)
    );
    vault.setMaxNavAge(2 hours);
  }

  function test_SetMaxNavAge_RevertsIfZero() public {
    vm.prank(vaultAdmin);
    vm.expectRevert(IPortfolioVault.InvalidMaxNavAge.selector);
    vault.setMaxNavAge(0);
  }

  // ──────────── setMaxNavComputationTime (admin-only) ────────────

  function test_SetMaxNavComputationTime_UpdatesMaxNavComputationTime() public {
    uint256 newTime = 20 minutes;
    vm.prank(vaultAdmin);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.MaxNavComputationTimeUpdated(newTime);
    vault.setMaxNavComputationTime(newTime);
    assertEq(vault.maxNavComputationTime(), newTime);
  }

  function test_SetMaxNavComputationTime_RevertsIfNotAdmin() public {
    address nobody = makeAddr("nobody");
    vm.prank(nobody);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, adminRole)
    );
    vault.setMaxNavComputationTime(20 minutes);
  }

  function test_SetMaxNavComputationTime_RevertsIfZero() public {
    vm.prank(vaultAdmin);
    vm.expectRevert(IPortfolioVault.InvalidMaxNavComputationTime.selector);
    vault.setMaxNavComputationTime(0);
  }
}

contract PortfolioVault_ViewsTest is VaultTestBase {
  uint256 internal constant WAD_UNIT = 1e18;

  function test_Nav_ReturnsLastNav() public {
    _setupInitialNav();
    assertEq(vault.nav(), vault.lastNav());
  }

  function test_SharePrice_ReturnsLastNavScaledByTotalSupply() public {
    _setupShareholderWithShares(shareholder1, DEFAULT_DEPOSIT_AMOUNT, DEFAULT_LOAN_VALUATION);

    uint256 expected = (vault.lastNav() * WAD_UNIT) / shareToken.totalSupply();
    assertEq(vault.sharePrice(), expected);
  }

  function test_SupportsInterface_AdvertisesIERC7540Redeem() public view {
    assertTrue(vault.supportsInterface(0x620ee8e4));
  }
}

contract PortfolioVault_ConstructorTest is VaultTestBase {
  function _deploy(ILoans loans_, ILoansNFT loansNFT_, IERC20 asset_) internal returns (PortfolioVault) {
    return
      new PortfolioVault(
        loans_,
        loansNFT_,
        ILoansExchange(address(exchange)),
        asset_,
        IVaultShareToken(address(shareToken)),
        INavCalculator(address(mockCalculator)),
        guardian,
        recoveryAddress,
        MAX_NAV_AGE,
        MAX_NAV_COMPUTATION_TIME
      );
  }

  function test_Constructor_RevertsIfAssetMismatch() public {
    IERC20 otherCurrency = IERC20(makeAddr("otherUsdc"));
    Loans wrongCurrencyLoans = new Loans(otherCurrency, guardian, recoveryAddress);
    LoansNFT pairedNFT = new LoansNFT(address(wrongCurrencyLoans), "Wrong", "");

    vm.expectRevert(IPortfolioVault.AssetMismatch.selector);
    _deploy(ILoans(address(wrongCurrencyLoans)), ILoansNFT(address(pairedNFT)), IERC20(address(usdc)));
  }

  function test_Constructor_RevertsIfReversePointerMismatch() public {
    Loans otherLoans = new Loans(IERC20(address(usdc)), guardian, recoveryAddress);
    LoansNFT mismatchedNFT = new LoansNFT(address(otherLoans), "Mismatch", "");

    vm.expectRevert(IPortfolioVault.ReversePointerMismatch.selector);
    _deploy(ILoans(address(loans)), ILoansNFT(address(mismatchedNFT)), IERC20(address(usdc)));
  }
}
