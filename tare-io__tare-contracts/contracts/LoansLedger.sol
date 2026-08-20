// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LoansAuth} from "./misc/LoansAuth.sol";
import {Entry} from "contracts/interfaces/ILoans.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";
import {
  ACC_CASH,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_INVESTOR_INTEREST_PAID,
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_INVESTOR_PRINCIPAL_REPAID
} from "contracts/interfaces/Accounts.sol";

/**
 * @title LoansLedger
 * @notice Ledger storage and read helpers for the `Loans` contract.
 * @dev Holds per-loan account balances and entries, exposes them via the
 *      `ILoans` view functions, and provides internal primitives (`_deposit`,
 *      `_withdraw`, `_createInternalEntry`) used by the concrete `Loans`
 *      lifecycle functions to mutate the ledger.
 */
abstract contract LoansLedger is ILoans, LoansAuth {
  using SafeERC20 for IERC20;

  /// @inheritdoc ILoans
  uint64 public loanCount;

  /// @inheritdoc ILoans
  IERC20 public immutable currency;

  /// @inheritdoc ILoans
  mapping(uint72 key => int128 balance) public accountBalances;

  /// @inheritdoc ILoans
  mapping(uint128 entryIndex => Entry entry) public entries;

  /// @inheritdoc ILoans
  mapping(uint64 loanId => uint64 count) public entryCount;

  modifier loanExists(uint64 loanId) {
    _loanExists(loanId);
    _;
  }

  constructor(IERC20 _currency, address initialGuardian) LoansAuth(initialGuardian) {
    require(address(_currency) != address(0), ZeroAddress());
    currency = _currency;
  }

  /// @inheritdoc ILoans
  function getLoanAccountBalance(uint64 loanId, uint8 account) external view loanExists(loanId) returns (int128) {
    return _getAccountBalance(loanId, account);
  }

  /// @inheritdoc ILoans
  function getLoanAccountBalanceNormalized(
    uint64 loanId,
    uint8 account
  ) external view loanExists(loanId) returns (int128) {
    int128 balance = _getAccountBalance(loanId, account);
    return _isNormallyNegative(account) ? -balance : balance;
  }

  /// @inheritdoc ILoans
  function getLoanEntry(uint64 loanId, uint64 entryNumber) external view loanExists(loanId) returns (Entry memory) {
    uint64 count = entryCount[loanId];
    require(entryNumber > 0 && entryNumber <= count, InvalidAmount());

    uint128 entryIndex = (uint128(loanId) << 64) | uint128(entryNumber);
    return entries[entryIndex];
  }

  /// @inheritdoc ILoans
  function getLoanEntries(
    uint64 loanId,
    uint64 startIndex,
    uint64 endIndex
  ) external view loanExists(loanId) returns (Entry[] memory) {
    uint64 count = entryCount[loanId];
    require(startIndex > 0 && startIndex <= count, InvalidAmount());
    require(endIndex >= startIndex && endIndex <= count, InvalidAmount());

    uint64 rangeSize = endIndex - startIndex + 1;
    Entry[] memory loanEntries = new Entry[](rangeSize);
    uint128 loanIdShifted = uint128(loanId) << 64;

    for (uint64 i = startIndex; i <= endIndex; ++i) {
      uint128 entryIndex = loanIdShifted | uint128(i);
      loanEntries[i - startIndex] = entries[entryIndex];
    }

    return loanEntries;
  }

  /**
   * @dev Reverts with `DoesNotExist` if `loanId` has not yet been allocated by `_create`.
   *      Loan ids are dense and start at `1`; `loanCount` is the highest allocated id.
   */
  function _loanExists(uint64 loanId) internal view {
    require(loanId != 0 && loanId <= loanCount, DoesNotExist());
  }

  /**
   * @dev Returns the signed balance of `account` on `loanId` using the packed
   *      `(loanId, account)` key.
   */
  function _getAccountBalance(uint64 loanId, uint8 account) internal view returns (int128) {
    uint72 key = _getBalanceKey(loanId, account);
    return accountBalances[key];
  }

  /**
   * @dev Returns the net amount still owed on a (payable, paid) account pair.
   *      `payableAccount` is a liability or contra-asset (normally negative) tracking
   *      the total obligation; `paidAccount` is a contra-liability (normally positive)
   *      tracking what has already been paid. The returned value is positive when there
   *      is something left to pay out.
   */
  function _getNetPayable(uint64 loanId, uint8 payableAccount, uint8 paidAccount) internal view returns (int128) {
    return -_getAccountBalance(loanId, payableAccount) - _getAccountBalance(loanId, paidAccount);
  }

  /**
   * @dev Convenience accessor for the net interest still owed to the loan's investor.
   */
  function _getNetInterestPayableToInvestor(uint64 loanId) internal view returns (int128) {
    return _getNetPayable(loanId, ACC_INVESTOR_INTEREST_PAYABLE, ACC_INVESTOR_INTEREST_PAID);
  }

  /**
   * @dev Convenience accessor for the net principal currently payable to the loan's
   *      investor: principal already repaid by the borrower, minus principal already
   *      paid out to the investor. This is bounded by borrower repayments and is not
   *      the investor's full remaining principal claim.
   */
  function _getNetPrincipalPayableToInvestor(uint64 loanId) internal view returns (int128) {
    return _getNetPayable(loanId, ACC_BORROWER_PRINCIPAL_REPAID, ACC_INVESTOR_PRINCIPAL_REPAID);
  }

  /**
   * @dev Writes a Cash -> `toAccount` ledger entry for `amount` if positive and returns
   *      the same `amount`, allowing the caller to accumulate a single ERC20 transfer
   *      total across multiple loans. No entry is written when `amount` is zero.
   */
  function _withdrawToAccount(
    uint64 loanId,
    uint8 toAccount,
    int128 amount,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  ) internal returns (int128) {
    if (amount > 0) {
      _createInternalEntry(loanId, ACC_CASH, toAccount, amount, timestamp, entryType, ref);
      return amount;
    }
    return 0;
  }

  /**
   * @dev Bumps the per-loan entry counter and returns the packed
   *      `(loanId << 64) | entryNumber` identifier for the new entry.
   */
  function _createNextEntryIndex(uint64 loanId) internal returns (uint128) {
    uint64 entryNumber = ++entryCount[loanId];
    return (uint128(loanId) << 64) | uint128(entryNumber);
  }

  /**
   * @dev Applies a transfer of `amount` from `from` to `to`. Subtracts from `from`
   *      and adds to `to`. Reverts with `InsufficientCashBalance` when `from` is the
   *      `CASH` account and the loan does not hold enough cash. Returns the updated
   *      balances so callers can include them in the emitted `EntryCreated` event.
   */
  function _updateBalances(
    uint64 loanId,
    uint8 from,
    uint8 to,
    int128 amount
  ) internal returns (int128 updatedFromBalance, int128 updatedToBalance) {
    uint72 fromKey = _getBalanceKey(loanId, from);
    uint72 toKey = _getBalanceKey(loanId, to);

    int128 fromBalance = accountBalances[fromKey];
    if (from == ACC_CASH) {
      require(fromBalance >= amount, InsufficientCashBalance());
    }

    updatedFromBalance = fromBalance - amount;
    updatedToBalance = accountBalances[toKey] + amount;

    accountBalances[fromKey] = updatedFromBalance;
    accountBalances[toKey] = updatedToBalance;
  }

  /**
   * @dev Records a ledger entry transferring `amount` from the ledger accounts `from` to `to` on `loanId`,
   *      updates the corresponding balances, and emits `EntryCreated`. Reverts when
   *      `from == to` or `amount <= 0`.
   */
  function _createInternalEntry(
    uint64 loanId,
    uint8 from,
    uint8 to,
    int128 amount,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  ) internal returns (uint128 entryIndex) {
    require(from != to, InvalidAccount());
    require(amount > 0, InvalidAmount());

    entryIndex = _createNextEntryIndex(loanId);

    entries[entryIndex] = Entry({
      amount: amount,
      timestamp: timestamp,
      from: from,
      to: to,
      entryType: entryType,
      ref: ref
    });

    (int128 updatedFromBalance, int128 updatedToBalance) = _updateBalances(loanId, from, to, amount);

    emit EntryCreated(entryIndex, from, to, amount, updatedFromBalance, updatedToBalance, entryType, ref);
  }

  /**
   * @dev Pulls `amount` of `currency` from `addr` into the contract and records a
   *      `fromAccount` -> CASH ledger entry. `fromAccount` cannot be CASH (that
   *      would double-count the inflow). Requires `addr` to have approved the
   *      contract for at least `amount`.
   */
  function _deposit(
    uint64 loanId,
    uint8 fromAccount,
    int128 amount,
    address addr,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  ) internal returns (uint128 entryIndex) {
    require(amount > 0, InvalidAmount());
    require(fromAccount != ACC_CASH, InvalidAccount());
    require(addr != address(0), ZeroAddress());

    currency.safeTransferFrom(addr, address(this), uint256(int256(amount)));

    entryIndex = _createInternalEntry(loanId, fromAccount, ACC_CASH, amount, timestamp, entryType, ref);
  }

  /**
   * @dev Records a CASH -> `toAccount` ledger entry and transfers `amount` of
   *      `currency` from the contract to `withdrawalAddress`. `toAccount` cannot
   *      be CASH (the cash outflow is already represented by the entry's `from`
   *      account).
   */
  function _withdraw(
    uint64 loanId,
    uint8 toAccount,
    int128 amount,
    address withdrawalAddress,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  ) internal returns (uint128 entryIndex) {
    require(amount > 0, InvalidAmount());
    require(toAccount != ACC_CASH, InvalidAccount());
    require(withdrawalAddress != address(0), ZeroAddress());

    entryIndex = _createInternalEntry(loanId, ACC_CASH, toAccount, amount, timestamp, entryType, ref);

    currency.safeTransfer(withdrawalAddress, uint256(int256(amount)));
  }

  /**
   * @dev Packs `(loanId, account)` into the storage key used by `accountBalances`.
   *      Format: `loanId << 8 | account`.
   */
  function _getBalanceKey(uint64 loanId, uint8 account) internal pure returns (uint72) {
    return (uint72(loanId) << 8) | uint72(account);
  }

  /**
   * @dev True for accounts whose natural sign is negative (liability / revenue / equity).
   *      By convention, account ids `>= 200` are normally-negative; ids below 200 are
   *      normally-positive (assets / expenses).
   */
  function _isNormallyNegative(uint8 account) internal pure returns (bool) {
    return account >= 200;
  }
}
