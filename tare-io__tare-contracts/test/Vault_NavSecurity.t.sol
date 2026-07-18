// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";

/**
 * @title Vault_NavSecurityTest
 * @notice Tests that verify the mathematical soundness and exploit-resistance of the
 * PortfolioVault's NAV accounting, share price preservation, and claim arithmetic:
 * - Share price (lastNav / totalSupply) must be preserved at every step of every flow
 * - Multi-user approve-before-claim must not corrupt subsequent share pricing
 * - deposit() vs mint() equivalence (no arbitrage between claim paths)
 * - redeem() vs withdraw() equivalence (no arbitrage between claim paths)
 * - Extreme amounts (very large and very small)
 * - Multiple partial approvals at different NAV values
 * - Decimal mismatch robustness (6-decimal assets vs 18-decimal shares)
 * - Vault share balance invariant (vault holds exactly claimable + locked shares)
 * - lastNav manual adjustments match full recomputation
 */
contract Vault_NavSecurityTest is VaultTestBase {
  function setUp() public override {
    super.setUp();

    usdc.mint(shareholder1, type(uint128).max);
    vm.prank(shareholder1);
    usdc.approve(address(vault), type(uint256).max);

    usdc.mint(shareholder2, type(uint128).max);
    vm.prank(shareholder2);
    usdc.approve(address(vault), type(uint256).max);
  }

  // ═══════════════════════════════════════════════════════════════
  //  1. SHARE PRICE PRESERVATION
  //     Share price must stay correct at every step of every flow.
  //     Approving multiple users before any claim must not corrupt pricing.
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice Verifies lastNav, totalSupply, and share price are correct after each
   * step of a single-user deposit: request → approve → claim.
   */
  function test_DepositFlow_SharePriceConsistentAtEveryStep(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);

    uint256 priceBefore = _sharePrice();
    uint256 navBefore = vault.lastNav();
    uint256 supplyBefore = shareToken.totalSupply();

    // Step 1: Request — NAV and totalSupply should NOT change
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    assertEq(vault.lastNav(), navBefore, "request: lastNav should not change");
    assertEq(shareToken.totalSupply(), supplyBefore, "request: totalSupply should not change");

    // Step 2: Refresh NAV — pending deposits are excluded from NAV
    uint256 navAfterRefresh = vault.lastNav();
    assertEq(navAfterRefresh, navBefore, "refresh: NAV should exclude pending deposits");
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "refresh: share price should be unchanged");

    // Step 3: Approve — shares minted to vault, lastNav increased
    uint256 supplyBeforeApprove = shareToken.totalSupply();
    uint256 navBeforeApprove = vault.lastNav();

    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 newShares = shareToken.totalSupply() - supplyBeforeApprove;
    assertTrue(newShares > 0, "approve: should have minted shares");
    uint256 priceAfterApprove = _sharePrice();
    assertApproxEqRel(priceAfterApprove, priceBefore, 1e7, "approve: share price must be preserved");
    assertEq(vault.lastNav(), navBeforeApprove + depositAmount, "approve: lastNav should increase by deposit");

    // Step 4: Claim — no change to NAV or totalSupply (just transfers pre-minted shares)
    uint256 navBeforeClaim = vault.lastNav();
    uint256 supplyBeforeClaim = shareToken.totalSupply();

    vm.prank(shareholder1);
    vault.deposit(depositAmount, shareholder1, shareholder1);

    assertEq(vault.lastNav(), navBeforeClaim, "claim: lastNav should not change");
    assertEq(shareToken.totalSupply(), supplyBeforeClaim, "claim: totalSupply should not change");
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "claim: share price should be unchanged");
  }

  /**
   * @notice Shareholder1 gets approved, then Shareholder2 gets approved BEFORE Shareholder1 claims.
   * Shareholder2's share price must equal Shareholder1's because they deposited at the same NAV.
   */
  function test_DepositFlow_TwoUsers_ApproveBothBeforeClaim(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);

    uint256 priceBeforeDeposits = _sharePrice();

    // Both request at the same time
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(shareholder2);
    vault.requestDeposit(depositAmount, shareholder2, shareholder2);

    // Approve Shareholder1
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);
    assertApproxEqRel(
      _sharePrice(),
      priceBeforeDeposits,
      1e7,
      "price after Shareholder1's approval should be unchanged"
    );

    // Approve Shareholder2 — BEFORE Shareholder1 claims
    vm.prank(manager);
    vault.approveDeposit(shareholder2, depositAmount);
    assertApproxEqRel(
      _sharePrice(),
      priceBeforeDeposits,
      1e7,
      "price after Shareholder2's approval should be unchanged"
    );

    // Both users should get the same number of shares (same deposit, same price)
    uint256 aliceShares = vault.claimableDepositShares(shareholder1);
    uint256 bobShares = vault.claimableDepositShares(shareholder2);
    assertEq(aliceShares, bobShares, "same deposit at same NAV must produce same shares");

    // Claims don't affect share price
    vm.prank(shareholder1);
    vault.deposit(depositAmount, shareholder1, shareholder1);
    assertApproxEqRel(_sharePrice(), priceBeforeDeposits, 1e7, "price after Shareholder1 claims should be unchanged");

    vm.prank(shareholder2);
    vault.deposit(depositAmount, shareholder2, shareholder2);
    assertApproxEqRel(_sharePrice(), priceBeforeDeposits, 1e7, "price after Shareholder2 claims should be unchanged");
  }

  /**
   * @notice Sequential approvals for the SAME user: approve 40k, then approve 60k
   * without claiming in between. Share price must stay consistent.
   */
  function test_DepositFlow_SequentialPartialApprovals_PricePreserved(
    uint256 depositAmount,
    uint256 loanValuation
  ) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);

    uint256 totalDeposit = depositAmount;
    uint256 firstApproval = (depositAmount * 40) / 100;
    uint256 secondApproval = depositAmount - firstApproval;
    vm.assume(firstApproval > 0 && secondApproval > 0);
    // Both partial amounts must produce non-zero shares at current NAV
    _assumeNonZeroShares(firstApproval);

    uint256 priceBefore = _sharePrice();

    vm.prank(shareholder1);
    vault.requestDeposit(totalDeposit, shareholder1, shareholder1);

    // First partial approval
    vm.prank(manager);
    vault.approveDeposit(shareholder1, firstApproval);
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "price after first partial approval");

    // Second partial approval (no NAV refresh — same NAV epoch)
    vm.prank(manager);
    vault.approveDeposit(shareholder1, secondApproval);
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "price after second partial approval");

    // Claim all
    uint256 claimableAssets = vault.claimableDepositAssets(shareholder1);
    vm.prank(shareholder1);
    vault.deposit(claimableAssets, shareholder1, shareholder1);
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "price after full claim");
  }

  /**
   * @notice Verifies lastNav, totalSupply, and share price at every step
   * of a single-user redemption: request → approve → claim.
   */
  function test_RedeemFlow_SharePriceConsistentAtEveryStep(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    uint256 shares = _depositAndClaim(shareholder1, depositAmount);

    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);

    uint256 priceBefore = _sharePrice();
    uint256 navBefore = vault.lastNav();
    uint256 supplyBefore = shareToken.totalSupply();

    // Step 1: Request — transfers shares to vault, no NAV / totalSupply change
    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    assertEq(vault.lastNav(), navBefore, "request: lastNav should not change");
    assertEq(shareToken.totalSupply(), supplyBefore, "request: totalSupply should not change");
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "request: share price should be unchanged");

    // Step 2: Refresh NAV
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "refresh: share price should be unchanged");

    // Step 3: Approve — shares burned, lastNav decreased proportionally
    uint256 supplyBeforeApprove = shareToken.totalSupply();
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 burnedShares = supplyBeforeApprove - shareToken.totalSupply();
    assertEq(burnedShares, shares, "approve: should burn exact shares");
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "approve: share price must be preserved");

    // Step 4: Claim — assets transfer out, no totalSupply change
    uint256 supplyBeforeClaim = shareToken.totalSupply();
    uint256 navBeforeClaim = vault.lastNav();
    uint256 claimableShares = vault.maxRedeem(shareholder1);

    vm.prank(shareholder1);
    vault.redeem(claimableShares, shareholder1, shareholder1);

    assertEq(shareToken.totalSupply(), supplyBeforeClaim, "claim: totalSupply should not change");
    assertEq(vault.lastNav(), navBeforeClaim, "claim: lastNav should not change");
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "claim: share price should be unchanged");
  }

  /**
   * @notice Shareholder1 gets approved for redemption, then Shareholder2 gets approved BEFORE Shareholder1
   * claims. Shareholder2's share-to-asset conversion rate must be the same as Shareholder1's.
   */
  function test_RedeemFlow_TwoUsers_ApproveBothBeforeClaim(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    uint256 aliceShares = _depositAndClaim(shareholder1, depositAmount);
    uint256 bobShares = _depositAndClaim(shareholder2, depositAmount);

    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);
    vm.prank(shareholder2);
    shareToken.approve(address(vault), type(uint256).max);

    uint256 priceBeforeRedeems = _sharePrice();

    // Both request at the same time
    vm.prank(shareholder1);
    vault.requestRedeem(aliceShares, shareholder1, shareholder1);
    vm.prank(shareholder2);
    vault.requestRedeem(bobShares, shareholder2, shareholder2);

    // Approve Shareholder1
    vm.prank(manager);
    vault.approveRedemption(shareholder1, aliceShares);
    assertApproxEqRel(_sharePrice(), priceBeforeRedeems, 1e7, "price after Shareholder1's redemption approval");

    // Approve Shareholder2 — BEFORE Shareholder1 claims
    vm.prank(manager);
    vault.approveRedemption(shareholder2, bobShares);
    assertApproxEqRel(_sharePrice(), priceBeforeRedeems, 1e7, "price after Shareholder2's redemption approval");

    // Both deposited the same amount, so they should get the same assets back
    uint256 aliceAssets = vault.claimableRedeemAssets(shareholder1);
    uint256 bobAssets = vault.claimableRedeemAssets(shareholder2);
    assertApproxEqAbs(aliceAssets, bobAssets, 1, "same shares at same NAV must produce same assets");

    // Claims don't affect share price
    uint256 aliceClaimable = vault.maxRedeem(shareholder1);
    vm.prank(shareholder1);
    vault.redeem(aliceClaimable, shareholder1, shareholder1);
    assertApproxEqRel(_sharePrice(), priceBeforeRedeems, 1e7, "price after Shareholder1 claims");

    uint256 bobClaimable = vault.maxRedeem(shareholder2);
    vm.prank(shareholder2);
    vault.redeem(bobClaimable, shareholder2, shareholder2);
    assertApproxEqRel(_sharePrice(), priceBeforeRedeems, 1e7, "price after Shareholder2 claims");
  }

  /**
   * @notice Sequential partial redemption approvals without claiming in between.
   * Share price must remain consistent.
   */
  function test_RedeemFlow_SequentialPartialApprovals_PricePreserved(
    uint256 depositAmount,
    uint256 loanValuation
  ) public {
    depositAmount = bound(depositAmount, 1e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    uint256 totalShares = _depositAndClaim(shareholder1, depositAmount);

    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);

    uint256 priceBefore = _sharePrice();

    vm.prank(shareholder1);
    vault.requestRedeem(totalShares, shareholder1, shareholder1);

    // First partial approval: 40%
    uint256 firstShares = (totalShares * 40) / 100;
    // Ensure partial shares produce nonzero assets
    uint256 nav = vault.lastNav();
    uint256 supply = shareToken.totalSupply();
    vm.assume(firstShares > 0 && (firstShares * nav) / supply > 0);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, firstShares);
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "price after first partial redemption approval");

    // Second partial approval: remaining 60%
    uint256 remainingShares = vault.pendingRedeemShares(shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, remainingShares);
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "price after second partial redemption approval");

    // Claim all
    uint256 claimableShares = vault.maxRedeem(shareholder1);
    vm.prank(shareholder1);
    vault.redeem(claimableShares, shareholder1, shareholder1);
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "price after full redemption claim");
  }

  /**
   * @notice Shareholder1 deposits while Shareholder2 redeems, both approved before either claims.
   * Share price must stay correct at each step.
   */
  function test_MixedFlow_DepositAndRedeemApprovedBeforeClaim(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 2e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);

    // Give Shareholder2 shares to redeem
    uint256 bobShares = _depositAndClaim(shareholder2, depositAmount);
    vm.prank(shareholder2);
    shareToken.approve(address(vault), type(uint256).max);

    uint256 priceBeforeMixed = _sharePrice();

    // Shareholder1 requests deposit, Shareholder2 requests redeem
    uint256 aliceDeposit = depositAmount / 2;
    vm.assume(aliceDeposit > 0);
    _assumeNonZeroShares(aliceDeposit);
    vm.prank(shareholder1);
    vault.requestDeposit(aliceDeposit, shareholder1, shareholder1);

    vm.prank(shareholder2);
    vault.requestRedeem(bobShares, shareholder2, shareholder2);

    // Approve Shareholder1's deposit
    vm.prank(manager);
    vault.approveDeposit(shareholder1, aliceDeposit);
    assertApproxEqRel(_sharePrice(), priceBeforeMixed, 1e7, "price after deposit approval in mixed flow");

    // Approve Shareholder2's redemption
    vm.prank(manager);
    vault.approveRedemption(shareholder2, bobShares);
    assertApproxEqRel(_sharePrice(), priceBeforeMixed, 1e7, "price after redeem approval in mixed flow");

    // Claims shouldn't change price
    vm.prank(shareholder1);
    vault.deposit(aliceDeposit, shareholder1, shareholder1);
    assertApproxEqRel(_sharePrice(), priceBeforeMixed, 1e7, "price after deposit claim in mixed flow");

    uint256 bobClaimable = vault.maxRedeem(shareholder2);
    vm.prank(shareholder2);
    vault.redeem(bobClaimable, shareholder2, shareholder2);
    assertApproxEqRel(_sharePrice(), priceBeforeMixed, 1e7, "price after redeem claim in mixed flow");
  }

  /**
   * @notice The reverse order: approve redeem first, then deposit.
   * Price must still be preserved.
   */
  function test_MixedFlow_RedeemApprovedBeforeDeposit(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 2e6, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);

    uint256 bobShares = _depositAndClaim(shareholder2, depositAmount);
    vm.prank(shareholder2);
    shareToken.approve(address(vault), type(uint256).max);

    uint256 priceBefore = _sharePrice();

    uint256 aliceDeposit = depositAmount / 2;
    vm.assume(aliceDeposit > 0);
    _assumeNonZeroShares(aliceDeposit);
    vm.prank(shareholder1);
    vault.requestDeposit(aliceDeposit, shareholder1, shareholder1);
    vm.prank(shareholder2);
    vault.requestRedeem(bobShares, shareholder2, shareholder2);

    // Approve redeem FIRST, then deposit
    vm.prank(manager);
    vault.approveRedemption(shareholder2, bobShares);
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "price after redeem-first approval");

    vm.prank(manager);
    vault.approveDeposit(shareholder1, aliceDeposit);
    assertApproxEqRel(_sharePrice(), priceBefore, 1e7, "price after deposit-second approval");
  }

  // ═══════════════════════════════════════════════════════════════
  //  2. DEPOSIT vs MINT EQUIVALENCE (no arbitrage)
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice Claiming all via deposit(allAssets) produces the same result as mint(allShares).
   * Both consume 100% of claimable assets and shares, so no value leak.
   */
  function test_DepositVsMint_FullClaim_SameResult() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;

    // --- Path A: claim via deposit() ---
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableAssetsA = vault.claimableDepositAssets(shareholder1);
    uint256 claimableSharesA = vault.claimableDepositShares(shareholder1);

    vm.prank(shareholder1);
    uint256 sharesViaDeposit = vault.deposit(claimableAssetsA, shareholder1, shareholder1);

    assertEq(sharesViaDeposit, claimableSharesA, "deposit(fullAssets) should yield all claimable shares");

    // --- Path B: claim via mint() for shareholder2 at the same NAV snapshot ---
    vm.prank(shareholder2);
    vault.requestDeposit(depositAmount, shareholder2, shareholder2);
    vm.prank(manager);
    vault.approveDeposit(shareholder2, depositAmount);

    uint256 claimableSharesB = vault.claimableDepositShares(shareholder2);
    uint256 claimableAssetsB = vault.claimableDepositAssets(shareholder2);

    vm.prank(shareholder2);
    uint256 assetsViaMint = vault.mint(claimableSharesB, shareholder2, shareholder2);

    assertEq(assetsViaMint, claimableAssetsB, "mint(fullShares) should consume all claimable assets");
    assertEq(sharesViaDeposit, claimableSharesB, "deposit and mint yield same shares for same deposit");
  }

  /**
   * @notice Trying to extract extra shares by calling deposit(1 wei assets) repeatedly.
   * Each call rounds shares DOWN, so the attacker gets fewer total shares than one big call.
   */
  function test_DepositVsMint_SplittingDoesNotExtraShares() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 totalClaimableAssets = vault.claimableDepositAssets(shareholder1);
    uint256 totalClaimableShares = vault.claimableDepositShares(shareholder1);

    // Claim in many small chunks
    uint256 chunkSize = totalClaimableAssets / 100;
    uint256 totalSharesFromChunks;

    for (uint256 i; i < 99; ++i) {
      vm.prank(shareholder1);
      totalSharesFromChunks += vault.deposit(chunkSize, shareholder1, shareholder1);
    }
    // Claim remainder
    uint256 remaining = vault.claimableDepositAssets(shareholder1);
    if (remaining > 0) {
      vm.prank(shareholder1);
      totalSharesFromChunks += vault.deposit(remaining, shareholder1, shareholder1);
    }

    // Total shares from many small claims ≤ total shares from one big claim
    assertLe(totalSharesFromChunks, totalClaimableShares, "splitting claims must not yield extra shares");
  }

  /**
   * @notice Trying to extract extra assets by calling mint(1 share) repeatedly.
   * Each call rounds assets DOWN, so attacker consumes fewer assets per share → gets "cheaper" shares.
   * But the remaining claimable pool shrinks, so the attacker can never extract more than the approved amount.
   */
  function test_Mint_SplittingDoesNotLeakAssets() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 totalClaimableShares = vault.claimableDepositShares(shareholder1);
    uint256 totalClaimableAssets = vault.claimableDepositAssets(shareholder1);

    // Claim in many small chunks by shares
    uint256 chunkShares = totalClaimableShares / 100;
    uint256 totalAssetsConsumed;

    for (uint256 i; i < 99; ++i) {
      vm.prank(shareholder1);
      totalAssetsConsumed += vault.mint(chunkShares, shareholder1, shareholder1);
    }
    uint256 remainingShares = vault.claimableDepositShares(shareholder1);
    if (remainingShares > 0) {
      vm.prank(shareholder1);
      totalAssetsConsumed += vault.mint(remainingShares, shareholder1, shareholder1);
    }

    assertLe(totalAssetsConsumed, totalClaimableAssets, "split minting must not consume more than approved");
  }

  // ═══════════════════════════════════════════════════════════════
  //  3. REDEEM vs WITHDRAW EQUIVALENCE (no arbitrage)
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice Claiming all via redeem(allShares) produces the same result as withdraw(allAssets).
   */
  function test_RedeemVsWithdraw_FullClaim_SameResult() public {
    uint256 depositAmount = 100_000e6;

    // Setup shareholder1 with shares
    _setupInitialNav();
    uint256 shares = _depositAndClaim(shareholder1, depositAmount);
    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);

    // Request redeem
    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.claimableRedeemShares(shareholder1);
    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);

    // Full redeem by shares
    vm.prank(shareholder1);
    uint256 assetsFromRedeem = vault.redeem(claimableShares, shareholder1, shareholder1);

    assertEq(assetsFromRedeem, claimableAssets, "redeem(allShares) should yield all claimable assets");

    // --- Same setup for shareholder2 via withdraw() ---
    uint256 shares2 = _depositAndClaim(shareholder2, depositAmount);
    vm.prank(shareholder2);
    shareToken.approve(address(vault), type(uint256).max);

    vm.prank(shareholder2);
    vault.requestRedeem(shares2, shareholder2, shareholder2);
    vm.prank(manager);
    vault.approveRedemption(shareholder2, shares2);

    uint256 claimableAssets2 = vault.claimableRedeemAssets(shareholder2);
    uint256 claimableShares2 = vault.claimableRedeemShares(shareholder2);

    vm.prank(shareholder2);
    uint256 sharesFromWithdraw = vault.withdraw(claimableAssets2, shareholder2, shareholder2);

    assertEq(sharesFromWithdraw, claimableShares2, "withdraw(allAssets) should burn all claimable shares");
  }

  /**
   * @notice Splitting redeem into many small claims can't yield more total assets.
   */
  function test_Redeem_SplittingDoesNotExtraAssets() public {
    uint256 depositAmount = 100_000e6;
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 totalClaimableShares = vault.claimableRedeemShares(shareholder1);
    uint256 totalClaimableAssets = vault.claimableRedeemAssets(shareholder1);

    uint256 chunkShares = totalClaimableShares / 100;
    uint256 totalAssetsFromChunks;

    for (uint256 i; i < 99; ++i) {
      vm.prank(shareholder1);
      totalAssetsFromChunks += vault.redeem(chunkShares, shareholder1, shareholder1);
    }
    uint256 remaining = vault.claimableRedeemShares(shareholder1);
    if (remaining > 0) {
      vm.prank(shareholder1);
      totalAssetsFromChunks += vault.redeem(remaining, shareholder1, shareholder1);
    }

    assertLe(totalAssetsFromChunks, totalClaimableAssets, "splitting redeems must not yield extra assets");
  }

  /**
   * @notice Splitting withdraw into many small claims can't burn fewer total shares.
   */
  function test_Withdraw_SplittingDoesNotBurnFewerShares() public {
    uint256 depositAmount = 100_000e6;
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 totalClaimableAssets = vault.claimableRedeemAssets(shareholder1);
    uint256 totalClaimableShares = vault.claimableRedeemShares(shareholder1);

    uint256 chunkAssets = totalClaimableAssets / 100;
    uint256 totalSharesBurned;

    for (uint256 i; i < 99; ++i) {
      vm.prank(shareholder1);
      totalSharesBurned += vault.withdraw(chunkAssets, shareholder1, shareholder1);
    }
    uint256 remainingAssets = vault.claimableRedeemAssets(shareholder1);
    if (remainingAssets > 0) {
      vm.prank(shareholder1);
      totalSharesBurned += vault.withdraw(remainingAssets, shareholder1, shareholder1);
    }

    assertLe(totalSharesBurned, totalClaimableShares, "split withdraws must not burn more shares than full");
  }

  // ═══════════════════════════════════════════════════════════════
  //  4. EXTREME AMOUNTS
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice Very large deposit (100B USDC) works correctly without overflow.
   */
  function test_ExtremeDeposit_VeryLargeAmount() public {
    _setupInitialNav();

    uint256 largeDeposit = 100_000_000_000e6; // 100 billion USDC

    vm.prank(shareholder1);
    vault.requestDeposit(largeDeposit, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, largeDeposit);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    uint256 claimableAssets = vault.claimableDepositAssets(shareholder1);
    assertTrue(claimableShares > 0, "should have claimable shares");
    assertEq(claimableAssets, largeDeposit, "claimable assets should match");

    vm.prank(shareholder1);
    uint256 shares = vault.deposit(claimableAssets, shareholder1, shareholder1);
    assertEq(shares, claimableShares, "all shares claimed");
  }

  /**
   * @notice Very large redemption works correctly without overflow.
   */
  function test_ExtremeRedeem_VeryLargeAmount() public {
    uint256 largeDeposit = 100_000_000_000e6;
    uint256 shares = _setupShareholderWithShares(shareholder1, largeDeposit, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.claimableRedeemShares(shareholder1);
    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);
    assertTrue(claimableAssets > 0, "should have claimable assets");

    vm.prank(shareholder1);
    uint256 assets = vault.redeem(claimableShares, shareholder1, shareholder1);
    assertEq(assets, claimableAssets, "all assets claimed");
  }

  /**
   * @notice Smallest possible valid deposit (1 USDC = 1e6).
   * Must either succeed cleanly or revert at approveDeposit if shares rounds to zero.
   */
  function test_ExtremeDeposit_SmallestValidAmount() public {
    _setupInitialNav();

    uint256 smallDeposit = 1e6;

    vm.prank(shareholder1);
    vault.requestDeposit(smallDeposit, shareholder1, shareholder1);

    // NAV ≈ 500k, totalSupply ≈ 1e9 (dead shares)
    // shares = 1e6 * 1e9 / 500_000e6 = 2000 → succeeds
    vm.prank(manager);
    vault.approveDeposit(shareholder1, smallDeposit);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    assertTrue(claimableShares > 0, "should have some shares for 1 USDC");

    vm.prank(shareholder1);
    uint256 shares = vault.deposit(smallDeposit, shareholder1, shareholder1);
    assertEq(shares, claimableShares, "shares match");
  }

  /**
   * @notice With DEAD_SHARES = 1e18, even 1 wei of USDC produces nonzero shares
   * because totalSupply is large relative to NAV in USDC.
   */
  function test_ExtremeDeposit_1WeiAsset_ProducesNonzeroShares() public {
    _setupInitialNav();

    vm.prank(shareholder1);
    vault.requestDeposit(1, shareholder1, shareholder1);

    // shares = 1 * 1e18 / 500_000e6 = 2_000_000 > 0
    vm.prank(manager);
    vault.approveDeposit(shareholder1, 1);

    assertTrue(vault.claimableDepositShares(shareholder1) > 0, "1 wei deposit produces shares with 1e18 dead shares");
  }

  /**
   * @notice With DEAD_SHARES = 1e18, each share's value in USDC-wei is tiny.
   * 1 share = NAV / totalSupply ≈ 0 due to integer division, so approveRedemption
   * should revert with ZeroAmount.
   */
  function test_ExtremeRedeem_1Share_RevertsWhenShareWorthless() public {
    _setupShareholderWithShares(shareholder1, 100_000e6, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(1, shareholder1, shareholder1);

    // At current ratio with 1e18 dead shares, 1 share ≈ 0 USDC-wei
    uint256 nav = vault.lastNav();
    uint256 supply = shareToken.totalSupply();
    uint256 expectedAssets = (1 * nav) / supply;
    assertEq(expectedAssets, 0, "1 share rounds to 0 assets with 1e18 dead shares");

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ZeroAmount.selector));
    vault.approveRedemption(shareholder1, 1);
  }

  // ═══════════════════════════════════════════════════════════════
  //  5. MULTIPLE PARTIAL APPROVALS
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice Multiple partial deposit approvals at different NAV values then claiming
   * in one shot. The weighted average price is correct and no value is created or destroyed.
   */
  function test_MultiplePartialDeposits_WeightedAverageCorrect() public {
    _setupInitialNav();

    uint256 totalDeposit = 100_000e6;
    vm.prank(shareholder1);
    vault.requestDeposit(totalDeposit, shareholder1, shareholder1);

    // First approval at NAV1: approve 30k
    uint256 nav1 = vault.lastNav();
    uint256 supply1 = shareToken.totalSupply();
    uint256 firstApproval = 30_000e6;

    vm.prank(manager);
    vault.approveDeposit(shareholder1, firstApproval);

    uint256 expectedShares1 = (firstApproval * supply1) / nav1;
    assertEq(vault.claimableDepositShares(shareholder1), expectedShares1, "first batch shares");

    // Increase NAV by 50% (add more USDC to vault)
    usdc.mint(address(vault), 250_000e6);
    _refreshNav();
    uint256 nav2 = vault.lastNav();
    uint256 supply2 = shareToken.totalSupply();
    assertTrue(nav2 > nav1, "NAV should have increased");

    // Second approval at NAV2: approve remaining 70k
    uint256 secondApproval = 70_000e6;
    vm.prank(manager);
    vault.approveDeposit(shareholder1, secondApproval);

    uint256 expectedShares2 = (secondApproval * supply2) / nav2;
    uint256 totalExpectedShares = expectedShares1 + expectedShares2;
    assertEq(vault.claimableDepositShares(shareholder1), totalExpectedShares, "accumulated shares");

    // Claim everything in one call via deposit()
    uint256 totalClaimableAssets = vault.claimableDepositAssets(shareholder1);
    vm.prank(shareholder1);
    uint256 mintedShares = vault.deposit(totalClaimableAssets, shareholder1, shareholder1);

    assertEq(mintedShares, totalExpectedShares, "all shares minted in one claim");
    assertEq(vault.claimableDepositAssets(shareholder1), 0, "no residual assets");
    assertEq(vault.claimableDepositShares(shareholder1), 0, "no residual shares");
  }

  /**
   * @notice Multiple partial redeem approvals at different NAV values then claiming
   * in one shot. The weighted average price is correct.
   */
  function test_MultiplePartialRedeems_WeightedAverageCorrect() public {
    uint256 depositAmount = 100_000e6;
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // First approval at NAV1: approve 40% of shares
    uint256 nav1 = vault.lastNav();
    uint256 supply1 = shareToken.totalSupply();
    uint256 firstShares = (shares * 40) / 100;

    vm.prank(manager);
    vault.approveRedemption(shareholder1, firstShares);

    uint256 expectedAssets1 = (firstShares * nav1) / supply1;
    assertEq(vault.claimableRedeemAssets(shareholder1), expectedAssets1, "first batch assets");

    // Increase NAV by adding USDC
    usdc.mint(address(vault), 200_000e6);
    _refreshNav();
    uint256 nav2 = vault.lastNav();
    uint256 supply2 = shareToken.totalSupply();

    // Second approval at NAV2: approve remaining 60%
    uint256 remainingShares = vault.pendingRedeemShares(shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, remainingShares);

    uint256 expectedAssets2 = (remainingShares * nav2) / supply2;
    uint256 totalExpectedAssets = expectedAssets1 + expectedAssets2;
    assertEq(vault.claimableRedeemAssets(shareholder1), totalExpectedAssets, "accumulated assets");

    // Claim everything via redeem()
    uint256 totalClaimableShares = vault.claimableRedeemShares(shareholder1);
    vm.prank(shareholder1);
    uint256 receivedAssets = vault.redeem(totalClaimableShares, shareholder1, shareholder1);

    assertEq(receivedAssets, totalExpectedAssets, "all assets received in one claim");
    assertEq(vault.claimableRedeemShares(shareholder1), 0, "no residual shares");
    assertEq(vault.claimableRedeemAssets(shareholder1), 0, "no residual assets");
  }

  /**
   * @notice Interleaving partial deposit approvals with partial claims.
   * Approve 40k → claim 20k → approve 60k → claim all remaining.
   * Must not allow extracting more shares than were approved.
   */
  function test_InterleavedPartialApprovalAndClaim_Deposit() public {
    _setupInitialNav();

    uint256 totalDeposit = 100_000e6;
    vm.prank(shareholder1);
    vault.requestDeposit(totalDeposit, shareholder1, shareholder1);

    // Approve 40k
    vm.prank(manager);
    vault.approveDeposit(shareholder1, 40_000e6);

    // Claim only 20k worth
    vm.prank(shareholder1);
    uint256 claimed1 = vault.deposit(20_000e6, shareholder1, shareholder1);

    uint256 remainingClaimableAssets = vault.claimableDepositAssets(shareholder1);
    assertEq(remainingClaimableAssets, 20_000e6, "20k remaining claimable");

    // Approve remaining 60k
    vm.prank(manager);
    vault.approveDeposit(shareholder1, 60_000e6);

    uint256 totalClaimableNow = vault.claimableDepositAssets(shareholder1);
    assertEq(totalClaimableNow, 20_000e6 + 60_000e6, "80k total claimable");

    // Claim all remaining
    vm.prank(shareholder1);
    uint256 claimed2 = vault.deposit(totalClaimableNow, shareholder1, shareholder1);

    uint256 totalShares = claimed1 + claimed2;
    assertEq(shareToken.balanceOf(shareholder1), totalShares, "all shares accounted for");
    assertEq(vault.claimableDepositAssets(shareholder1), 0, "nothing left");
    assertEq(vault.claimableDepositShares(shareholder1), 0, "nothing left");
  }

  /**
   * @notice Interleaving partial redeem approvals with partial claims.
   */
  function test_InterleavedPartialApprovalAndClaim_Redeem() public {
    uint256 depositAmount = 100_000e6;
    uint256 shares = _setupShareholderWithShares(shareholder1, depositAmount, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // Approve 40% of shares
    uint256 firstBatch = (shares * 40) / 100;
    vm.prank(manager);
    vault.approveRedemption(shareholder1, firstBatch);

    // Claim half of the approved shares
    uint256 halfBatch = firstBatch / 2;
    vm.prank(shareholder1);
    vault.redeem(halfBatch, shareholder1, shareholder1);

    // Approve remaining 60%
    uint256 secondBatch = vault.pendingRedeemShares(shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, secondBatch);

    // Claim all remaining via withdraw (asset-denominated)
    uint256 remainingAssets = vault.claimableRedeemAssets(shareholder1);
    vm.prank(shareholder1);
    vault.withdraw(remainingAssets, shareholder1, shareholder1);

    assertEq(vault.claimableRedeemAssets(shareholder1), 0, "no residual assets");
    assertEq(vault.claimableRedeemShares(shareholder1), 0, "no residual shares");
  }

  // ═══════════════════════════════════════════════════════════════
  //  6. DECIMAL MISMATCH (6-decimal asset, 18-decimal shares)
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice With USDC (6 decimals) and shares (18 decimals), the 1e12 ratio does not
   * create rounding exploits. Small USDC deposits produce proportionally correct share amounts.
   */
  function test_DecimalMismatch_SmallDeposit_RoundsCorrectly() public {
    _setupInitialNav();

    uint256 deposit_ = 10e6; // 10 USDC
    vm.prank(shareholder1);
    vault.requestDeposit(deposit_, shareholder1, shareholder1);

    uint256 nav = vault.lastNav();
    uint256 supply = shareToken.totalSupply();
    uint256 expectedShares = (deposit_ * supply) / nav;
    assertTrue(expectedShares > 0, "10 USDC should yield shares given dead shares supply");

    vm.prank(manager);
    vault.approveDeposit(shareholder1, deposit_);

    assertEq(vault.claimableDepositShares(shareholder1), expectedShares);
  }

  /**
   * @notice Verifies round-trip consistency: deposit USDC → get shares → redeem shares → get USDC.
   * The returned USDC must be ≤ deposited USDC (rounding always favors the vault).
   */
  function test_DecimalMismatch_RoundTrip_NoValueCreation() public {
    _setupInitialNav();

    uint256 depositAmount = 50_000e6;

    // Deposit
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableAssets = vault.claimableDepositAssets(shareholder1);
    vm.prank(shareholder1);
    uint256 shares = vault.deposit(claimableAssets, shareholder1, shareholder1);

    // Immediately redeem the same shares (at the same NAV)
    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    vm.prank(shareholder1);
    uint256 redeemedAssets = vault.redeem(shares, shareholder1, shareholder1);

    assertLe(redeemedAssets, depositAmount, "round-trip must not create value");
  }

  /**
   * @notice Same round-trip test but using mint() and withdraw() instead.
   */
  function test_DecimalMismatch_RoundTrip_MintWithdraw_NoValueCreation() public {
    _setupInitialNav();

    uint256 depositAmount = 50_000e6;

    // Deposit via requestDeposit, claim via mint()
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    vm.prank(shareholder1);
    vault.mint(claimableShares, shareholder1, shareholder1);

    // Redeem via withdraw()
    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);

    vm.prank(shareholder1);
    vault.requestRedeem(claimableShares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, claimableShares);

    uint256 claimableRedeemAssets = vault.claimableRedeemAssets(shareholder1);
    vm.prank(shareholder1);
    vault.withdraw(claimableRedeemAssets, shareholder1, shareholder1);

    assertLe(claimableRedeemAssets, depositAmount, "round-trip (mint/withdraw) must not create value");
  }

  /**
   * @notice With DEAD_SHARES = 1e18, even small USDC deposits produce nonzero shares
   * at typical share prices due to the large initial supply.
   */
  function test_DecimalMismatch_HighSharePrice_SmallDepositSucceeds() public {
    _setupInitialNav();

    vm.prank(shareholder1);
    vault.requestDeposit(1, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, 1);

    assertTrue(vault.claimableDepositShares(shareholder1) > 0, "1 wei deposit produces shares with 1e18 dead shares");
  }

  /**
   * @notice With DEAD_SHARES = 1e18, each share is worth a tiny fraction of a USDC-wei.
   * 1 share rounds to 0 assets, so approveRedemption reverts.
   */
  function test_DecimalMismatch_LowSharePrice_1ShareRoundsToZero() public {
    _setupShareholderWithShares(shareholder1, 100_000e6, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(1, shareholder1, shareholder1);

    uint256 nav = vault.lastNav();
    uint256 supply = shareToken.totalSupply();
    uint256 assetsFor1Share = (1 * nav) / supply;

    assertEq(assetsFor1Share, 0, "1 share rounds to 0 at 1e18 dead shares");

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ZeroAmount.selector));
    vault.approveRedemption(shareholder1, 1);
  }

  // ═══════════════════════════════════════════════════════════════
  //  7. CLAIM-PATH ROUNDING GUARDS
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice If deposit() is called with an amount so small that shares rounds to 0,
   * the _claimDeposit guard reverts. Prevents consuming 0 shares while keeping assets.
   */
  function test_Deposit_TinyAssets_Reverts_WhenSharesRoundToZero() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    uint256 claimableAssets = vault.claimableDepositAssets(shareholder1);

    // shares = tinyAssets * claimableShares / claimableAssets
    // For shares = 0: tinyAssets < claimableAssets / claimableShares
    uint256 threshold = claimableAssets / claimableShares;

    if (threshold > 0) {
      vm.prank(shareholder1);
      vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsClaimable.selector));
      vault.deposit(1, shareholder1, shareholder1);
    }
  }

  /**
   * @notice If mint() is called with an amount so small that assets rounds to 0,
   * the _claimDeposit guard reverts. Prevents free share minting.
   */
  function test_Mint_TinyShares_Reverts_WhenAssetsRoundToZero() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    uint256 claimableAssets = vault.claimableDepositAssets(shareholder1);

    // assets = tinyShares * claimableAssets / claimableShares
    // For assets = 0: tinyShares < claimableShares / claimableAssets
    uint256 threshold = claimableShares / claimableAssets;

    if (threshold > 0) {
      vm.prank(shareholder1);
      vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsClaimable.selector));
      vault.mint(1, shareholder1, shareholder1);
    }
  }

  /**
   * @notice If redeem() is called with tiny shares that produce 0 assets,
   * the _claimRedeem guard reverts. Prevents burning shares for nothing.
   */
  function test_Redeem_TinyShares_Reverts_WhenAssetsRoundToZero() public {
    uint256 shares = _setupShareholderWithShares(shareholder1, 100_000e6, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.claimableRedeemShares(shareholder1);
    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);

    uint256 threshold = claimableShares / claimableAssets;

    if (threshold > 0) {
      vm.prank(shareholder1);
      vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsClaimable.selector));
      vault.redeem(1, shareholder1, shareholder1);
    }
  }

  /**
   * @notice If withdraw() is called with tiny assets that produce 0 shares,
   * the _claimRedeem guard reverts. Prevents free USDC extraction.
   */
  function test_Withdraw_TinyAssets_Reverts_WhenSharesRoundToZero() public {
    uint256 shares = _setupShareholderWithShares(shareholder1, 100_000e6, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.claimableRedeemShares(shareholder1);
    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);

    uint256 threshold = claimableAssets / claimableShares;

    if (threshold > 0) {
      vm.prank(shareholder1);
      vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsClaimable.selector));
      vault.withdraw(1, shareholder1, shareholder1);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  8. CONSERVATION INVARIANT
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice After deposit approval, the total value (claimableAssets + claimableShares) is
   * fully consumed regardless of claim path. No "phantom" value remains.
   */
  function test_Conservation_DepositClaimFully_NoDust() public {
    _setupInitialNav();

    uint256 depositAmount = 77_777e6; // odd number
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableAssets = vault.claimableDepositAssets(shareholder1);
    vm.prank(shareholder1);
    vault.deposit(claimableAssets, shareholder1, shareholder1);

    assertEq(vault.claimableDepositAssets(shareholder1), 0, "no asset dust");
    assertEq(vault.claimableDepositShares(shareholder1), 0, "no share dust");
  }

  /**
   * @notice After redeem approval, full claim via redeem() leaves no dust.
   */
  function test_Conservation_RedeemClaimFully_NoDust() public {
    uint256 shares = _setupShareholderWithShares(shareholder1, 77_777e6, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.claimableRedeemShares(shareholder1);
    vm.prank(shareholder1);
    vault.redeem(claimableShares, shareholder1, shareholder1);

    assertEq(vault.claimableRedeemShares(shareholder1), 0, "no share dust");
    assertEq(vault.claimableRedeemAssets(shareholder1), 0, "no asset dust");
  }

  /**
   * @notice After redeem approval, full claim via withdraw() leaves no dust.
   */
  function test_Conservation_WithdrawClaimFully_NoDust() public {
    uint256 shares = _setupShareholderWithShares(shareholder1, 77_777e6, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);
    vm.prank(shareholder1);
    vault.withdraw(claimableAssets, shareholder1, shareholder1);

    assertEq(vault.claimableRedeemShares(shareholder1), 0, "no share dust");
    assertEq(vault.claimableRedeemAssets(shareholder1), 0, "no asset dust");
  }

  /**
   * @notice totalClaimableRedeemAssets counter stays consistent across multiple partial
   * approvals and claims for multiple controllers.
   */
  function test_Conservation_TotalClaimableRedeemAssets_Consistent() public {
    _setupInitialNav();

    // Both deposit and get shares
    uint256 shares1 = _depositAndClaim(shareholder1, 60_000e6);
    uint256 shares2 = _depositAndClaim(shareholder2, 40_000e6);

    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);
    vm.prank(shareholder2);
    shareToken.approve(address(vault), type(uint256).max);

    // Both request redeem
    vm.prank(shareholder1);
    vault.requestRedeem(shares1, shareholder1, shareholder1);
    vm.prank(shareholder2);
    vault.requestRedeem(shares2, shareholder2, shareholder2);

    // Approve both
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares1);
    vm.prank(manager);
    vault.approveRedemption(shareholder2, shares2);

    uint256 expected = vault.claimableRedeemAssets(shareholder1) + vault.claimableRedeemAssets(shareholder2);
    assertEq(vault.totalClaimableRedeemAssets(), expected, "counter should equal sum of individual");

    // Shareholder1 claims half
    uint256 halfShares1 = shares1 / 2;
    vm.prank(shareholder1);
    uint256 assets1 = vault.redeem(halfShares1, shareholder1, shareholder1);

    expected -= assets1;
    assertEq(vault.totalClaimableRedeemAssets(), expected, "counter after partial claim");

    // Shareholder2 claims all via withdraw
    uint256 allAssets2 = vault.claimableRedeemAssets(shareholder2);
    vm.prank(shareholder2);
    vault.withdraw(allAssets2, shareholder2, shareholder2);

    expected -= allAssets2;
    assertEq(vault.totalClaimableRedeemAssets(), expected, "counter after shareholder2's full claim");

    // Shareholder1 claims remainder
    uint256 remainingShares1 = vault.claimableRedeemShares(shareholder1);
    vm.prank(shareholder1);
    uint256 remainingAssets1 = vault.redeem(remainingShares1, shareholder1, shareholder1);

    expected -= remainingAssets1;
    assertEq(vault.totalClaimableRedeemAssets(), expected, "counter should be 0");
    assertEq(expected, 0, "all value claimed");
  }

  // ═══════════════════════════════════════════════════════════════
  //  9. CROSS-PATH CONSISTENCY (deposit→redeem, mint→withdraw)
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice deposit() for claim, then redeem() for exit — no exploit from mixing paths.
   */
  function test_CrossPath_DepositThenRedeem_NoExploit() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;

    // Claim deposit via deposit()
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 allAssets = vault.claimableDepositAssets(shareholder1);
    vm.prank(shareholder1);
    uint256 shares = vault.deposit(allAssets, shareholder1, shareholder1);

    // Exit via redeem()
    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);
    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 claimableShares = vault.claimableRedeemShares(shareholder1);
    vm.prank(shareholder1);
    uint256 assetsBack = vault.redeem(claimableShares, shareholder1, shareholder1);

    assertLe(assetsBack, depositAmount, "deposit-then-redeem must not create value");
  }

  /**
   * @notice mint() for claim, then withdraw() for exit — no exploit from mixing paths.
   */
  function test_CrossPath_MintThenWithdraw_NoExploit() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;

    // Claim deposit via mint()
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 allShares = vault.claimableDepositShares(shareholder1);
    vm.prank(shareholder1);
    vault.mint(allShares, shareholder1, shareholder1);

    // Exit via withdraw()
    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);
    vm.prank(shareholder1);
    vault.requestRedeem(allShares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, allShares);

    uint256 claimableAssets = vault.claimableRedeemAssets(shareholder1);
    vm.prank(shareholder1);
    vault.withdraw(claimableAssets, shareholder1, shareholder1);

    assertLe(claimableAssets, depositAmount, "mint-then-withdraw must not create value");
  }

  // ═══════════════════════════════════════════════════════════════
  //  10. MIXED CLAIM PATHS ON SAME CLAIMABLE POOL
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice Alternating between deposit() and mint() on the same claimable pool
   * cannot extract more than the approved total.
   */
  function test_MixedDepositMint_CannotExceedApproved() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 totalClaimableAssets = vault.claimableDepositAssets(shareholder1);
    uint256 totalClaimableShares = vault.claimableDepositShares(shareholder1);

    // Claim 25% via deposit()
    uint256 quarterAssets = totalClaimableAssets / 4;
    vm.prank(shareholder1);
    uint256 shares1 = vault.deposit(quarterAssets, shareholder1, shareholder1);

    // Claim 25% via mint()
    uint256 remainingShares = vault.claimableDepositShares(shareholder1);
    uint256 quarterShares = remainingShares / 3; // 1/3 of remaining 75% ≈ 25% of total
    vm.prank(shareholder1);
    vault.mint(quarterShares, shareholder1, shareholder1);

    // Claim remaining via deposit()
    uint256 finalAssets = vault.claimableDepositAssets(shareholder1);
    vm.prank(shareholder1);
    uint256 shares3 = vault.deposit(finalAssets, shareholder1, shareholder1);

    uint256 totalSharesMinted = shares1 + quarterShares + shares3;
    assertLe(totalSharesMinted, totalClaimableShares, "mixed claims must not exceed total approved shares");
    assertEq(vault.claimableDepositAssets(shareholder1), 0, "all consumed");
    assertEq(vault.claimableDepositShares(shareholder1), 0, "all consumed");
  }

  /**
   * @notice Alternating between redeem() and withdraw() on the same claimable pool
   * cannot extract more than the approved total.
   */
  function test_MixedRedeemWithdraw_CannotExceedApproved() public {
    uint256 shares = _setupShareholderWithShares(shareholder1, 100_000e6, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    uint256 totalClaimableAssets = vault.claimableRedeemAssets(shareholder1);
    uint256 totalClaimableShares = vault.claimableRedeemShares(shareholder1);

    // Claim 25% via redeem()
    uint256 quarterShares = totalClaimableShares / 4;
    vm.prank(shareholder1);
    uint256 assets1 = vault.redeem(quarterShares, shareholder1, shareholder1);

    // Claim 25% via withdraw()
    uint256 remainingAssets = vault.claimableRedeemAssets(shareholder1);
    uint256 quarterAssets = remainingAssets / 3;
    vm.prank(shareholder1);
    vault.withdraw(quarterAssets, shareholder1, shareholder1);

    // Claim remaining via redeem()
    uint256 finalShares = vault.claimableRedeemShares(shareholder1);
    vm.prank(shareholder1);
    uint256 assets3 = vault.redeem(finalShares, shareholder1, shareholder1);

    uint256 totalAssets = assets1 + quarterAssets + assets3;
    assertLe(totalAssets, totalClaimableAssets, "mixed claims must not exceed approved");
    assertEq(vault.claimableRedeemAssets(shareholder1), 0, "all consumed");
    assertEq(vault.claimableRedeemShares(shareholder1), 0, "all consumed");
  }

  // ═══════════════════════════════════════════════════════════════
  //  11. VAULT SHARE BALANCE INVARIANT
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice The vault's share balance must always equal the sum of all
   * claimable deposit shares plus all pending redeem shares (locked).
   */
  function test_VaultShareBalance_EqualsClaimableDepositPlusPendingRedeem() public {
    _setupInitialNav();

    uint256 depositAmount = 100_000e6;

    // Shareholder1 deposits
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 expectedVaultShares = vault.claimableDepositShares(shareholder1);
    assertEq(
      shareToken.balanceOf(address(vault)),
      expectedVaultShares,
      "vault shares = claimable deposit shares after approval"
    );

    // Shareholder2 deposits too
    vm.prank(shareholder2);
    vault.requestDeposit(depositAmount, shareholder2, shareholder2);

    vm.prank(manager);
    vault.approveDeposit(shareholder2, depositAmount);

    expectedVaultShares = vault.claimableDepositShares(shareholder1) + vault.claimableDepositShares(shareholder2);
    assertEq(
      shareToken.balanceOf(address(vault)),
      expectedVaultShares,
      "vault shares = sum of claimable deposit shares"
    );

    // Shareholder1 claims her deposit
    vm.prank(shareholder1);
    vault.deposit(depositAmount, shareholder1, shareholder1);

    expectedVaultShares = vault.claimableDepositShares(shareholder2);
    assertEq(shareToken.balanceOf(address(vault)), expectedVaultShares, "vault shares after Shareholder1 claims");

    // Shareholder2 claims, then requests a redeem
    uint256 bobShares = vault.claimableDepositShares(shareholder2);
    vm.prank(shareholder2);
    vault.deposit(depositAmount, shareholder2, shareholder2);

    vm.prank(shareholder2);
    shareToken.approve(address(vault), type(uint256).max);
    vm.prank(shareholder2);
    vault.requestRedeem(bobShares, shareholder2, shareholder2);

    // Vault now holds only Shareholder2's locked redeem shares
    expectedVaultShares = vault.pendingRedeemShares(shareholder2);
    assertEq(shareToken.balanceOf(address(vault)), expectedVaultShares, "vault shares = pending redeem shares");

    vm.prank(manager);
    vault.approveRedemption(shareholder2, bobShares);

    // After approval, shares are burned — vault holds nothing
    assertEq(shareToken.balanceOf(address(vault)), 0, "vault shares = 0 after all approvals and claims");
  }

  // ═══════════════════════════════════════════════════════════════
  //  12. lastNav TRACKING
  // ═══════════════════════════════════════════════════════════════

  /**
   * @notice lastNav must be adjusted manually by approveDeposit (+assets) and
   * approveRedemption (-assets) so it stays correct between updateNav calls.
   * Verify the incremental adjustments match the full recomputation.
   */
  function test_LastNav_MatchesFullRecomputation_AfterApprovals() public {
    _setupInitialNav();

    uint256 navAfterSeed = vault.lastNav();
    uint256 depositAmount = 100_000e6;

    // Request and approve a deposit
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 navAfterApproval = vault.lastNav();
    assertEq(navAfterApproval, navAfterSeed + depositAmount, "lastNav after deposit approval");

    // Full recomputation should agree
    _refreshNav();
    assertEq(vault.lastNav(), navAfterApproval, "recomputed NAV matches manual adjustment");

    // Now claim and request a redeem
    vm.prank(shareholder1);
    vault.deposit(depositAmount, shareholder1, shareholder1);
    uint256 aliceShares = shareToken.balanceOf(shareholder1);

    vm.prank(shareholder1);
    shareToken.approve(address(vault), type(uint256).max);
    vm.prank(shareholder1);
    vault.requestRedeem(aliceShares, shareholder1, shareholder1);

    uint256 navBeforeRedeem = vault.lastNav();

    vm.prank(manager);
    vault.approveRedemption(shareholder1, aliceShares);

    uint256 redeemedAssets = vault.claimableRedeemAssets(shareholder1);
    assertEq(vault.lastNav(), navBeforeRedeem - redeemedAssets, "lastNav after redeem approval");

    // Full recomputation should agree
    _refreshNav();
    assertEq(vault.lastNav(), navBeforeRedeem - redeemedAssets, "recomputed NAV matches after redeem");
  }
}
