// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeployLoansLibrary, Loans, IERC20} from "./lib/DeployLoansLibrary.sol";
import {DeploySmartAccountsLibrary} from "./lib/DeploySmartAccountsLibrary.sol";
import {DeployVaultLibrary} from "./lib/DeployVaultLibrary.sol";
import {ILoans} from "../contracts/interfaces/ILoans.sol";
import {ILoansNFT} from "../contracts/interfaces/ILoansNFT.sol";
import {ILoansExchange} from "../contracts/interfaces/ILoansExchange.sol";
import {MockUSDC} from "../test/mocks/USDC.sol";
import {DeploySafeSingleton} from "../test/helpers/DeploySafeSingleton.sol";
import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";
import {MultiSendCallOnly} from "safe-smart-account/libraries/MultiSendCallOnly.sol";
import {ISafe} from "../contracts/misc/interfaces/ISafe.sol";

/**
 * @title Local deployment script for all contracts
 * @notice Deploys Loans, SmartAccounts, Safe infrastructure, and a sample originator on a local chain
 *
 * Required environment variables:
 *   DEPLOY_ADMIN          — Admin address (must be non-zero and distinct from deployer)
 *   DEPLOY_GUARDIAN       — Guardian address (must be non-zero and distinct from deployer)
 *   DEPLOY_LOANS_BASE_URI — Base URI for loan NFT metadata
 *
 * Optional environment variables:
 *   DEPLOYMENT_NAME       — Deployment name (default: "dev")
 *   SIMULATE_ONLY         — Run in simulation mode (default: false)
 *   DEPLOYER_ADDR         — Deployer address (required when SIMULATE_ONLY=true)
 *   DEPLOY_HOT_SAFE_OWNER — HotSafe owner EOA (default: DEPLOY_ADMIN)
 */
contract DeployLocal is DeployLoansLibrary, DeploySmartAccountsLibrary, DeployVaultLibrary {
  // ---------------------------------------------------------------------------
  // Deployment parameters
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

  function setUp() public withCreateX {
    simulateOnly = vm.envOr("SIMULATE_ONLY", false);

    string memory _deploymentName = vm.envOr("DEPLOYMENT_NAME", string("dev"));
    initializeBase("loans", _deploymentName);
  }

  function run() public withCreateX {
    if (simulateOnly) {
      deployer = vm.envAddress("DEPLOYER_ADDR");
      vm.startPrank(deployer);
    } else {
      vm.startBroadcast();
    }

    MockUSDC mockUsdc = MockUSDC(
      create3(keccak256("tareio-MockUSDC-1"), abi.encodePacked(type(MockUSDC).creationCode))
    );
    mockUsdc.mint(deployer, 1_000_000e6);

    address _admin = vm.envAddress("DEPLOY_ADMIN");
    address _guardian = vm.envAddress("DEPLOY_GUARDIAN");

    // Fixed salts (version-independent) shared with DeploySafeInfra, which may
    // have landed these already so governance Safes could deploy pre-protocol.
    address _safeSingleton = create3IfAbsent(
      keccak256("tareio-SafeSingleton-1"),
      DeploySafeSingleton.SAFE_CREATION_CODE
    );
    address _safeProxyFactory = create3IfAbsent(
      keccak256("tareio-SafeProxyFactory-1"),
      abi.encodePacked(type(SafeProxyFactory).creationCode)
    );
    address _multisend = create3IfAbsent(
      keccak256("tareio-MultiSendCallOnly-1"),
      abi.encodePacked(type(MultiSendCallOnly).creationCode)
    );

    Loans _loans = deployLoansContracts(IERC20(address(mockUsdc)), vm.envString("DEPLOY_LOANS_BASE_URI"), _guardian);

    deployLoansExchangeContract(address(loansNFT), address(_loans), _guardian);

    // Deploy vault before accounts so accounts can whitelist vault selectors
    uint256[8] memory factors = _discountFactors();
    string memory shareTokenName = string.concat(
      "Tare Vault Shares (",
      vm.envOr("DEPLOYMENT_NAME", string("dev")),
      ")"
    );
    VaultParams memory vaultParams = VaultParams({
      loans: ILoans(address(_loans)),
      loansNFT: ILoansNFT(address(loansNFT)),
      exchange: ILoansExchange(address(loansExchange)),
      usdc: IERC20(address(mockUsdc)),
      admin: _admin,
      guardian: _guardian,
      recoveryAddress: _guardian,
      portfolioManager: _admin,
      investorManager: _admin,
      calculatingAgent: _admin,
      whitelister: _admin,
      maxNavAge: DEFAULT_MAX_NAV_AGE,
      maxNavComputationTime: DEFAULT_MAX_NAV_COMPUTATION_TIME,
      discountFactors: factors,
      shareTokenName: shareTokenName,
      shareTokenSymbol: "tVAULT"
    });
    deployVaultContracts(vaultParams);

    AccountsParams memory accountsParams = AccountsParams({
      safeSingleton: _safeSingleton,
      safeProxyFactory: _safeProxyFactory,
      multisend: _multisend,
      admin: _admin,
      guardian: _guardian,
      recoveryAddress: _guardian,
      loansContract: address(_loans),
      loansExchange: address(loansExchange),
      portfolioVault: address(portfolioVault)
    });
    AccountsResult memory accounts = deployAccounts(accountsParams);

    // The HotSafe's owner is the hot-proxy signing EOA, not the protocol admin —
    // when DEPLOY_ADMIN is a Safe, the LMS hot-proxy worker must still be able to
    // sign HotSafe transactions with its configured key.
    address _hotSafeOwner = vm.envOr("DEPLOY_HOT_SAFE_OWNER", _admin);
    address[] memory owners = new address[](1);
    owners[0] = _hotSafeOwner;
    bytes memory initializer = abi.encodeWithSelector(
      ISafe.setup.selector,
      owners,
      1,
      address(0),
      "",
      address(0),
      address(0),
      0,
      address(0)
    );
    address hotSafe = address(
      SafeProxyFactory(_safeProxyFactory).createProxyWithNonce(
        _safeSingleton,
        initializer,
        uint256(keccak256("HotSafe-1"))
      )
    );

    setLoansPermissions(_admin, _guardian);
    setLoansExchangePermissions(_admin, _guardian);
    // setVaultOperators must run before setVaultPermissions, which renounces the deployer's
    // GUARDIAN_ROLE on vault contracts (operator role-admin).
    setVaultOperators(vaultParams);
    setVaultPermissions(_admin, _guardian);

    if (simulateOnly) {
      vm.stopPrank();
    } else {
      vm.stopBroadcast();
    }

    addDeployedContract("HotSafe", hotSafe);
    writeLoansDeployment(address(_loans), address(mockUsdc));

    startNewComponent("accounts");
    writeAccountsDeployment(accountsParams, accounts);

    startNewComponent("vault");
    writeVaultDeployment();
  }
}
