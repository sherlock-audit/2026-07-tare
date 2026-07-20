// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployerTestBase} from "./DeployerTestBase.t.sol";
import {DeployVault} from "../../script/DeployVault.s.sol";
import {Loans} from "../../contracts/Loans.sol";
import {LoansNFT} from "../../contracts/LoansNFT.sol";
import {LoansExchange} from "../../contracts/LoansExchange.sol";
import {NavCalculator} from "../../contracts/NavCalculator.sol";
import {VaultShareToken} from "../../contracts/VaultShareToken.sol";
import {PortfolioVault} from "../../contracts/PortfolioVault.sol";
import {ILoans} from "../../contracts/interfaces/ILoans.sol";
import {ILoansNFT} from "../../contracts/interfaces/ILoansNFT.sol";
import {IVaultShareToken} from "../../contracts/interfaces/IVaultShareToken.sol";
import {INavCalculator, ValuationBucket} from "../../contracts/interfaces/INavCalculator.sol";

/**
 * @title TestableDeployVault
 * @notice Extended DeployVault with test helpers for setting internal state
 */
contract TestableDeployVault is DeployVault {
  address public testLoans;
  address public testLoansNFT;
  address public testLoansExchange;
  address public testUsdc;
  address public testAdmin;
  address public testGuardian;

  /// @dev Override parent setUp to prevent Foundry from running it
  function setUp() public override {}

  function setTestConfig(
    address _loans,
    address _loansNFT,
    address _loansExchange,
    address _usdc,
    address _admin,
    address _guardian,
    address _deployer
  ) external {
    testLoans = _loans;
    testLoansNFT = _loansNFT;
    testLoansExchange = _loansExchange;
    testUsdc = _usdc;
    testAdmin = _admin;
    testGuardian = _guardian;
    deployer = _deployer;
  }

  function initCreateX() external {
    setUpCreateXFactory();
  }

  function runDeploy() external {
    vm.startBroadcast(deployer);

    uint256[8] memory factors = [uint256(1e18), 1e18, 1e18, 1e18, 1e18, 1e18, 0, 0];
    deployVault(
      VaultParams({
        loans: ILoans(testLoans),
        loansNFT: ILoansNFT(testLoansNFT),
        exchange: ILoansExchange(testLoansExchange),
        usdc: IERC20(testUsdc),
        admin: testAdmin,
        guardian: testGuardian,
        recoveryAddress: testGuardian,
        portfolioManager: address(0),
        investorManager: address(0),
        calculatingAgent: address(0),
        whitelister: address(0),
        maxNavAge: 14_400,
        maxNavComputationTime: 1800,
        discountFactors: factors,
        shareTokenName: "Tare Vault Shares (test)",
        shareTokenSymbol: "tVAULT"
      })
    );

    vm.stopBroadcast();
  }
}

import {ILoansNFT} from "../../contracts/interfaces/ILoansNFT.sol";
import {ILoansExchange} from "../../contracts/interfaces/ILoansExchange.sol";

/**
 * @title DeployVaultTest
 * @notice Tests for the DeployVault script deployment flow
 */
contract DeployVaultTest is DeployerTestBase {
  TestableDeployVault public deployerScript;
  Loans public loansContract;
  LoansNFT public loansNFTContract;
  LoansExchange public loansExchangeContract;
  NavCalculator public navCalculatorContract;
  VaultShareToken public vaultShareTokenContract;
  PortfolioVault public portfolioVaultContract;
  address public timelock = makeAddr("timelock");

  function setUp() public override {
    super.setUp();
    vm.stopPrank();

    // Pre-deploy Loans infrastructure (required by vault)
    loansContract = new Loans(IERC20(address(usdc)), admin, admin);
    loansNFTContract = new LoansNFT(address(loansContract), "Tare Loans (test)", "");
    vm.prank(admin);
    loansContract.setLoansNFT(address(loansNFTContract));
    loansExchangeContract = new LoansExchange(
      ILoansNFT(address(loansNFTContract)),
      ILoans(address(loansContract)),
      admin,
      admin
    );

    deployerScript = new TestableDeployVault();
    deployerScript.setTestConfig(
      address(loansContract),
      address(loansNFTContract),
      address(loansExchangeContract),
      address(usdc),
      admin,
      timelock,
      deployer
    );

    deployerScript.initCreateX();
    deployerScript.runDeploy();

    navCalculatorContract = deployerScript.navCalculator();
    vaultShareTokenContract = deployerScript.vaultShareToken();
    portfolioVaultContract = deployerScript.portfolioVault();
  }

  // ========== Deployment Verification ==========

  function test_Deploy_NavCalculatorDeployed() public view {
    assertTrue(address(navCalculatorContract) != address(0));
    assertTrue(hasCode(address(navCalculatorContract)));
  }

  function test_Deploy_VaultShareTokenDeployed() public view {
    assertTrue(address(vaultShareTokenContract) != address(0));
    assertTrue(hasCode(address(vaultShareTokenContract)));
  }

  function test_Deploy_PortfolioVaultDeployed() public view {
    assertTrue(address(portfolioVaultContract) != address(0));
    assertTrue(hasCode(address(portfolioVaultContract)));
  }

  // ========== Cross-Contract Wiring ==========

  function test_Deploy_VaultShareTokenPointsToVault() public view {
    assertEq(vaultShareTokenContract.vault(address(usdc)), address(portfolioVaultContract));
  }

  function test_Deploy_VaultShareTokenPointsToAsset() public view {
    // Returns address(0) for wrong asset
    assertEq(vaultShareTokenContract.vault(address(1)), address(0));
  }

  function test_Deploy_PortfolioVaultPointsToLoans() public view {
    assertEq(address(portfolioVaultContract.loans()), address(loansContract));
  }

  function test_Deploy_PortfolioVaultPointsToLoansNFT() public view {
    assertEq(address(portfolioVaultContract.loansNFT()), address(loansNFTContract));
  }

  function test_Deploy_PortfolioVaultPointsToExchange() public view {
    assertEq(address(portfolioVaultContract.exchange()), address(loansExchangeContract));
  }

  function test_Deploy_PortfolioVaultPointsToShareToken() public view {
    assertEq(address(portfolioVaultContract.shareToken()), address(vaultShareTokenContract));
  }

  function test_Deploy_PortfolioVaultPointsToCalculator() public view {
    assertEq(address(portfolioVaultContract.calculator()), address(navCalculatorContract));
  }

  // ========== VaultShareToken Roles ==========

  function test_Deploy_VaultHasMinterRole() public view {
    assertTrue(vaultShareTokenContract.hasRole(vaultShareTokenContract.MINTER_ROLE(), address(portfolioVaultContract)));
  }

  function test_Deploy_VaultHasBurnerRole() public view {
    assertTrue(vaultShareTokenContract.hasRole(vaultShareTokenContract.BURNER_ROLE(), address(portfolioVaultContract)));
  }

  function test_Deploy_VaultHasShareholderRole() public view {
    assertTrue(
      vaultShareTokenContract.hasRole(vaultShareTokenContract.SHAREHOLDER_ROLE(), address(portfolioVaultContract))
    );
  }

  function test_Deploy_DeadAddressLacksShareholderRole() public view {
    assertFalse(vaultShareTokenContract.hasRole(vaultShareTokenContract.SHAREHOLDER_ROLE(), address(0xdead)));
  }

  function test_Deploy_DeadSharesMinted() public view {
    assertEq(vaultShareTokenContract.balanceOf(address(0xdead)), 1e18);
  }

  function test_Deploy_DeadSharesAreLocked() public {
    vm.prank(address(0xdead));
    vm.expectRevert(abi.encodeWithSelector(IVaultShareToken.ShareholderRestricted.selector, address(0xdead)));
    IERC20(address(vaultShareTokenContract)).transfer(address(portfolioVaultContract), 1);
  }

  function test_Deploy_DeadAddressCannotReceiveShares() public {
    vm.prank(address(portfolioVaultContract));
    vm.expectRevert(abi.encodeWithSelector(IVaultShareToken.ShareholderRestricted.selector, address(0xdead)));
    vaultShareTokenContract.mint(address(0xdead), 1);
  }

  // ========== Permission Transfers ==========

  function test_Deploy_AdminGainsAdminRights() public view {
    assertTrue(portfolioVaultContract.hasRole(portfolioVaultContract.ADMIN_ROLE(), admin));
    assertTrue(navCalculatorContract.hasRole(navCalculatorContract.ADMIN_ROLE(), admin));
    assertTrue(vaultShareTokenContract.hasRole(vaultShareTokenContract.ADMIN_ROLE(), admin));
  }

  function test_Deploy_GuardianSetToTimelock() public view {
    assertTrue(portfolioVaultContract.hasRole(portfolioVaultContract.GUARDIAN_ROLE(), timelock));
    assertTrue(navCalculatorContract.hasRole(navCalculatorContract.GUARDIAN_ROLE(), timelock));
    assertTrue(vaultShareTokenContract.hasRole(vaultShareTokenContract.GUARDIAN_ROLE(), timelock));
  }

  function test_Deploy_DeployerLosesPriviledgedRolesInScript() public view {
    bytes32 guardianRole = portfolioVaultContract.GUARDIAN_ROLE();

    assertFalse(portfolioVaultContract.hasRole(guardianRole, deployer));
    assertFalse(navCalculatorContract.hasRole(guardianRole, deployer));
    assertFalse(vaultShareTokenContract.hasRole(guardianRole, deployer));

    assertFalse(portfolioVaultContract.hasRole(portfolioVaultContract.ADMIN_ROLE(), deployer));
    assertFalse(navCalculatorContract.hasRole(navCalculatorContract.ADMIN_ROLE(), deployer));
    assertFalse(vaultShareTokenContract.hasRole(vaultShareTokenContract.ADMIN_ROLE(), deployer));
  }

  // ========== Configuration ==========

  function test_Deploy_NavConfigDefaults() public view {
    assertEq(portfolioVaultContract.maxNavAge(), 14_400);
    assertEq(portfolioVaultContract.maxNavComputationTime(), 1800);
  }

  function test_Deploy_DiscountFactorsAllSetCorrectly() public view {
    for (uint256 i; i < 6; i++) {
      assertEq(navCalculatorContract.discountFactors(ValuationBucket(i)), 1e18);
    }
    assertEq(navCalculatorContract.discountFactors(ValuationBucket.Closed), 0);
    assertEq(navCalculatorContract.discountFactors(ValuationBucket.Cancelled), 0);
  }
}
