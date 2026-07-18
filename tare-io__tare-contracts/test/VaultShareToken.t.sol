// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {VaultShareToken} from "../contracts/VaultShareToken.sol";
import {IVaultShareToken} from "../contracts/interfaces/IVaultShareToken.sol";
import {IERC1404} from "../contracts/interfaces/IERC1404.sol";
import {IRescuable} from "../contracts/misc/interfaces/IRescuable.sol";
import {RescueTokensTestBase} from "./helpers/RescueTokensTestBase.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract VaultShareTokenTest is Test, RescueTokensTestBase {
  VaultShareToken public token;

  address public guardian = makeAddr("guardian");
  address public admin = makeAddr("admin");
  address public whitelister = makeAddr("whitelister");
  address public recoveryAddr = makeAddr("recovery");
  address public vaultAddr = makeAddr("vault");
  address public assetAddr = makeAddr("usdc");
  address public alice = makeAddr("alice");
  address public bob = makeAddr("bob");
  address public randomUser = makeAddr("randomUser");

  string public tokenName = "Tare Vault Share Token";
  string public tokenSymbol = "TVST";

  bytes32 public ADMIN_ROLE;
  bytes32 public GUARDIAN_ROLE;
  bytes32 public SHAREHOLDER_ROLE;
  bytes32 public WHITELISTER_ROLE;
  bytes32 public MINTER_ROLE;
  bytes32 public BURNER_ROLE;

  function setUp() public {
    token = new VaultShareToken(tokenName, tokenSymbol, guardian, recoveryAddr, vaultAddr, assetAddr);
    ADMIN_ROLE = token.ADMIN_ROLE();
    GUARDIAN_ROLE = token.GUARDIAN_ROLE();
    SHAREHOLDER_ROLE = token.SHAREHOLDER_ROLE();
    WHITELISTER_ROLE = token.WHITELISTER_ROLE();
    MINTER_ROLE = token.MINTER_ROLE();
    BURNER_ROLE = token.BURNER_ROLE();

    vm.startPrank(guardian);
    token.grantRole(ADMIN_ROLE, admin);
    token.grantRole(WHITELISTER_ROLE, whitelister);
    vm.stopPrank();

    vm.startPrank(whitelister);
    token.grantRole(SHAREHOLDER_ROLE, alice);
    token.grantRole(SHAREHOLDER_ROLE, bob);
    vm.stopPrank();

    vm.prank(vaultAddr);
    token.mint(alice, 1000e18);
  }

  // ---- Transfer restrictions ----

  function testTransferBetweenWhitelistedSucceeds() public {
    vm.prank(alice);
    token.transfer(bob, 100e18);
    assertEq(token.balanceOf(bob), 100e18);
    assertEq(token.balanceOf(alice), 900e18);
  }

  function testTransferFromBetweenWhitelistedSucceeds() public {
    vm.prank(alice);
    token.approve(bob, 200e18);

    vm.prank(bob);
    token.transferFrom(alice, bob, 200e18);
    assertEq(token.balanceOf(bob), 200e18);
  }

  function testTransferToNonWhitelistedReverts() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IVaultShareToken.ShareholderRestricted.selector, randomUser));
    token.transfer(randomUser, 100e18);
  }

  function testTransferFromNonWhitelistedReverts() public {
    vm.prank(whitelister);
    token.grantRole(SHAREHOLDER_ROLE, randomUser);

    vm.prank(vaultAddr);
    token.mint(randomUser, 500e18);

    vm.prank(whitelister);
    token.revokeRole(SHAREHOLDER_ROLE, randomUser);

    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(IVaultShareToken.ShareholderRestricted.selector, randomUser));
    token.transfer(alice, 100e18);
  }

  // ---- Mint / Burn ----

  function testMintByVaultSucceeds() public {
    vm.prank(vaultAddr);
    token.mint(alice, 500e18);
    assertEq(token.balanceOf(alice), 1500e18);
  }

  function testMintByNonMinterReverts() public {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, MINTER_ROLE)
    );
    token.mint(alice, 500e18);
  }

  function testMintToNonWhitelistedReverts() public {
    vm.prank(vaultAddr);
    vm.expectRevert(abi.encodeWithSelector(IVaultShareToken.ShareholderRestricted.selector, randomUser));
    token.mint(randomUser, 500e18);
  }

  function testBurnByVaultSucceeds() public {
    vm.prank(vaultAddr);
    token.burn(alice, 300e18);
    assertEq(token.balanceOf(alice), 700e18);
  }

  function testBurnByNonBurnerReverts() public {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, BURNER_ROLE)
    );
    token.burn(alice, 300e18);
  }

  function testBurnFromNonWhitelistedReverts() public {
    vm.prank(whitelister);
    token.grantRole(SHAREHOLDER_ROLE, randomUser);

    vm.prank(vaultAddr);
    token.mint(randomUser, 500e18);

    vm.prank(whitelister);
    token.revokeRole(SHAREHOLDER_ROLE, randomUser);

    vm.prank(vaultAddr);
    vm.expectRevert(abi.encodeWithSelector(IVaultShareToken.ShareholderRestricted.selector, randomUser));
    token.burn(randomUser, 100e18);
  }

  // ---- Whitelist management ----

  function testWhitelisterCanGrantShareholderRole() public {
    vm.prank(whitelister);
    token.grantRole(SHAREHOLDER_ROLE, randomUser);
    assertTrue(token.hasRole(SHAREHOLDER_ROLE, randomUser));
  }

  function testWhitelisterCanRevokeShareholderRole() public {
    vm.prank(whitelister);
    token.revokeRole(SHAREHOLDER_ROLE, alice);
    assertFalse(token.hasRole(SHAREHOLDER_ROLE, alice));
  }

  function testNonWhitelisterCannotGrantShareholderRole() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, WHITELISTER_ROLE)
    );
    token.grantRole(SHAREHOLDER_ROLE, randomUser);
  }

  function testAdminCannotDirectlyGrantShareholderRole() public {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, WHITELISTER_ROLE)
    );
    token.grantRole(SHAREHOLDER_ROLE, randomUser);
  }

  // ---- Role hierarchy ----

  function testGuardianCanGrantWhitelisterRole() public {
    vm.prank(guardian);
    token.grantRole(WHITELISTER_ROLE, randomUser);
    assertTrue(token.hasRole(WHITELISTER_ROLE, randomUser));
  }

  function testGuardianCanRevokeWhitelisterRole() public {
    vm.prank(guardian);
    token.revokeRole(WHITELISTER_ROLE, whitelister);
    assertFalse(token.hasRole(WHITELISTER_ROLE, whitelister));
  }

  function testWhitelisterCannotGrantWhitelisterRole() public {
    vm.prank(whitelister);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, whitelister, GUARDIAN_ROLE)
    );
    token.grantRole(WHITELISTER_ROLE, randomUser);
  }

  function testWhitelisterCannotGrantAdminRole() public {
    vm.prank(whitelister);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, whitelister, GUARDIAN_ROLE)
    );
    token.grantRole(ADMIN_ROLE, randomUser);
  }

  // ---- supportsInterface ----

  function testSupportsERC7575Share() public view {
    assertTrue(token.supportsInterface(0xf815c03d));
  }

  function testSupportsIERC20() public view {
    assertTrue(token.supportsInterface(type(IERC20).interfaceId));
  }

  function testSupportsIERC1404() public view {
    assertTrue(token.supportsInterface(type(IERC1404).interfaceId));
  }

  function testSupportsIERC165() public view {
    assertTrue(token.supportsInterface(type(IERC165).interfaceId));
  }

  function testSupportsIAccessControl() public view {
    assertTrue(token.supportsInterface(type(IAccessControl).interfaceId));
  }

  // ---- Misc ----

  function testTokenMetadata() public view {
    assertEq(token.name(), tokenName);
    assertEq(token.symbol(), tokenSymbol);
    assertEq(token.decimals(), 18);
  }

  function testVaultAddress() public view {
    assertEq(token.vault(assetAddr), vaultAddr);
  }

  function testVaultWithWrongAssetReturnsZero() public view {
    assertEq(token.vault(address(1)), address(0));
  }

  function testConstructorRevertsZeroAdmin() public {
    vm.expectRevert(IVaultShareToken.ZeroAddress.selector);
    new VaultShareToken(tokenName, tokenSymbol, address(0), recoveryAddr, vaultAddr, assetAddr);
  }

  function testConstructorRevertsZeroRecovery() public {
    vm.expectRevert(IRescuable.InvalidRecoveryAddress.selector);
    new VaultShareToken(tokenName, tokenSymbol, guardian, address(0), vaultAddr, assetAddr);
  }

  function testConstructorRevertsZeroVault() public {
    vm.expectRevert(IVaultShareToken.ZeroAddress.selector);
    new VaultShareToken(tokenName, tokenSymbol, guardian, recoveryAddr, address(0), assetAddr);
  }

  function testConstructorRevertsZeroAsset() public {
    vm.expectRevert(IVaultShareToken.ZeroAddress.selector);
    new VaultShareToken(tokenName, tokenSymbol, guardian, recoveryAddr, vaultAddr, address(0));
  }

  function testConstructorGrantsMinterAndBurnerToVault() public view {
    assertTrue(token.hasRole(MINTER_ROLE, vaultAddr));
    assertTrue(token.hasRole(BURNER_ROLE, vaultAddr));
  }

  function testConstructorEmitsVaultUpdate() public {
    vm.expectEmit(true, false, false, true);
    emit IVaultShareToken.VaultUpdate(assetAddr, vaultAddr);
    new VaultShareToken(tokenName, tokenSymbol, guardian, recoveryAddr, vaultAddr, assetAddr);
  }

  // ---- ERC-1404 ----

  function testDetectTransferRestrictionReturnsZeroForWhitelisted() public view {
    assertEq(token.detectTransferRestriction(alice, bob, 100e18), 0);
  }

  function testDetectTransferRestrictionReturnsSenderCode() public view {
    assertEq(token.detectTransferRestriction(randomUser, bob, 100e18), 1);
  }

  function testDetectTransferRestrictionReturnsRecipientCode() public view {
    assertEq(token.detectTransferRestriction(alice, randomUser, 100e18), 2);
  }

  function testDetectTransferRestrictionSkipsMintAddress() public view {
    assertEq(token.detectTransferRestriction(address(0), alice, 100e18), 0);
  }

  function testDetectTransferRestrictionSkipsBurnAddress() public view {
    assertEq(token.detectTransferRestriction(alice, address(0), 100e18), 0);
  }

  function testMessageForTransferRestrictionSuccess() public view {
    assertEq(token.messageForTransferRestriction(0), "SUCCESS");
  }

  function testMessageForTransferRestrictionSender() public view {
    assertEq(token.messageForTransferRestriction(1), "Sender is not whitelisted");
  }

  function testMessageForTransferRestrictionRecipient() public view {
    assertEq(token.messageForTransferRestriction(2), "Recipient is not whitelisted");
  }

  function testMessageForTransferRestrictionUnknownCode() public view {
    assertEq(token.messageForTransferRestriction(255), "UNKNOWN");
  }

  // ---- setVault ----

  function testSetVault() public {
    address newVault = makeAddr("newVault");
    vm.prank(guardian);
    vm.expectEmit(true, false, false, true);
    emit IVaultShareToken.VaultUpdate(assetAddr, newVault);
    token.setVault(newVault);
    assertEq(token.vault(assetAddr), newVault);
  }

  function testSetVaultByNonGuardianReverts() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, GUARDIAN_ROLE)
    );
    token.setVault(makeAddr("newVault"));
  }

  function testSetVaultZeroAddressReverts() public {
    vm.prank(guardian);
    vm.expectRevert(IVaultShareToken.ZeroAddress.selector);
    token.setVault(address(0));
  }

  function testSetVaultRevokesMinterAndBurnerFromOldVault() public {
    assertTrue(token.hasRole(MINTER_ROLE, vaultAddr));
    assertTrue(token.hasRole(BURNER_ROLE, vaultAddr));

    address newVault = makeAddr("newVault");
    vm.prank(guardian);
    token.setVault(newVault);

    assertFalse(token.hasRole(MINTER_ROLE, vaultAddr), "old vault keeps MINTER_ROLE");
    assertFalse(token.hasRole(BURNER_ROLE, vaultAddr), "old vault keeps BURNER_ROLE");
    // New vault is not auto-granted; guardian grants separately.
    assertFalse(token.hasRole(MINTER_ROLE, newVault), "new vault auto-granted MINTER_ROLE");
    assertFalse(token.hasRole(BURNER_ROLE, newVault), "new vault auto-granted BURNER_ROLE");
  }

  function testSetVaultOldVaultCannotMintAfterRotation() public {
    vm.prank(guardian);
    token.setVault(makeAddr("newVault"));

    vm.prank(vaultAddr);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, vaultAddr, MINTER_ROLE)
    );
    token.mint(alice, 1e18);
  }

  // ---- MINTER_ROLE / BURNER_ROLE ----

  function test_GuardianCanGrantMinterRole() public {
    vm.prank(guardian);
    token.grantRole(MINTER_ROLE, randomUser);
    assertTrue(token.hasRole(MINTER_ROLE, randomUser));
  }

  function test_GuardianCanRevokeMinterRole() public {
    vm.prank(guardian);
    token.revokeRole(MINTER_ROLE, vaultAddr);
    assertFalse(token.hasRole(MINTER_ROLE, vaultAddr));
  }

  function test_GuardianCanGrantBurnerRole() public {
    vm.prank(guardian);
    token.grantRole(BURNER_ROLE, randomUser);
    assertTrue(token.hasRole(BURNER_ROLE, randomUser));
  }

  function test_GuardianCanRevokeBurnerRole() public {
    vm.prank(guardian);
    token.revokeRole(BURNER_ROLE, vaultAddr);
    assertFalse(token.hasRole(BURNER_ROLE, vaultAddr));
  }

  function testNonAdminCannotGrantMinterRole() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, GUARDIAN_ROLE)
    );
    token.grantRole(MINTER_ROLE, randomUser);
  }

  function testNonAdminCannotGrantBurnerRole() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, GUARDIAN_ROLE)
    );
    token.grantRole(BURNER_ROLE, randomUser);
  }

  // ---- rescueTokens (inherited from Rescuable) ----

  function testRescueERC20TokensSuccess() public {
    _testRescueERC20TokensSuccess(address(token), guardian);
  }

  function testRescueERC20TokensRevertsWhenNotGuardian() public {
    _testRescueERC20TokensRevertsIfNotGuardian(address(token), randomUser, GUARDIAN_ROLE);
  }

  function testRescueERC20TokensRevertsWhenAdmin() public {
    _testRescueERC20TokensRevertsIfAdminNotGuardian(address(token), admin, GUARDIAN_ROLE);
  }

  function testRescueERC20TokensZeroBalance() public {
    _testRescueERC20TokensZeroBalance(address(token), guardian);
  }

  function testRescueERC20TokensPartialAmount() public {
    _testRescueERC20TokensPartialAmount(address(token), guardian);
  }

  function testRescueERC20TokensExceedsBalance() public {
    _testRescueERC20TokensExceedsBalance(address(token), guardian);
  }

  function testRescueERC721TokensSuccess() public {
    _testRescueERC721TokensSuccess(address(token), guardian);
  }

  function testRescueERC721TokensRevertsWhenNotGuardian() public {
    _testRescueERC721TokensRevertsIfNotGuardian(address(token), randomUser, GUARDIAN_ROLE);
  }

  function testRescueERC721TokensMultiple() public {
    _testRescueERC721TokensMultiple(address(token), guardian);
  }

  function testSetRecoveryAddressSuccess() public {
    _testSetRecoveryAddressSuccess(address(token), guardian);
  }

  function testSetRecoveryAddressRevertsWhenNotGuardian() public {
    _testSetRecoveryAddressRevertsIfNotGuardian(address(token), randomUser, GUARDIAN_ROLE);
  }

  function testSetRecoveryAddressRevertsWhenZeroAddress() public {
    _testSetRecoveryAddressRevertsIfZeroAddress(address(token), guardian);
  }

  function testConstructorSetsRecoveryAddress() public view {
    assertEq(token.recoveryAddress(), recoveryAddr);
  }
}
