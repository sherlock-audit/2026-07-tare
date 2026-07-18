// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "./setup/LoansTestBase.t.sol";
import {PortfolioVault} from "contracts/PortfolioVault.sol";
import {ILoans, Roles} from "contracts/interfaces/ILoans.sol";
import {ILoansExchange} from "contracts/interfaces/ILoansExchange.sol";
import {IVaultShareToken} from "contracts/interfaces/IVaultShareToken.sol";
import {INavCalculator} from "contracts/interfaces/INavCalculator.sol";
import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";
import {LoansExchange} from "contracts/LoansExchange.sol";
import {VaultShareToken} from "contracts/VaultShareToken.sol";
import {MockNavCalculator} from "test/lib/MockNavCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title VaultTestBase
 * @notice Shared base for all PortfolioVault test suites. Deploys the vault
 * infrastructure (exchange, calculator, share token, vault) and grants
 * common roles. Children add their own shareholders and funding.
 */
contract VaultTestBase is LoansTestBase {
  PortfolioVault public vault;
  MockNavCalculator public mockCalculator;
  VaultShareToken public shareToken;
  LoansExchange public exchange;

  address public manager = makeAddr("manager");
  address public shareholder1 = makeAddr("shareholder1");
  address public shareholder2 = makeAddr("shareholder2");
  address public operatorAddr = makeAddr("operatorAddr");
  address public loanBuyer = makeAddr("loanBuyer");

  uint256 internal constant WAD = 1e18;
  uint256 internal constant MAX_NAV_AGE = 1 hours;
  uint256 internal constant MAX_NAV_COMPUTATION_TIME = 10 minutes;
  uint256 internal constant INITIAL_ASSETS = 475_000e6;
  uint256 internal constant DEFAULT_LOAN_VALUATION = 25_000e6;
  uint256 internal constant DEFAULT_DEPOSIT_AMOUNT = 100_000e6;
  uint256 internal constant DEFAULT_REDEEM_SHARES = 50_000e18;
  uint256 internal constant NAV_BATCH_SIZE = 10;
  uint128 internal constant DEFAULT_OFFER_PRICE = 10_000e6;
  uint48 internal constant DEADLINE_OFFSET = 1 days;

  // Max fuzz value for deposits and loan valuations. The redeem path computes
  // shares * lastNav which can overflow. After a deposit, shares ≈ deposit * 1e18 / nav,
  // so shares * nav ≈ deposit² * 1e18 / nav. Using uint112 keeps this safely under uint256 max.
  uint256 internal constant MAX_FUZZ_AMOUNT = type(uint112).max;

  bytes32 internal portfolioManagerRole;
  bytes32 internal investorManagerRole;
  bytes32 internal adminRole;
  bytes32 internal defaultAdminRole;
  bytes32 internal guardianRole;

  function setUp() public virtual override {
    super.setUp();

    exchange = new LoansExchange(ILoansNFT(address(loansNFT)), ILoans(address(loans)), address(this), recoveryAddress);
    mockCalculator = new MockNavCalculator();

    // Predict vault address so VaultShareToken can grant MINTER/BURNER roles at deployment
    address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
    shareToken = new VaultShareToken(
      "Vault Shares",
      "vTARE",
      address(this),
      recoveryAddress,
      predictedVault,
      address(usdc)
    );

    // DEAD_ADDRESS must be whitelisted before vault deployment (dead shares mint)
    shareToken.grantRole(shareToken.WHITELISTER_ROLE(), address(this));
    shareToken.grantRole(shareToken.SHAREHOLDER_ROLE(), address(0xdead));

    vault = new PortfolioVault(
      ILoans(address(loans)),
      ILoansNFT(address(loansNFT)),
      ILoansExchange(address(exchange)),
      IERC20(address(usdc)),
      IVaultShareToken(address(shareToken)),
      INavCalculator(address(mockCalculator)),
      guardian,
      recoveryAddress,
      MAX_NAV_AGE,
      MAX_NAV_COMPUTATION_TIME
    );

    // Mirror the deploy script: 0xdead only needs the role for the constructor mint
    shareToken.revokeRole(shareToken.SHAREHOLDER_ROLE(), address(0xdead));

    portfolioManagerRole = vault.PORTFOLIO_MANAGER();
    investorManagerRole = vault.INVESTOR_MANAGER();
    adminRole = vault.ADMIN_ROLE();
    defaultAdminRole = vault.DEFAULT_ADMIN_ROLE();
    guardianRole = vault.GUARDIAN_ROLE();

    vm.startPrank(guardian);
    vault.grantRole(investorManagerRole, manager);
    vault.grantRole(adminRole, address(this));
    vault.grantRole(portfolioManagerRole, address(this));
    vm.stopPrank();

    // Vault receives SHAREHOLDER_ROLE in the VaultShareToken constructor
    shareToken.grantRole(shareToken.SHAREHOLDER_ROLE(), shareholder1);
    shareToken.grantRole(shareToken.SHAREHOLDER_ROLE(), shareholder2);
  }

  /** @notice Returns a default deadline 1 day from now */
  function _deadline() internal view returns (uint48) {
    return timeNow + DEADLINE_OFFSET;
  }

  /** @notice Builds a single-element loan ID array */
  function _singleLoanArray(uint64 id) internal pure returns (uint64[] memory) {
    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    return ids;
  }

  /** @notice Transfers a loan NFT from investor to vault and admits it into NAV */
  function _transferLoanToVault(uint64 id) internal virtual {
    vm.prank(investor);
    loansNFT.safeTransferFrom(investor, address(vault), uint256(id));
    vault.addLoansToNav(_singleLoanArray(id));
  }

  /** @notice Creates a loan with withdrawable cashflows and transfers it to the vault */
  function _createVaultLoanWithCashflow() internal virtual returns (uint64 id) {
    return _createVaultLoanWithCashflow(DEFAULT_TEST_PRINCIPAL);
  }

  /** @notice Creates a loan with withdrawable cashflows and transfers it to the vault */
  function _createVaultLoanWithCashflow(int128 principal) internal returns (uint64 id) {
    id = _createLoanWithInvestorCashflow(principal, bytes32("ref"));
    _transferLoanToVault(id);
  }

  /** @notice Creates a loan with the vault set as investor at creation time */
  function _createLoanForVaultInvestor(int128 principal) internal returns (uint64 loanId_) {
    vm.prank(originator);
    loans.registerAddress(Roles.Investor, address(vault));

    vm.prank(originator);
    loanId_ = loans.create(borrower, address(vault), servicer, originator, principal, timeNow);
  }

  /** @notice Creates an offer to sell a loan to the vault */
  function _createOfferForVault() internal virtual returns (uint64 offerId, uint64 loanId_) {
    return _createOfferForVault(DEFAULT_TEST_PRINCIPAL, DEFAULT_OFFER_PRICE);
  }

  /** @notice Creates an offer to sell a loan to the vault */
  function _createOfferForVault(int128 principal, uint128 price) internal returns (uint64 offerId, uint64 loanId_) {
    loanId_ = _createActiveLoan(principal);
    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanId_;

    vm.prank(investor);
    offerId = exchange.createOffer(address(vault), price, _deadline(), loanIds);
  }

  /** @notice Creates a sale offer from the vault to loanBuyer */
  function _createSaleOfferFromVault() internal virtual returns (uint64 offerId, uint64 loanId_) {
    return _createSaleOfferFromVault(DEFAULT_TEST_PRINCIPAL, DEFAULT_OFFER_PRICE);
  }

  /** @notice Creates a sale offer from the vault to loanBuyer */
  function _createSaleOfferFromVault(
    int128 principal,
    uint128 price
  ) internal returns (uint64 offerId, uint64 loanId_) {
    loanId_ = _createActiveLoan(principal);
    _transferLoanToVault(loanId_);

    vm.prank(manager);
    offerId = vault.createSaleOffer(loanBuyer, price, _deadline(), _singleLoanArray(loanId_));
  }

  /** @notice Returns share price in WAD (1e18 = 1:1) */
  function _sharePrice() internal view returns (uint256) {
    return (vault.lastNav() * WAD) / shareToken.totalSupply();
  }

  /** @notice Sets up a realistic initial NAV: transfers a loan to the vault, adds idle USDC, and finalizes the NAV */
  function _setupInitialNav() internal {
    _setupInitialNav(DEFAULT_LOAN_VALUATION);
  }

  /**
   * @notice Sets up initial NAV with a custom loan valuation, producing NAV = INITIAL_ASSETS + loanValuation
   * @param loanValuation The value the calculator returns for the loan
   */
  function _setupInitialNav(uint256 loanValuation) internal {
    uint64 loanId_ = _createActiveLoan(25_000e6);
    _transferLoanToVault(loanId_);

    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(loanValuation);

    vm.prank(manager);
    vault.updateNav(NAV_BATCH_SIZE);
  }

  /** @notice Refreshes the NAV with current vault balances */
  function _refreshNav() internal {
    _refreshNav(DEFAULT_LOAN_VALUATION);
  }

  /** @notice Refreshes the NAV with a custom loan valuation */
  function _refreshNav(uint256 loanValuation) internal {
    mockCalculator.setNextValuation(loanValuation);
    vm.prank(manager);
    vault.updateNav(NAV_BATCH_SIZE);
  }

  /** @notice Mints USDC to a shareholder and approves the vault */
  function _fundShareholder(address who, uint256 amount) internal {
    usdc.mint(who, amount);
    vm.prank(who);
    usdc.approve(address(vault), type(uint256).max);
  }

  /** @notice Skips fuzz runs where deposit would produce zero shares (too small relative to NAV) */
  function _assumeNonZeroShares(uint256 depositAmount) internal view {
    vm.assume((depositAmount * shareToken.totalSupply()) / vault.lastNav() > 0);
  }

  /**
   * @notice Sets up NAV with a fuzzed loan valuation, deposits, and returns shares.
   * Also approves the vault to transfer shares (needed for requestRedeem).
   */
  function _setupShareholderWithShares(
    address who,
    uint256 depositAmount,
    uint256 loanValuation
  ) internal returns (uint256 shares) {
    _setupInitialNav(loanValuation);
    _assumeNonZeroShares(depositAmount);
    _fundShareholder(who, depositAmount);
    shares = _depositAndClaim(who, depositAmount);

    vm.prank(who);
    shareToken.approve(address(vault), type(uint256).max);
  }

  /** @notice Full deposit flow: request → approve → claim. Caller must ensure NAV is fresh. */
  function _depositAndClaim(address who, uint256 assets) internal returns (uint256 shares) {
    vm.prank(who);
    vault.requestDeposit(assets, who, who);

    vm.prank(manager);
    vault.approveDeposit(who, assets);

    uint256 claimableAssets = vault.maxDeposit(who);
    vm.prank(who);
    shares = vault.deposit(claimableAssets, who, who);
  }
}
