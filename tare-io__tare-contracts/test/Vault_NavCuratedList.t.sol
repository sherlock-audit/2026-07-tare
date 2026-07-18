// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title Vault_NavCuratedListTest
 * @notice Covers the curated loan list introduced as the H11 fix. The vault no longer
 * derives NAV inputs from `loansNFT.balanceOf(vault)` and `tokenOfOwnerByIndex`; instead
 * loans must be explicitly admitted via `addLoansToNav`, `fundLoan`, or `acceptSaleOffer`.
 * Donated NFTs cannot influence NAV, and outbound transfers are reconciled on the next
 * NAV cycle when the ownership nonce changes.
 */
contract Vault_NavCuratedListTest is VaultTestBase {
  int128 internal constant PRINCIPAL = 50_000e6;
  uint256 internal constant LOAN_VALUE = 30_000e6;
  /// @dev Batch size that processes exactly one list slot, leaving multi-loan cycles mid-flight.
  uint256 internal constant BATCH_OF_ONE = 1;

  function setUp() public override {
    super.setUp();
    mockCalculator.setNextValuation(LOAN_VALUE);
  }

  // ──────────────────── addLoanToNav: auth and validation ───────────────────

  function test_AddLoanToNav_RevertsIfNotPortfolioManager() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(id));

    address stranger = makeAddr("stranger");
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, portfolioManagerRole)
    );
    vault.addLoansToNav(_singleLoanArray(id));
  }

  function test_AddLoanToNav_RevertsIfNotOwnedByVault() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    // NFT still belongs to the investor — vault may not admit it.
    vm.expectRevert(IPortfolioVault.LoanNotOwned.selector);
    vault.addLoansToNav(_singleLoanArray(id));
  }

  function test_AddLoanToNav_Idempotent() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(id));

    vault.addLoansToNav(_singleLoanArray(id));
    vault.addLoansToNav(_singleLoanArray(id));

    assertEq(vault.navLoanCount(), 1, "second admit must not duplicate");
    assertTrue(vault.isInNav(id));
  }

  function test_AddLoanToNav_EmitsEvent() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(id));

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanAddedToNav(id);
    vault.addLoansToNav(_singleLoanArray(id));

    assertEq(vault.navLoanCount(), 1, "event emission must coincide with list growth");
    assertTrue(vault.isInNav(id));
  }

  // ──────────────────── Donations are NAV-neutral (H11) ─────────────────────

  function test_DonatedNFT_DoesNotEnterNav() public {
    uint64 donated = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(donated));

    // No admit call — NAV must not include the donation.
    assertEq(vault.navLoanCount(), 0);
    assertFalse(vault.isInNav(donated));

    // Calculator would charge LOAN_VALUE if it were ever called; if the list
    // is empty the vault must skip the calculator entirely.
    vault.updateNav(NAV_BATCH_SIZE);
    assertEq(vault.lastNav(), 0, "donation must not contribute to NAV");
  }

  function test_DonatedNFT_DoesNotBreakNavFinalization() public {
    // Seed two real loans through the helper (which admits them).
    uint64 a = _createActiveLoan(PRINCIPAL);
    uint64 b = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);
    _transferLoanToVault(b);

    // First batch — does not finalize.
    vault.updateNav(BATCH_OF_ONE);

    // Attacker donates a third NFT mid-cycle. Pre-fix, this would extend the
    // iteration window and could DoS finalization. Now it only bumps the
    // ownership nonce, which triggers a clean restart against the curated list.
    uint64 donated = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(donated));

    // Restarts (proven via NavComputationStarted), processes 1 of 2.
    mockCalculator.setNextValuation(LOAN_VALUE);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavComputationStarted(block.timestamp);
    vault.updateNav(BATCH_OF_ONE);
    assertEq(vault.navCursor(), 1, "restart processed 1 of 2 curated loans");

    // Finalize.
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(BATCH_OF_ONE);
    assertEq(vault.navCursor(), 0, "cycle finalized");
    assertEq(vault.navLoanCount(), 2, "donation never entered curated list");
    assertFalse(vault.isInNav(donated));
    assertGt(vault.lastNavUpdate(), 0, "finalization stamped lastNavUpdate");
  }

  // ──────────────────── Ownership sync on nonce change ──────────────────────

  function test_NavCycleStart_SyncsOwnershipAndDropsTransferredLoans() public {
    uint64 a = _createActiveLoan(PRINCIPAL);
    uint64 b = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);
    _transferLoanToVault(b);

    assertEq(vault.navLoanCount(), 2);

    // Vault transfers `a` out (e.g. via transferLoans). We do it raw here to
    // simulate an external-driven state where the list isn't cleaned up
    // synchronously.
    vm.prank(address(vault));
    loansNFT.transferFrom(address(vault), investor, uint256(a));

    // Next NAV cycle reconciles ownership before iterating.
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavComputationStarted(block.timestamp);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanRemovedFromNav(a);
    vault.updateNav(NAV_BATCH_SIZE);

    assertEq(vault.navLoanCount(), 1, "out-transferred loan removed");
    assertTrue(vault.isInNav(b));
    assertFalse(vault.isInNav(a));
    assertEq(vault.lastNav(), LOAN_VALUE, "NAV reflects only retained loan");
    assertEq(vault.navCursor(), 0, "cycle finalized");
  }

  function test_TransferLoans_RemovesFromNavList() public {
    uint64 a = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);

    uint64[] memory ids = new uint64[](1);
    ids[0] = a;
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanRemovedFromNav(a);
    vault.transferLoans(ids, investor);

    assertEq(vault.navLoanCount(), 0);
    assertFalse(vault.isInNav(a));
    assertEq(loansNFT.ownerOf(uint256(a)), investor, "NFT moved to recipient");
  }

  // ──────────────────── addLoanToNav: NAV invalidation ──────────────────────

  /// @dev Admitting a vault-owned loan grows the valuation set without bumping
  /// the ownership nonce, so the cached NAV no longer reflects the list.
  /// `addLoansToNav` must clear `lastNavUpdate` and emit `NavInvalidated`.
  function test_AddLoanToNav_InvalidatesNav() public {
    uint64 baseline = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(baseline);
    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(NAV_BATCH_SIZE);
    uint256 freshAt = vault.lastNavUpdate();
    assertGt(freshAt, 0, "baseline NAV is fresh");

    // Bring in a second loan via raw transfer so the nonce bumps once now and
    // then `addLoansToNav` is the only call that mutates the list.
    uint64 extra = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(extra));
    // Refresh to absorb the nonce bump from the raw transfer so we isolate
    // the invalidation effect of `addLoansToNav` itself.
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(NAV_BATCH_SIZE);
    assertGt(vault.lastNavUpdate(), 0, "NAV refreshed after raw transfer");

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavInvalidated();
    vault.addLoansToNav(_singleLoanArray(extra));

    assertEq(vault.lastNavUpdate(), 0, "addLoanToNav cleared lastNavUpdate");
    assertTrue(vault.isInNav(extra));
    assertEq(vault.navLoanCount(), 2, "second loan admitted into curated list");
  }

  /// @dev Re-admitting a loan already in the list must not re-invalidate NAV.
  function test_AddLoanToNav_IdempotentDoesNotInvalidate() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(id);
    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(NAV_BATCH_SIZE);
    uint256 freshAt = vault.lastNavUpdate();

    vault.addLoansToNav(_singleLoanArray(id)); // already present
    assertEq(vault.lastNavUpdate(), freshAt, "idempotent admit must not touch lastNavUpdate");
  }

  function test_AddLoanToNav_RevertsIfNavInProgress() public {
    uint64 a = _createActiveLoan(PRINCIPAL);
    uint64 b = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);
    _transferLoanToVault(b);
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(BATCH_OF_ONE); // start but do not finalize
    uint256 startSnapshot = vault.navStart();
    uint256 cursorSnapshot = vault.navCursor();
    uint256 countSnapshot = vault.navLoanCount();
    assertGt(startSnapshot, 0);

    uint64 extra = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(extra));

    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.addLoansToNav(_singleLoanArray(extra));

    assertEq(vault.navStart(), startSnapshot, "navStart unchanged after revert");
    assertEq(vault.navCursor(), cursorSnapshot, "navCursor unchanged after revert");
    assertEq(vault.navLoanCount(), countSnapshot, "list unchanged after revert");
    assertFalse(vault.isInNav(extra));
  }

  // ──────────────────── removeLoanFromNav ──────────────────────────────────

  function test_RemoveLoanFromNav_RevertsIfNotPortfolioManager() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(id);

    address stranger = makeAddr("stranger");
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, portfolioManagerRole)
    );
    vault.removeLoansFromNav(_singleLoanArray(id));
  }

  function test_RemoveLoanFromNav_RemovesFromList() public {
    uint64 a = _createActiveLoan(PRINCIPAL);
    uint64 b = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);
    _transferLoanToVault(b);

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanRemovedFromNav(a);
    vault.removeLoansFromNav(_singleLoanArray(a));

    assertFalse(vault.isInNav(a));
    assertTrue(vault.isInNav(b));
    assertEq(vault.navLoanCount(), 1);
    // NFT stays in the vault — only the valuation set shrank.
    assertEq(loansNFT.ownerOf(uint256(a)), address(vault), "NFT not transferred out");
  }

  function test_RemoveLoanFromNav_IdempotentForAbsentLoan() public {
    uint64 id = _createActiveLoan(PRINCIPAL); // never admitted, never owned

    // No revert, no event, no invalidation. Calculator valuation left at zero
    // because an empty curated list means getLoansValue is never called.
    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(0);
    vault.updateNav(NAV_BATCH_SIZE);
    uint256 freshAt = vault.lastNavUpdate();

    vault.removeLoansFromNav(_singleLoanArray(id));
    assertEq(vault.lastNavUpdate(), freshAt, "removing absent loan must not invalidate");
    assertEq(vault.navLoanCount(), 0);
    assertFalse(vault.isInNav(id));
  }

  /// @dev Symmetric to `addLoansToNav`: shrinking the valuation set without
  /// transferring the NFT out doesn't bump the ownership nonce, so the
  /// function must explicitly invalidate the cached NAV.
  function test_RemoveLoanFromNav_InvalidatesNav() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(id);
    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(NAV_BATCH_SIZE);
    assertGt(vault.lastNavUpdate(), 0);

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavInvalidated();
    vault.removeLoansFromNav(_singleLoanArray(id));

    assertEq(vault.lastNavUpdate(), 0, "removeLoanFromNav cleared lastNavUpdate");
    assertFalse(vault.isInNav(id));
    assertEq(vault.navLoanCount(), 0, "list emptied");
  }

  /// @dev After exclusion, the next `updateNav` must price NAV without the
  /// removed loan even though the vault still owns the NFT.
  function test_RemoveLoanFromNav_ExcludesFromSubsequentNav() public {
    uint64 included = _createActiveLoan(PRINCIPAL);
    uint64 excluded = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(included);
    _transferLoanToVault(excluded);
    usdc.mint(address(vault), INITIAL_ASSETS);

    vault.removeLoansFromNav(_singleLoanArray(excluded));

    // Calculator only sees `included`; if `excluded` leaked through the mock
    // would charge it the same valuation and the assert below would fail.
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(NAV_BATCH_SIZE);

    assertEq(vault.lastNav(), INITIAL_ASSETS + LOAN_VALUE, "NAV reflects only retained loan");
    assertEq(loansNFT.ownerOf(uint256(excluded)), address(vault), "NFT not transferred out");
  }

  function test_RemoveLoanFromNav_RevertsIfNavInProgress() public {
    uint64 a = _createActiveLoan(PRINCIPAL);
    uint64 b = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);
    _transferLoanToVault(b);
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(BATCH_OF_ONE); // start but do not finalize
    uint256 countSnapshot = vault.navLoanCount();

    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.removeLoansFromNav(_singleLoanArray(a));

    assertEq(vault.navLoanCount(), countSnapshot, "list unchanged after revert");
    assertTrue(vault.isInNav(a), "loan still present after reverted removal");
  }

  // ──────────────────── multi-entry self-heal ───────────────────

  function test_UpdateNav_SelfHealsMultipleAdjacentStaleEntries() public {
    uint64 a = _createActiveLoan(PRINCIPAL);
    uint64 b = _createActiveLoan(PRINCIPAL);
    uint64 c = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);
    _transferLoanToVault(b);
    _transferLoanToVault(c);

    // Strip ownership of the first two list entries without informing the
    // vault. updateNav must drop both stale slots in a single batch by
    // re-scanning the index after each swap-and-pop.
    vm.startPrank(address(vault));
    loansNFT.transferFrom(address(vault), investor, uint256(a));
    loansNFT.transferFrom(address(vault), investor, uint256(b));
    vm.stopPrank();

    mockCalculator.setNextValuation(LOAN_VALUE);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanRemovedFromNav(a);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanRemovedFromNav(b);
    vault.updateNav(NAV_BATCH_SIZE);

    assertEq(vault.navLoanCount(), 1, "two stale entries dropped, retained loan kept");
    assertTrue(vault.isInNav(c));
    assertFalse(vault.isInNav(a));
    assertFalse(vault.isInNav(b));
    assertEq(vault.navCursor(), 0, "cycle finalized");
    // No USDC minted, no portfolio adjustment offset: only `c` reached the calculator.
    assertEq(vault.lastNav(), LOAN_VALUE, "calculator only saw the retained loan");
  }

  // ──────────────────── addLoanToNav invalidates downstream operations ─

  function test_AddLoanToNav_CausesApproveDepositToRevertStaleNav() public {
    // Baseline: one admitted loan, vault funded, fresh NAV, pending deposit.
    uint64 baseline = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(baseline);
    usdc.mint(address(vault), INITIAL_ASSETS);
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);
    _refreshNav(LOAN_VALUE);

    // Bring a second NFT into the vault (bumps the ownership nonce) and
    // refresh so the nonce snapshot catches up. After this point the NAV
    // is fresh and only addLoanToNav can invalidate it.
    uint64 extra = _createActiveLoan(PRINCIPAL);
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(extra));
    _refreshNav(LOAN_VALUE);
    assertTrue(vault.lastNavUpdate() > 0);

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavInvalidated();
    vault.addLoansToNav(_singleLoanArray(extra));
    assertEq(vault.lastNavUpdate(), 0, "addLoanToNav must zero lastNavUpdate");

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.StaleNav.selector);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  // ──────────────────── additional edge cases ────────────────────────

  /// @dev When every admitted loan is no longer owned by the vault, the
  /// self-heal loop empties the curated list and `ownedCount` stays zero,
  /// so the calculator's `getLoansValue` must not be invoked. NAV collapses
  /// to the vault's idle USDC balance only.
  function test_UpdateNav_AllStaleEntries_SkipsCalculatorAndUsesUsdcOnly() public {
    uint64 a = _createActiveLoan(PRINCIPAL);
    uint64 b = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);
    _transferLoanToVault(b);
    usdc.mint(address(vault), INITIAL_ASSETS);

    vm.startPrank(address(vault));
    loansNFT.transferFrom(address(vault), investor, uint256(a));
    loansNFT.transferFrom(address(vault), investor, uint256(b));
    vm.stopPrank();

    // Sentinel valuation: if getLoansValue ever runs, it would land in NAV
    // and the equality below would fail.
    mockCalculator.setNextValuation(999_999e6);
    vault.updateNav(NAV_BATCH_SIZE);

    assertEq(vault.navLoanCount(), 0, "all entries self-healed");
    assertEq(vault.lastNav(), INITIAL_ASSETS, "NAV equals idle USDC only");
    assertEq(vault.navCursor(), 0, "cycle finalized");
  }

  /// @dev `_removeLoanFromNav` uses swap-and-pop: removing a middle element
  /// must relocate the tail into the freed slot and keep `navLoanIdAt`
  /// indexing consistent.
  function test_RemoveLoanFromNav_SwapAndPopPreservesTailElement() public {
    uint64 a = _createActiveLoan(PRINCIPAL);
    uint64 b = _createActiveLoan(PRINCIPAL);
    uint64 c = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(a);
    _transferLoanToVault(b);
    _transferLoanToVault(c);

    assertEq(vault.navLoanIdAt(0), a);
    assertEq(vault.navLoanIdAt(1), b);
    assertEq(vault.navLoanIdAt(2), c);

    vault.removeLoansFromNav(_singleLoanArray(b));

    // Swap-and-pop moves `c` (the tail) into `b`'s slot.
    assertEq(vault.navLoanCount(), 2);
    assertEq(vault.navLoanIdAt(0), a, "head untouched");
    assertEq(vault.navLoanIdAt(1), c, "tail swapped into removed slot");
    assertTrue(vault.isInNav(a));
    assertFalse(vault.isInNav(b));
    assertTrue(vault.isInNav(c));
  }

  /// @dev A loan removed from NAV must be admittable again in the same idle
  /// window, and the re-admission must re-invalidate NAV.
  function test_AddLoanToNav_ReAdmitsAfterRemoval() public {
    uint64 id = _createActiveLoan(PRINCIPAL);
    _transferLoanToVault(id);
    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(LOAN_VALUE);
    vault.updateNav(NAV_BATCH_SIZE);

    vault.removeLoansFromNav(_singleLoanArray(id));
    assertFalse(vault.isInNav(id));

    // Refresh so we isolate the invalidation effect of re-admission.
    mockCalculator.setNextValuation(0);
    vault.updateNav(NAV_BATCH_SIZE);
    assertGt(vault.lastNavUpdate(), 0);

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanAddedToNav(id);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavInvalidated();
    vault.addLoansToNav(_singleLoanArray(id));

    assertTrue(vault.isInNav(id), "re-admit restored presence");
    assertEq(vault.navLoanCount(), 1);
    assertEq(vault.lastNavUpdate(), 0, "re-admit invalidated NAV");
  }
}
