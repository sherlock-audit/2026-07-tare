// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Enum} from "safe-smart-account/common/Enum.sol";
import {SafeProxy} from "../lib/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "../lib/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";

import {Forwarder} from "../contracts/Forwarder.sol";
import {TrustedCalls} from "../contracts/TrustedCalls.sol";
import {ITrustedCalls} from "../contracts/interfaces/ITrustedCalls.sol";
import {ISafe} from "../contracts/misc/interfaces/ISafe.sol";
import {MockUSDC} from "./mocks/USDC.sol";
import {DeploySafeSingleton} from "./helpers/DeploySafeSingleton.sol";

// Mock target contract for testing forwarded trusted calls
contract MockTarget {
  uint256 public value;
  address public lastCaller;

  function setValue(uint256 newValue) external {
    value = newValue;
    lastCaller = msg.sender;
  }
}

contract ForwarderTest is Test {
  bytes4 internal constant SET_VALUE_SELECTOR = bytes4(keccak256("setValue(uint256)"));

  Forwarder public forwarder;
  TrustedCalls public trustedCallsModule;
  ISafe public safeSingleton;
  SafeProxyFactory public proxyFactory;
  ISafe public smartAccount;
  ISafe public ownedSafe;
  MockUSDC public usdc;
  MockTarget public target;

  address public forwarderOwner = makeAddr("forwarderOwner");
  address public guardian = makeAddr("guardian");
  address public stranger = makeAddr("stranger");

  uint256 public hotWallet1Key = 0xA11CE;
  uint256 public hotWallet2Key = 0xB0B;
  uint256 public rotatedWalletKey = 0xCA57;
  uint256 public safeOwnerKey = 1;
  address public hotWallet1;
  address public hotWallet2;
  address public rotatedWallet;
  address public safeOwner;

  function setUp() public {
    hotWallet1 = vm.addr(hotWallet1Key);
    hotWallet2 = vm.addr(hotWallet2Key);
    rotatedWallet = vm.addr(rotatedWalletKey);
    safeOwner = vm.addr(safeOwnerKey);

    usdc = new MockUSDC();
    target = new MockTarget();
    trustedCallsModule = new TrustedCalls(guardian, makeAddr("recoveryAddress"));

    forwarder = new Forwarder(address(usdc), forwarderOwner);
    vm.prank(forwarderOwner);
    forwarder.setAuthorizedSenders(_senders(hotWallet1, hotWallet2));

    // Deploy Safe infrastructure
    // TODO: We can't use `new Safe()` until we figure out to compile Safe without stack too deep error
    // so we use deployment from contract creation code as a workaround
    safeSingleton = ISafe(DeploySafeSingleton.deployFromCreationCode());
    proxyFactory = new SafeProxyFactory();

    // Smart account (delegate path): EOA-owned Safe with the TrustedCalls module
    // and the forwarder registered as delegate.
    smartAccount = _deploySafe(safeOwner, 100);
    _enableModule(smartAccount, safeOwnerKey, address(trustedCallsModule));
    vm.startPrank(guardian);
    trustedCallsModule.addDelegate(address(smartAccount), address(forwarder));
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);
    vm.stopPrank();

    // Owner-slot path: Safe owned solely by the forwarder (threshold 1).
    ownedSafe = _deploySafe(address(forwarder), 200);
  }

  // ========== forward() delegate path ==========

  function testForwardExecutesTrustedCall() public {
    vm.prank(hotWallet1);
    forwarder.forward(address(trustedCallsModule), _executeTrustedCallData(42));

    assertEq(target.value(), 42);
    assertEq(target.lastCaller(), address(smartAccount));
  }

  function testForwardConcurrentSendersShareNoNonce() public {
    vm.prank(hotWallet1);
    forwarder.forward(address(trustedCallsModule), _executeTrustedCallData(1));

    vm.prank(hotWallet2);
    forwarder.forward(address(trustedCallsModule), _executeTrustedCallData(2));

    assertEq(target.value(), 2);
  }

  function testMultiForwardBatchesCalls() public {
    address[] memory targets = new address[](2);
    bytes[] memory datas = new bytes[](2);
    targets[0] = address(trustedCallsModule);
    targets[1] = address(trustedCallsModule);
    datas[0] = _executeTrustedCallData(7);
    datas[1] = _executeTrustedCallData(8);

    vm.prank(hotWallet1);
    forwarder.multiForward(targets, datas);

    assertEq(target.value(), 8);
  }

  function testForwardRevertsForUnauthorizedSender() public {
    vm.prank(stranger);
    vm.expectRevert("Not authorized sender");
    forwarder.forward(address(trustedCallsModule), _executeTrustedCallData(42));
  }

  function testForwardBubblesRevertReason() public {
    bytes memory untrustedCall = abi.encodeCall(
      ITrustedCalls.executeTrustedCall,
      (address(smartAccount), address(target), abi.encodeWithSignature("unknownFunction()"))
    );

    vm.prank(hotWallet1);
    vm.expectRevert(ITrustedCalls.CallNotTrusted.selector);
    forwarder.forward(address(trustedCallsModule), untrustedCall);
  }

  function testForwardRevertsForTokenTarget() public {
    vm.prank(hotWallet1);
    vm.expectRevert("Cannot forward to Link token");
    forwarder.forward(address(usdc), abi.encodeWithSignature("transfer(address,uint256)", stranger, 1));
  }

  function testForwardRevertsForNonContractTarget() public {
    vm.prank(hotWallet1);
    vm.expectRevert("Must forward to a contract");
    forwarder.forward(stranger, hex"deadbeef");
  }

  // ========== sender rotation ==========

  function testSetAuthorizedSendersRotatesAtomically() public {
    vm.prank(forwarderOwner);
    forwarder.setAuthorizedSenders(_senders(rotatedWallet, address(0)));

    assertTrue(forwarder.isAuthorizedSender(rotatedWallet));
    assertFalse(forwarder.isAuthorizedSender(hotWallet1));
    assertFalse(forwarder.isAuthorizedSender(hotWallet2));

    vm.prank(hotWallet1);
    vm.expectRevert("Not authorized sender");
    forwarder.forward(address(trustedCallsModule), _executeTrustedCallData(42));
  }

  function testSetAuthorizedSendersOnlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert("Cannot set authorized senders");
    forwarder.setAuthorizedSenders(_senders(stranger, address(0)));
  }

  // ========== Safe owner slot: forwarded execTransaction (single tx) ==========

  function testOwnerSlotForwardedExecTransaction() public {
    bytes memory callData = abi.encodeCall(MockTarget.setValue, (77));

    // The Safe sees the owner Forwarder as msg.sender, an implicit v=1 approval
    vm.prank(hotWallet1);
    forwarder.forward(address(ownedSafe), _execSafeTxData(address(target), callData));

    assertEq(target.value(), 77);
    assertEq(target.lastCaller(), address(ownedSafe));
  }

  function testOwnerSlotForwardedExecTransactionRejectsUnauthorizedSender() public {
    bytes memory callData = abi.encodeCall(MockTarget.setValue, (77));

    vm.prank(stranger);
    vm.expectRevert("Not authorized sender");
    forwarder.forward(address(ownedSafe), _execSafeTxData(address(target), callData));
  }

  function testOwnerSlotForwardedExecTransactionRejectedAfterRotation() public {
    bytes memory callData = abi.encodeCall(MockTarget.setValue, (77));

    vm.prank(forwarderOwner);
    forwarder.setAuthorizedSenders(_senders(rotatedWallet, address(0)));

    vm.prank(hotWallet1);
    vm.expectRevert("Not authorized sender");
    forwarder.forward(address(ownedSafe), _execSafeTxData(address(target), callData));
  }

  // ========== Safe owner slot: approved hash path ==========

  function testOwnerSlotApprovedHash() public {
    bytes memory callData = abi.encodeCall(MockTarget.setValue, (88));
    bytes32 txHash = _safeTxHash(ownedSafe, address(target), callData);

    // Hot wallet pre-approves the hash through the forwarder (the Safe owner)
    vm.prank(hotWallet1);
    forwarder.forward(address(ownedSafe), abi.encodeCall(ISafe.approveHash, (txHash)));

    // v=1 approved-hash signature; r encodes the approving owner
    bytes memory signatures = abi.encodePacked(bytes32(uint256(uint160(address(forwarder)))), bytes32(0), uint8(1));
    vm.prank(stranger);
    _execSafeTx(ownedSafe, address(target), callData, signatures);

    assertEq(target.value(), 88);
    assertEq(target.lastCaller(), address(ownedSafe));
  }

  function testOwnerSlotApprovedHashRejectsUnapprovedHash() public {
    bytes memory callData = abi.encodeCall(MockTarget.setValue, (88));

    bytes memory signatures = abi.encodePacked(bytes32(uint256(uint160(address(forwarder)))), bytes32(0), uint8(1));
    vm.prank(stranger);
    vm.expectRevert("GS025");
    _execSafeTx(ownedSafe, address(target), callData, signatures);
  }

  // ========== Helpers ==========

  /// @dev Builds a 1- or 2-element sender array (second element skipped when zero).
  function _senders(address first, address second) internal pure returns (address[] memory senders) {
    if (second == address(0)) {
      senders = new address[](1);
      senders[0] = first;
    } else {
      senders = new address[](2);
      senders[0] = first;
      senders[1] = second;
    }
  }

  /// @dev Deploys a threshold-1 Safe owned by `owner` with a unique salt.
  function _deploySafe(address owner, uint256 salt) internal returns (ISafe deployedSafe) {
    address[] memory owners = new address[](1);
    owners[0] = owner;
    bytes memory initializer = abi.encodeWithSelector(
      ISafe.setup.selector,
      owners,
      1, // threshold
      address(0), // to
      new bytes(0), // data
      address(0), // fallbackHandler
      address(0), // paymentToken
      0, // payment
      address(0) // paymentReceiver
    );
    SafeProxy proxy = proxyFactory.createProxyWithNonce(address(safeSingleton), initializer, salt);
    deployedSafe = ISafe(payable(address(proxy)));
  }

  /// @dev Enables `module` on `targetSafe` via an owner-signed execTransaction.
  function _enableModule(ISafe targetSafe, uint256 ownerKey, address module) internal {
    bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", module);
    bytes32 txHash = _safeTxHash(targetSafe, address(targetSafe), enableModuleData);
    (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(ownerKey, txHash);
    _execSafeTx(targetSafe, address(targetSafe), enableModuleData, abi.encodePacked(sigR, sigS, sigV));
  }

  /// @dev Calldata for a trusted setValue call on the smart account.
  function _executeTrustedCallData(uint256 newValue) internal view returns (bytes memory) {
    return
      abi.encodeCall(
        ITrustedCalls.executeTrustedCall,
        (address(smartAccount), address(target), abi.encodeCall(MockTarget.setValue, (newValue)))
      );
  }

  /// @dev Safe transaction hash for a zero-value call with default gas params.
  function _safeTxHash(ISafe targetSafe, address to, bytes memory data) internal view returns (bytes32) {
    return
      targetSafe.getTransactionHash(
        to,
        0,
        data,
        Enum.Operation.Call,
        0,
        0,
        0,
        address(0),
        address(0),
        targetSafe.nonce()
      );
  }

  /// @dev Executes a zero-value Safe transaction with the given signatures blob.
  function _execSafeTx(ISafe targetSafe, address to, bytes memory data, bytes memory signatures) internal {
    targetSafe.execTransaction(to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(0), signatures);
  }

  /// @dev execTransaction calldata for a zero-value call, confirmed by a v=1 signature
  ///      naming the forwarder as the approving owner.
  function _execSafeTxData(address to, bytes memory data) internal view returns (bytes memory) {
    bytes memory signatures = abi.encodePacked(bytes32(uint256(uint160(address(forwarder)))), bytes32(0), uint8(1));
    return
      abi.encodeCall(
        ISafe.execTransaction,
        (to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signatures)
      );
  }
}
