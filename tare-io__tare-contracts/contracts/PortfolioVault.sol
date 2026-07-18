// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Rescuable} from "contracts/misc/Rescuable.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {IERC7540Deposit, IERC7540Redeem, IERC7540Operator} from "contracts/misc/interfaces/IERC7540.sol";
import {IERC7575} from "contracts/misc/interfaces/IERC7575.sol";
import {INavCalculator} from "contracts/interfaces/INavCalculator.sol";
import {ILoans, InvestorWithdrawalResult, Roles} from "contracts/interfaces/ILoans.sol";
import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";
import {ILoansExchange, SaleOffer} from "contracts/interfaces/ILoansExchange.sol";
import {IVaultShareToken} from "contracts/interfaces/IVaultShareToken.sol";
import {ILoansAuth} from "contracts/misc/interfaces/ILoansAuth.sol";

/**
 * @title Tare Portfolio Vault
 * @notice Core vault contract that holds loan NFTs and computes on-chain NAV via
 * paginated enumeration. Delegates loan valuation to an external INavCalculator
 * contract. Implements ERC-7540.
 */
contract PortfolioVault is IPortfolioVault, Rescuable, ReentrancyGuardTransient, IERC721Receiver {
  using SafeERC20 for IERC20;

  // ───────────────────── Constants ──────────────────────

  bytes32 public constant PORTFOLIO_MANAGER = keccak256("PORTFOLIO_MANAGER");
  bytes32 public constant INVESTOR_MANAGER = keccak256("INVESTOR_MANAGER");

  uint256 internal constant WAD_UNIT = 1e18;
  uint256 internal constant DEAD_SHARES = 1e18;
  address internal constant DEAD_ADDRESS = address(0xdead);

  // ───────────────────── Immutables ─────────────────────

  /// @notice The underlying asset token (e.g. USDC) used to settle deposits and redemptions.
  IERC20 public immutable assetToken;

  /// @notice The share token minted to investors when their deposit is approved.
  IVaultShareToken public immutable shareToken;

  // ──────────────────── External references ─────────────

  /// @notice The Loans contract this vault funds and collects cashflows from.
  ILoans public loans;

  /// @notice The LoansExchange contract used to atomically buy or sell loan bundles.
  ILoansExchange public exchange;

  /// @notice The Loans NFT contract (ERC721Enumerable) used to enumerate vault holdings.
  ILoansNFT public loansNFT;

  /// @inheritdoc IPortfolioVault
  INavCalculator public calculator;

  // ───────────────────── NAV state ─────────────────────

  /**
   * @notice Index into `_navLoanIds` of the next loan to value in the current
   *         NAV computation cycle. Reset to `0` once the full list has been swept.
   */
  uint256 public navCursor;

  /**
   * @notice Accumulator for the in-progress NAV computation. Folded into `lastNav`
   *         when the cycle finalises.
   */
  uint256 public pendingNav;

  /// @inheritdoc IPortfolioVault
  uint256 public navStart;

  /// @notice The most recently finalised NAV value.
  uint256 public lastNav;

  /// @inheritdoc IPortfolioVault
  uint256 public lastNavUpdate;

  /**
   * @notice Snapshot of `loansNFT.ownershipNonce(address(this))` used during NAV
   *         computation and retained between cycles. Mismatch across batches triggers
   *         a restart and re-syncs the NAV list against on-chain ownership; mismatch
   *         at approval time reverts with `PortfolioHoldingsChanged`.
   */
  uint256 public lastOwnershipNonce;

  /**
   * @notice Snapshot of `calculator.configurationVersion()` used during NAV
   *         computation and retained between cycles. Mismatch across batches triggers
   *         a restart; mismatch at approval time reverts with `CalculatorConfigurationChanged`.
   */
  uint256 public lastCalculatorConfigurationVersion;

  /**
   * @dev Curated list of loan IDs included in NAV. Loans must be owned by the
   *      vault to count; ownership is re-verified on every nonce change. Donations
   *      landing in the vault are not added automatically and therefore cannot
   *      influence NAV until a manager explicitly admits them via `addLoansToNav`.
   */
  uint64[] internal _navLoanIds;

  /// @dev 1-indexed position of each loanId in `_navLoanIds`; 0 means absent.
  mapping(uint64 loanId => uint256 indexPlusOne) internal _navLoanIndex;

  // ────────────────── NAV deduction counters ────────────

  /**
   * @notice Total assets pending deposit approval across all controllers.
   *         Subtracted from on-chain `assetToken` balance when computing NAV.
   */
  uint256 public totalPendingDepositAssets;

  /**
   * @notice Total assets reserved for approved-but-unclaimed redemptions across all controllers.
   *         Subtracted from on-chain `assetToken` balance when computing NAV.
   */
  uint256 public totalClaimableRedeemAssets;

  // ──────────────────── Configuration ──────────────────

  /// @inheritdoc IPortfolioVault
  uint256 public maxNavAge;

  /// @inheritdoc IPortfolioVault
  uint256 public maxNavComputationTime;

  // ──────────────────── Async deposit/redeem state ────────

  /**
   * @dev ERC-7540 operator authorisations: `_isOperator[controller][operator]`.
   */
  mapping(address controller => mapping(address operator => bool approved)) internal _isOperator;

  /**
   * @notice Asset amount waiting for approval per controller. Pending requests can be
   *         cancelled by the controller; once approved, assets move to the claimable pool.
   */
  mapping(address controller => uint256 assets) public pendingDepositAssets;

  /**
   * @notice Shares pre-minted to the vault at deposit approval, claimable per controller.
   */
  mapping(address controller => uint256 shares) public claimableDepositShares;

  /**
   * @notice Asset value the controller's claimable shares were minted against. Tracked alongside
   *         shares to keep the conversion ratio fixed at the approval-time NAV.
   */
  mapping(address controller => uint256 assets) public claimableDepositAssets;

  /**
   * @notice Shares transferred to the vault and waiting for redeem approval per controller.
   *         Pending requests can be cancelled by the controller; on approval, shares are burned.
   */
  mapping(address controller => uint256 shares) public pendingRedeemShares;

  /**
   * @notice Bookkeeping count of shares the controller's claimable assets were redeemed against.
   *         Shares themselves were burned at approval time; this value backs the redeem/withdraw math.
   */
  mapping(address controller => uint256 shares) public claimableRedeemShares;

  /**
   * @notice Asset amount reserved for the controller and ready to be withdrawn against burned shares.
   */
  mapping(address controller => uint256 assets) public claimableRedeemAssets;

  /**
   * @notice Deploys the PortfolioVault
   * @param loans_ Loans contract address
   * @param loansNFT_ Loans NFT contract (ERC721Enumerable)
   * @param exchange_ LoansExchange contract for atomic loan purchases/sales
   * @param asset_ Underlying asset
   * @param share_ Vault share token contract (ERC20)
   * @param calculator_ Initial NAV calculator contract
   * @param initialGuardian Address that receives GUARDIAN_ROLE (also controls DEFAULT_ADMIN_ROLE)
   * @param initialRecoveryAddress Address that receives rescued tokens
   * @param maxNavAge_ Maximum age (seconds) of NAV for share-price-sensitive operations
   * @param maxNavComputationTime_ Maximum allowed duration (seconds) for a NAV computation
   */
  constructor(
    ILoans loans_,
    ILoansNFT loansNFT_,
    ILoansExchange exchange_,
    IERC20 asset_,
    IVaultShareToken share_,
    INavCalculator calculator_,
    address initialGuardian,
    address initialRecoveryAddress,
    uint256 maxNavAge_,
    uint256 maxNavComputationTime_
  ) {
    require(initialGuardian != address(0), ZeroAddress());
    require(address(loans_) != address(0), ZeroAddress());
    require(address(loansNFT_) != address(0), ZeroAddress());
    require(address(exchange_) != address(0), ZeroAddress());
    require(address(asset_) != address(0), ZeroAddress());
    require(address(share_) != address(0), ZeroAddress());
    require(address(calculator_) != address(0), ZeroAddress());
    require(maxNavAge_ > 0, InvalidMaxNavAge());
    require(maxNavComputationTime_ > 0, InvalidMaxNavComputationTime());
    _validateLoansWiring(loans_, loansNFT_, asset_);

    loans = loans_;
    exchange = exchange_;
    assetToken = asset_;
    shareToken = share_;
    calculator = calculator_;
    loansNFT = loansNFT_;
    maxNavAge = maxNavAge_;
    maxNavComputationTime = maxNavComputationTime_;

    _initGuardian(initialGuardian);
    _initRecoveryAddress(initialRecoveryAddress);
    _setRoleAdmin(PORTFOLIO_MANAGER, GUARDIAN_ROLE);
    _setRoleAdmin(INVESTOR_MANAGER, GUARDIAN_ROLE);

    // Mint dead shares to prevent share price manipulation.
    // Reverts if DEAD_ADDRESS lacks SHAREHOLDER_ROLE on the share token.
    shareToken.mint(DEAD_ADDRESS, DEAD_SHARES);
  }

  // ──────────────────────── Modifiers ─────────────────────────────

  /**
   * @notice Ensures the caller is the account itself or an approved operator
   * @param account The account address to check against
   */
  modifier onlyAccountOrOperator(address account) {
    require(msg.sender == account || _isOperator[account][msg.sender], Unauthorized());
    _;
  }

  // ──────────────────────── External Functions ────────────────────

  /// @inheritdoc IPortfolioVault
  function updateNav(uint256 batchSize) external whenNotPaused {
    _requireManagerRole();
    require(batchSize > 0, ZeroAmount());

    ILoansNFT loansNFT_ = loansNFT;
    INavCalculator calculator_ = calculator;
    ILoans loans_ = loans;

    uint256 currentNonce = loansNFT_.ownershipNonce(address(this));
    uint256 currentConfigurationVersion = calculator_.configurationVersion();
    if (navStart == 0) {
      navStart = block.timestamp;
      lastOwnershipNonce = currentNonce;
      lastCalculatorConfigurationVersion = currentConfigurationVersion;
      emit NavComputationStarted(block.timestamp);
    } else if (
      currentNonce != lastOwnershipNonce ||
      currentConfigurationVersion != lastCalculatorConfigurationVersion ||
      block.timestamp - navStart > maxNavComputationTime
    ) {
      // Restart if the vault's NFT holdings changed mid-cycle, calculator
      // factors changed, or the previous computation took too long. The in-loop
      // ownership check below self-heals the list as it walks.
      navStart = block.timestamp;
      navCursor = 0;
      pendingNav = 0;
      lastOwnershipNonce = currentNonce;
      lastCalculatorConfigurationVersion = currentConfigurationVersion;
      emit NavComputationStarted(block.timestamp);
    }

    uint256 cursor = navCursor;
    uint64[] memory owned = new uint64[](batchSize);
    uint256 ownedCount;

    for (uint256 i; i < batchSize; ++i) {
      if (cursor >= _navLoanIds.length) break;
      uint64 loanId = _navLoanIds[cursor];
      // Treat a reverting `ownerOf` (e.g. burned token) the same as a foreign
      // owner so the list self-heals instead of bricking NAV computation.
      bool owns;
      try loansNFT_.ownerOf(uint256(loanId)) returns (address owner) {
        owns = owner == address(this);
      } catch {
        owns = false;
      }
      if (owns) {
        owned[ownedCount++] = loanId;
        unchecked {
          ++cursor;
        }
      } else {
        // Drop stale entry; swap-and-pop places a new entry at `cursor`, so do
        // not advance — the next iteration re-scans this slot.
        _removeLoanFromNav(loanId);
      }
    }

    if (ownedCount > 0) {
      // Trim the memory array to its used length before passing to the calculator.
      assembly {
        mstore(owned, ownedCount)
      }
      pendingNav += calculator_.getLoansValue(loans_, owned);
    }

    navCursor = cursor;

    // Finalize if we've processed all loans
    if (cursor >= _navLoanIds.length) {
      lastNav =
        assetToken.balanceOf(address(this)) +
        calculator_.applyPortfolioAdjustment(pendingNav) -
        totalPendingDepositAssets -
        totalClaimableRedeemAssets;
      lastNavUpdate = block.timestamp;
      navCursor = 0;
      pendingNav = 0;
      navStart = 0;
      emit NavUpdated(lastNav, block.timestamp);
    }
  }

  /// @inheritdoc IPortfolioVault
  function approveDeposit(
    address controller,
    uint256 assets
  ) external onlyRole(INVESTOR_MANAGER) whenNotPaused returns (uint256 shares) {
    _requireFreshNav();
    require(assets > 0, ZeroAmount());

    uint256 pending = pendingDepositAssets[controller];
    require(pending > 0, NoPendingDeposit());
    require(assets <= pending, ExceedsPending());

    uint256 totalSupply = shareToken.totalSupply();
    shares = (assets * totalSupply) / lastNav;
    // Prevents approving a tiny amount that rounds to 0 shares, which would strand assets
    require(shares > 0, ZeroAmount());

    pendingDepositAssets[controller] = pending - assets;
    totalPendingDepositAssets -= assets;
    claimableDepositShares[controller] += shares;
    claimableDepositAssets[controller] += assets;
    lastNav += assets;

    // Mint shares to vault so totalSupply stays correct for subsequent approvals
    shareToken.mint(address(this), shares);

    emit DepositApproved(controller, assets, shares);
  }

  /// @inheritdoc IPortfolioVault
  function approveRedemption(
    address controller,
    uint256 shares
  ) external onlyRole(INVESTOR_MANAGER) whenNotPaused returns (uint256 assets) {
    _requireFreshNav();
    require(shares > 0, ZeroAmount());

    uint256 pending = pendingRedeemShares[controller];
    require(pending > 0, NoPendingRedeem());
    require(shares <= pending, ExceedsPending());

    uint256 totalSupply = shareToken.totalSupply();
    assets = (shares * lastNav) / totalSupply;
    // Prevents approving a tiny amount that rounds to 0 assets, which would burn shares for nothing
    require(assets > 0, ZeroAmount());
    // Reserve must be backed by idle USDC; otherwise NAV finalization would underflow
    require(assets <= idleLiquidity(), InsufficientLiquidity());

    pendingRedeemShares[controller] = pending - shares;
    claimableRedeemShares[controller] += shares;
    claimableRedeemAssets[controller] += assets;
    totalClaimableRedeemAssets += assets;
    lastNav -= assets;

    // Burn shares so totalSupply stays correct for subsequent approvals
    shareToken.burn(address(this), shares);

    emit RedeemApproved(controller, shares, assets);
  }

  /// @inheritdoc IPortfolioVault
  function collectCashflows(
    uint64[] calldata loanIds,
    bytes32 ref
  ) external nonReentrant whenNotPaused returns (InvestorWithdrawalResult[] memory loanWithdrawals) {
    _requireManagerRole();
    _requireIdleNav();

    // Reject loans excluded from NAV; their cashflows would otherwise inflate NAV via idleLiquidity.
    uint256 length = loanIds.length;
    for (uint256 i; i < length; ++i) {
      require(_navLoanIndex[loanIds[i]] != 0, LoanNotInNav());
    }

    loanWithdrawals = loans.investorWithdraw(loanIds, uint48(block.timestamp), ref);

    // Mutates idleLiquidity and per-loan ledger state without bumping the ownership nonce.
    _invalidateNav();

    emit CashflowsCollected(loanWithdrawals);
  }

  /// @inheritdoc IPortfolioVault
  function fundLoan(
    uint64 loanId,
    int128 amount,
    uint48 timestamp,
    bytes32 ref
  ) external onlyRole(PORTFOLIO_MANAGER) nonReentrant whenNotPaused {
    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanId;
    int128[] memory amounts = new int128[](1);
    amounts[0] = amount;
    _fundLoans(loanIds, amounts, timestamp, ref);
  }

  /// @inheritdoc IPortfolioVault
  function fundLoans(
    uint64[] calldata loanIds,
    int128[] calldata amounts,
    uint48 timestamp,
    bytes32 ref
  ) external onlyRole(PORTFOLIO_MANAGER) nonReentrant whenNotPaused {
    require(loanIds.length > 0, ZeroAmount());
    require(amounts.length == loanIds.length, LengthMismatch());
    _fundLoans(loanIds, amounts, timestamp, ref);
  }

  /// @inheritdoc IPortfolioVault
  function addLoansToNav(uint64[] calldata loanIds) external onlyRole(PORTFOLIO_MANAGER) whenNotPaused {
    _requireIdleNav();
    bool changed;
    uint256 length = loanIds.length;
    for (uint256 i; i < length; ++i) {
      uint64 loanId = loanIds[i];
      require(loansNFT.ownerOf(uint256(loanId)) == address(this), LoanNotOwned());
      if (_navLoanIndex[loanId] == 0) {
        _addLoanToNav(loanId);
        changed = true;
      }
    }
    // Admitting new loans grows the valuation set without bumping the ownership
    // nonce; invalidate the cached NAV so approvals can't run against a
    // snapshot that excluded these loans.
    if (changed) _invalidateNav();
  }

  /// @inheritdoc IPortfolioVault
  function removeLoansFromNav(uint64[] calldata loanIds) external onlyRole(PORTFOLIO_MANAGER) whenNotPaused {
    _requireIdleNav();
    bool changed;
    uint256 length = loanIds.length;
    for (uint256 i; i < length; ++i) {
      uint64 loanId = loanIds[i];
      if (_navLoanIndex[loanId] != 0) {
        _removeLoanFromNav(loanId);
        changed = true;
      }
    }
    // Removing shrinks the valuation set without bumping the ownership nonce;
    // invalidate the cached NAV so approvals can't run against a snapshot
    // that still included these loans.
    if (changed) _invalidateNav();
  }

  /// @inheritdoc IPortfolioVault
  function setCalculator(address _calculator) external onlyRole(GUARDIAN_ROLE) {
    _requireIdleNav();
    require(_calculator != address(0), ZeroAddress());
    calculator = INavCalculator(_calculator);
    // Cached NAV was computed against the previous calculator; force a refresh
    // before any share-price-sensitive operation runs again.
    _invalidateNav();
    emit CalculatorUpdated(_calculator);
  }

  /// @inheritdoc IPortfolioVault
  function setLoans(address _loans, address _loansNFT) external onlyRole(GUARDIAN_ROLE) {
    _requireIdleNav();
    require(_loans != address(0), ZeroAddress());
    require(_loansNFT != address(0), ZeroAddress());
    _validateLoansWiring(ILoans(_loans), ILoansNFT(_loansNFT), assetToken);

    // Curated loanIds reference the OLD NFT collection's tokenIds; they have no
    // meaning under the new pair and must be cleared so the next NAV computation
    // doesn't price stale ids (and so re-admission of any colliding id is possible).
    _clearNavLoanIds();

    loans = ILoans(_loans);
    loansNFT = ILoansNFT(_loansNFT);
    _invalidateNav();
    emit LoansUpdated(_loans, _loansNFT);
  }

  /// @inheritdoc IPortfolioVault
  function setExchange(address _exchange) external onlyRole(GUARDIAN_ROLE) {
    _requireIdleNav();
    require(_exchange != address(0), ZeroAddress());
    require(ILoansExchange(_exchange).LOANS() == loans, InvalidExchange());
    require(ILoansExchange(_exchange).LOANS_NFT() == loansNFT, InvalidExchange());
    require(address(ILoansExchange(_exchange).CURRENCY()) == address(assetToken), InvalidExchange());
    exchange = ILoansExchange(_exchange);
    emit ExchangeUpdated(_exchange);
  }

  /// @inheritdoc IPortfolioVault
  function setMaxNavAge(uint256 _maxNavAge) external onlyAdminOrGuardian {
    require(_maxNavAge > 0, InvalidMaxNavAge());
    maxNavAge = _maxNavAge;
    emit MaxNavAgeUpdated(_maxNavAge);
  }

  /// @inheritdoc IPortfolioVault
  function setMaxNavComputationTime(uint256 _maxNavComputationTime) external onlyAdminOrGuardian {
    require(_maxNavComputationTime > 0, InvalidMaxNavComputationTime());
    maxNavComputationTime = _maxNavComputationTime;
    emit MaxNavComputationTimeUpdated(_maxNavComputationTime);
  }

  /// @inheritdoc IERC721Receiver
  function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
    require(msg.sender == address(loansNFT), OnlyLoansNFT());
    return IERC721Receiver.onERC721Received.selector;
  }

  // ──────────────── Portfolio Manager Functions ───────────────────

  /// @inheritdoc IPortfolioVault
  function acceptSaleOffer(uint64 offerId) external onlyRole(PORTFOLIO_MANAGER) nonReentrant whenNotPaused {
    _requireIdleNav();
    SaleOffer memory offer = exchange.getOffer(offerId);
    if (offer.price > 0) {
      require(uint256(offer.price) <= idleLiquidity(), InsufficientLiquidity());
      assetToken.forceApprove(address(exchange), uint256(offer.price));
    }
    exchange.acceptOffer(offerId);

    // Verify the exchange actually delivered each NFT before admitting it into NAV.
    uint256 length = offer.loanIds.length;
    for (uint256 i; i < length; ++i) {
      uint64 loanId = offer.loanIds[i];
      require(loansNFT.ownerOf(uint256(loanId)) == address(this), LoanNotOwned());
      _addLoanToNav(loanId);
    }
  }

  /// @inheritdoc IPortfolioVault
  function createSaleOffer(
    address buyer,
    uint128 price,
    uint48 deadline,
    uint64[] calldata loanIds
  ) external onlyRole(PORTFOLIO_MANAGER) nonReentrant whenNotPaused returns (uint64 offerId) {
    uint256 length = loanIds.length;
    for (uint256 i; i < length; ++i) {
      IERC721(address(loansNFT)).approve(address(exchange), uint256(loanIds[i]));
    }
    offerId = exchange.createOffer(buyer, price, deadline, loanIds);
  }

  /// @inheritdoc IPortfolioVault
  function cancelSaleOffer(uint64 offerId) external onlyRole(PORTFOLIO_MANAGER) nonReentrant whenNotPaused {
    exchange.cancelOffer(offerId);
  }

  /// @inheritdoc IPortfolioVault
  function transferLoans(
    uint64[] calldata loanIds,
    address recipient
  ) external onlyRole(PORTFOLIO_MANAGER) nonReentrant whenNotPaused {
    _requireIdleNav();
    uint256 length = loanIds.length;
    for (uint256 i; i < length; ++i) {
      uint64 loanId = loanIds[i];
      _removeLoanFromNav(loanId);
      IERC721(address(loansNFT)).transferFrom(address(this), recipient, uint256(loanId));
    }
  }

  /// @inheritdoc IPortfolioVault
  function registerAddress(address addr) external {
    _requireAddressBookManager();
    ILoansAuth(address(loans)).registerAddress(Roles.Investor, addr);
  }

  /// @inheritdoc IPortfolioVault
  function unregisterAddress(address addr) external {
    _requireAddressBookManager();
    ILoansAuth(address(loans)).unregisterAddress(Roles.Investor, addr);
  }

  // ──────────────── ERC-7540 Async Deposit ───────────────────────

  /// @inheritdoc IERC7540Deposit
  function requestDeposit(
    uint256 assets,
    address controller,
    address owner
  ) external nonReentrant whenNotPaused onlyAccountOrOperator(owner) returns (uint256 requestId) {
    require(controller != address(this), InvalidController());
    _requireInvestor(owner);
    _requireInvestor(controller);
    require(assets > 0, ZeroAmount());

    assetToken.safeTransferFrom(owner, address(this), assets);

    pendingDepositAssets[controller] += assets;
    totalPendingDepositAssets += assets;

    emit DepositRequest(controller, owner, 0, msg.sender, assets);
    return 0;
  }

  /**
   * @notice Claims an approved deposit by transferring pre-minted shares to the receiver (asset-denominated)
   * @param assets Amount of assets to claim (converted to shares at the locked price)
   * @param receiver Address to receive the shares
   * @param controller The controller of the deposit request
   * @return shares Number of shares transferred
   */
  function deposit(
    uint256 assets,
    address receiver,
    address controller
  ) external nonReentrant whenNotPaused onlyAccountOrOperator(controller) returns (uint256 shares) {
    _requireInvestor(controller);
    uint256 claimableAssets_ = claimableDepositAssets[controller];
    uint256 claimableShares_ = claimableDepositShares[controller];
    require(claimableAssets_ > 0 && claimableShares_ > 0, NoClaimableDeposit());
    require(assets > 0 && assets <= claimableAssets_, ExceedsClaimable());

    shares = (assets * claimableShares_) / claimableAssets_;
    _claimDeposit(controller, receiver, assets, shares, claimableAssets_, claimableShares_);
  }

  /**
   * @notice Claims an approved deposit by transferring exact pre-minted shares to the receiver
   * @param shares Number of shares to transfer
   * @param receiver Address to receive the shares
   * @param controller The controller of the deposit request
   * @return assets The asset equivalent of the claimed shares
   */
  function mint(
    uint256 shares,
    address receiver,
    address controller
  ) external nonReentrant whenNotPaused onlyAccountOrOperator(controller) returns (uint256 assets) {
    _requireInvestor(controller);
    uint256 claimableAssets_ = claimableDepositAssets[controller];
    uint256 claimableShares_ = claimableDepositShares[controller];
    require(claimableAssets_ > 0 && claimableShares_ > 0, NoClaimableDeposit());
    require(shares > 0 && shares <= claimableShares_, ExceedsClaimable());

    assets = (shares * claimableAssets_) / claimableShares_;
    _claimDeposit(controller, receiver, assets, shares, claimableAssets_, claimableShares_);
  }

  /// @inheritdoc IPortfolioVault
  function cancelDepositRequest(
    address controller,
    address receiver
  ) external nonReentrant whenNotPaused onlyAccountOrOperator(controller) returns (uint256 assets) {
    _requireInvestor(controller);
    _requireInvestor(receiver);
    require(receiver != address(this), InvalidReceiver());
    assets = pendingDepositAssets[controller];
    require(assets > 0, NoPendingDeposit());

    pendingDepositAssets[controller] = 0;
    totalPendingDepositAssets -= assets;

    assetToken.safeTransfer(receiver, assets);

    emit DepositRequestCancelled(controller, receiver, assets);
  }

  // ──────────────── ERC-7540 Operator Management ─────────────────

  /// @inheritdoc IERC7540Operator
  function setOperator(address operator, bool approved) external returns (bool) {
    _isOperator[msg.sender][operator] = approved;
    emit OperatorSet(msg.sender, operator, approved);
    return true;
  }

  // ──────────────── ERC-7540 Must-Revert Functions ───────────────

  /// @inheritdoc IERC7575
  function deposit(uint256, address) external pure returns (uint256) {
    revert MustRevert();
  }

  /// @inheritdoc IERC7575
  function mint(uint256, address) external pure returns (uint256) {
    revert MustRevert();
  }

  /// @inheritdoc IERC7575
  function previewDeposit(uint256) external pure returns (uint256) {
    revert MustRevert();
  }

  /// @inheritdoc IERC7575
  function previewMint(uint256) external pure returns (uint256) {
    revert MustRevert();
  }

  /// @inheritdoc IERC7575
  function previewWithdraw(uint256) external pure returns (uint256) {
    revert MustRevert();
  }

  /// @inheritdoc IERC7575
  function previewRedeem(uint256) external pure returns (uint256) {
    revert MustRevert();
  }

  // ──────────────── ERC-7540 Async Redeem ──────────────────────────

  /// @inheritdoc IERC7540Redeem
  function requestRedeem(
    uint256 shares,
    address controller,
    address owner
  ) external nonReentrant whenNotPaused onlyAccountOrOperator(owner) returns (uint256 requestId) {
    require(controller != address(this), InvalidController());
    _requireInvestor(controller);
    require(shares > 0, ZeroAmount());

    // Lock shares by transferring from owner to vault
    IERC20(address(shareToken)).safeTransferFrom(owner, address(this), shares);

    pendingRedeemShares[controller] += shares;

    emit RedeemRequest(controller, owner, 0, msg.sender, shares);
    return 0;
  }

  /**
   * @notice Claims an approved redemption by transferring assets (shares already burned at approval)
   * @param shares Number of shares to redeem from the claimable pool
   * @param receiver Address to receive the assets
   * @param controller The controller of the redeem request
   * @return assets The amount of assets transferred
   */
  function redeem(
    uint256 shares,
    address receiver,
    address controller
  ) external nonReentrant whenNotPaused onlyAccountOrOperator(controller) returns (uint256 assets) {
    _requireInvestor(controller);
    _requireInvestor(receiver);
    uint256 claimableShares_ = claimableRedeemShares[controller];
    uint256 claimableAssets_ = claimableRedeemAssets[controller];
    require(claimableShares_ > 0 && claimableAssets_ > 0, NoClaimableRedeem());
    require(shares > 0 && shares <= claimableShares_, ExceedsClaimable());

    assets = (shares * claimableAssets_) / claimableShares_;
    _claimRedeem(controller, receiver, assets, shares, claimableAssets_, claimableShares_);
  }

  /**
   * @notice Claims an approved redemption by transferring exact assets (shares already burned at approval)
   * @param assets Amount of assets to withdraw
   * @param receiver Address to receive the assets
   * @param controller The controller of the redeem request
   * @return shares The number of shares deducted from claimable pool
   */
  function withdraw(
    uint256 assets,
    address receiver,
    address controller
  ) external nonReentrant whenNotPaused onlyAccountOrOperator(controller) returns (uint256 shares) {
    _requireInvestor(controller);
    _requireInvestor(receiver);
    uint256 claimableShares_ = claimableRedeemShares[controller];
    uint256 claimableAssets_ = claimableRedeemAssets[controller];
    require(claimableShares_ > 0 && claimableAssets_ > 0, NoClaimableRedeem());
    require(assets > 0 && assets <= claimableAssets_, ExceedsClaimable());

    shares = (assets * claimableShares_) / claimableAssets_;
    _claimRedeem(controller, receiver, assets, shares, claimableAssets_, claimableShares_);
  }

  /// @inheritdoc IPortfolioVault
  function cancelRedeemRequest(
    address controller,
    address receiver
  ) external nonReentrant whenNotPaused onlyAccountOrOperator(controller) returns (uint256 shares) {
    _requireInvestor(controller);
    require(receiver != address(this), InvalidReceiver());
    shares = pendingRedeemShares[controller];
    require(shares > 0, NoPendingRedeem());

    pendingRedeemShares[controller] = 0;

    IERC20(address(shareToken)).safeTransfer(receiver, shares);

    emit RedeemRequestCancelled(controller, receiver, shares);
  }

  // ──────────────────────── View Functions ────────────────────────

  /// @inheritdoc IPortfolioVault
  function nav() external view returns (uint256) {
    return lastNav;
  }

  /// @inheritdoc IPortfolioVault
  function sharePrice() external view returns (uint256) {
    return (lastNav * WAD_UNIT) / shareToken.totalSupply();
  }

  /// @inheritdoc IERC7540Operator
  function isOperator(address controller, address operator) external view returns (bool) {
    return _isOperator[controller][operator];
  }

  /// @inheritdoc IERC7540Deposit
  function pendingDepositRequest(uint256, address controller) external view returns (uint256 pendingAssets) {
    pendingAssets = pendingDepositAssets[controller];
  }

  /// @inheritdoc IERC7540Deposit
  function claimableDepositRequest(uint256, address controller) external view returns (uint256 claimableAssets) {
    claimableAssets = maxDeposit(controller);
  }

  /// @inheritdoc IERC7540Redeem
  function pendingRedeemRequest(uint256, address controller) external view returns (uint256 pendingShares) {
    pendingShares = pendingRedeemShares[controller];
  }

  /// @inheritdoc IERC7540Redeem
  function claimableRedeemRequest(uint256, address controller) external view returns (uint256 claimableShares) {
    claimableShares = maxRedeem(controller);
  }

  // ──────────────── ERC-7575 View Functions ──────────────────────

  /// @inheritdoc IERC7575
  function asset() external view returns (address) {
    return address(assetToken);
  }

  /// @inheritdoc IERC7575
  function share() external view returns (address) {
    return address(shareToken);
  }

  /// @inheritdoc IERC7575
  /// @dev Prices off the last finalized NAV. Returns 0 only before the first NAV. While a NAV is
  ///      invalidated (`lastNavUpdate == 0`, pending a fresh `updateNav`) this still returns the last
  ///      value, so external integrators must not treat it as a live oracle.
  function convertToShares(uint256 assets) external view returns (uint256) {
    if (lastNav == 0) return 0;
    return (assets * shareToken.totalSupply()) / lastNav;
  }

  /// @inheritdoc IERC7575
  /// @dev Prices off the last finalized NAV. Returns 0 only before the first NAV. While a NAV is
  ///      invalidated (`lastNavUpdate == 0`, pending a fresh `updateNav`) this still returns the last
  ///      value, so external integrators must not treat it as a live oracle.
  function convertToAssets(uint256 shares) external view returns (uint256) {
    if (lastNav == 0) return 0;
    return (shares * lastNav) / shareToken.totalSupply();
  }

  /// @inheritdoc IERC7575
  function totalAssets() external view returns (uint256) {
    return lastNav;
  }

  /// @inheritdoc IERC7575
  function maxDeposit(address controller) public view returns (uint256) {
    if (paused()) return 0;
    return claimableDepositAssets[controller];
  }

  /// @inheritdoc IERC7575
  function maxMint(address controller) external view returns (uint256) {
    if (paused()) return 0;
    return claimableDepositShares[controller];
  }

  /// @inheritdoc IERC7575
  function maxWithdraw(address controller) external view returns (uint256) {
    if (paused()) return 0;
    return claimableRedeemAssets[controller];
  }

  /// @inheritdoc IERC7575
  function maxRedeem(address controller) public view returns (uint256) {
    if (paused()) return 0;
    return claimableRedeemShares[controller];
  }

  /**
   * @notice ERC-165 interface support advertising ERC-721 receiver, ERC-7540 and ERC-7575 interfaces.
   * @dev Hard-coded interface ids match the values from the respective draft EIPs; they cannot
   *      be derived from `type(I).interfaceId` for interfaces that inherit from each other.
   */
  function supportsInterface(bytes4 interfaceId) public view override(AccessControl, IERC165) returns (bool) {
    return
      interfaceId == 0xe3bc4e65 || // IERC7540Operator
      interfaceId == 0x2f0a18c5 || // IERC7575
      interfaceId == 0xce3bbe50 || // IERC7540Deposit
      interfaceId == 0x620ee8e4 || // IERC7540Redeem
      interfaceId == type(IERC721Receiver).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  /// @inheritdoc IPortfolioVault
  function navLoanCount() external view returns (uint256) {
    return _navLoanIds.length;
  }

  /// @inheritdoc IPortfolioVault
  function navLoanIdAt(uint256 index) external view returns (uint64) {
    return _navLoanIds[index];
  }

  /// @inheritdoc IPortfolioVault
  function isInNav(uint64 loanId) external view returns (bool) {
    return _navLoanIndex[loanId] != 0;
  }

  /**
   * @notice Returns funds available for portfolio operations after reserved investor assets.
   * @dev Reserved assets are the sum of `totalPendingDepositAssets` (assets in flight awaiting
   *      approval) and `totalClaimableRedeemAssets` (already-approved redemptions awaiting claim).
   */
  function idleLiquidity() public view returns (uint256) {
    uint256 balance = assetToken.balanceOf(address(this));
    uint256 reservedAssets = totalPendingDepositAssets + totalClaimableRedeemAssets;

    if (reservedAssets >= balance) return 0;
    return balance - reservedAssets;
  }

  // ──────────────────────── Internal Functions ────────────────────

  /**
   * @notice Shared logic for deposit and mint claim paths. Transfers pre-minted shares
   * from vault to receiver (shares were minted to vault at approval time).
   * @param controller The controller of the deposit request
   * @param receiver Address to receive the shares
   * @param assets The asset amount being claimed
   * @param shares The share amount being transferred
   * @param claimableAssets_ Cached claimable assets for the controller
   * @param claimableShares_ Cached claimable shares for the controller
   */
  function _claimDeposit(
    address controller,
    address receiver,
    uint256 assets,
    uint256 shares,
    uint256 claimableAssets_,
    uint256 claimableShares_
  ) private {
    require(receiver != address(this), InvalidReceiver());
    // Prevents rounding exploits: mint() could compute assets=0 (free shares),
    // deposit() could compute shares=0 (assets consumed for nothing)
    require(assets > 0 && shares > 0, ExceedsClaimable());

    claimableDepositAssets[controller] = claimableAssets_ - assets;
    claimableDepositShares[controller] = claimableShares_ - shares;

    IERC20(address(shareToken)).safeTransfer(receiver, shares);
    emit Deposit(controller, receiver, assets, shares);
  }

  /**
   * @notice Shared logic for redeem and withdraw claim paths. Transfers assets to receiver
   * (shares were already burned at approval time).
   * @param controller The controller of the redeem request
   * @param receiver Address to receive the assets
   * @param assets The asset amount being transferred
   * @param shares The share amount being claimed (already burned, used for bookkeeping)
   * @param claimableAssets_ Cached claimable assets for the controller
   * @param claimableShares_ Cached claimable shares for the controller
   */
  function _claimRedeem(
    address controller,
    address receiver,
    uint256 assets,
    uint256 shares,
    uint256 claimableAssets_,
    uint256 claimableShares_
  ) private {
    require(receiver != address(this), InvalidReceiver());
    // Prevents rounding exploits: withdraw() could compute shares=0 (free USDC),
    // redeem() could compute assets=0 (shares redeemed for nothing)
    require(assets > 0 && shares > 0, ExceedsClaimable());

    claimableRedeemShares[controller] = claimableShares_ - shares;
    claimableRedeemAssets[controller] = claimableAssets_ - assets;
    totalClaimableRedeemAssets -= assets;

    assetToken.safeTransfer(receiver, assets);

    emit Withdraw(msg.sender, receiver, controller, assets, shares);
  }

  /**
   * @dev Shared implementation for `fundLoan` and `fundLoans`.
   */
  function _fundLoans(uint64[] memory loanIds, int128[] memory amounts, uint48 timestamp, bytes32 ref) internal {
    _requireIdleNav();
    uint256 length = loanIds.length;

    uint256 totalAmount;
    for (uint256 i; i < length; ++i) {
      int128 amount = amounts[i];
      require(amount > 0, ILoans.InvalidAmount());
      totalAmount += uint256(int256(amount));
    }
    require(totalAmount <= idleLiquidity(), InsufficientLiquidity());

    assetToken.forceApprove(address(loans), totalAmount);
    for (uint256 i; i < length; ++i) {
      uint64 loanId = loanIds[i];
      int128 amount = amounts[i];
      uint128 entryIndex = loans.fund(loanId, amount, timestamp, ref);
      _addLoanToNav(loanId);
      emit LoanFunded(loanId, amount, entryIndex, ref);
    }

    // NAV-preserving only when portfolioFactor is 1e18; invalidate unconditionally since no ownership-nonce bump occurs.
    _invalidateNav();
  }

  /**
   * @dev Adds a loan to the NAV list if not already present. Idempotent. Caller is
   *      responsible for verifying ownership when the call site doesn't already
   *      guarantee it (the internal callers used here do).
   */
  function _addLoanToNav(uint64 loanId) internal {
    if (_navLoanIndex[loanId] != 0) return;
    _navLoanIds.push(loanId);
    _navLoanIndex[loanId] = _navLoanIds.length;
    emit LoanAddedToNav(loanId);
  }

  /**
   * @dev Removes a loan from the curated loan list using swap-and-pop. No-op if absent.
   */
  function _removeLoanFromNav(uint64 loanId) internal {
    uint256 idx = _navLoanIndex[loanId];
    if (idx == 0) return;
    uint256 lastIdx = _navLoanIds.length;
    if (idx != lastIdx) {
      uint64 lastId = _navLoanIds[lastIdx - 1];
      _navLoanIds[idx - 1] = lastId;
      _navLoanIndex[lastId] = idx;
    }
    _navLoanIds.pop();
    _navLoanIndex[loanId] = 0;
    emit LoanRemovedFromNav(loanId);
  }

  /**
   * @notice Empties the curated NAV list, clearing both the array and the index map.
   * @dev Pops from the end so each iteration is cheap (no swap); emits one `LoanRemovedFromNav` per id.
   */
  function _clearNavLoanIds() internal {
    for (uint256 i = _navLoanIds.length; i > 0; --i) {
      uint64 loanId = _navLoanIds[i - 1];
      _navLoanIndex[loanId] = 0;
      _navLoanIds.pop();
      emit LoanRemovedFromNav(loanId);
    }
  }

  /**
   * @dev Reverts if the NAV is stale, zero, or a computation is in progress.
   *      Used by share-price-sensitive operations (approveDeposit, approveRedemption, etc.).
   *      The nonce equality check ensures `lastNav` reflects the current set of
   *      vault-owned loan NFTs: any out-of-band transfer in or out (e.g. an
   *      external buyer settling an open sale offer, a rescue, a donation) bumps
   *      the nonce and forces the manager to run `updateNav` before approvals.
   */
  function _requireFreshNav() internal view {
    require(navStart == 0, NavComputationInProgress());
    require(lastNav > 0, ZeroNav());
    // Specific staleness signals come before the generic age check so callers
    // see the most informative error (e.g. `PortfolioHoldingsChanged` when an
    // NFT moved, even if `lastNavUpdate` was also explicitly cleared).
    require(loansNFT.ownershipNonce(address(this)) == lastOwnershipNonce, PortfolioHoldingsChanged());
    require(calculator.configurationVersion() == lastCalculatorConfigurationVersion, CalculatorConfigurationChanged());
    require(block.timestamp - lastNavUpdate <= maxNavAge, StaleNav());
  }

  /// @notice Reverts if a NAV computation is currently in progress.
  function _requireIdleNav() internal view {
    require(navStart == 0, NavComputationInProgress());
  }

  /**
   * @dev Reverts unless the Loans contract settles in `asset_` and the LoansNFT points back at it.
   */
  function _validateLoansWiring(ILoans loans_, ILoansNFT loansNFT_, IERC20 asset_) internal view {
    require(address(loans_.currency()) == address(asset_), AssetMismatch());
    require(loansNFT_.LOANS_CONTRACT() == address(loans_), ReversePointerMismatch());
  }

  /**
   * @dev Clears the cached NAV freshness stamp so the next share-price-sensitive
   *      operation must wait for a new `updateNav` cycle. Used by call sites that
   *      mutate NAV inputs (vault USDC balance, curated list, loan ledger state)
   *      without bumping `loansNFT.ownershipNonce`.
   */
  function _invalidateNav() internal {
    lastNavUpdate = 0;
    emit NavInvalidated();
  }

  /// @notice Reverts if caller holds neither PORTFOLIO_MANAGER nor INVESTOR_MANAGER
  function _requireManagerRole() internal view {
    if (!hasRole(PORTFOLIO_MANAGER, msg.sender) && !hasRole(INVESTOR_MANAGER, msg.sender)) {
      revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, PORTFOLIO_MANAGER);
    }
  }

  /// @notice Reverts unless caller holds PORTFOLIO_MANAGER, ADMIN_ROLE, or GUARDIAN_ROLE
  function _requireAddressBookManager() internal view {
    if (!hasRole(PORTFOLIO_MANAGER, msg.sender) && !_isAdminOrGuardian(msg.sender)) {
      revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, PORTFOLIO_MANAGER);
    }
  }

  /**
   * @dev Reverts if the account is not a verified investor. Uses `SHAREHOLDER_ROLE` on the share
   *      token as the investor verification mechanism: shareholders are automatically considered
   *      verified investors.
   */
  function _requireInvestor(address account) internal view {
    require(shareToken.hasRole(shareToken.SHAREHOLDER_ROLE(), account), NotShareholder());
  }
}
