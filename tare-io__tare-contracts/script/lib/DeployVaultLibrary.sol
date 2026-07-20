// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeploymentBase} from "./DeploymentBase.sol";
import {NavCalculator} from "../../contracts/NavCalculator.sol";
import {VaultShareToken} from "../../contracts/VaultShareToken.sol";
import {PortfolioVault} from "../../contracts/PortfolioVault.sol";
import {ILoans} from "../../contracts/interfaces/ILoans.sol";
import {ILoansNFT} from "../../contracts/interfaces/ILoansNFT.sol";
import {ILoansExchange} from "../../contracts/interfaces/ILoansExchange.sol";
import {IVaultShareToken} from "../../contracts/interfaces/IVaultShareToken.sol";
import {INavCalculator} from "../../contracts/interfaces/INavCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract DeployVaultLibrary is DeploymentBase {
  NavCalculator public navCalculator;
  VaultShareToken public vaultShareToken;
  PortfolioVault public portfolioVault;

  struct VaultParams {
    ILoans loans;
    ILoansNFT loansNFT;
    ILoansExchange exchange;
    IERC20 usdc;
    address admin;
    address guardian;
    address recoveryAddress;
    address portfolioManager;
    address investorManager;
    address calculatingAgent;
    address whitelister;
    uint256 maxNavAge;
    uint256 maxNavComputationTime;
    uint256[8] discountFactors;
    string shareTokenName;
    string shareTokenSymbol;
  }

  /** @notice Full deployment: contracts + admin/guardian role wiring + operator role grants. */
  function deployVault(VaultParams memory p) internal returns (PortfolioVault) {
    deployVaultContracts(p);
    setVaultOperators(p);
    setVaultPermissions(p.admin, p.guardian);
    return portfolioVault;
  }

  /**
   * @notice Deploy NavCalculator, VaultShareToken, and PortfolioVault.
   * @dev Uses CREATE3 address prediction to resolve the VaultShareToken <-> PortfolioVault
   *      circular dependency: the share token constructor needs the vault address for
   *      MINTER/BURNER role grants, but the vault constructor needs the share token address.
   */
  function deployVaultContracts(VaultParams memory p) internal returns (PortfolioVault) {
    // 1. NavCalculator — stateless w.r.t. the Loans contract; the vault passes
    // its `loans` reference on each `getLoansValue` call so the two cannot drift.
    navCalculator = NavCalculator(
      create3(
        generateSalt("NavCalculator"),
        abi.encodePacked(type(NavCalculator).creationCode, abi.encode(deployer, p.discountFactors))
      )
    );

    // 2. Predict PortfolioVault address before deploying VaultShareToken
    address predictedVaultAddress = computeCreate3Address("PortfolioVault");

    // 3. VaultShareToken — uses predicted vault address for MINTER/BURNER roles
    vaultShareToken = VaultShareToken(
      create3(
        generateSalt("VaultShareToken"),
        abi.encodePacked(
          type(VaultShareToken).creationCode,
          abi.encode(
            p.shareTokenName,
            p.shareTokenSymbol,
            deployer,
            p.recoveryAddress,
            predictedVaultAddress,
            address(p.usdc)
          )
        )
      )
    );

    // 3b. Whitelist DEAD_ADDRESS before vault deployment — the PortfolioVault constructor
    // mints dead shares to prevent share price manipulation, which requires SHAREHOLDER_ROLE
    vaultShareToken.grantRole(vaultShareToken.WHITELISTER_ROLE(), deployer);
    vaultShareToken.grantRole(vaultShareToken.SHAREHOLDER_ROLE(), address(0xdead));

    // 4. PortfolioVault — deployed at the predicted address
    portfolioVault = PortfolioVault(
      create3(
        generateSalt("PortfolioVault"),
        abi.encodePacked(
          type(PortfolioVault).creationCode,
          abi.encode(
            address(p.loans),
            address(p.loansNFT),
            address(p.exchange),
            address(p.usdc),
            address(vaultShareToken),
            address(navCalculator),
            deployer,
            p.recoveryAddress,
            p.maxNavAge,
            p.maxNavComputationTime
          )
        )
      )
    );

    // 4b. Revoke 0xdead's SHAREHOLDER_ROLE — only needed for the constructor's dead-shares
    // mint; leaving it would let shareholders send shares to 0xdead
    vaultShareToken.revokeRole(vaultShareToken.SHAREHOLDER_ROLE(), address(0xdead));

    // 4c. Revoke deployer's WHITELISTER_ROLE to lock down share token permissions
    vaultShareToken.revokeRole(vaultShareToken.WHITELISTER_ROLE(), deployer);

    return portfolioVault;
  }

  /**
   * @notice Grant the four operational roles on the deployed vault contracts.
   * @dev Each grant is skipped when its target address is `address(0)`. Called inside the
   *      deploy broadcast while the deployer still holds GUARDIAN_ROLE (the role-admin for
   *      all four roles). Operators can be (re)assigned post-deploy by the new guardian.
   */
  function setVaultOperators(VaultParams memory p) internal {
    if (p.portfolioManager != address(0)) {
      portfolioVault.grantRole(portfolioVault.PORTFOLIO_MANAGER(), p.portfolioManager);
    }
    if (p.investorManager != address(0)) {
      portfolioVault.grantRole(portfolioVault.INVESTOR_MANAGER(), p.investorManager);
    }
    if (p.calculatingAgent != address(0)) {
      navCalculator.grantRole(navCalculator.CALCULATING_AGENT(), p.calculatingAgent);
    }
    if (p.whitelister != address(0)) {
      vaultShareToken.grantRole(vaultShareToken.WHITELISTER_ROLE(), p.whitelister);
    }
  }

  /**
   * @notice Set up the two-tier permission model on vault contracts.
   * @dev Grants ADMIN_ROLE and GUARDIAN_ROLE on every vault contract, then revokes the
   *      deployer's GUARDIAN_ROLE on each. Both `admin` and `guardian` are required, must
   *      be non-zero, and must differ from the deployer.
   */
  function setVaultPermissions(address admin, address guardian) internal {
    require(admin != address(0) && admin != deployer, "setVaultPermissions: invalid admin");
    require(guardian != address(0) && guardian != deployer, "setVaultPermissions: invalid guardian");

    bytes32 ADMIN_ROLE = portfolioVault.ADMIN_ROLE();
    bytes32 GUARDIAN_ROLE = portfolioVault.GUARDIAN_ROLE();

    portfolioVault.grantRole(ADMIN_ROLE, admin);
    navCalculator.grantRole(ADMIN_ROLE, admin);
    vaultShareToken.grantRole(ADMIN_ROLE, admin);

    portfolioVault.grantRole(GUARDIAN_ROLE, guardian);
    navCalculator.grantRole(GUARDIAN_ROLE, guardian);
    vaultShareToken.grantRole(GUARDIAN_ROLE, guardian);

    portfolioVault.revokeRole(GUARDIAN_ROLE, deployer);
    navCalculator.revokeRole(GUARDIAN_ROLE, deployer);
    vaultShareToken.revokeRole(GUARDIAN_ROLE, deployer);
  }

  function writeVaultDeployment() internal {
    addDeployedContract("NavCalculator", address(navCalculator));
    addDeployedContract("VaultShareToken", address(vaultShareToken));
    addDeployedContract("PortfolioVault", address(portfolioVault));
    writeDeploymentInfo(buildDeploymentJson());
  }
}
