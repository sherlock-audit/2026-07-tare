// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeployVaultLibrary} from "./lib/DeployVaultLibrary.sol";
import {PortfolioVault} from "../contracts/PortfolioVault.sol";
import {ILoans} from "../contracts/interfaces/ILoans.sol";
import {ILoansNFT} from "../contracts/interfaces/ILoansNFT.sol";
import {ILoansExchange} from "../contracts/interfaces/ILoansExchange.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Deployer for Vault contracts (NavCalculator, VaultShareToken, PortfolioVault)
 * @notice Script to deploy the vault infrastructure on top of existing Loans contracts
 *
 * Required environment variables:
 *   DEPLOY_ADMIN                   — ADMIN_ROLE grantee (must be non-zero and distinct from deployer)
 *   DEPLOY_GUARDIAN                — Guardian / timelock address (must be non-zero and distinct from deployer)
 *
 * Optional environment variables:
 *   DEPLOYMENT_NAME                — Deployment name (default: "dev")
 *   DEPLOY_RECOVERY_ADDRESS        — Rescue recipient baked into PortfolioVault and VaultShareToken (default: DEPLOY_GUARDIAN)
 *   DEPLOY_PORTFOLIO_MANAGER       — PORTFOLIO_MANAGER grantee on PortfolioVault (default: none)
 *   DEPLOY_INVESTOR_MANAGER        — INVESTOR_MANAGER grantee on PortfolioVault (default: none)
 *   DEPLOY_CALCULATING_AGENT       — CALCULATING_AGENT grantee on NavCalculator (default: none)
 *   DEPLOY_WHITELISTER             — WHITELISTER_ROLE grantee on VaultShareToken (default: none)
 *   DEPLOY_MAX_NAV_AGE             — Max NAV age in seconds (default: 14400 = 4 hours)
 *   DEPLOY_MAX_NAV_COMPUTATION_TIME — Max NAV computation time in seconds (default: 1800 = 30 min)
 *   DEPLOY_SHARE_TOKEN_NAME        — Share token name (default: "Tare Vault Shares ({deploymentName})")
 *   DEPLOY_SHARE_TOKEN_SYMBOL      — Share token symbol (default: "tVAULT")
 *
 * Reads from:
 *   deployments/{chain}/{name}/loans/latest.json — Loans, LoansNFT, LoansExchange, USDC addresses
 */
contract DeployVault is DeployVaultLibrary {
  // ---------------------------------------------------------------------------
  // Deployment parameters — REVIEW BEFORE EVERY DEPLOY
  // ---------------------------------------------------------------------------
  // NavCalculator discount factors (1e18 == 100%).
  function _discountFactors() internal pure returns (uint256[8] memory factors) {
    factors[0] = 1e18; // Current
    factors[1] = 1e18; // DQ30
    factors[2] = 1e18; // DQ60
    factors[3] = 1e18; // DQ90
    factors[4] = 1e18; // DQ120
    factors[5] = 1e18; // ChargedOff
    factors[6] = 0; // Closed
    factors[7] = 0; // Cancelled
  }

  uint256 internal constant DEFAULT_MAX_NAV_AGE = 14_400; // 4 hours
  uint256 internal constant DEFAULT_MAX_NAV_COMPUTATION_TIME = 1800; // 30 minutes
  // ---------------------------------------------------------------------------

  constructor() {}

  function setUp() public virtual withCreateX {
    string memory _deploymentName = vm.envOr("DEPLOYMENT_NAME", string("dev"));
    initializeBase("vault", _deploymentName);
  }

  function run() public withCreateX {
    // Read Loans deployment JSON for contract addresses
    string memory loansDeploymentPath = string(
      abi.encodePacked("deployments/", chainName, "/", deploymentName, "/loans/latest.json")
    );
    string memory loansJson = vm.readFile(loansDeploymentPath);
    address _loans = vm.parseJsonAddress(loansJson, ".contracts.Loans");
    address _loansNFT = vm.parseJsonAddress(loansJson, ".contracts.LoansNFT");
    address _loansExchange = vm.parseJsonAddress(loansJson, ".contracts.LoansExchange");
    address _usdc = vm.parseJsonAddress(loansJson, ".contracts.USDC");

    address _admin = vm.envAddress("DEPLOY_ADMIN");
    address _guardian = vm.envAddress("DEPLOY_GUARDIAN");
    address _recoveryAddress = vm.envOr("DEPLOY_RECOVERY_ADDRESS", _guardian);

    string memory defaultName = string.concat("Tare Vault Shares (", deploymentName, ")");

    VaultParams memory p = VaultParams({
      loans: ILoans(_loans),
      loansNFT: ILoansNFT(_loansNFT),
      exchange: ILoansExchange(_loansExchange),
      usdc: IERC20(_usdc),
      admin: _admin,
      guardian: _guardian,
      recoveryAddress: _recoveryAddress,
      portfolioManager: vm.envOr("DEPLOY_PORTFOLIO_MANAGER", address(0)),
      investorManager: vm.envOr("DEPLOY_INVESTOR_MANAGER", address(0)),
      calculatingAgent: vm.envOr("DEPLOY_CALCULATING_AGENT", address(0)),
      whitelister: vm.envOr("DEPLOY_WHITELISTER", address(0)),
      maxNavAge: vm.envOr("DEPLOY_MAX_NAV_AGE", DEFAULT_MAX_NAV_AGE),
      maxNavComputationTime: vm.envOr("DEPLOY_MAX_NAV_COMPUTATION_TIME", DEFAULT_MAX_NAV_COMPUTATION_TIME),
      discountFactors: _discountFactors(),
      shareTokenName: vm.envOr("DEPLOY_SHARE_TOKEN_NAME", defaultName),
      shareTokenSymbol: vm.envOr("DEPLOY_SHARE_TOKEN_SYMBOL", string("tVAULT"))
    });

    vm.startBroadcast();
    deployVault(p);
    vm.stopBroadcast();

    writeVaultDeployment();
  }
}
