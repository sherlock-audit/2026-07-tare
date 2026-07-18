// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";
import {CREATEX_ADDRESS} from "createx-forge/script/CreateX.d.sol";
import {ChainNames} from "../utils/ChainNames.sol";

/**
 * @title DeploymentBase
 * @notice Shared primitives for all deployment scripts: CREATE3 salt scheme,
 *         chain resolution, manifest writing, and validation invariants.
 */
abstract contract DeploymentBase is Script, CreateXScript {
  address public deployer;
  bool public simulateOnly;
  string public componentName;
  string public deploymentName;
  string public deployDir;

  uint256 public chainId;
  string public chainName;
  string public version;
  string public commitHash;

  struct ContractInfo {
    string name;
    address addr;
  }

  ContractInfo[] public deployedContracts;

  /**
   * @notice Initialises shared deployment state read from env + chain context.
   * @dev Reverts on misconfiguration (unknown chain, empty deployment name) so the
   *      operator fails fast rather than writing manifests into a meaningless path.
   *      `ALLOW_UNKNOWN_CHAIN=true` may be set explicitly for local/forge tests.
   */
  function initializeBase(string memory componentName_, string memory deploymentName_) internal {
    require(bytes(deploymentName_).length > 0, "DeploymentBase: empty DEPLOYMENT_NAME");

    deployer = msg.sender;
    chainId = block.chainid;
    chainName = ChainNames.getChainName(chainId);
    componentName = componentName_;
    deploymentName = deploymentName_;
    deployDir = string(abi.encodePacked("deployments/", chainName, "/", deploymentName, "/", componentName, "/"));

    version = vm.envString("PACKAGE_VERSION");
    commitHash = vm.envOr("COMMIT_HASH", string(""));

    console.log(string(abi.encodePacked("Component: ", componentName)));
    console.log(string(abi.encodePacked("Deployment: ", deploymentName)));
    console.log(string(abi.encodePacked("Chain: ", chainName)));
    console.log(string(abi.encodePacked("Version: ", version)));

    if (
      bytes(commitHash).length == 0 && chainId != 31337 && keccak256(bytes(chainName)) != keccak256(bytes("unknown"))
    ) {
      console.log("WARNING: COMMIT_HASH env var is empty for a production-like deploy");
    }

    if (chainId != 31337 && keccak256(bytes(deploymentName)) == keccak256(bytes("dev"))) {
      console.log("WARNING: DEPLOYMENT_NAME=dev on a live chain - make sure this is intentional");
    }
  }

  /**
   * @notice Deterministic salt for CREATE3 deployments.
   * @dev Namespaced by deployment name so distinct deployments on the same chain
   *      (e.g. `dev` vs `prod`) at the same version do not collide on addresses.
   *      Version is included so new versions produce fresh addresses.
   */
  function generateSalt(string memory contractName) internal view returns (bytes32) {
    return keccak256(abi.encodePacked(deploymentName, contractName, version));
  }

  /**
   * @notice Computes the CREATE3 address a contract will deploy to under our salt scheme.
   * @dev Our salts (keccak256 of deploymentName+contract+version) have random first-20-bytes,
   *      so CreateX's `_guard` follows the (Random, Unspecified) path:
   *      guardedSalt = keccak256(abi.encode(salt)).
   */
  function computeCreate3Address(string memory contractName) public view returns (address) {
    bytes32 salt = generateSalt(contractName);
    bytes32 guardedSalt = keccak256(abi.encode(salt));
    return CreateX.computeCreate3Address(guardedSalt, CREATEX_ADDRESS);
  }

  /**
   * @notice CREATE3-deploy unless the salt's address already has code, then return that address.
   * @dev Lets a fixed-salt contract (e.g. the local Safe infra) be landed by an earlier
   *      bootstrap script and reused by a later one — a repeat CREATE3 to the same salt
   *      would revert. Only valid for raw keccak salts (random first 20 bytes), where
   *      CreateX guards with `keccak256(abi.encode(salt))`.
   */
  function create3IfAbsent(bytes32 salt, bytes memory initCode) internal returns (address addr) {
    addr = CreateX.computeCreate3Address(keccak256(abi.encode(salt)), CREATEX_ADDRESS);
    if (addr.code.length == 0) {
      address deployed = create3(salt, initCode);
      require(deployed == addr, "create3IfAbsent: predicted address mismatch");
    }
  }

  /** @notice Writes the deployment manifest to `latest.json` and a versioned copy. */
  function writeDeploymentInfo(string memory json) internal {
    if (!simulateOnly && vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) return;

    string memory latestPath = string(abi.encodePacked(deployDir, "latest.json"));
    // forge-lint: disable-next-line(unsafe-cheatcode)
    vm.writeJson(json, latestPath);

    if (!simulateOnly) {
      string memory filename = string(abi.encodePacked(deployDir, version, ".json"));
      // forge-lint: disable-next-line(unsafe-cheatcode)
      vm.writeJson(json, filename);
      console.log("Deployment info written to", filename, "and", latestPath);
    } else {
      console.log("Deployment info written to", latestPath);
    }
  }

  /**
   * @notice Reset manifest state for a new component within the same script run.
   * @dev Clears `deployedContracts`, updates `componentName`, and recomputes `deployDir`.
   *      Use when a single script (e.g. `DeployLocal`) writes multiple component manifests.
   */
  function startNewComponent(string memory name) internal {
    delete deployedContracts;
    componentName = name;
    deployDir = string(abi.encodePacked("deployments/", chainName, "/", deploymentName, "/", name, "/"));
  }

  /** @notice Records a deployed contract for inclusion in the manifest. */
  function addDeployedContract(string memory contractName, address contractAddress) internal {
    deployedContracts.push(ContractInfo({name: contractName, addr: contractAddress}));
    console.log(string(abi.encodePacked(contractName, " deployed at: ")), contractAddress);
  }

  /**
   * @notice Builds the deployment manifest JSON using Foundry's serializer cheatcodes.
   * @dev Schema (kept stable for downstream consumers):
   *      {
   *        version, commitHash, component, deploymentName,
   *        chain, chainId, blockNumber, timestamp,
   *        contracts: { name: address, ... }
   *      }
   */
  function buildDeploymentJson() internal returns (string memory) {
    string memory contractsKey = "_contracts";
    string memory contractsJson = "{}";
    uint256 contractsLength = deployedContracts.length;
    for (uint256 index; index < contractsLength; ++index) {
      contractsJson = vm.serializeAddress(contractsKey, deployedContracts[index].name, deployedContracts[index].addr);
    }

    string memory rootKey = "root";
    vm.serializeString(rootKey, "version", version);
    vm.serializeString(rootKey, "commitHash", commitHash);
    vm.serializeString(rootKey, "component", componentName);
    vm.serializeString(rootKey, "deploymentName", deploymentName);
    vm.serializeString(rootKey, "chain", chainName);
    vm.serializeUint(rootKey, "chainId", chainId);
    vm.serializeUint(rootKey, "blockNumber", block.number);
    vm.serializeUint(rootKey, "timestamp", block.timestamp);
    return vm.serializeString(rootKey, "contracts", contractsJson);
  }

  /**
   * @notice Whether `needle` is present in `haystack`.
   * @dev Linear scan — fine for the handful of role addresses or contract names a deploy script handles.
   */
  function _contains(address[] memory haystack, address needle) internal pure returns (bool) {
    for (uint256 index; index < haystack.length; index++) {
      if (haystack[index] == needle) return true;
    }
    return false;
  }
}
