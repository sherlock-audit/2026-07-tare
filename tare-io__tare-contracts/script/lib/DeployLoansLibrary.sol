// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeployLoansExchangeLibrary} from "./DeployLoansExchangeLibrary.sol";
import {Loans} from "../../contracts/Loans.sol";
import {LoansNFT} from "../../contracts/LoansNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract DeployLoansLibrary is DeployLoansExchangeLibrary {
  Loans public loans;
  LoansNFT public loansNFT;

  struct LoansParams {
    IERC20 usdc;
    address admin;
    address guardian;
    address recoveryAddress;
    string baseURI;
  }

  /// @notice Full deployment: Loans + LoansNFT + LoansExchange + admin transfer
  function deployLoans(LoansParams memory p) internal returns (Loans) {
    deployLoansContracts(p.usdc, p.baseURI, p.recoveryAddress);

    deployLoansExchange(
      LoansExchangeParams({
        loans: address(loans),
        loansNFT: address(loansNFT),
        admin: p.admin,
        guardian: p.guardian,
        recoveryAddress: p.recoveryAddress
      })
    );

    setLoansPermissions(p.admin, p.guardian);

    return loans;
  }

  /// @notice Deploy only Loans + LoansNFT contracts (for local/custom flows)
  /// @dev `recoveryAddress` is the rescue recipient baked into Loans via Rescuable.
  ///      It is independent of ADMIN_ROLE — the latter is granted in `setLoansPermissions`.
  function deployLoansContracts(IERC20 usdc, string memory baseURI, address recoveryAddress) internal returns (Loans) {
    string memory nftCollectionName = string.concat("Tare Loans (", deploymentName, ")");

    // Deployer is the initial guardian — guardian passes onlyAdmin via >=
    loans = Loans(
      create3(
        generateSalt("Loans"),
        abi.encodePacked(type(Loans).creationCode, abi.encode(address(usdc), deployer, recoveryAddress))
      )
    );

    loansNFT = LoansNFT(
      create3(
        generateSalt("LoansNFT"),
        abi.encodePacked(type(LoansNFT).creationCode, abi.encode(address(loans), nftCollectionName, baseURI))
      )
    );

    loans.setLoansNFT(address(loansNFT));

    return loans;
  }

  /**
   * @notice Set up the two-tier permission model on the Loans contract.
   * @dev Grants ADMIN_ROLE to the admin wallet and GUARDIAN_ROLE to the guardian, then
   *      revokes the deployer's GUARDIAN_ROLE so deployment artifacts ship with the
   *      intended owners only. Both `admin` and `guardian` are required, must be non-zero,
   *      and must differ from the deployer.
   *      LoansExchange permissions are set separately by `setLoansExchangePermissions`.
   */
  function setLoansPermissions(address admin, address guardian) internal {
    require(admin != address(0) && admin != deployer, "setLoansPermissions: invalid admin");
    require(guardian != address(0) && guardian != deployer, "setLoansPermissions: invalid guardian");

    loans.grantRole(loans.ADMIN_ROLE(), admin);
    loans.grantRole(loans.GUARDIAN_ROLE(), guardian);
    loans.revokeRole(loans.GUARDIAN_ROLE(), deployer);
  }

  function writeLoansDeployment(address _loans, address _usdc) internal {
    addDeployedContract("Loans", _loans);
    addDeployedContract("LoansNFT", address(loansNFT));
    addDeployedContract("LoansExchange", address(loansExchange));
    addDeployedContract("USDC", _usdc);
    writeDeploymentInfo(buildDeploymentJson());
  }
}
