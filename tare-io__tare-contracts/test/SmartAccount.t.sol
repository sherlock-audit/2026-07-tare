// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SmartAccountFactory} from "../contracts/SmartAccountFactory.sol";
import {ISmartAccountFactory} from "../contracts/interfaces/ISmartAccountFactory.sol";
import {TrustedCalls} from "../contracts/TrustedCalls.sol";
import {ITrustedCalls} from "../contracts/interfaces/ITrustedCalls.sol";
import {TrustedSpender} from "../contracts/TrustedSpender.sol";
import {ITrustedSpender} from "../contracts/interfaces/ITrustedSpender.sol";
import {Enum} from "../lib/safe-smart-account/contracts/common/Enum.sol";
import {ISafe} from "../contracts/misc/interfaces/ISafe.sol";
import {SafeProxyFactory} from "../lib/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {MockUSDC} from "./mocks/USDC.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {console} from "forge-std/console.sol";
import {DeploySafeSingleton} from "./helpers/DeploySafeSingleton.sol";
import {AddressArrays} from "./helpers/AddressArrays.sol";

// Mock target contract for testing TrustedCalls
contract MockTarget {
  uint256 public value;
  address public lastCaller;

  event ValueSet(uint256 newValue, address caller);
  event AdminAction(address admin);

  function setValue(uint256 _value) external {
    value = _value;
    lastCaller = msg.sender;
    emit ValueSet(_value, msg.sender);
  }

  function adminFunction() external {
    emit AdminAction(msg.sender);
  }

  function restrictedFunction() external pure returns (string memory) {
    return "This should not be callable via TrustedCalls";
  }
}

/**
 * @title SmartAccountTest
 * @notice Combined test suite for Smart Account system including factory deployment and functionality
 */
contract SmartAccountTest is Test {
  // Core contracts
  SmartAccountFactory public factory;
  SafeProxyFactory public safeProxyFactory;
  ISafe public safeSingleton;
  TrustedCalls public trustedCallsModule;
  TrustedSpender public trustedSpender;

  // Mock contracts
  MockUSDC public usdc;
  MockUSDC public dai;
  MockTarget public target;

  // Test actors
  address public owner1;
  uint256 public owner1Key = 1;
  address public owner2;
  uint256 public owner2Key = 2;
  address public owner3 = makeAddr("owner3");
  address public delegate1 = makeAddr("delegate1");
  address public delegate2 = makeAddr("delegate2");
  address public trustedRecipient1 = makeAddr("trustedRecipient1");
  address public trustedRecipient2 = makeAddr("trustedRecipient2");
  address public untrustedRecipient = makeAddr("untrustedRecipient");
  address public nonDelegate = makeAddr("nonDelegate");

  // Deployed Smart Account for functional tests
  address public smartAccount;

  // Events
  event SmartAccountDeployed(address indexed account, address indexed deployer, address[] owners, uint256 threshold);
  event Transfer(address indexed from, address indexed to, uint256 value);

  function setUp() public {
    // Setup signers with private keys for multisig tests
    owner1 = vm.addr(owner1Key);
    owner2 = vm.addr(owner2Key);

    // Deploy Safe infrastructure
    // TODO: We can't use `new Safe()` until we figure out to compile Safe without stack too deep error
    // so we use deployment from contract creation code as a workaround
    address safe = DeploySafeSingleton.deployFromCreationCode();
    console.log("Safe Singleton deployed at:", safe);
    safeSingleton = ISafe(payable(safe));
    safeProxyFactory = new SafeProxyFactory();

    // Deploy modules
    trustedCallsModule = new TrustedCalls(owner1, makeAddr("recoveryAddress"));
    trustedSpender = new TrustedSpender(owner1, makeAddr("recoveryAddress"));

    // Deploy mock tokens
    usdc = new MockUSDC();
    dai = new MockUSDC();

    // Deploy mock target contract
    target = new MockTarget();

    // Deploy factory
    factory = new SmartAccountFactory(
      address(safeProxyFactory),
      address(safeSingleton),
      address(trustedCallsModule),
      address(trustedSpender)
    );

    // Deploy a Smart Account for functional tests
    _deploySmartAccountForFunctionalTests();
  }

  function _deploySmartAccountForFunctionalTests() private {
    // Deploy Smart Account (2-of-2 multisig)
    smartAccount = factory.deploySmartAccount(
      AddressArrays.make(delegate1, delegate2),
      AddressArrays.make(address(usdc), address(dai)),
      AddressArrays.make(),
      AddressArrays.make(trustedRecipient1, trustedRecipient2),
      type(uint48).max,
      AddressArrays.make(owner1, owner2),
      2
    );

    // Fund the Safe with tokens for testing
    usdc.mint(smartAccount, 10000e6); // 10,000 USDC
    dai.mint(smartAccount, 10000e18); // 10,000 DAI

    // Add trusted functions to TrustedCalls module
    bytes4 setValueSelector = bytes4(keccak256("setValue(uint256)"));
    vm.prank(owner1);
    trustedCallsModule.addTrustedCall(address(target), setValueSelector);

    // Grant the Safe guardian access so it can manage trusted calls via multisig
    bytes32 guardianRole = trustedCallsModule.GUARDIAN_ROLE();
    vm.prank(owner1);
    trustedCallsModule.grantRole(guardianRole, smartAccount);
  }

  // ============================================
  // Factory Deployment Tests
  // ============================================

  function testDeploySmartAccount() public {
    // Deploy new Smart Account (different from setUp one)
    address newAccount = factory.deploySmartAccount(
      AddressArrays.make(delegate1, delegate2),
      AddressArrays.make(address(usdc), address(dai)),
      AddressArrays.make(),
      AddressArrays.make(trustedRecipient1, trustedRecipient2),
      type(uint48).max,
      AddressArrays.make(owner1, owner2),
      2
    );

    assertTrue(newAccount != address(0));
    assertTrue(newAccount != smartAccount); // Different from setUp account

    ISafe safe = ISafe(payable(newAccount));

    // Verify owners and threshold
    assertTrue(safe.isOwner(owner1));
    assertTrue(safe.isOwner(owner2));
    assertEq(safe.getThreshold(), 2);

    // Verify TrustedCalls module is enabled
    assertTrue(safe.isModuleEnabled(address(trustedCallsModule)));

    // Verify delegates are set for both TrustedCalls module and TrustedSpender
    assertTrue(trustedCallsModule.isDelegate(newAccount, delegate1));
    assertTrue(trustedCallsModule.isDelegate(newAccount, delegate2));
    assertTrue(trustedSpender.isDelegate(newAccount, delegate1));
    assertTrue(trustedSpender.isDelegate(newAccount, delegate2));

    // Verify token approvals for TrustedSpender
    assertEq(usdc.allowance(newAccount, address(trustedSpender)), type(uint256).max);
    assertEq(dai.allowance(newAccount, address(trustedSpender)), type(uint256).max);

    // Verify allowances for trusted recipients in TrustedSpender
    (uint256 usdcR1Amount, ) = trustedSpender.getAllowance(address(usdc), newAccount, trustedRecipient1);
    (uint256 usdcR2Amount, ) = trustedSpender.getAllowance(address(usdc), newAccount, trustedRecipient2);
    (uint256 daiR1Amount, ) = trustedSpender.getAllowance(address(dai), newAccount, trustedRecipient1);
    (uint256 daiR2Amount, ) = trustedSpender.getAllowance(address(dai), newAccount, trustedRecipient2);
    assertEq(usdcR1Amount, type(uint208).max);
    assertEq(usdcR2Amount, type(uint208).max);
    assertEq(daiR1Amount, type(uint208).max);
    assertEq(daiR2Amount, type(uint208).max);
  }

  function testDeploySmartAccountSingleOwner() public {
    address newAccount = factory.deploySmartAccount(
      AddressArrays.make(),
      AddressArrays.make(),
      AddressArrays.make(),
      AddressArrays.make(),
      type(uint48).max,
      AddressArrays.make(owner1),
      1
    );

    ISafe safe = ISafe(payable(newAccount));
    assertTrue(safe.isOwner(owner1));
    assertEq(safe.getThreshold(), 1);

    // Verify TrustedCalls module is still enabled even with empty config
    assertTrue(safe.isModuleEnabled(address(trustedCallsModule)));
  }

  function test_PredictSmartAccountAddress() public {
    address[] memory delegates = AddressArrays.make(delegate1, delegate2);
    address[] memory currencies = AddressArrays.make(address(usdc), address(dai));
    address[] memory nftCollections = AddressArrays.make();
    address[] memory trustedRecipients = AddressArrays.make(trustedRecipient1, trustedRecipient2);
    address[] memory owners = AddressArrays.make(owner1, owner2);

    address predicted = factory.predictSmartAccountAddress(
      address(this),
      1,
      delegates,
      currencies,
      nftCollections,
      trustedRecipients,
      type(uint48).max,
      owners,
      2
    );

    address deployed = factory.deploySmartAccount(
      delegates,
      currencies,
      nftCollections,
      trustedRecipients,
      type(uint48).max,
      owners,
      2
    );

    assertEq(predicted, deployed);
  }

  function test_PredictSmartAccountAddressSingleOwner() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1);

    address predicted = factory.predictSmartAccountAddress(
      address(this),
      1,
      empty,
      empty,
      empty,
      empty,
      type(uint48).max,
      owners,
      1
    );

    address deployed = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 1);

    assertEq(predicted, deployed);
  }

  function test_DeployMultipleAccountsForSameDeployer() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1, owner2);

    address account1 = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 1);
    address account2 = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 2);

    assertTrue(account1 != account2);
    assertTrue(account1 != smartAccount);
    assertTrue(account2 != smartAccount);
  }

  function test_IsDeployedSmartAccount() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1);

    // setUp account is registered; arbitrary addresses are not
    assertTrue(factory.isDeployedSmartAccount(smartAccount));
    assertFalse(factory.isDeployedSmartAccount(makeAddr("random")));
    assertFalse(factory.isDeployedSmartAccount(address(0)));

    // Predicted address is not registered until actually deployed
    address predicted = factory.predictSmartAccountAddress(
      address(this),
      factory.nonces(address(this)),
      empty,
      empty,
      empty,
      empty,
      type(uint48).max,
      owners,
      1
    );
    assertFalse(factory.isDeployedSmartAccount(predicted));

    address deployed = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 1);
    assertEq(deployed, predicted);
    assertTrue(factory.isDeployedSmartAccount(deployed));
  }

  function test_IsDeployedSmartAccount_MultipleDeployments() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1, owner2);

    address account1 = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 1);
    address account2 = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 2);

    assertTrue(factory.isDeployedSmartAccount(account1));
    assertTrue(factory.isDeployedSmartAccount(account2));
  }

  function test_PredictStableAcrossDeployers() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1);

    // Alice predicts her next address
    address alice = makeAddr("alice");
    uint256 aliceNonce = factory.nonces(alice);
    address predicted = factory.predictSmartAccountAddress(
      alice,
      aliceNonce,
      empty,
      empty,
      empty,
      empty,
      type(uint48).max,
      owners,
      1
    );

    // Bob deploys in between — should NOT shift Alice's address
    vm.prank(makeAddr("bob"));
    factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 1);

    // Alice deploys and gets the originally predicted address
    vm.prank(alice);
    address deployed = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 1);

    assertEq(predicted, deployed);
  }

  function testRevertNoOwners() public {
    address[] memory empty = AddressArrays.make();

    vm.expectRevert(ISmartAccountFactory.NoOwners.selector);
    factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, empty, 1);
  }

  function testRevertInvalidThreshold() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1, owner2);

    vm.expectRevert(ISmartAccountFactory.InvalidThreshold.selector);
    factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 0);
  }

  function testRevertThresholdTooHigh() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1, owner2);

    vm.expectRevert(ISmartAccountFactory.ThresholdTooHigh.selector);
    factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 3);
  }

  function test_DeploySmartAccount_Reverts_WhenValidUntilInPast() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1);

    vm.warp(1_000);

    vm.expectRevert(ISmartAccountFactory.InvalidAllowanceDeadline.selector);
    factory.deploySmartAccount(empty, empty, empty, empty, uint48(999), owners, 1);
  }

  function test_DeploySmartAccount_Reverts_WhenValidUntilEqualsBlockTimestamp() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1);

    vm.warp(1_000);

    vm.expectRevert(ISmartAccountFactory.InvalidAllowanceDeadline.selector);
    factory.deploySmartAccount(empty, empty, empty, empty, uint48(1_000), owners, 1);
  }

  function testEmitSmartAccountDeployedEvent() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1, owner2);

    vm.expectEmit(false, true, false, true);
    emit SmartAccountDeployed(address(0), address(this), owners, 2);

    factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 2);
  }

  function testDifferentDeployersGetDifferentAccounts() public {
    address[] memory empty = AddressArrays.make();
    address[] memory owners = AddressArrays.make(owner1);

    address account1 = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 1);

    vm.prank(owner2);
    address account2 = factory.deploySmartAccount(empty, empty, empty, empty, type(uint48).max, owners, 1);

    assertTrue(account1 != account2);
  }

  // ============================================
  // TrustedSpender Functionality Tests
  // ============================================

  function testDelegateCanWithdrawToTrustedAddress() public {
    uint256 withdrawAmount = 1000e6; // 1000 USDC
    uint256 initialBalance = usdc.balanceOf(trustedRecipient1);

    // Delegate withdraws USDC to trusted recipient
    vm.prank(delegate1);
    trustedSpender.executeTransfer(address(usdc), smartAccount, trustedRecipient1, withdrawAmount);

    // Verify transfer succeeded
    assertEq(usdc.balanceOf(trustedRecipient1), initialBalance + withdrawAmount);
    assertEq(usdc.balanceOf(smartAccount), 10000e6 - withdrawAmount);
  }

  function testDelegateCannotWithdrawToUntrustedAddress() public {
    uint256 withdrawAmount = 1000e6;

    // Attempt to withdraw to untrusted recipient should fail
    vm.prank(delegate1);
    vm.expectRevert(); // Will revert with arithmetic underflow due to no allowance
    trustedSpender.executeTransfer(address(usdc), smartAccount, untrustedRecipient, withdrawAmount);

    // Verify no transfer occurred
    assertEq(usdc.balanceOf(untrustedRecipient), 0);
    assertEq(usdc.balanceOf(smartAccount), 10000e6);
  }

  function testNonDelegateCannotWithdraw() public {
    uint256 withdrawAmount = 1000e6;

    // Non-delegate attempts to withdraw
    vm.prank(nonDelegate);
    vm.expectRevert(ITrustedSpender.NotADelegate.selector);
    trustedSpender.executeTransfer(address(usdc), smartAccount, trustedRecipient1, withdrawAmount);

    // Verify no transfer occurred
    assertEq(usdc.balanceOf(trustedRecipient1), 0);
    assertEq(usdc.balanceOf(smartAccount), 10000e6);
  }

  function testMultipleDelegatesCanWithdraw() public {
    uint256 withdrawAmount = 500e6;

    // First delegate withdraws
    vm.prank(delegate1);
    trustedSpender.executeTransfer(address(usdc), smartAccount, trustedRecipient1, withdrawAmount);

    // Second delegate withdraws
    vm.prank(delegate2);
    trustedSpender.executeTransfer(address(usdc), smartAccount, trustedRecipient2, withdrawAmount);

    // Verify both transfers succeeded
    assertEq(usdc.balanceOf(trustedRecipient1), withdrawAmount);
    assertEq(usdc.balanceOf(trustedRecipient2), withdrawAmount);
    assertEq(usdc.balanceOf(smartAccount), 10000e6 - 2 * withdrawAmount);
  }

  function testDelegateWithdrawalRespectsCurrencyLimits() public {
    // Create a mock ERC20 that wasn't approved
    MockUSDC unapprovedToken = new MockUSDC();
    unapprovedToken.mint(smartAccount, 1000e18);

    // Delegate tries to withdraw unapproved token
    vm.prank(delegate1);
    vm.expectRevert(); // Will fail because token has no approval
    trustedSpender.executeTransfer(address(unapprovedToken), smartAccount, trustedRecipient1, 100e18);

    // Verify no transfer occurred
    assertEq(unapprovedToken.balanceOf(trustedRecipient1), 0);
    assertEq(unapprovedToken.balanceOf(smartAccount), 1000e18);
  }

  // ============================================
  // TrustedCalls Functionality Tests
  // ============================================

  function testDelegateCanExecuteTrustedCall() public {
    uint256 newValue = 42;

    // Delegate executes trusted setValue call
    bytes memory callData = abi.encodeWithSignature("setValue(uint256)", newValue);

    vm.prank(delegate1);
    (bool success, ) = trustedCallsModule.executeTrustedCall(smartAccount, address(target), callData);

    assertTrue(success);
    assertEq(target.value(), newValue);
    assertEq(target.lastCaller(), smartAccount); // Call came from Safe, not delegate
  }

  function testDelegateCannotExecuteNonTrustedCall() public {
    // Try to call restrictedFunction which is not whitelisted
    bytes memory callData = abi.encodeWithSignature("restrictedFunction()");

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.CallNotTrusted.selector);
    trustedCallsModule.executeTrustedCall(smartAccount, address(target), callData);

    // Try to call adminFunction which is also not whitelisted
    callData = abi.encodeWithSignature("adminFunction()");

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.CallNotTrusted.selector);
    trustedCallsModule.executeTrustedCall(smartAccount, address(target), callData);
  }

  function testNonDelegateCannotExecuteTrustedCall() public {
    bytes memory callData = abi.encodeWithSignature("setValue(uint256)", 123);

    vm.prank(nonDelegate);
    vm.expectRevert(ITrustedCalls.NotADelegate.selector);
    trustedCallsModule.executeTrustedCall(smartAccount, address(target), callData);

    // Verify call did not execute
    assertEq(target.value(), 0);
  }

  function testCanAddNewTrustedCallViaMultisig() public {
    // First verify adminFunction is not callable
    bytes memory callData = abi.encodeWithSignature("adminFunction()");

    vm.prank(delegate1);
    vm.expectRevert(ITrustedCalls.CallNotTrusted.selector);
    trustedCallsModule.executeTrustedCall(smartAccount, address(target), callData);

    // Owners add adminFunction to trusted calls via multisig
    bytes4 adminSelector = bytes4(keccak256("adminFunction()"));
    bytes memory addTrustedCallData = abi.encodeWithSignature(
      "addTrustedCall(address,bytes4)",
      address(target),
      adminSelector
    );

    // Create multisig transaction to add trusted call
    bytes32 txHash = ISafe(payable(smartAccount)).getTransactionHash(
      address(trustedCallsModule),
      0,
      addTrustedCallData,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      address(0),
      ISafe(payable(smartAccount)).nonce()
    );

    // Both owners sign
    (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Key, txHash);
    (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Key, txHash);

    // Signatures must be sorted by owner address
    bytes memory signatures = abi.encodePacked(r2, s2, v2, r1, s1, v1);

    ISafe(payable(smartAccount)).execTransaction(
      address(trustedCallsModule),
      0,
      addTrustedCallData,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(address(0)),
      signatures
    );

    // Now delegate should be able to call adminFunction
    vm.prank(delegate1);
    (bool success, ) = trustedCallsModule.executeTrustedCall(smartAccount, address(target), callData);

    assertTrue(success);
  }

  // ============================================
  // End-to-End Integration Tests
  // ============================================

  function testCompleteWorkflow() public {
    // This test demonstrates a complete workflow:
    // 1. Delegate executes a trusted call to update a value
    // 2. Delegate withdraws funds to a trusted recipient
    // 3. Multiple delegates operate independently

    // Step 1: Delegate executes trusted call
    uint256 newValue = 999;
    bytes memory setValueCall = abi.encodeWithSignature("setValue(uint256)", newValue);

    vm.prank(delegate2);
    (bool success, ) = trustedCallsModule.executeTrustedCall(smartAccount, address(target), setValueCall);
    assertTrue(success);
    assertEq(target.value(), newValue);

    // Step 2: Delegate withdraws USDC
    uint256 withdrawAmount = 2500e6; // 2500 USDC

    vm.prank(delegate2);
    trustedSpender.executeTransfer(address(usdc), smartAccount, trustedRecipient2, withdrawAmount);
    assertEq(usdc.balanceOf(trustedRecipient2), withdrawAmount);

    // Step 3: Different delegate withdraws DAI to different recipient
    uint256 daiAmount = 1500e18; // 1500 DAI

    vm.prank(delegate1);
    trustedSpender.executeTransfer(address(dai), smartAccount, trustedRecipient1, daiAmount);
    assertEq(dai.balanceOf(trustedRecipient1), daiAmount);

    // Verify final balances
    assertEq(usdc.balanceOf(smartAccount), 10000e6 - withdrawAmount);
    assertEq(dai.balanceOf(smartAccount), 10000e18 - daiAmount);
    assertEq(target.value(), newValue);
  }

  // ============================================
  // configureSmartAccount Safety Rails
  // ============================================

  function test_ConfigureSmartAccount_RevertsWhenCalledDirectlyOnFactory() public {
    address[] memory empty = AddressArrays.make();

    vm.expectRevert(ISmartAccountFactory.NotDelegateCall.selector);
    factory.configureSmartAccount(empty, empty, empty, empty, type(uint48).max);
  }

  function test_ConfigureSmartAccount_RevertsOnReplay() public {
    // Re-running configureSmartAccount via delegatecall from the already-configured Safe
    // must hit the CONFIGURED_SLOT one-shot guard. Using a non-zero safeTxGas so the Safe
    // catches the inner AlreadyConfigured revert and returns false (rather than bubbling
    // up as the generic GS013).
    address[] memory empty = AddressArrays.make();
    bytes memory configureData = abi.encodeWithSelector(
      factory.configureSmartAccount.selector,
      empty,
      empty,
      empty,
      empty,
      type(uint48).max
    );

    uint256 safeTxGas = 200_000;
    bytes32 txHash = ISafe(payable(smartAccount)).getTransactionHash(
      address(factory),
      0,
      configureData,
      Enum.Operation.DelegateCall,
      safeTxGas,
      0,
      0,
      address(0),
      address(0),
      ISafe(payable(smartAccount)).nonce()
    );

    (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Key, txHash);
    (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Key, txHash);
    bytes memory signatures = owner1 < owner2
      ? abi.encodePacked(r1, s1, v1, r2, s2, v2)
      : abi.encodePacked(r2, s2, v2, r1, s1, v1);

    bool success = ISafe(payable(smartAccount)).execTransaction(
      address(factory),
      0,
      configureData,
      Enum.Operation.DelegateCall,
      safeTxGas,
      0,
      0,
      address(0),
      payable(address(0)),
      signatures
    );

    assertFalse(success, "replayed configureSmartAccount should fail");
  }

  // ============================================
  // Loop-skip Branches (empty input arrays)
  // ============================================

  function test_DeploySmartAccount_WithEmptyCurrencies_Succeeds() public {
    address deployed = factory.deploySmartAccount(
      AddressArrays.make(delegate1),
      AddressArrays.make(),
      AddressArrays.make(),
      AddressArrays.make(trustedRecipient1),
      type(uint48).max,
      AddressArrays.make(owner1),
      1
    );

    assertTrue(deployed != address(0));
    assertTrue(trustedSpender.isDelegate(deployed, delegate1));
  }

  function test_DeploySmartAccount_WithEmptyDelegates_Succeeds() public {
    address deployed = factory.deploySmartAccount(
      AddressArrays.make(),
      AddressArrays.make(address(usdc)),
      AddressArrays.make(),
      AddressArrays.make(trustedRecipient1),
      type(uint48).max,
      AddressArrays.make(owner1),
      1
    );

    assertTrue(deployed != address(0));
    assertFalse(trustedSpender.isDelegate(deployed, delegate1));
    assertEq(usdc.allowance(deployed, address(trustedSpender)), type(uint256).max);
  }

  function test_DeploySmartAccount_WithEmptyNftCollections_Succeeds() public {
    address deployed = factory.deploySmartAccount(
      AddressArrays.make(delegate1),
      AddressArrays.make(address(usdc)),
      AddressArrays.make(),
      AddressArrays.make(trustedRecipient1),
      type(uint48).max,
      AddressArrays.make(owner1),
      1
    );

    assertTrue(deployed != address(0));
  }

  function test_DeploySmartAccount_WithNftCollections_GrantsApprovalForAll() public {
    MockERC721 nftCollection1 = new MockERC721();
    MockERC721 nftCollection2 = new MockERC721();

    address deployed = factory.deploySmartAccount(
      AddressArrays.make(delegate1),
      AddressArrays.make(address(usdc)),
      AddressArrays.make(address(nftCollection1), address(nftCollection2)),
      AddressArrays.make(trustedRecipient1),
      type(uint48).max,
      AddressArrays.make(owner1),
      1
    );

    assertTrue(IERC721(address(nftCollection1)).isApprovedForAll(deployed, address(trustedSpender)));
    assertTrue(IERC721(address(nftCollection2)).isApprovedForAll(deployed, address(trustedSpender)));
  }

  function test_DeploySmartAccount_MultipleCurrenciesAndRecipients_SetsCartesianAllowances() public {
    uint48 validUntil = uint48(block.timestamp + 365 days);

    address deployed = factory.deploySmartAccount(
      AddressArrays.make(delegate1),
      AddressArrays.make(address(usdc), address(dai)),
      AddressArrays.make(),
      AddressArrays.make(trustedRecipient1, trustedRecipient2),
      validUntil,
      AddressArrays.make(owner1),
      1
    );

    // 2 currencies × 2 recipients = 4 routes, each at uint208.max and validUntil
    address[2] memory tokens = [address(usdc), address(dai)];
    address[2] memory recipients = [trustedRecipient1, trustedRecipient2];
    for (uint256 i = 0; i < tokens.length; ++i) {
      for (uint256 j = 0; j < recipients.length; ++j) {
        (uint256 amount, uint48 vu) = trustedSpender.getAllowance(tokens[i], deployed, recipients[j]);
        assertEq(amount, uint256(type(uint208).max), "route allowance not maxed");
        assertEq(vu, validUntil, "route validUntil mismatch");
      }
    }
  }

  // ============================================
  // Post-deploy State Assertions
  // ============================================

  function test_DeploySmartAccount_EnablesTrustedCallsModule() public view {
    assertTrue(ISafe(payable(smartAccount)).isModuleEnabled(address(trustedCallsModule)));
  }

  function test_DeploySmartAccount_ApprovesCurrenciesForSpenderToMax() public view {
    assertEq(usdc.allowance(smartAccount, address(trustedSpender)), type(uint256).max);
    assertEq(dai.allowance(smartAccount, address(trustedSpender)), type(uint256).max);
  }

  function test_DeploySmartAccount_RegistersDelegatesOnBothModules() public view {
    assertTrue(trustedSpender.isDelegate(smartAccount, delegate1));
    assertTrue(trustedSpender.isDelegate(smartAccount, delegate2));
    assertTrue(trustedCallsModule.isDelegate(smartAccount, delegate1));
    assertTrue(trustedCallsModule.isDelegate(smartAccount, delegate2));
  }
}
