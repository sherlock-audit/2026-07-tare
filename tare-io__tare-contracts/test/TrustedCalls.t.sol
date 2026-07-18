// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {TrustedCalls} from "../contracts/TrustedCalls.sol";
import {ITrustedCalls} from "../contracts/interfaces/ITrustedCalls.sol";
import {Enum} from "safe-smart-account/common/Enum.sol";
import {RescueTokensTestBase} from "./helpers/RescueTokensTestBase.sol";
import {ISafe} from "../contracts/misc/interfaces/ISafe.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeProxy} from "../lib/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "../lib/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DeploySafeSingleton} from "./helpers/DeploySafeSingleton.sol";

// Mock target contract for testing
contract MockTarget {
  uint256 public value;
  address public lastCaller;

  event ValueSet(uint256 newValue);
  event Pinged();

  function setValue(uint256 _value) external {
    value = _value;
    lastCaller = msg.sender;
    emit ValueSet(_value);
  }

  function getValue() external view returns (uint256) {
    return value;
  }

  function ping() external {
    emit Pinged();
  }

  function restrictedFunction() external pure {
    // Function that should not be trusted
  }
}

contract TrustedCallsTest is Test, RescueTokensTestBase {
  TrustedCalls public trustedCallsModule;
  ISafe public safeSingleton;
  SafeProxyFactory public proxyFactory;
  ISafe public safe;
  MockTarget public target;

  address public admin = address(0x1);
  address public delegate1 = address(0x2);
  address public delegate2 = address(0x3);
  address public guardian = address(0x4);

  // Use vm.addr to generate addresses from known private keys
  uint256 owner1PrivKey = 1;
  uint256 owner2PrivKey = 2;
  address public owner1;
  address public owner2;
  address public nonDelegate = address(0x6);

  bytes4 public constant SET_VALUE_SELECTOR = bytes4(keccak256("setValue(uint256)"));
  bytes4 public constant GET_VALUE_SELECTOR = bytes4(keccak256("getValue()"));
  bytes4 public constant PING_SELECTOR = bytes4(keccak256("ping()"));
  bytes4 public constant RESTRICTED_SELECTOR = bytes4(keccak256("restrictedFunction()"));

  bytes32 internal guardianRole;

  event TrustedCallAdded(address indexed target, bytes4 selector);
  event TrustedCallRemoved(address indexed target, bytes4 selector);
  event DelegateAdded(address indexed safe, address indexed delegate);
  event DelegateRemoved(address indexed safe, address indexed delegate);
  event Paused(address account);
  event Unpaused(address account);

  function setUp() public {
    // Generate owner addresses from private keys
    owner1 = vm.addr(owner1PrivKey);
    owner2 = vm.addr(owner2PrivKey);

    // Deploy TrustedCalls module
    trustedCallsModule = new TrustedCalls(guardian, _recoveryAddress);
    guardianRole = trustedCallsModule.GUARDIAN_ROLE();

    // setup admin
    bytes32 adminRole = trustedCallsModule.ADMIN_ROLE();
    vm.prank(guardian);
    trustedCallsModule.grantRole(adminRole, admin);

    // Deploy Safe infrastructure
    // TODO: We can't use `new Safe()` until we figure out to compile Safe without stack too deep error
    // so we use deployment from contract creation code as a workaround
    safeSingleton = ISafe(DeploySafeSingleton.deployFromCreationCode());
    proxyFactory = new SafeProxyFactory();

    // Deploy a Safe
    address[] memory owners = new address[](2);
    owners[0] = owner1;
    owners[1] = owner2;

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

    SafeProxy proxy = proxyFactory.createProxyWithNonce(address(safeSingleton), initializer, 0);
    safe = ISafe(payable(address(proxy)));

    // Enable module on Safe (must be done through execTransaction)
    bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", address(trustedCallsModule));

    // Create the transaction hash for signature
    bytes32 txHash = safe.getTransactionHash(
      address(safe), // to
      0, // value
      enableModuleData, // data
      Enum.Operation.Call,
      0, // safeTxGas
      0, // baseGas
      0, // gasPrice
      address(0), // gasToken
      address(0), // refundReceiver
      safe.nonce() // nonce
    );

    // Owner1 signs the transaction
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1PrivKey, txHash);
    bytes memory signature = abi.encodePacked(r, s, v);

    // Execute transaction to enable module
    safe.execTransaction(
      address(safe),
      0,
      enableModuleData,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(0),
      signature
    );

    // Deploy mock target
    target = new MockTarget();
  }

  // ========== Auth Functions Tests ==========

  function testAddTrustedCall() public {
    vm.prank(guardian);
    vm.expectEmit(true, true, false, true);
    emit TrustedCallAdded(address(target), SET_VALUE_SELECTOR);
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);

    assertTrue(trustedCallsModule.isTrustedCall(address(target), SET_VALUE_SELECTOR));
  }

  function testAddTrustedCallUnauthorized() public {
    vm.prank(nonDelegate);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonDelegate, guardianRole)
    );
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);
  }

  function testRemoveTrustedCall() public {
    // Add trusted call first
    vm.prank(guardian);
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);
    assertTrue(trustedCallsModule.isTrustedCall(address(target), SET_VALUE_SELECTOR));

    // Remove it
    vm.prank(admin);
    vm.expectEmit(true, true, false, true);
    emit TrustedCallRemoved(address(target), SET_VALUE_SELECTOR);
    trustedCallsModule.removeTrustedCall(address(target), SET_VALUE_SELECTOR);

    assertFalse(trustedCallsModule.isTrustedCall(address(target), SET_VALUE_SELECTOR));
  }

  function testAddTrustedCallsBatch() public {
    address[] memory targets = new address[](3);
    bytes4[] memory selectors = new bytes4[](3);
    targets[0] = address(target);
    targets[1] = address(target);
    targets[2] = address(target);
    selectors[0] = SET_VALUE_SELECTOR;
    selectors[1] = PING_SELECTOR;
    selectors[2] = GET_VALUE_SELECTOR;

    vm.prank(guardian);
    trustedCallsModule.addTrustedCalls(targets, selectors);

    assertTrue(trustedCallsModule.isTrustedCall(address(target), SET_VALUE_SELECTOR));
    assertTrue(trustedCallsModule.isTrustedCall(address(target), PING_SELECTOR));
    assertTrue(trustedCallsModule.isTrustedCall(address(target), GET_VALUE_SELECTOR));
  }

  function testAddTrustedCallsBatchEmitsEvents() public {
    address[] memory targets = new address[](2);
    bytes4[] memory selectors = new bytes4[](2);
    targets[0] = address(target);
    targets[1] = address(target);
    selectors[0] = SET_VALUE_SELECTOR;
    selectors[1] = PING_SELECTOR;

    vm.expectEmit(true, true, false, true);
    emit TrustedCallAdded(address(target), SET_VALUE_SELECTOR);
    vm.expectEmit(true, true, false, true);
    emit TrustedCallAdded(address(target), PING_SELECTOR);

    vm.prank(guardian);
    trustedCallsModule.addTrustedCalls(targets, selectors);
  }

  function testAddTrustedCallsBatchRevertsLengthMismatch() public {
    address[] memory targets = new address[](2);
    bytes4[] memory selectors = new bytes4[](1);
    targets[0] = address(target);
    targets[1] = address(target);
    selectors[0] = SET_VALUE_SELECTOR;

    vm.prank(guardian);
    vm.expectRevert(ITrustedCalls.LengthMismatch.selector);
    trustedCallsModule.addTrustedCalls(targets, selectors);
  }

  function testAddTrustedCallsBatchRevertsEmptyBatch() public {
    address[] memory targets = new address[](0);
    bytes4[] memory selectors = new bytes4[](0);

    vm.prank(guardian);
    vm.expectRevert(ITrustedCalls.EmptyBatch.selector);
    trustedCallsModule.addTrustedCalls(targets, selectors);
  }

  function testAddTrustedCallsBatchRevertsInvalidSelector() public {
    address[] memory targets = new address[](2);
    bytes4[] memory selectors = new bytes4[](2);
    targets[0] = address(target);
    targets[1] = address(target);
    selectors[0] = SET_VALUE_SELECTOR;
    selectors[1] = bytes4(0);

    vm.prank(guardian);
    vm.expectRevert(ITrustedCalls.InvalidSelector.selector);
    trustedCallsModule.addTrustedCalls(targets, selectors);
  }

  function testAddTrustedCallsBatchRevertsUnauthorized() public {
    address[] memory targets = new address[](1);
    bytes4[] memory selectors = new bytes4[](1);
    targets[0] = address(target);
    selectors[0] = SET_VALUE_SELECTOR;

    vm.prank(nonDelegate);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonDelegate, guardianRole)
    );
    trustedCallsModule.addTrustedCalls(targets, selectors);
  }

  function testPause() public {
    assertFalse(trustedCallsModule.paused());

    vm.prank(admin);
    vm.expectEmit(true, false, false, true);
    emit Paused(admin);
    trustedCallsModule.pause();

    assertTrue(trustedCallsModule.paused());
  }

  function testUnpause() public {
    vm.prank(admin);
    trustedCallsModule.pause();
    assertTrue(trustedCallsModule.paused());

    vm.prank(guardian);
    vm.expectEmit(true, false, false, true);
    emit Unpaused(guardian);
    trustedCallsModule.unpause();

    assertFalse(trustedCallsModule.paused());
  }

  // ========== Safe Functions Tests ==========

  function testAddDelegateBySafe() public {
    // Safe adds delegate
    vm.prank(address(safe));
    vm.expectEmit(true, true, false, true);
    emit DelegateAdded(address(safe), delegate1);
    trustedCallsModule.addDelegate(address(safe), delegate1);

    assertTrue(trustedCallsModule.isDelegate(address(safe), delegate1));
  }

  function testAddDelegateByGuardian() public {
    // Guardian adds delegate
    vm.prank(guardian);
    vm.expectEmit(true, true, false, true);
    emit DelegateAdded(address(safe), delegate1);
    trustedCallsModule.addDelegate(address(safe), delegate1);

    assertTrue(trustedCallsModule.isDelegate(address(safe), delegate1));
  }

  function testAddDelegateByAdminReverts() public {
    // Admin (non-guardian) cannot add delegate — restricted to safeOrGuardian
    vm.prank(admin);
    vm.expectRevert(ITrustedCalls.UnauthorizedCaller.selector);
    trustedCallsModule.addDelegate(address(safe), delegate1);
  }

  function testAddDelegateUnauthorized() public {
    vm.prank(nonDelegate);
    vm.expectRevert(ITrustedCalls.UnauthorizedCaller.selector);
    trustedCallsModule.addDelegate(address(safe), delegate1);
  }

  function testRemoveDelegateByAdmin() public {
    // Admin can still remove delegates (defensive action)
    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);
    assertTrue(trustedCallsModule.isDelegate(address(safe), delegate1));

    vm.prank(admin);
    trustedCallsModule.removeDelegate(address(safe), delegate1);
    assertFalse(trustedCallsModule.isDelegate(address(safe), delegate1));
  }

  function testRemoveDelegate() public {
    // Add delegate first
    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);
    assertTrue(trustedCallsModule.isDelegate(address(safe), delegate1));

    // Remove delegate
    vm.prank(address(safe));
    vm.expectEmit(true, true, false, true);
    emit DelegateRemoved(address(safe), delegate1);
    trustedCallsModule.removeDelegate(address(safe), delegate1);

    assertFalse(trustedCallsModule.isDelegate(address(safe), delegate1));
  }

  // ========== Execute Trusted Call Tests ==========

  function testExecuteTrustedCall() public {
    // Setup: Add trusted call and delegate
    vm.prank(guardian);
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);

    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);

    // Execute trusted call
    bytes memory data = abi.encodeWithSelector(SET_VALUE_SELECTOR, 42);

    vm.prank(delegate1);
    (bool success, ) = trustedCallsModule.executeTrustedCall(address(safe), address(target), data);

    assertTrue(success);
    assertEq(target.value(), 42);
    assertEq(target.lastCaller(), address(safe)); // Call executed from Safe
  }

  function testExecuteTrustedCallWhilePaused() public {
    // Setup
    vm.prank(guardian);
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);

    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);

    // Pause
    vm.prank(admin);
    trustedCallsModule.pause();

    // Try to execute
    bytes memory data = abi.encodeWithSelector(SET_VALUE_SELECTOR, 42);

    vm.prank(delegate1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    trustedCallsModule.executeTrustedCall(address(safe), address(target), data);
  }

  function testExecuteTrustedCallNotDelegate() public {
    // Setup: Add trusted call but not delegate
    vm.prank(guardian);
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);

    // Try to execute
    bytes memory data = abi.encodeWithSelector(SET_VALUE_SELECTOR, 42);

    vm.prank(nonDelegate);
    vm.expectRevert(ITrustedCalls.NotADelegate.selector);
    trustedCallsModule.executeTrustedCall(address(safe), address(target), data);
  }

  function testExecuteTrustedCallNotTrusted() public {
    // Setup: Add delegate but not trusted call
    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);

    // Try to execute non-trusted function
    bytes memory data = abi.encodeWithSelector(RESTRICTED_SELECTOR);

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.CallNotTrusted.selector);
    trustedCallsModule.executeTrustedCall(address(safe), address(target), data);
  }

  function testExecuteTrustedCallInvalidSelector() public {
    // Setup
    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);

    // Try to execute with invalid data (less than 4 bytes)
    bytes memory data = hex"1234"; // Only 2 bytes

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.InvalidSelector.selector);
    trustedCallsModule.executeTrustedCall(address(safe), address(target), data);
  }

  // ========== View Functions Tests ==========

  function testIsTrustedCall() public {
    assertFalse(trustedCallsModule.isTrustedCall(address(target), SET_VALUE_SELECTOR));

    vm.prank(guardian);
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);

    assertTrue(trustedCallsModule.isTrustedCall(address(target), SET_VALUE_SELECTOR));
    assertFalse(trustedCallsModule.isTrustedCall(address(target), RESTRICTED_SELECTOR));
  }

  function testIsDelegate() public {
    assertFalse(trustedCallsModule.isDelegate(address(safe), delegate1));

    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);

    assertTrue(trustedCallsModule.isDelegate(address(safe), delegate1));
    assertFalse(trustedCallsModule.isDelegate(address(safe), delegate2));
  }

  function testGetTrustKey() public view {
    bytes32 expectedKey = keccak256(abi.encodePacked(address(target), SET_VALUE_SELECTOR));
    bytes32 actualKey = trustedCallsModule.getTrustKey(address(target), SET_VALUE_SELECTOR);

    assertEq(actualKey, expectedKey);
  }

  // ========== Integration Tests ==========

  function testMultipleDelegatesMultipleSafes() public {
    // Deploy second Safe
    address[] memory owners = new address[](1);
    owners[0] = owner2;

    bytes memory initializer = abi.encodeWithSelector(
      ISafe.setup.selector,
      owners,
      1,
      address(0),
      new bytes(0),
      address(0),
      address(0),
      0,
      address(0)
    );

    SafeProxy proxy2 = proxyFactory.createProxyWithNonce(address(safeSingleton), initializer, 1);
    ISafe safe2 = ISafe(payable(address(proxy2)));

    // Enable module on safe2 (must be done through execTransaction)
    bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", address(trustedCallsModule));

    bytes32 txHash = safe2.getTransactionHash(
      address(safe2),
      0,
      enableModuleData,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      address(0),
      safe2.nonce()
    );

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner2PrivKey, txHash);
    bytes memory signature = abi.encodePacked(r, s, v);

    safe2.execTransaction(
      address(safe2),
      0,
      enableModuleData,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(0),
      signature
    );

    // Add trusted call (shared across all safes)
    vm.prank(guardian);
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);

    // Add different delegates for each safe
    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);

    vm.prank(address(safe2));
    trustedCallsModule.addDelegate(address(safe2), delegate2);

    // Verify delegates are safe-specific
    assertTrue(trustedCallsModule.isDelegate(address(safe), delegate1));
    assertFalse(trustedCallsModule.isDelegate(address(safe), delegate2));
    assertFalse(trustedCallsModule.isDelegate(address(safe2), delegate1));
    assertTrue(trustedCallsModule.isDelegate(address(safe2), delegate2));

    // Both delegates can execute the same trusted call for their respective safes
    bytes memory data = abi.encodeWithSelector(SET_VALUE_SELECTOR, 100);

    vm.prank(delegate1);
    (bool success1, ) = trustedCallsModule.executeTrustedCall(address(safe), address(target), data);
    assertTrue(success1);

    data = abi.encodeWithSelector(SET_VALUE_SELECTOR, 200);
    vm.prank(delegate2);
    (bool success2, ) = trustedCallsModule.executeTrustedCall(address(safe2), address(target), data);
    assertTrue(success2);
  }

  function testCanStillManageWhilePaused() public {
    // Add trusted call before pausing
    vm.prank(guardian);
    trustedCallsModule.addTrustedCall(address(target), PING_SELECTOR);
    assertTrue(trustedCallsModule.isTrustedCall(address(target), PING_SELECTOR));

    // Pause the module
    vm.prank(admin);
    trustedCallsModule.pause();

    // Safe can still add delegates
    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);
    assertTrue(trustedCallsModule.isDelegate(address(safe), delegate1));

    // Guardian can still remove trusted calls
    vm.prank(guardian);
    trustedCallsModule.removeTrustedCall(address(target), PING_SELECTOR);
    assertFalse(trustedCallsModule.isTrustedCall(address(target), PING_SELECTOR));
  }

  function testAddTrustedCall_RevertsWhenPaused() public {
    vm.prank(admin);
    trustedCallsModule.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    trustedCallsModule.addTrustedCall(address(target), PING_SELECTOR);
  }

  function testAddTrustedCalls_RevertsWhenPaused() public {
    vm.prank(admin);
    trustedCallsModule.pause();

    address[] memory targets = new address[](1);
    targets[0] = address(target);
    bytes4[] memory selectors = new bytes4[](1);
    selectors[0] = PING_SELECTOR;

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    trustedCallsModule.addTrustedCalls(targets, selectors);
  }

  function test_rescueERC20Tokens_Success() public {
    _testRescueERC20TokensSuccess(address(trustedCallsModule), guardian);
  }

  function test_rescueERC20Tokens_RevertsIfNotGuardian() public {
    _testRescueERC20TokensRevertsIfNotGuardian(address(trustedCallsModule), nonDelegate, guardianRole);
  }

  function test_rescueERC20Tokens_ZeroBalance() public {
    _testRescueERC20TokensZeroBalance(address(trustedCallsModule), guardian);
  }

  function test_rescueERC20Tokens_RevertsIfAdminNotGuardian() public {
    _testRescueERC20TokensRevertsIfAdminNotGuardian(address(trustedCallsModule), admin, guardianRole);
  }

  function test_rescueERC20Tokens_PartialAmount() public {
    _testRescueERC20TokensPartialAmount(address(trustedCallsModule), guardian);
  }

  function test_rescueERC20Tokens_ExceedsBalance() public {
    _testRescueERC20TokensExceedsBalance(address(trustedCallsModule), guardian);
  }

  function test_rescueERC20Tokens_ZeroAmount() public {
    _testRescueERC20TokensZeroAmount(address(trustedCallsModule), guardian);
  }

  function test_rescueERC20Tokens_MultipleRescues() public {
    _testRescueERC20TokensMultipleRescues(address(trustedCallsModule), guardian);
  }

  function test_rescueERC721Tokens_Success() public {
    _testRescueERC721TokensSuccess(address(trustedCallsModule), guardian);
  }

  function test_rescueERC721Tokens_RevertsIfNotGuardian() public {
    _testRescueERC721TokensRevertsIfNotGuardian(address(trustedCallsModule), nonDelegate, guardianRole);
  }

  function test_rescueERC721Tokens_RevertsIfAdminNotGuardian() public {
    _testRescueERC721TokensRevertsIfAdminNotGuardian(address(trustedCallsModule), admin, guardianRole);
  }

  function test_rescueERC721Tokens_Multiple() public {
    _testRescueERC721TokensMultiple(address(trustedCallsModule), guardian);
  }

  function test_setRecoveryAddress_Success() public {
    _testSetRecoveryAddressSuccess(address(trustedCallsModule), guardian);
  }

  function test_setRecoveryAddress_RevertsIfNotGuardian() public {
    _testSetRecoveryAddressRevertsIfNotGuardian(address(trustedCallsModule), nonDelegate, guardianRole);
  }

  function test_setRecoveryAddress_RevertsIfZeroAddress() public {
    _testSetRecoveryAddressRevertsIfZeroAddress(address(trustedCallsModule), guardian);
  }

  function test_rescueERC20Tokens_RevertsWhenPaused() public {
    vm.prank(admin);
    trustedCallsModule.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    trustedCallsModule.rescueERC20Tokens(address(1), 1);
  }

  function test_rescueERC721Tokens_RevertsWhenPaused() public {
    vm.prank(admin);
    trustedCallsModule.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    trustedCallsModule.rescueERC721Tokens(address(1), 1);
  }

  // ========== Execute Trusted Call Batch Tests ==========

  function _setupBatch() internal {
    vm.startPrank(guardian);
    trustedCallsModule.addTrustedCall(address(target), SET_VALUE_SELECTOR);
    trustedCallsModule.addTrustedCall(address(target), PING_SELECTOR);
    vm.stopPrank();

    vm.prank(address(safe));
    trustedCallsModule.addDelegate(address(safe), delegate1);
  }

  function testExecuteBatch_success() public {
    _setupBatch();

    address[] memory targets = new address[](2);
    targets[0] = address(target);
    targets[1] = address(target);

    bytes[] memory data = new bytes[](2);
    data[0] = abi.encodeWithSelector(SET_VALUE_SELECTOR, 42);
    data[1] = abi.encodeWithSelector(SET_VALUE_SELECTOR, 99);

    vm.prank(delegate1);
    bytes[] memory results = trustedCallsModule.executeTrustedCallBatch(address(safe), targets, data);

    assertEq(results.length, 2);
    assertEq(target.value(), 99);
    assertEq(target.lastCaller(), address(safe));
  }

  function testExecuteBatch_returnsData() public {
    _setupBatch();

    vm.prank(guardian);
    trustedCallsModule.addTrustedCall(address(target), GET_VALUE_SELECTOR);

    target.setValue(123);

    address[] memory targets = new address[](2);
    targets[0] = address(target);
    targets[1] = address(target);

    bytes[] memory data = new bytes[](2);
    data[0] = abi.encodeWithSelector(SET_VALUE_SELECTOR, 456);
    data[1] = abi.encodeWithSelector(GET_VALUE_SELECTOR);

    vm.prank(delegate1);
    bytes[] memory results = trustedCallsModule.executeTrustedCallBatch(address(safe), targets, data);

    uint256 returnedValue = abi.decode(results[1], (uint256));
    assertEq(returnedValue, 456);
  }

  function testExecuteBatch_revertsIfPaused() public {
    _setupBatch();

    vm.prank(admin);
    trustedCallsModule.pause();

    address[] memory targets = new address[](1);
    targets[0] = address(target);

    bytes[] memory data = new bytes[](1);
    data[0] = abi.encodeWithSelector(SET_VALUE_SELECTOR, 42);

    vm.prank(delegate1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    trustedCallsModule.executeTrustedCallBatch(address(safe), targets, data);
  }

  function testExecuteBatch_revertsIfNotDelegate() public {
    _setupBatch();

    address[] memory targets = new address[](1);
    targets[0] = address(target);

    bytes[] memory data = new bytes[](1);
    data[0] = abi.encodeWithSelector(SET_VALUE_SELECTOR, 42);

    vm.prank(nonDelegate);
    vm.expectRevert(ITrustedCalls.NotADelegate.selector);
    trustedCallsModule.executeTrustedCallBatch(address(safe), targets, data);
  }

  function testExecuteBatch_revertsIfCallNotTrusted() public {
    _setupBatch();

    address[] memory targets = new address[](2);
    targets[0] = address(target);
    targets[1] = address(target);

    bytes[] memory data = new bytes[](2);
    data[0] = abi.encodeWithSelector(SET_VALUE_SELECTOR, 42);
    data[1] = abi.encodeWithSelector(RESTRICTED_SELECTOR);

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.CallNotTrusted.selector);
    trustedCallsModule.executeTrustedCallBatch(address(safe), targets, data);

    assertEq(target.value(), 0);
  }

  function testExecuteBatch_revertsIfEmpty() public {
    _setupBatch();

    address[] memory targets = new address[](0);
    bytes[] memory data = new bytes[](0);

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.EmptyBatch.selector);
    trustedCallsModule.executeTrustedCallBatch(address(safe), targets, data);
  }

  function testExecuteBatch_revertsIfLengthMismatch() public {
    _setupBatch();

    address[] memory targets = new address[](2);
    targets[0] = address(target);
    targets[1] = address(target);

    bytes[] memory data = new bytes[](1);
    data[0] = abi.encodeWithSelector(SET_VALUE_SELECTOR, 42);

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.LengthMismatch.selector);
    trustedCallsModule.executeTrustedCallBatch(address(safe), targets, data);
  }

  function testExecuteBatch_revertsIfInvalidSelector() public {
    _setupBatch();

    address[] memory targets = new address[](1);
    targets[0] = address(target);

    bytes[] memory data = new bytes[](1);
    data[0] = hex"1234";

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.InvalidSelector.selector);
    trustedCallsModule.executeTrustedCallBatch(address(safe), targets, data);
  }
}
