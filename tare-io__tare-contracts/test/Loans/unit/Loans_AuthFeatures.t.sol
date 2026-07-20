// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {RescueTokensTestBase} from "../../helpers/RescueTokensTestBase.sol";

contract Loans_AdminFeaturesTest is LoansTestBase, RescueTokensTestBase {
  function test_rescueERC20Tokens_Success() public {
    _testRescueERC20TokensSuccess(address(loans), guardian);
  }

  function test_rescueERC20Tokens_RevertsIfNotGuardian() public {
    _testRescueERC20TokensRevertsIfNotGuardian(address(loans), randomUser, loans.GUARDIAN_ROLE());
  }

  function test_rescueERC20Tokens_RevertsIfAdmin() public {
    _testRescueERC20TokensRevertsIfAdminNotGuardian(address(loans), admin, loans.GUARDIAN_ROLE());
  }

  function test_rescueERC20Tokens_ZeroBalance() public {
    _testRescueERC20TokensZeroBalance(address(loans), guardian);
  }

  function test_rescueERC20Tokens_PartialAmount() public {
    _testRescueERC20TokensPartialAmount(address(loans), guardian);
  }

  function test_rescueERC20Tokens_ExceedsBalance() public {
    _testRescueERC20TokensExceedsBalance(address(loans), guardian);
  }

  function test_rescueERC721Tokens_Success() public {
    _testRescueERC721TokensSuccess(address(loans), guardian);
  }

  function test_rescueERC721Tokens_RevertsIfNotGuardian() public {
    _testRescueERC721TokensRevertsIfNotGuardian(address(loans), randomUser, loans.GUARDIAN_ROLE());
  }

  function test_rescueERC721Tokens_RevertsIfAdmin() public {
    _testRescueERC721TokensRevertsIfAdminNotGuardian(address(loans), admin, loans.GUARDIAN_ROLE());
  }

  function test_rescueERC721Tokens_Multiple() public {
    _testRescueERC721TokensMultiple(address(loans), guardian);
  }

  function test_setRecoveryAddress_Success() public {
    _testSetRecoveryAddressSuccess(address(loans), guardian);
  }

  function test_setRecoveryAddress_RevertsIfNotGuardian() public {
    _testSetRecoveryAddressRevertsIfNotGuardian(address(loans), randomUser, loans.GUARDIAN_ROLE());
  }

  function test_setRecoveryAddress_RevertsIfZeroAddress() public {
    _testSetRecoveryAddressRevertsIfZeroAddress(address(loans), guardian);
  }
}
