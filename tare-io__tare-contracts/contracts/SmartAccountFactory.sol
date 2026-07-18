// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeProxy} from "safe-smart-account/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";

import {ISmartAccountFactory} from "contracts/interfaces/ISmartAccountFactory.sol";
import {ITrustedCalls} from "contracts/interfaces/ITrustedCalls.sol";
import {ITrustedSpender} from "contracts/interfaces/ITrustedSpender.sol";
import {IModuleManager} from "contracts/misc/interfaces/IModuleManager.sol";
import {ISafe} from "contracts/misc/interfaces/ISafe.sol";

/**
 * @title SmartAccountFactory
 * @notice Deploys Gnosis Safe smart accounts with the `TrustedCalls` module enabled, the
 *         `TrustedSpender` contract pre-approved for the requested tokens, and per-route
 *         allowances set up so delegates can act on the Safe's behalf from day one.
 */
contract SmartAccountFactory is ISmartAccountFactory {
  using SafeERC20 for IERC20;

  // Immutable references to Safe infrastructure
  SafeProxyFactory public immutable SAFE_PROXY_FACTORY;
  address public immutable SAFE_SINGLETON;

  // TrustedCalls module reference for installation
  address public immutable TRUSTED_CALLS_MODULE;

  // TrustedSpender contract reference (not a module, uses token approvals)
  address public immutable TRUSTED_SPENDER;

  address private immutable _SELF = address(this);

  bytes32 private constant CONFIGURED_SLOT = keccak256("Tare.SmartAccountFactory.configured");

  /// @inheritdoc ISmartAccountFactory
  mapping(address deployer => uint256 nonce) public nonces;

  /// @inheritdoc ISmartAccountFactory
  mapping(address account => bool deployed) public isDeployedSmartAccount;

  constructor(address _safeProxyFactory, address _safeSingleton, address _trustedCallsModule, address _trustedSpender) {
    SAFE_PROXY_FACTORY = SafeProxyFactory(_safeProxyFactory);
    SAFE_SINGLETON = _safeSingleton;
    TRUSTED_CALLS_MODULE = _trustedCallsModule;
    TRUSTED_SPENDER = _trustedSpender;
  }

  /// @inheritdoc ISmartAccountFactory
  function deploySmartAccount(
    address[] memory delegates,
    address[] memory currencies,
    address[] memory nftCollections,
    address[] memory trustedRecipients,
    uint48 validUntil,
    address[] memory owners,
    uint256 threshold
  ) external returns (address) {
    require(owners.length > 0, NoOwners());
    require(threshold > 0, InvalidThreshold());
    require(threshold <= owners.length, ThresholdTooHigh());
    require(validUntil > block.timestamp, InvalidAllowanceDeadline());

    // Calculate the salt nonce for deterministic address (scoped per deployer)
    uint256 deployerNonce = nonces[msg.sender]++;
    uint256 saltNonce = uint256(keccak256(abi.encodePacked(msg.sender, deployerNonce)));

    bytes memory initializer = _buildInitializer(
      delegates,
      currencies,
      nftCollections,
      trustedRecipients,
      validUntil,
      owners,
      threshold
    );

    SafeProxy proxy = SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, initializer, saltNonce);

    address safeAddress = address(proxy);
    isDeployedSmartAccount[safeAddress] = true;
    emit SmartAccountDeployed(safeAddress, msg.sender, owners, threshold);

    return safeAddress;
  }

  /// @inheritdoc ISmartAccountFactory
  function configureSmartAccount(
    address[] memory delegates,
    address[] memory currencies,
    address[] memory nftCollections,
    address[] memory trustedRecipients,
    uint48 validUntil
  ) external {
    require(address(this) != _SELF, NotDelegateCall());
    _setConfigured();

    // 1. Enable TrustedCalls module
    IModuleManager(payable(address(this))).enableModule(TRUSTED_CALLS_MODULE);

    // 2. Approve currencies for TrustedSpender (standard ERC20 approvals)
    for (uint256 i = 0; i < currencies.length; ++i) {
      IERC20(currencies[i]).forceApprove(TRUSTED_SPENDER, type(uint256).max);
    }

    // 3. Approve NFT collections for TrustedSpender (blanket setApprovalForAll)
    for (uint256 i = 0; i < nftCollections.length; ++i) {
      IERC721(nftCollections[i]).setApprovalForAll(TRUSTED_SPENDER, true);
    }

    // 4. Add delegates to both TrustedCalls module and TrustedSpender contract
    for (uint256 i = 0; i < delegates.length; ++i) {
      // Add to TrustedCalls module
      ITrustedCalls(TRUSTED_CALLS_MODULE).addDelegate(address(this), delegates[i]);

      // Add to TrustedSpender contract
      ITrustedSpender(TRUSTED_SPENDER).addDelegate(address(this), delegates[i]);
    }

    // 5. Set ERC20 allowances for trusted recipients in TrustedSpender.
    //    NFT per-route allowances are set lazily via TrustedSpender.setNFTAllowance.
    for (uint256 i = 0; i < trustedRecipients.length; ++i) {
      for (uint256 j = 0; j < currencies.length; ++j) {
        ITrustedSpender(TRUSTED_SPENDER).setAllowance(
          currencies[j],
          address(this),
          trustedRecipients[i],
          type(uint208).max,
          validUntil
        );
      }
    }
  }

  /// @inheritdoc ISmartAccountFactory
  function predictSmartAccountAddress(
    address deployer,
    uint256 _nonce,
    address[] memory delegates,
    address[] memory currencies,
    address[] memory nftCollections,
    address[] memory trustedRecipients,
    uint48 validUntil,
    address[] memory owners,
    uint256 threshold
  ) public view returns (address) {
    uint256 saltNonce = uint256(keccak256(abi.encodePacked(deployer, _nonce)));

    bytes memory initializer = _buildInitializer(
      delegates,
      currencies,
      nftCollections,
      trustedRecipients,
      validUntil,
      owners,
      threshold
    );
    bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));

    bytes memory deploymentData = abi.encodePacked(
      SAFE_PROXY_FACTORY.proxyCreationCode(),
      uint256(uint160(SAFE_SINGLETON))
    );

    bytes32 hash = keccak256(
      abi.encodePacked(bytes1(0xff), address(SAFE_PROXY_FACTORY), salt, keccak256(deploymentData))
    );

    return address(uint160(uint256(hash)));
  }

  /**
   * @notice One-shot guard that marks the Safe as configured by writing to a custom storage slot.
   * @dev Reverts if the slot is already non-zero. Invoked from `configureSmartAccount` only.
   */
  function _setConfigured() internal {
    bytes32 slot = CONFIGURED_SLOT;
    uint256 configured;
    assembly {
      configured := sload(slot)
    }
    require(configured == 0, AlreadyConfigured());
    assembly {
      sstore(slot, 1)
    }
  }

  /**
   * @notice Builds the `Safe.setup` initializer that runs `configureSmartAccount` via delegatecall.
   * @return The ABI-encoded `Safe.setup` calldata used by `SafeProxyFactory.createProxyWithNonce`.
   */
  function _buildInitializer(
    address[] memory delegates,
    address[] memory currencies,
    address[] memory nftCollections,
    address[] memory trustedRecipients,
    uint48 validUntil,
    address[] memory owners,
    uint256 threshold
  ) internal view returns (bytes memory) {
    bytes memory configureData = abi.encodeWithSelector(
      this.configureSmartAccount.selector,
      delegates,
      currencies,
      nftCollections,
      trustedRecipients,
      validUntil
    );

    return
      abi.encodeWithSelector(
        ISafe.setup.selector,
        owners, // final owners from the start
        threshold, // final threshold
        address(this), // to: this factory contract for delegatecall
        configureData, // data: configuration call
        address(0), // fallbackHandler
        address(0), // paymentToken
        0, // payment
        address(0) // paymentReceiver
      );
  }
}
