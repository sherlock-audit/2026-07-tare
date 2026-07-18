// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeploymentBase} from "./DeploymentBase.sol";
import {Loans} from "../../contracts/Loans.sol";
import {LoansExchange} from "../../contracts/LoansExchange.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

abstract contract DeployLoansExchangeLibrary is DeploymentBase {
  LoansExchange public loansExchange;

  struct LoansExchangeParams {
    address loans;
    address loansNFT;
    address admin;
    address guardian;
    address recoveryAddress;
  }

  /// @notice Full deployment: contract + admin transfer
  function deployLoansExchange(LoansExchangeParams memory p) internal returns (LoansExchange) {
    deployLoansExchangeContract(p.loansNFT, p.loans, p.recoveryAddress);
    setLoansExchangePermissions(p.admin, p.guardian);
    return loansExchange;
  }

  /// @notice Deploy only the LoansExchange contract (for composite flows that wire permissions elsewhere).
  /// @dev `recoveryAddress` is the rescue recipient baked into LoansExchange via Rescuable.
  function deployLoansExchangeContract(
    address loansNFT,
    address loansContract,
    address recoveryAddress
  ) internal returns (LoansExchange) {
    // Deployer is the initial guardian — guardian passes onlyAdmin via >=
    loansExchange = LoansExchange(
      create3(
        generateSalt("LoansExchange"),
        abi.encodePacked(
          type(LoansExchange).creationCode,
          abi.encode(IERC721(loansNFT), loansContract, deployer, recoveryAddress)
        )
      )
    );
    return loansExchange;
  }

  /**
   * @notice Set up the two-tier permission model on the LoansExchange contract.
   * @dev Grants ADMIN_ROLE and GUARDIAN_ROLE, then revokes the deployer's GUARDIAN_ROLE.
   *      Both `admin` and `guardian` are required, must be non-zero, and must differ from
   *      the deployer.
   */
  function setLoansExchangePermissions(address admin, address guardian) internal {
    require(admin != address(0) && admin != deployer, "setLoansExchangePermissions: invalid admin");
    require(guardian != address(0) && guardian != deployer, "setLoansExchangePermissions: invalid guardian");

    loansExchange.grantRole(loansExchange.ADMIN_ROLE(), admin);
    loansExchange.grantRole(loansExchange.GUARDIAN_ROLE(), guardian);
    loansExchange.revokeRole(loansExchange.GUARDIAN_ROLE(), deployer);
  }

  function writeLoansExchangeDeployment() internal {
    addDeployedContract("LoansExchange", address(loansExchange));
    writeDeploymentInfo(buildDeploymentJson());
  }
}
