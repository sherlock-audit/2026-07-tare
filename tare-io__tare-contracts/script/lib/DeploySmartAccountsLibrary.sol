// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeploymentBase} from "./DeploymentBase.sol";
import {SmartAccountFactory} from "../../contracts/SmartAccountFactory.sol";
import {TrustedCalls} from "../../contracts/TrustedCalls.sol";
import {TrustedSpender} from "../../contracts/TrustedSpender.sol";
import {ILoans} from "../../contracts/interfaces/ILoans.sol";
import {ILoansExchange} from "../../contracts/interfaces/ILoansExchange.sol";
import {IPortfolioVault} from "../../contracts/interfaces/IPortfolioVault.sol";
import {IERC7540Deposit, IERC7540Redeem} from "../../contracts/misc/interfaces/IERC7540.sol";
import {IERC7575} from "../../contracts/misc/interfaces/IERC7575.sol";

abstract contract DeploySmartAccountsLibrary is DeploymentBase {
  address public safeSingleton;
  address public safeProxyFactory;
  address public accountsAdmin;
  address public accountsGuardian;
  address public accountsRecoveryAddress;
  ILoans public loansContract;
  address public loansExchangeContract;
  address public portfolioVaultContract;
  address public smartAccountFactory;
  address public trustedCalls;
  address public trustedSpender;

  struct AccountsParams {
    address safeSingleton;
    address safeProxyFactory;
    address multisend;
    address admin;
    address guardian;
    address recoveryAddress;
    address loansContract;
    address loansExchange;
    address portfolioVault;
  }

  struct AccountsResult {
    address smartAccountFactory;
    address trustedCalls;
    address trustedSpender;
  }

  function deployAccounts(AccountsParams memory p) internal returns (AccountsResult memory r) {
    safeSingleton = p.safeSingleton;
    safeProxyFactory = p.safeProxyFactory;
    accountsAdmin = p.admin;
    accountsGuardian = p.guardian;
    accountsRecoveryAddress = p.recoveryAddress;
    loansContract = ILoans(p.loansContract);
    loansExchangeContract = p.loansExchange;
    portfolioVaultContract = p.portfolioVault;
    deployAccountsImpl();
    r.smartAccountFactory = smartAccountFactory;
    r.trustedCalls = trustedCalls;
    r.trustedSpender = trustedSpender;
    return r;
  }

  function deployAccountsImpl() public {
    // Deployer is the initial guardian — guardian passes onlyAdmin via >=
    trustedCalls = create3(
      generateSalt("TrustedCalls"),
      abi.encodePacked(type(TrustedCalls).creationCode, abi.encode(deployer, accountsRecoveryAddress))
    );

    trustedSpender = create3(
      generateSalt("TrustedSpender"),
      abi.encodePacked(type(TrustedSpender).creationCode, abi.encode(deployer, accountsRecoveryAddress))
    );

    smartAccountFactory = create3(
      generateSalt("SmartAccountFactory"),
      abi.encodePacked(
        type(SmartAccountFactory).creationCode,
        abi.encode(safeProxyFactory, safeSingleton, trustedCalls, trustedSpender)
      )
    );

    whitelistInitialTrustedCalls();

    setSmartAccountsPermissions(accountsAdmin, accountsGuardian);
  }

  /**
   * @notice Whitelist the initial set of Loans, LoansExchange, and PortfolioVault entry points on TrustedCalls.
   * @dev Requires `portfolioVaultContract` to be set — the entry script enforces this invariant.
   */
  function whitelistInitialTrustedCalls() internal {
    require(portfolioVaultContract != address(0), "whitelistInitialTrustedCalls: portfolioVault required");

    uint256 count = 30;
    address[] memory targets = new address[](count);
    bytes4[] memory selectors = new bytes4[](count);

    address loansContractAddress = address(loansContract);

    // Loans functions (14)
    targets[0] = loansContractAddress;
    selectors[0] = ILoans.create.selector;

    targets[1] = loansContractAddress;
    selectors[1] = ILoans.accrue.selector;

    targets[2] = loansContractAddress;
    selectors[2] = ILoans.fund.selector;

    targets[3] = loansContractAddress;
    selectors[3] = ILoans.disburse.selector;

    targets[4] = loansContractAddress;
    selectors[4] = ILoans.pay.selector;

    targets[5] = loansContractAddress;
    selectors[5] = ILoans.applyWaterfall.selector;

    targets[6] = loansContractAddress;
    selectors[6] = ILoans.servicerWithdraw.selector;

    targets[7] = loansContractAddress;
    selectors[7] = ILoans.investorWithdraw.selector;

    targets[8] = loansContractAddress;
    selectors[8] = ILoans.originatorWithdraw.selector;

    targets[9] = loansContractAddress;
    selectors[9] = ILoans.updateLoanData.selector;

    targets[10] = loansContractAddress;
    selectors[10] = ILoans.chargeMiscFee.selector;

    targets[11] = loansContractAddress;
    selectors[11] = ILoans.createLedgerEntries.selector;

    targets[12] = loansContractAddress;
    selectors[12] = ILoans.refundBorrower.selector;

    targets[13] = loansContractAddress;
    selectors[13] = ILoans.returnFunds.selector;

    // LoansExchange functions (3)
    targets[14] = loansExchangeContract;
    selectors[14] = ILoansExchange.createOffer.selector;
    targets[15] = loansExchangeContract;
    selectors[15] = ILoansExchange.acceptOffer.selector;
    targets[16] = loansExchangeContract;
    selectors[16] = ILoansExchange.cancelOffer.selector;

    // PortfolioVault functions (13)
    targets[17] = portfolioVaultContract;
    selectors[17] = IPortfolioVault.updateNav.selector;
    targets[18] = portfolioVaultContract;
    selectors[18] = IPortfolioVault.collectCashflows.selector;
    targets[19] = portfolioVaultContract;
    selectors[19] = IPortfolioVault.acceptSaleOffer.selector;
    targets[20] = portfolioVaultContract;
    selectors[20] = IPortfolioVault.createSaleOffer.selector;
    targets[21] = portfolioVaultContract;
    selectors[21] = IPortfolioVault.cancelSaleOffer.selector;

    // ERC-7540 async deposit/redeem. Safe to whitelist because every payout destination must hold
    // SHAREHOLDER_ROLE (asset paths check _requireInvestor(receiver); share paths are gated by the
    // share token's transfer hook), and that role is administered by WHITELISTER_ROLE, not a delegate.
    targets[22] = portfolioVaultContract;
    selectors[22] = IERC7540Deposit.requestDeposit.selector;
    targets[23] = portfolioVaultContract;
    selectors[23] = IERC7540Deposit.deposit.selector;
    targets[24] = portfolioVaultContract;
    selectors[24] = IPortfolioVault.approveDeposit.selector;
    targets[25] = portfolioVaultContract;
    selectors[25] = IPortfolioVault.cancelDepositRequest.selector;
    targets[26] = portfolioVaultContract;
    selectors[26] = IERC7540Redeem.requestRedeem.selector;
    targets[27] = portfolioVaultContract;
    selectors[27] = IERC7575.redeem.selector;
    targets[28] = portfolioVaultContract;
    selectors[28] = IPortfolioVault.approveRedemption.selector;
    targets[29] = portfolioVaultContract;
    selectors[29] = IPortfolioVault.cancelRedeemRequest.selector;

    TrustedCalls(trustedCalls).addTrustedCalls(targets, selectors);
  }

  /**
   * @notice Set up the two-tier permission model on TrustedCalls and TrustedSpender.
   * @dev Grants ADMIN_ROLE and GUARDIAN_ROLE on both contracts, then revokes the
   *      deployer's GUARDIAN_ROLE. Both `admin` and `guardian` are required, must be
   *      non-zero, and must differ from the deployer.
   */
  function setSmartAccountsPermissions(address admin, address guardian) internal {
    require(admin != address(0) && admin != deployer, "setSmartAccountsPermissions: invalid admin");
    require(guardian != address(0) && guardian != deployer, "setSmartAccountsPermissions: invalid guardian");

    TrustedCalls trustedCallsRef = TrustedCalls(trustedCalls);
    TrustedSpender trustedSpenderRef = TrustedSpender(trustedSpender);
    bytes32 ADMIN_ROLE = trustedCallsRef.ADMIN_ROLE();
    bytes32 GUARDIAN_ROLE = trustedCallsRef.GUARDIAN_ROLE();

    trustedSpenderRef.grantRole(ADMIN_ROLE, admin);
    trustedCallsRef.grantRole(ADMIN_ROLE, admin);

    trustedSpenderRef.grantRole(GUARDIAN_ROLE, guardian);
    trustedCallsRef.grantRole(GUARDIAN_ROLE, guardian);

    trustedSpenderRef.revokeRole(GUARDIAN_ROLE, deployer);
    trustedCallsRef.revokeRole(GUARDIAN_ROLE, deployer);
  }

  function writeAccountsDeployment(AccountsParams memory p, AccountsResult memory r) internal {
    addDeployedContract("SafeSingleton", p.safeSingleton);
    addDeployedContract("SafeProxyFactory", p.safeProxyFactory);
    addDeployedContract("MultiSendCallOnly", p.multisend);
    addDeployedContract("SmartAccountFactory", r.smartAccountFactory);
    addDeployedContract("TrustedSpender", r.trustedSpender);
    addDeployedContract("TrustedCalls", r.trustedCalls);
    writeDeploymentInfo(buildDeploymentJson());
  }
}
