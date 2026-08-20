// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Enum} from "safe-smart-account/common/Enum.sol";
import {SafeProxy} from "../lib/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "../lib/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";

import {CctpBridgeModule} from "../contracts/CctpBridgeModule.sol";
import {ICctpBridgeModule} from "../contracts/interfaces/ICctpBridgeModule.sol";
import {ISafe} from "../contracts/misc/interfaces/ISafe.sol";
import {DeploySafeSingleton} from "./helpers/DeploySafeSingleton.sol";
import {MockUSDC} from "./mocks/USDC.sol";
import {MockTokenMessenger, RevertingTokenMessenger} from "./mocks/MockTokenMessenger.sol";
import {FalseApproveToken} from "./mocks/FalseApproveToken.sol";
import {NoReturnApproveToken} from "./mocks/NoReturnApproveToken.sol";
import {RevertingApproveToken} from "./mocks/RevertingApproveToken.sol";

/**
 * @notice Shared fixture: a real Safe (2 owners, threshold 1 for setup convenience) with the
 *         module enabled. The route is hardcoded in the module, so mocks are `vm.etch`ed at
 *         the real Base mainnet USDC and TokenMessenger addresses.
 */
abstract contract CctpBridgeModuleTestBase is Test {
  bytes32 internal constant MINT_RECIPIENT = bytes32(uint256(uint160(address(0xFA11BACC))));
  // Must match the constants hardcoded in CctpBridgeModule (pinned in testStoresConfiguration).
  address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address internal constant BASE_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
  uint256 internal constant FLAT_FEE = 0.5e6;
  uint256 internal constant FAST_FEE_NUMERATOR = 13;
  uint256 internal constant FAST_FEE_DENOMINATOR = 100_000;
  uint32 internal constant FINALITY_THRESHOLD_STANDARD = 2000;
  uint32 internal constant FINALITY_THRESHOLD_FAST = 1000;
  uint256 internal constant INITIAL_BALANCE = 1_000e6;
  uint256 internal constant BRIDGE_AMOUNT = 100e6;
  uint256 internal constant MAX_FUZZ_BRIDGE_AMOUNT = 100_000_000e6;

  ISafe internal safe;
  MockUSDC internal usdc;
  MockTokenMessenger internal messenger;
  CctpBridgeModule internal module;

  uint256 internal owner1PrivKey = 1;
  uint256 internal owner2PrivKey = 2;
  address internal owner1;
  address internal owner2;
  address internal nonOwner = address(0xBAD);

  function setUp() public virtual {
    owner1 = vm.addr(owner1PrivKey);
    owner2 = vm.addr(owner2PrivKey);

    // The module's route is compile-time constants, so the mocks must live at the real
    // Base mainnet addresses.
    vm.etch(BASE_USDC, address(new MockUSDC()).code);
    usdc = MockUSDC(BASE_USDC);
    vm.etch(BASE_TOKEN_MESSENGER, address(new MockTokenMessenger()).code);
    messenger = MockTokenMessenger(BASE_TOKEN_MESSENGER);

    ISafe safeSingleton = ISafe(DeploySafeSingleton.deployFromCreationCode());
    SafeProxyFactory proxyFactory = new SafeProxyFactory();

    address[] memory owners = new address[](2);
    owners[0] = owner1;
    owners[1] = owner2;

    bytes memory initializer = abi.encodeWithSelector(
      ISafe.setup.selector,
      owners,
      1, // threshold
      address(0),
      new bytes(0),
      address(0),
      address(0),
      0,
      address(0)
    );
    SafeProxy proxy = proxyFactory.createProxyWithNonce(address(safeSingleton), initializer, 0);
    safe = ISafe(payable(address(proxy)));

    module = new CctpBridgeModule({_safe: address(safe), _mintRecipient: MINT_RECIPIENT});

    _enableModule(address(module));

    usdc.mint(address(safe), INITIAL_BALANCE);
  }

  /// @notice Mirrors the module's Fast-mode fee allowance formula.
  function _fastMaxFee(uint256 amount) internal pure returns (uint256) {
    return FLAT_FEE + (amount * FAST_FEE_NUMERATOR) / FAST_FEE_DENOMINATOR;
  }

  /// @notice Enables `moduleAddress` on the Safe via an owner1-signed execTransaction.
  function _enableModule(address moduleAddress) internal {
    _execSafeTx(abi.encodeWithSignature("enableModule(address)", moduleAddress));
  }

  /// @notice Executes `data` on the Safe itself via an owner1-signed execTransaction.
  function _execSafeTx(bytes memory data) internal {
    bytes32 txHash = safe.getTransactionHash(
      address(safe),
      0,
      data,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      address(0),
      safe.nonce()
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1PrivKey, txHash);
    safe.execTransaction(
      address(safe),
      0,
      data,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(0),
      abi.encodePacked(r, s, v)
    );
  }
}

contract CctpBridgeModule_ConstructorTest is CctpBridgeModuleTestBase {
  function testStoresConfiguration() public view {
    assertEq(module.safe(), address(safe));
    assertEq(module.mintRecipient(), MINT_RECIPIENT);
    assertEq(module.USDC(), BASE_USDC);
    assertEq(module.TOKEN_MESSENGER(), BASE_TOKEN_MESSENGER);
    assertEq(module.DESTINATION_DOMAIN(), 1);
    assertEq(module.FLAT_FEE(), FLAT_FEE);
    assertEq(module.FAST_FEE_NUMERATOR(), FAST_FEE_NUMERATOR);
    assertEq(module.FAST_FEE_DENOMINATOR(), FAST_FEE_DENOMINATOR);
    assertEq(module.FINALITY_THRESHOLD_STANDARD(), FINALITY_THRESHOLD_STANDARD);
    assertEq(module.FINALITY_THRESHOLD_FAST(), FINALITY_THRESHOLD_FAST);
    assertEq(module.FORWARDING_HOOK_DATA(), hex"636374702d666f72776172640000000000000000000000000000000000000000");
  }

  function testRevertsOnZeroSafe() public {
    vm.expectRevert(ICctpBridgeModule.ZeroAddress.selector);
    new CctpBridgeModule(address(0), MINT_RECIPIENT);
  }

  function testRevertsOnZeroMintRecipient() public {
    vm.expectRevert(ICctpBridgeModule.ZeroAddress.selector);
    new CctpBridgeModule(address(safe), bytes32(0));
  }
}

contract CctpBridgeModule_BridgeTest is CctpBridgeModuleTestBase {
  function testBridgesExplicitAmount() public {
    vm.expectEmit(true, false, false, true);
    emit ICctpBridgeModule.Bridged(owner1, BRIDGE_AMOUNT, FLAT_FEE, false, MINT_RECIPIENT);

    vm.prank(owner1);
    uint256 bridgedAmount = module.bridge(BRIDGE_AMOUNT);

    assertEq(bridgedAmount, BRIDGE_AMOUNT);
    assertEq(usdc.balanceOf(address(safe)), INITIAL_BALANCE - BRIDGE_AMOUNT);
    assertEq(usdc.balanceOf(address(messenger)), BRIDGE_AMOUNT);

    assertEq(messenger.callCount(), 1);
    assertEq(messenger.lastCaller(), address(safe));
    assertEq(messenger.lastAmount(), BRIDGE_AMOUNT);
    assertEq(messenger.lastDestinationDomain(), module.DESTINATION_DOMAIN());
    assertEq(messenger.lastMintRecipient(), MINT_RECIPIENT);
    assertEq(messenger.lastBurnToken(), address(usdc));
    assertEq(messenger.lastDestinationCaller(), bytes32(0));
    assertEq(messenger.lastMaxFee(), FLAT_FEE);
    assertEq(messenger.lastMinFinalityThreshold(), FINALITY_THRESHOLD_STANDARD);
    assertEq(messenger.lastHookData(), module.FORWARDING_HOOK_DATA());
  }

  function testBridgeZeroSweepsFullBalance() public {
    vm.expectEmit(true, false, false, true);
    // The event carries the resolved (full-balance) amount, not the 0 sentinel.
    emit ICctpBridgeModule.Bridged(owner2, INITIAL_BALANCE, FLAT_FEE, false, MINT_RECIPIENT);

    vm.prank(owner2);
    uint256 bridgedAmount = module.bridge(0);

    assertEq(bridgedAmount, INITIAL_BALANCE);
    assertEq(usdc.balanceOf(address(safe)), 0);
    assertEq(usdc.balanceOf(address(messenger)), INITIAL_BALANCE);
    assertEq(messenger.lastAmount(), INITIAL_BALANCE);
  }

  function testLeavesNoResidualAllowance() public {
    vm.prank(owner1);
    module.bridge(BRIDGE_AMOUNT);

    assertEq(usdc.allowance(address(safe), address(messenger)), 0);
  }

  function testAnyOwnerCanBridge() public {
    vm.prank(owner1);
    module.bridge(BRIDGE_AMOUNT);
    vm.prank(owner2);
    module.bridge(BRIDGE_AMOUNT);

    assertEq(messenger.callCount(), 2);
  }

  function testRevertsForNonOwner() public {
    vm.prank(nonOwner);
    vm.expectRevert(ICctpBridgeModule.NotSafeOwner.selector);
    module.bridge(BRIDGE_AMOUNT);
  }

  function testRevertsForSafeItself() public {
    // The Safe is not its own owner; only owner EOAs may trigger the module.
    vm.prank(address(safe));
    vm.expectRevert(ICctpBridgeModule.NotSafeOwner.selector);
    module.bridge(BRIDGE_AMOUNT);
  }

  function testRevertsForRemovedOwner() public {
    // Owner membership is checked live on the Safe, not snapshotted at deploy.
    _execSafeTx(abi.encodeWithSignature("removeOwner(address,address,uint256)", owner1, owner2, 1));

    vm.prank(owner2);
    vm.expectRevert(ICctpBridgeModule.NotSafeOwner.selector);
    module.bridge(BRIDGE_AMOUNT);

    vm.prank(owner1);
    module.bridge(BRIDGE_AMOUNT);
    assertEq(messenger.callCount(), 1);
  }

  function testRevertsWhenAmountEqualsMaxFee() public {
    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.AmountTooSmall.selector);
    module.bridge(FLAT_FEE);
  }

  function testRevertsWhenAmountBelowMaxFee() public {
    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.AmountTooSmall.selector);
    module.bridge(FLAT_FEE - 1);
  }

  function testBridgesAmountJustAboveMaxFee() public {
    vm.prank(owner1);
    uint256 bridgedAmount = module.bridge(FLAT_FEE + 1);

    assertEq(bridgedAmount, FLAT_FEE + 1);
  }

  function testRevertsSweepWhenBalanceBelowMaxFee() public {
    // Drain the Safe's balance down to exactly maxFee, then sweep.
    vm.prank(owner1);
    module.bridge(INITIAL_BALANCE - FLAT_FEE);

    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.AmountTooSmall.selector);
    module.bridge(0);
  }

  function testRevertsWhenMessengerReverts() public {
    vm.etch(BASE_TOKEN_MESSENGER, address(new RevertingTokenMessenger()).code);

    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.ModuleCallFailed.selector);
    module.bridge(BRIDGE_AMOUNT);
  }

  function testRevertsWhenApproveReturnsFalse() public {
    vm.etch(BASE_USDC, address(new FalseApproveToken()).code);

    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.UsdcApprovalFailed.selector);
    module.bridge(BRIDGE_AMOUNT);
  }

  function testRevertsWhenApproveReverts() public {
    vm.etch(BASE_USDC, address(new RevertingApproveToken()).code);

    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.ModuleCallFailed.selector);
    module.bridge(BRIDGE_AMOUNT);
  }

  function testAcceptsApproveWithNoReturnData() public {
    vm.etch(BASE_USDC, address(new NoReturnApproveToken()).code);

    vm.prank(owner1);
    uint256 bridgedAmount = module.bridge(BRIDGE_AMOUNT);

    assertEq(bridgedAmount, BRIDGE_AMOUNT);
    assertEq(messenger.callCount(), 1);
    assertEq(messenger.lastAmount(), BRIDGE_AMOUNT);
  }

  function testRevertsSweepWhenBalanceIsZero() public {
    vm.prank(owner1);
    module.bridge(0);
    assertEq(usdc.balanceOf(address(safe)), 0);

    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.AmountTooSmall.selector);
    module.bridge(0);
  }

  function testRevertsWhenModuleNotEnabled() public {
    CctpBridgeModule disabledModule = new CctpBridgeModule(address(safe), MINT_RECIPIENT);

    vm.prank(owner1);
    vm.expectRevert("GS104");
    disabledModule.bridge(BRIDGE_AMOUNT);
  }

  function testSmallTransferPassesInBothModes() public {
    uint256 smallAmount = 10e6;

    vm.prank(owner1);
    module.bridge(smallAmount);
    vm.prank(owner1);
    module.bridgeFast(smallAmount);

    assertEq(messenger.callCount(), 2);
  }

  function testFuzzStandardFeeFormula(uint256 amount) public {
    amount = bound(amount, FLAT_FEE + 1, MAX_FUZZ_BRIDGE_AMOUNT);
    usdc.mint(address(safe), amount);

    vm.prank(owner1);
    module.bridge(amount);

    // Standard mode's allowance is the flat fee regardless of amount.
    assertEq(messenger.lastMaxFee(), FLAT_FEE);
    assertEq(messenger.lastMinFinalityThreshold(), FINALITY_THRESHOLD_STANDARD);
  }

  function testFuzzRevertsUpToMaxFeeBoundary(uint256 amount) public {
    // Largest amount where amount <= FLAT_FEE (0 is the sweep sentinel, so start at 1).
    amount = bound(amount, 1, FLAT_FEE);

    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.AmountTooSmall.selector);
    module.bridge(amount);
  }
}

contract CctpBridgeModule_BridgeFastTest is CctpBridgeModuleTestBase {
  function testBridgesExplicitAmount() public {
    uint256 expectedMaxFee = _fastMaxFee(BRIDGE_AMOUNT);

    vm.expectEmit(true, false, false, true);
    emit ICctpBridgeModule.Bridged(owner1, BRIDGE_AMOUNT, expectedMaxFee, true, MINT_RECIPIENT);

    vm.prank(owner1);
    uint256 bridgedAmount = module.bridgeFast(BRIDGE_AMOUNT);

    assertEq(bridgedAmount, BRIDGE_AMOUNT);
    assertEq(usdc.balanceOf(address(safe)), INITIAL_BALANCE - BRIDGE_AMOUNT);
    assertEq(usdc.balanceOf(address(messenger)), BRIDGE_AMOUNT);

    assertEq(messenger.callCount(), 1);
    assertEq(messenger.lastAmount(), BRIDGE_AMOUNT);
    assertEq(messenger.lastMaxFee(), expectedMaxFee);
    assertEq(messenger.lastMinFinalityThreshold(), FINALITY_THRESHOLD_FAST);
  }

  function testBridgeZeroSweepsFullBalance() public {
    vm.expectEmit(true, false, false, true);
    // The event carries the resolved (full-balance) amount and its fee, not the 0 sentinel.
    emit ICctpBridgeModule.Bridged(owner2, INITIAL_BALANCE, _fastMaxFee(INITIAL_BALANCE), true, MINT_RECIPIENT);

    vm.prank(owner2);
    uint256 bridgedAmount = module.bridgeFast(0);

    assertEq(bridgedAmount, INITIAL_BALANCE);
    assertEq(usdc.balanceOf(address(safe)), 0);
    assertEq(messenger.lastAmount(), INITIAL_BALANCE);
    // The fee is computed on the resolved (full-balance) amount, not the 0 sentinel.
    assertEq(messenger.lastMaxFee(), _fastMaxFee(INITIAL_BALANCE));
  }

  function testRevertsForNonOwner() public {
    vm.prank(nonOwner);
    vm.expectRevert(ICctpBridgeModule.NotSafeOwner.selector);
    module.bridgeFast(BRIDGE_AMOUNT);
  }

  function testRevertsWhenAmountEqualsMaxFee() public {
    // Smallest amount where amount == FLAT_FEE + amount * 13 / 100_000.
    uint256 boundary = FLAT_FEE + (FLAT_FEE * FAST_FEE_NUMERATOR) / FAST_FEE_DENOMINATOR;
    assertEq(boundary, _fastMaxFee(boundary));

    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.AmountTooSmall.selector);
    module.bridgeFast(boundary);
  }

  function testBridgesAmountJustAboveMaxFee() public {
    uint256 boundary = FLAT_FEE + (FLAT_FEE * FAST_FEE_NUMERATOR) / FAST_FEE_DENOMINATOR;

    vm.prank(owner1);
    uint256 bridgedAmount = module.bridgeFast(boundary + 1);

    assertEq(bridgedAmount, boundary + 1);
  }

  function testFuzzFastFeeFormula(uint256 amount) public {
    uint256 boundary = FLAT_FEE + (FLAT_FEE * FAST_FEE_NUMERATOR) / FAST_FEE_DENOMINATOR;
    amount = bound(amount, boundary + 1, MAX_FUZZ_BRIDGE_AMOUNT);
    usdc.mint(address(safe), amount);

    vm.prank(owner1);
    module.bridgeFast(amount);

    assertEq(messenger.lastMaxFee(), FLAT_FEE + (amount * FAST_FEE_NUMERATOR) / FAST_FEE_DENOMINATOR);
    assertEq(messenger.lastMinFinalityThreshold(), FINALITY_THRESHOLD_FAST);
    assertGt(amount, messenger.lastMaxFee());
  }

  function testFuzzRevertsUpToMaxFeeBoundary(uint256 amount) public {
    // Largest amount where amount <= FLAT_FEE + amount * 13 / 100_000.
    uint256 boundary = FLAT_FEE + (FLAT_FEE * FAST_FEE_NUMERATOR) / FAST_FEE_DENOMINATOR;
    amount = bound(amount, 1, boundary);

    vm.prank(owner1);
    vm.expectRevert(ICctpBridgeModule.AmountTooSmall.selector);
    module.bridgeFast(amount);
  }
}
