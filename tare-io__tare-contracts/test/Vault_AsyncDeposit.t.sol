// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC7540Deposit, IERC7540Operator} from "forge-std/interfaces/IERC7540.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract Vault_AsyncDepositTest is VaultTestBase {
  // ──────── Full Happy Path: request → approve → claim ────────

  function test_AsyncDeposit_FullHappyPath(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    _fundShareholder(shareholder1, depositAmount);

    // Step 1: Request deposit
    vm.prank(shareholder1);
    uint256 requestId = vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    assertEq(requestId, 0, "requestId should be 0");
    assertEq(vault.pendingDepositAssets(shareholder1), depositAmount, "pending deposit mismatch");
    assertEq(vault.totalPendingDepositAssets(), depositAmount, "totalPendingDepositAssets mismatch");
    assertEq(usdc.balanceOf(address(vault)), INITIAL_ASSETS + depositAmount, "vault USDC balance mismatch");

    // Step 2: Manager approves deposit
    uint256 navAtApproval = vault.lastNav();
    uint256 supplyAtApproval = shareToken.totalSupply();
    uint256 expectedShares = (depositAmount * supplyAtApproval) / navAtApproval;

    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    assertEq(claimableShares, expectedShares, "claimable shares mismatch");
    assertEq(vault.pendingDepositAssets(shareholder1), 0, "pending should be cleared");
    assertEq(vault.totalPendingDepositAssets(), 0, "totalPendingDepositAssets should be 0");

    // Step 3: Shareholder claims deposit (mints shares)
    uint256 sharesBefore = shareToken.balanceOf(shareholder1);
    vm.prank(shareholder1);
    uint256 claimableAssetsView = vault.claimableDepositRequest(0, shareholder1);
    vm.prank(shareholder1);
    uint256 mintedShares = vault.deposit(claimableAssetsView, shareholder1, shareholder1);

    assertEq(mintedShares, claimableShares, "minted shares should equal claimable");
    assertEq(shareToken.balanceOf(shareholder1), sharesBefore + mintedShares, "share balance mismatch");
    assertEq(vault.claimableDepositShares(shareholder1), 0, "claimable shares should be cleared after claim");
  }

  // ──────── requestDeposit ────────

  function test_RequestDeposit_TransfersAssetsToVault(uint256 depositAmount) public {
    depositAmount = bound(depositAmount, 1, MAX_FUZZ_AMOUNT);
    _fundShareholder(shareholder1, depositAmount);
    uint256 balanceBefore = usdc.balanceOf(shareholder1);

    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    assertEq(usdc.balanceOf(shareholder1), balanceBefore - depositAmount);
    assertEq(vault.pendingDepositAssets(shareholder1), depositAmount);
  }

  function test_RequestDeposit_EmitsDepositRequestEvent() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vm.expectEmit(true, true, true, true);
    emit IERC7540Deposit.DepositRequest(shareholder1, shareholder1, 0, shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);
  }

  function test_RequestDeposit_IsAdditive(uint256 firstDeposit, uint256 secondDeposit) public {
    firstDeposit = bound(firstDeposit, 1, MAX_FUZZ_AMOUNT / 2);
    secondDeposit = bound(secondDeposit, 1, MAX_FUZZ_AMOUNT / 2);
    _fundShareholder(shareholder1, firstDeposit + secondDeposit);

    vm.prank(shareholder1);
    vault.requestDeposit(firstDeposit, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vault.requestDeposit(secondDeposit, shareholder1, shareholder1);

    assertEq(vault.pendingDepositAssets(shareholder1), firstDeposit + secondDeposit);
    assertEq(vault.totalPendingDepositAssets(), firstDeposit + secondDeposit);
  }

  function test_RequestDeposit_AllowedByOperator() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, true);

    vm.prank(operatorAddr);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    assertEq(vault.pendingDepositAssets(shareholder1), DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_RequestDeposit_Reverts_WhenZeroAmount() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ZeroAmount.selector));
    vault.requestDeposit(0, shareholder1, shareholder1);
  }

  function test_RequestDeposit_Reverts_WhenUnauthorized() public {
    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.Unauthorized.selector));
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);
  }

  function test_RequestDeposit_Reverts_WhenOwnerNotShareholder() public {
    address nonShareholder = makeAddr("nonShareholder");
    _fundShareholder(nonShareholder, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(nonShareholder);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, nonShareholder);
  }

  function test_RequestDeposit_Reverts_WhenControllerNotShareholder() public {
    address nonShareholder = makeAddr("nonShareholder");
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, nonShareholder, shareholder1);
  }

  function test_RequestDeposit_Reverts_WhenControllerIsVault() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InvalidController.selector));
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, address(vault), shareholder1);
  }

  // ──────── approveDeposit ────────

  function test_ApproveDeposit_CalculatesSharesAtCurrentPrice(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    _fundShareholder(shareholder1, depositAmount);

    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    uint256 navBefore = vault.lastNav();
    uint256 totalSupplyBefore = shareToken.totalSupply();
    uint256 expectedShares = (depositAmount * totalSupplyBefore) / navBefore;

    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    assertEq(vault.claimableDepositShares(shareholder1), expectedShares, "shares mismatch");
    assertEq(vault.pendingDepositAssets(shareholder1), 0, "pending not cleared");
    assertEq(vault.totalPendingDepositAssets(), 0, "global counter not decremented");
  }

  function test_ApproveDeposit_EmitsDepositApprovedEvent() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    uint256 navBefore = vault.lastNav();
    uint256 totalSupplyBefore = shareToken.totalSupply();
    uint256 expectedShares = (DEFAULT_DEPOSIT_AMOUNT * totalSupplyBefore) / navBefore;

    vm.prank(manager);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.DepositApproved(shareholder1, DEFAULT_DEPOSIT_AMOUNT, expectedShares);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ApproveDeposit_PartialApproval_LeavesRemainingPending(
    uint256 depositAmount,
    uint256 approveAmount,
    uint256 loanValuation
  ) public {
    depositAmount = bound(depositAmount, 2, MAX_FUZZ_AMOUNT);
    approveAmount = bound(approveAmount, 1, depositAmount - 1);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _fundShareholder(shareholder1, depositAmount);

    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    uint256 navAtApproval = vault.lastNav();
    uint256 supplyAtApproval = shareToken.totalSupply();
    uint256 expectedShares = (approveAmount * supplyAtApproval) / navAtApproval;
    // Skip if rounding to 0 shares (contract would revert)
    vm.assume(expectedShares > 0);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, approveAmount);

    assertEq(vault.pendingDepositAssets(shareholder1), depositAmount - approveAmount, "remaining pending mismatch");
    assertEq(vault.claimableDepositRequest(0, shareholder1), approveAmount, "claimable assets mismatch");
    assertEq(vault.claimableDepositShares(shareholder1), expectedShares, "claimable shares mismatch");
    assertEq(vault.totalPendingDepositAssets(), depositAmount - approveAmount, "global counter mismatch");
  }

  function test_NavExcludesPendingDeposits(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _fundShareholder(shareholder1, depositAmount);
    uint256 navBefore = vault.lastNav();

    // Request a deposit — the USDC goes into the vault
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    // Recompute NAV — pending deposits should be deducted from idle cash
    _refreshNav(loanValuation);

    // NAV should be the same as before (pending deposit USDC is excluded)
    assertEq(vault.lastNav(), navBefore, "NAV should not increase from pending deposits");
  }

  function test_ApproveDeposit_Reverts_WhenZeroAmount() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ZeroAmount.selector));
    vault.approveDeposit(shareholder1, 0);
  }

  function test_ApproveDeposit_Reverts_WhenExceedsPending() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsPending.selector));
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT + 1);
  }

  function test_ApproveDeposit_Reverts_WhenNoPending() public {
    _setupInitialNav();

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NoPendingDeposit.selector));
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ApproveDeposit_Reverts_WhenStaleNav() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    // Warp past NAV age limit
    timeNow += uint48(MAX_NAV_AGE + 1);
    vm.warp(uint256(timeNow));

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.StaleNav.selector));
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ApproveDeposit_Reverts_WhenNavInProgress() public {
    // Create 2 loans so NAV doesn't finalize in 1 batch
    uint64 id1 = _createActiveLoan(25_000e6);
    uint64 id2 = _createActiveLoan(25_000e6);
    _transferLoanToVault(id1);
    _transferLoanToVault(id2);

    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);

    // Start computation without finishing it
    vm.prank(manager);
    vault.updateNav(1);

    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NavComputationInProgress.selector));
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ApproveDeposit_Reverts_WhenNotManager() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        shareholder1,
        investorManagerRole
      )
    );
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ApproveDeposit_Reverts_WhenNavIsZero() public {
    // Request a deposit — USDC enters the vault
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    // Finalize NAV with no loans and no extra USDC:
    // lastNav = USDC_balance - totalPendingDepositAssets = DEFAULT_DEPOSIT_AMOUNT - DEFAULT_DEPOSIT_AMOUNT = 0
    mockCalculator.setNextValuation(0); // no loans in vault, valuation is genuinely 0
    vm.prank(manager);
    vault.updateNav(NAV_BATCH_SIZE);
    assertEq(vault.lastNav(), 0, "NAV should be zero");

    // approveDeposit should revert with ZeroNav (not panic on division by zero)
    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ZeroNav.selector));
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  // ──────── deposit (claim by assets) ────────

  function test_Deposit_MintsSharesCorrectly(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    _fundShareholder(shareholder1, depositAmount);

    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);

    vm.prank(shareholder1);
    uint256 shares = vault.deposit(claimableAssets, shareholder1, shareholder1);

    assertEq(shares, claimableShares, "shares minted mismatch");
    assertEq(shareToken.balanceOf(shareholder1), shares, "share balance mismatch");
  }

  function test_Deposit_PartialClaim(uint256 depositAmount, uint256 claimFraction, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 2, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    _fundShareholder(shareholder1, depositAmount);

    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 totalClaimableShares = vault.claimableDepositShares(shareholder1);
    uint256 totalClaimableAssets = vault.claimableDepositRequest(0, shareholder1);
    uint256 claimAssets = bound(claimFraction, 1, totalClaimableAssets - 1);
    uint256 expectedSharesClaimed = (claimAssets * totalClaimableShares) / totalClaimableAssets;
    // Skip if rounding to 0 shares
    vm.assume(expectedSharesClaimed > 0);

    // Claim partial
    vm.prank(shareholder1);
    uint256 sharesClaimed = vault.deposit(claimAssets, shareholder1, shareholder1);

    assertEq(sharesClaimed, expectedSharesClaimed, "shares claimed mismatch");
    assertEq(
      vault.claimableDepositShares(shareholder1),
      totalClaimableShares - expectedSharesClaimed,
      "remaining shares mismatch"
    );
    assertEq(
      vault.claimableDepositAssets(shareholder1),
      totalClaimableAssets - claimAssets,
      "remaining assets mismatch"
    );
  }

  function test_Deposit_AfterPartialApproval_ClaimsApprovedPortion() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    uint256 halfAmount = DEFAULT_DEPOSIT_AMOUNT / 2;
    vm.prank(manager);
    vault.approveDeposit(shareholder1, halfAmount);

    // Claim the approved portion
    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);
    assertEq(claimableAssets, halfAmount, "claimable should equal approved amount");

    vm.prank(shareholder1);
    uint256 shares = vault.deposit(claimableAssets, shareholder1, shareholder1);
    assertEq(shares, claimableShares, "should mint all approved shares");

    // Nothing more claimable
    assertEq(vault.claimableDepositRequest(0, shareholder1), 0, "no more claimable after full claim");

    // But pending should still exist for the unapproved portion
    assertEq(vault.pendingDepositAssets(shareholder1), DEFAULT_DEPOSIT_AMOUNT - halfAmount, "remaining pending");
  }

  function test_Deposit_MintsToReceiver_WhenReceiverDiffersFromController() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);

    // Claim with receiver = shareholder2 (different from controller = shareholder1)
    vm.prank(shareholder1);
    uint256 shares = vault.deposit(claimableAssets, shareholder2, shareholder1);

    assertEq(shareToken.balanceOf(shareholder2), shares, "shares should go to receiver");
    assertEq(shareToken.balanceOf(shareholder1), 0, "controller should have no shares");
  }

  function test_Deposit_AllowedByOperator() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, true);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);

    vm.prank(operatorAddr);
    uint256 shares = vault.deposit(claimableAssets, shareholder1, shareholder1);
    assertEq(shares, claimableShares, "operator should receive all claimable shares");
  }

  function test_Deposit_AlwaysAvailable_EvenDuringNavComputation() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    // Start a new NAV computation (add another loan so it doesn't finalize)
    uint64 id2 = _createActiveLoan(25_000e6);
    _transferLoanToVault(id2);

    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    vm.prank(manager);
    vault.updateNav(1);
    assertTrue(vault.navStart() > 0, "NAV computation should be in progress");

    // Claim should still work — price was locked at approval time
    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);
    vm.prank(shareholder1);
    uint256 shares = vault.deposit(claimableAssets, shareholder1, shareholder1);
    assertEq(shares, claimableShares, "claim should succeed during NAV computation");
  }

  function test_Deposit_Reverts_WhenNoClaimable() public {
    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NoClaimableDeposit.selector));
    vault.deposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);
  }

  function test_Deposit_Reverts_WhenExceedsClaimable() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);
    uint256 tooMuch = claimableAssets * 2;

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsClaimable.selector));
    vault.deposit(tooMuch, shareholder1, shareholder1);
  }

  function test_Deposit_Reverts_WhenUnauthorized() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);

    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.Unauthorized.selector));
    vault.deposit(claimableAssets, shareholder1, shareholder1);
  }

  function test_Deposit_Reverts_WhenControllerNotShareholder() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);

    // Revoke shareholder1 role after approval
    shareToken.revokeRole(shareToken.SHAREHOLDER_ROLE(), shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.deposit(claimableAssets, shareholder1, shareholder1);
  }

  function test_Deposit_Reverts_WhenReceiverIsVault() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InvalidReceiver.selector));
    vault.deposit(claimableAssets, address(vault), shareholder1);
  }

  // ──────── mint (claim by shares) ────────

  function test_Mint_MintsExactShares(uint256 depositAmount, uint256 loanValuation) public {
    depositAmount = bound(depositAmount, 1, MAX_FUZZ_AMOUNT);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    _fundShareholder(shareholder1, depositAmount);

    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    uint256 claimableAssets = vault.claimableDepositAssets(shareholder1);

    vm.prank(shareholder1);
    uint256 assets = vault.mint(claimableShares, shareholder1, shareholder1);

    assertEq(shareToken.balanceOf(shareholder1), claimableShares, "shares minted mismatch");
    assertEq(assets, claimableAssets, "assets should equal full claimable amount");
  }

  function test_Mint_MintsToReceiver_WhenReceiverDiffersFromController() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);

    // Claim with receiver = shareholder2 (different from controller = shareholder1)
    vm.prank(shareholder1);
    vault.mint(claimableShares, shareholder2, shareholder1);

    assertEq(shareToken.balanceOf(shareholder2), claimableShares, "shares should go to receiver");
    assertEq(shareToken.balanceOf(shareholder1), 0, "controller should have no shares");
  }

  function test_Mint_Reverts_WhenExceedsClaimable() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.ExceedsClaimable.selector));
    vault.mint(claimableShares + 1, shareholder1, shareholder1);
  }

  function test_Mint_Reverts_WhenControllerNotShareholder() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);

    // Revoke shareholder1 role after approval
    shareToken.revokeRole(shareToken.SHAREHOLDER_ROLE(), shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.mint(claimableShares, shareholder1, shareholder1);
  }

  function test_Mint_Reverts_WhenReceiverIsVault() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InvalidReceiver.selector));
    vault.mint(claimableShares, address(vault), shareholder1);
  }

  // ──────── cancelDepositRequest ────────

  function test_CancelDeposit_Reverts_WhenReceiverIsVault() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.InvalidReceiver.selector));
    vault.cancelDepositRequest(shareholder1, address(vault));
  }

  function test_CancelDeposit_ReturnsAssetsToController(uint256 depositAmount) public {
    depositAmount = bound(depositAmount, 1, MAX_FUZZ_AMOUNT);
    _fundShareholder(shareholder1, depositAmount);

    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    uint256 balanceBefore = usdc.balanceOf(shareholder1);

    vm.prank(shareholder1);
    uint256 returned = vault.cancelDepositRequest(shareholder1, shareholder1);

    assertEq(returned, depositAmount, "returned amount mismatch");
    assertEq(usdc.balanceOf(shareholder1), balanceBefore + depositAmount, "USDC not returned");
    assertEq(vault.pendingDepositAssets(shareholder1), 0, "pending should be cleared");
    assertEq(vault.totalPendingDepositAssets(), 0, "global counter should be 0");
  }

  function test_CancelDeposit_EmitsEvent() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.DepositRequestCancelled(shareholder1, shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vault.cancelDepositRequest(shareholder1, shareholder1);
  }

  function test_CancelDeposit_AllowedByOperator() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, true);

    vm.prank(operatorAddr);
    uint256 returned = vault.cancelDepositRequest(shareholder1, shareholder1);
    assertEq(returned, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_CancelDeposit_AlwaysAvailable_EvenDuringNavComputation() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    // Start a NAV computation that doesn't finalize
    uint64 id2 = _createActiveLoan(25_000e6);
    _transferLoanToVault(id2);

    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    vm.prank(manager);
    vault.updateNav(1);
    assertTrue(vault.navStart() > 0, "NAV computation should be in progress");

    // Cancel should still work — it's NAV-neutral
    vm.prank(shareholder1);
    uint256 returned = vault.cancelDepositRequest(shareholder1, shareholder1);
    assertEq(returned, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_CancelDeposit_Reverts_WhenNoPending() public {
    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NoPendingDeposit.selector));
    vault.cancelDepositRequest(shareholder1, shareholder1);
  }

  function test_CancelDeposit_Reverts_WhenUnauthorized() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.Unauthorized.selector));
    vault.cancelDepositRequest(shareholder1, shareholder1);
  }

  function test_CancelDeposit_Reverts_WhenControllerNotShareholder() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    // Revoke shareholder1 role after request
    shareToken.revokeRole(shareToken.SHAREHOLDER_ROLE(), shareholder1);

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.cancelDepositRequest(shareholder1, shareholder1);
  }

  function test_CancelDeposit_Reverts_WhenReceiverNotShareholder() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    address nonShareholder = makeAddr("nonShareholder");

    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NotShareholder.selector));
    vault.cancelDepositRequest(shareholder1, nonShareholder);
  }

  // ──────── Operator Management ────────

  function test_SetOperator_GrantsAndRevokesAccess() public {
    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, true);
    assertTrue(vault.isOperator(shareholder1, operatorAddr));

    vm.prank(shareholder1);
    vault.setOperator(operatorAddr, false);
    assertFalse(vault.isOperator(shareholder1, operatorAddr));
  }

  function test_SetOperator_EmitsOperatorSetEvent() public {
    vm.prank(shareholder1);
    vm.expectEmit(true, true, true, true);
    emit IERC7540Operator.OperatorSet(shareholder1, operatorAddr, true);
    vault.setOperator(operatorAddr, true);
  }

  // ──────── Multiple Controllers ────────

  function test_MultipleControllers_IndependentDeposits(
    uint256 amount1,
    uint256 amount2,
    uint256 loanValuation
  ) public {
    amount1 = bound(amount1, 1, MAX_FUZZ_AMOUNT / 2);
    amount2 = bound(amount2, 1, MAX_FUZZ_AMOUNT / 2);
    loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(amount1);
    _assumeNonZeroShares(amount2);
    _fundShareholder(shareholder1, amount1);
    _fundShareholder(shareholder2, amount2);

    vm.prank(shareholder1);
    vault.requestDeposit(amount1, shareholder1, shareholder1);

    vm.prank(shareholder2);
    vault.requestDeposit(amount2, shareholder2, shareholder2);

    assertEq(vault.pendingDepositAssets(shareholder1), amount1);
    assertEq(vault.pendingDepositAssets(shareholder2), amount2);
    assertEq(vault.totalPendingDepositAssets(), amount1 + amount2);

    // Approve both independently
    uint256 nav1 = vault.lastNav();
    uint256 supply1 = shareToken.totalSupply();
    vm.prank(manager);
    vault.approveDeposit(shareholder1, amount1);
    uint256 expectedShares1 = (amount1 * supply1) / nav1;

    uint256 nav2 = vault.lastNav();
    uint256 supply2 = shareToken.totalSupply();
    vm.prank(manager);
    vault.approveDeposit(shareholder2, amount2);
    uint256 expectedShares2 = (amount2 * supply2) / nav2;

    assertEq(vault.claimableDepositShares(shareholder1), expectedShares1, "shareholder1 shares mismatch");
    assertEq(vault.claimableDepositShares(shareholder2), expectedShares2, "shareholder2 shares mismatch");
  }

  // ──────── View Functions ────────

  function test_PendingDepositRequest_ReturnsCorrectValue() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);
    assertEq(vault.pendingDepositRequest(0, shareholder1), DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ClaimableDepositRequest_ReturnsAssetsValue() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);
    assertEq(claimableAssets, DEFAULT_DEPOSIT_AMOUNT, "claimable assets should equal deposit amount");
  }

  function test_Asset_ReturnsUSDCAddress() public view {
    assertEq(vault.asset(), address(usdc));
  }

  function test_Share_ReturnsShareTokenAddress() public view {
    assertEq(vault.share(), address(shareToken));
  }

  function test_TotalAssets_ReturnsNav() public {
    _setupInitialNav();
    assertEq(vault.totalAssets(), vault.lastNav());
  }

  function test_ConvertToShares_ConvertsCorrectly() public {
    _setupInitialNav();
    uint256 expectedShares = (DEFAULT_DEPOSIT_AMOUNT * shareToken.totalSupply()) / vault.lastNav();
    uint256 shares = vault.convertToShares(DEFAULT_DEPOSIT_AMOUNT);
    assertEq(shares, expectedShares, "convertToShares mismatch");
  }

  function test_ConvertToAssets_ConvertsCorrectly() public {
    _setupInitialNav();
    uint256 sharesToConvert = 1_000e18;
    uint256 expectedAssets = (sharesToConvert * vault.lastNav()) / shareToken.totalSupply();
    uint256 assets = vault.convertToAssets(sharesToConvert);
    assertEq(assets, expectedAssets, "convertToAssets mismatch");
  }

  function test_MaxDeposit_ReturnsZero_WhenNoClaimable() public view {
    assertEq(vault.maxDeposit(shareholder1), 0);
  }

  function test_MaxDeposit_ReturnsClaimableAssets() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    assertEq(vault.maxDeposit(shareholder1), DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_MaxMint_ReturnsZero_WhenNoClaimable() public view {
    assertEq(vault.maxMint(shareholder1), 0);
  }

  function test_MaxMint_ReturnsClaimableShares() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    assertEq(vault.maxMint(shareholder1), vault.claimableDepositShares(shareholder1));
  }

  function test_MaxWithdraw_ReturnsZero() public view {
    assertEq(vault.maxWithdraw(shareholder1), 0);
  }

  function test_MaxRedeem_ReturnsZero() public view {
    assertEq(vault.maxRedeem(shareholder1), 0);
  }

  // ──────── Must-Revert Functions ────────

  function test_PreviewDeposit_Reverts() public {
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.MustRevert.selector));
    vault.previewDeposit(1000);
  }

  function test_PreviewMint_Reverts() public {
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.MustRevert.selector));
    vault.previewMint(1000);
  }

  function test_PreviewWithdraw_Reverts() public {
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.MustRevert.selector));
    vault.previewWithdraw(1000);
  }

  function test_PreviewRedeem_Reverts() public {
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.MustRevert.selector));
    vault.previewRedeem(1000);
  }

  function test_Withdraw_Reverts_WhenNoClaimable() public {
    vm.prank(shareholder1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.NoClaimableRedeem.selector));
    vault.withdraw(1000, shareholder1, shareholder1);
  }

  function test_SyncDeposit_Reverts() public {
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.MustRevert.selector));
    vault.deposit(1000, shareholder1);
  }

  function test_SyncMint_Reverts() public {
    vm.expectRevert(abi.encodeWithSelector(IPortfolioVault.MustRevert.selector));
    vault.mint(1000, shareholder1);
  }

  // ──────── ERC-165 ────────

  function test_SupportsInterface_ERC7540Operator() public view {
    assertTrue(vault.supportsInterface(0xe3bc4e65));
  }

  function test_SupportsInterface_ERC7575() public view {
    assertTrue(vault.supportsInterface(0x2f0a18c5));
  }

  function test_SupportsInterface_ERC7540Deposit() public view {
    assertTrue(vault.supportsInterface(0xce3bbe50));
  }

  function test_SupportsInterface_ERC7540Redeem() public view {
    assertTrue(vault.supportsInterface(0x620ee8e4));
  }

  function test_SupportsInterface_ERC721Receiver() public view {
    assertTrue(vault.supportsInterface(type(IERC721Receiver).interfaceId));
  }
}
