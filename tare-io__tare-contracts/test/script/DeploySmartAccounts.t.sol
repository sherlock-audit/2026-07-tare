// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployerTestBase} from "./DeployerTestBase.t.sol";
import {DeploySmartAccounts} from "../../script/DeploySmartAccounts.s.sol";
import {SmartAccountFactory} from "../../contracts/SmartAccountFactory.sol";
import {TrustedCalls} from "../../contracts/TrustedCalls.sol";
import {TrustedSpender} from "../../contracts/TrustedSpender.sol";
import {ILoans} from "../../contracts/interfaces/ILoans.sol";
import {IPortfolioVault} from "../../contracts/interfaces/IPortfolioVault.sol";
import {IERC7540Deposit, IERC7540Redeem} from "../../contracts/misc/interfaces/IERC7540.sol";
import {IERC7575} from "../../contracts/misc/interfaces/IERC7575.sol";
import {Loans} from "../../contracts/Loans.sol";
import {LoansNFT} from "../../contracts/LoansNFT.sol";

/**
 * @title TestableDeploySmartAccounts
 * @notice Extended DeploySmartAccounts with test helpers for setting internal state
 */
contract TestableDeploySmartAccounts is DeploySmartAccounts {
  function setTestConfig(
    address _safeProxyFactory,
    address _safeSingleton,
    address _admin,
    address _guardian,
    address _recoveryAddress,
    address _loansContract,
    address _loansExchange,
    address _portfolioVault,
    address _deployer
  ) external {
    safeProxyFactory = _safeProxyFactory;
    safeSingleton = _safeSingleton;
    accountsAdmin = _admin;
    accountsGuardian = _guardian;
    accountsRecoveryAddress = _recoveryAddress;
    loansContract = ILoans(_loansContract);
    loansExchangeContract = _loansExchange;
    portfolioVaultContract = _portfolioVault;
    deployer = _deployer;
  }

  function initCreateX() external {
    setUpCreateXFactory();
  }

  /**
   * @notice Run deployment with broadcast context (mirrors run() behavior)
   * @dev This runs deploy() inside vm.startBroadcast/stopBroadcast like the real script
   */
  function runDeploy() external {
    vm.startBroadcast(deployer);
    deployAccountsImpl();
    vm.stopBroadcast();
  }
}

/**
 * @title DeploySmartAccountsTest
 * @notice Tests for the DeploySmartAccounts deployment flow
 * @dev Tests call the actual script's deploy() function to ensure test/script parity
 */
contract DeploySmartAccountsTest is DeployerTestBase {
  TestableDeploySmartAccounts public deployerScript;
  Loans public loansContract;
  // forge-lint: disable-next-line(mixed-case-variable)
  LoansNFT public loansNFTContract;
  TrustedCalls public trustedCallsContract;
  TrustedSpender public trustedSpenderContract;
  SmartAccountFactory public smartAccountFactoryContract;
  address public timelock = makeAddr("timelock");

  function setUp() public override {
    super.setUp();
    vm.stopPrank();

    loansContract = new Loans(IERC20(address(usdc)), admin, admin);
    loansNFTContract = new LoansNFT(address(loansContract), "Tare Loans (test)", "");
    vm.prank(admin);
    loansContract.setLoansNFT(address(loansNFTContract));

    deployerScript = new TestableDeploySmartAccounts();

    deployerScript.setTestConfig(
      address(safeProxyFactory),
      safeSingleton,
      admin,
      timelock,
      timelock,
      address(loansContract),
      makeAddr("loansExchange"),
      makeAddr("portfolioVault"),
      deployer
    );

    // Initialize CreateX factory (etches bytecode on chain 31337)
    deployerScript.initCreateX();

    // Run deploy() with broadcast context inside the script
    deployerScript.runDeploy();

    // Store references for easier test access
    trustedCallsContract = TrustedCalls(deployerScript.trustedCalls());
    trustedSpenderContract = TrustedSpender(deployerScript.trustedSpender());
    smartAccountFactoryContract = SmartAccountFactory(deployerScript.smartAccountFactory());
  }

  function test_Deploy_TrustedCallsDeployed() public view {
    assertTrue(address(trustedCallsContract) != address(0), "TrustedCalls should have non-zero address");
    assertTrue(hasCode(address(trustedCallsContract)), "TrustedCalls should have deployed code");
  }

  function test_Deploy_TrustedSpenderDeployed() public view {
    assertTrue(address(trustedSpenderContract) != address(0), "TrustedSpender should have non-zero address");
    assertTrue(hasCode(address(trustedSpenderContract)), "TrustedSpender should have deployed code");
  }

  function test_Deploy_SmartAccountFactoryDeployed() public view {
    assertTrue(address(smartAccountFactoryContract) != address(0), "SmartAccountFactory should have non-zero address");
    assertTrue(hasCode(address(smartAccountFactoryContract)), "SmartAccountFactory should have deployed code");
  }

  /**
   * @notice Test that ILoans.create.selector is added as trusted call
   */
  function test_Deploy_TrustedCallsOnLoansContractAdded() public view {
    bytes4[] memory expectedSelectors = new bytes4[](4);
    expectedSelectors[0] = ILoans.create.selector;
    expectedSelectors[1] = ILoans.accrue.selector;
    expectedSelectors[2] = ILoans.fund.selector;
    expectedSelectors[3] = ILoans.disburse.selector;

    for (uint256 i = 0; i < expectedSelectors.length; i++) {
      assertTrue(
        trustedCallsContract.isTrustedCall(address(loansContract), expectedSelectors[i]),
        string.concat("Function selector from Loans is not set as trusted: ", vm.toString(expectedSelectors[i]))
      );
    }
  }

  /**
   * @notice Test that the ERC-7540 async deposit/redeem selectors are whitelisted on the vault
   */
  function test_Deploy_TrustedCallsOnVaultAsyncFunctionsAdded() public {
    address vault = makeAddr("portfolioVault");
    bytes4[] memory expectedSelectors = new bytes4[](8);
    expectedSelectors[0] = IERC7540Deposit.requestDeposit.selector;
    expectedSelectors[1] = IERC7540Deposit.deposit.selector;
    expectedSelectors[2] = IPortfolioVault.approveDeposit.selector;
    expectedSelectors[3] = IPortfolioVault.cancelDepositRequest.selector;
    expectedSelectors[4] = IERC7540Redeem.requestRedeem.selector;
    expectedSelectors[5] = IERC7575.redeem.selector;
    expectedSelectors[6] = IPortfolioVault.approveRedemption.selector;
    expectedSelectors[7] = IPortfolioVault.cancelRedeemRequest.selector;

    for (uint256 i = 0; i < expectedSelectors.length; i++) {
      assertTrue(
        trustedCallsContract.isTrustedCall(vault, expectedSelectors[i]),
        string.concat("Vault async function selector is not set as trusted: ", vm.toString(expectedSelectors[i]))
      );
    }
  }

  function test_Deploy_ApproveSelectorNotTrusted() public view {
    assertFalse(
      trustedCallsContract.isTrustedCall(address(loansContract.currency()), IERC20.approve.selector),
      "IERC20.approve should not be a trusted call on currency"
    );
  }

  function test_Deploy_DeployerLosesGuardianRoleOnTrustedCalls() public view {
    assertFalse(
      trustedCallsContract.hasRole(trustedCallsContract.ADMIN_ROLE(), deployer),
      "Deployer should not be admin on TrustedCalls"
    );
    assertFalse(
      trustedCallsContract.hasRole(trustedCallsContract.GUARDIAN_ROLE(), deployer),
      "Deployer should not be guardian on TrustedCalls"
    );
  }

  function test_Deploy_AdminGainsAdminOnTrustedCalls() public view {
    assertTrue(
      trustedCallsContract.hasRole(trustedCallsContract.ADMIN_ROLE(), admin),
      "Admin should be admin on TrustedCalls"
    );
  }

  function test_Deploy_TrustedSpenderHasCorrectAdmin() public view {
    assertTrue(
      trustedSpenderContract.hasRole(trustedSpenderContract.ADMIN_ROLE(), admin),
      "Admin should be admin on TrustedSpender"
    );

    assertFalse(
      trustedSpenderContract.hasRole(trustedSpenderContract.ADMIN_ROLE(), deployer),
      "Deployer should not be admin on TrustedSpender"
    );
    assertFalse(
      trustedSpenderContract.hasRole(trustedSpenderContract.GUARDIAN_ROLE(), deployer),
      "Deployer should not be guardian on TrustedSpender"
    );
  }

  function test_Deploy_GuardianSetToTimelockOnTrustedCalls() public view {
    assertTrue(
      trustedCallsContract.hasRole(trustedCallsContract.GUARDIAN_ROLE(), timelock),
      "Timelock should be guardian on TrustedCalls"
    );
  }

  function test_Deploy_GuardianSetToTimelockOnTrustedSpender() public view {
    assertTrue(
      trustedSpenderContract.hasRole(trustedSpenderContract.GUARDIAN_ROLE(), timelock),
      "Timelock should be guardian on TrustedSpender"
    );
  }

  function test_Deploy_SmartAccountFactoryImmutables() public view {
    assertEq(
      smartAccountFactoryContract.SAFE_SINGLETON(),
      safeSingleton,
      "SmartAccountFactory should reference correct safeSingleton"
    );
    assertEq(
      address(smartAccountFactoryContract.SAFE_PROXY_FACTORY()),
      address(safeProxyFactory),
      "SmartAccountFactory should reference correct safeProxyFactory"
    );
    assertEq(
      smartAccountFactoryContract.TRUSTED_CALLS_MODULE(),
      address(trustedCallsContract),
      "SmartAccountFactory should reference correct trustedCallsModule"
    );
    assertEq(
      smartAccountFactoryContract.TRUSTED_SPENDER(),
      address(trustedSpenderContract),
      "SmartAccountFactory should reference correct trustedSpender"
    );
  }
}
