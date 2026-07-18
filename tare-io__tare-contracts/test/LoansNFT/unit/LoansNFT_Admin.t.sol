// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansNFTTestBase} from "../setup/LoansNFTTestBase.t.sol";
import {ILoansNFT, ILockable} from "contracts/interfaces/ILoansNFT.sol";

contract LoansNFT_SetBaseURITest is LoansNFTTestBase {
  function test_SetBaseURI_UpdatesURI() public {
    uint64 id = _createTestLoan(PRINCIPAL);

    vm.prank(admin);
    loansNFT.setBaseURI(NEW_BASE_URI);

    assertEq(loansNFT.tokenURI(uint256(id)), string.concat(NEW_BASE_URI, vm.toString(uint256(id))));
  }

  function test_SetBaseURI_EmitsEvent() public {
    vm.expectEmit(false, false, false, true);
    emit ILoansNFT.BaseURIUpdated(NEW_BASE_URI);
    vm.prank(admin);
    loansNFT.setBaseURI(NEW_BASE_URI);
  }

  function test_SetBaseURI_AllowsEmptyURI() public {
    uint64 id = _createTestLoan(PRINCIPAL);

    vm.prank(admin);
    loansNFT.setBaseURI("");

    assertEq(loansNFT.tokenURI(uint256(id)), "");
  }

  function test_SetBaseURI_Reverts_WhenCalledByRandomUser() public {
    vm.prank(randomUser);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.setBaseURI(NEW_BASE_URI);
  }

  function test_SetBaseURI_Reverts_WhenCalledByServicer() public {
    vm.prank(servicer);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.setBaseURI(NEW_BASE_URI);
  }

  function test_SetBaseURI_Reverts_WhenCalledByLoansContract() public {
    vm.prank(address(loans));
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.setBaseURI(NEW_BASE_URI);
  }
}
