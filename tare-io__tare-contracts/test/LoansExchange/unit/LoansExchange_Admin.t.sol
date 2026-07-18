// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansExchangeTestBase} from "../setup/LoansExchange_TestBase.t.sol";
import {RescueTokensTestBase} from "../../helpers/RescueTokensTestBase.sol";
import {LoansExchange} from "contracts/LoansExchange.sol";
import {ILoansExchange} from "contracts/interfaces/ILoansExchange.sol";
import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";

// ============================================================================
// Constructor
// ============================================================================

contract LoansExchange_ConstructorTest is LoansExchangeTestBase {
  function test_Constructor_SetsImmutables() public view {
    assertEq(address(exchange.LOANS()), address(loans));
    assertEq(address(exchange.LOANS_NFT()), address(loansNFT));
    assertEq(address(exchange.CURRENCY()), address(usdc));
  }

  function test_Constructor_SetsGuardian() public view {
    assertTrue(exchange.hasRole(exchangeGuardianRole, guardian));
  }

  function test_Constructor_Reverts_WhenLoansNFTIsZero() public {
    vm.expectRevert(ILoansExchange.ZeroAddress.selector);
    new LoansExchange(ILoansNFT(address(0)), ILoans(address(loans)), guardian, recoveryAddress);
  }

  function test_Constructor_Reverts_WhenLoansIsZero() public {
    vm.expectRevert(ILoansExchange.ZeroAddress.selector);
    new LoansExchange(ILoansNFT(address(loansNFT)), ILoans(address(0)), guardian, recoveryAddress);
  }
}

// ============================================================================
// setMaxLoansPerOffer
// ============================================================================

contract LoansExchange_SetMaxLoansPerOfferTest is LoansExchangeTestBase {
  function test_SetMaxLoansPerOffer_UpdatesValue() public {
    uint64 newMax = 50;
    vm.prank(admin);
    exchange.setMaxLoansPerOffer(newMax);
    assertEq(exchange.maxLoansPerOffer(), newMax);
  }

  function test_SetMaxLoansPerOffer_EmitsEvent() public {
    uint64 newMax = 200;
    vm.prank(admin);
    vm.expectEmit(false, false, false, true, address(exchange));
    emit ILoansExchange.MaxLoansPerOfferUpdated(newMax);
    exchange.setMaxLoansPerOffer(newMax);
  }

  function test_SetMaxLoansPerOffer_Reverts_WhenNotAdmin() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, exchangeAdminRole)
    );
    exchange.setMaxLoansPerOffer(50);
  }

  function test_SetMaxLoansPerOffer_Reverts_WhenZero() public {
    vm.prank(admin);
    vm.expectRevert(ILoansExchange.InvalidMaxLoansPerOffer.selector);
    exchange.setMaxLoansPerOffer(0);
  }
}

// ============================================================================
// rescueTokens (inherited from Rescuable)
// ============================================================================

contract LoansExchange_RescueTokensTest is LoansExchangeTestBase, RescueTokensTestBase {
  function test_RescueERC20Tokens_Success() public {
    _testRescueERC20TokensSuccess(address(exchange), guardian);
  }

  function test_RescueERC20Tokens_Reverts_WhenNotGuardian() public {
    _testRescueERC20TokensRevertsIfNotGuardian(address(exchange), randomUser, exchangeGuardianRole);
  }

  function test_RescueERC20Tokens_Reverts_WhenAdmin() public {
    _testRescueERC20TokensRevertsIfNotGuardian(address(exchange), admin, exchangeGuardianRole);
  }

  function test_RescueERC20Tokens_ZeroBalance() public {
    _testRescueERC20TokensZeroBalance(address(exchange), guardian);
  }

  function test_RescueERC20Tokens_PartialAmount() public {
    _testRescueERC20TokensPartialAmount(address(exchange), guardian);
  }

  function test_RescueERC20Tokens_ExceedsBalance() public {
    _testRescueERC20TokensExceedsBalance(address(exchange), guardian);
  }

  function test_RescueERC721_Success() public {
    _testRescueERC721TokensSuccess(address(exchange), guardian);
  }

  function test_RescueERC721_Reverts_WhenNotGuardian() public {
    _testRescueERC721TokensRevertsIfNotGuardian(address(exchange), randomUser, exchangeGuardianRole);
  }

  function test_RescueERC721_Reverts_WhenAdmin() public {
    _testRescueERC721TokensRevertsIfAdminNotGuardian(address(exchange), admin, exchangeGuardianRole);
  }

  function test_RescueERC721_Multiple() public {
    _testRescueERC721TokensMultiple(address(exchange), guardian);
  }

  function test_SetRecoveryAddress_Success() public {
    _testSetRecoveryAddressSuccess(address(exchange), guardian);
  }

  function test_SetRecoveryAddress_Reverts_WhenNotGuardian() public {
    _testSetRecoveryAddressRevertsIfNotGuardian(address(exchange), randomUser, exchangeGuardianRole);
  }

  function test_SetRecoveryAddress_Reverts_WhenZeroAddress() public {
    _testSetRecoveryAddressRevertsIfZeroAddress(address(exchange), guardian);
  }
}
