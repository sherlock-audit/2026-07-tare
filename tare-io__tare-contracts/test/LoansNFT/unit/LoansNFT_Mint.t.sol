// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansNFTTestBase} from "../setup/LoansNFTTestBase.t.sol";
import {ILoansNFT, ILockable} from "contracts/interfaces/ILoansNFT.sol";

contract LoansNFT_MintTest is LoansNFTTestBase {
  function testFuzz_Mint_Success_WhenCalledByLoansContract(uint256 tokenId) public {
    vm.prank(address(loans));
    loansNFT.mint(borrower, tokenId);

    assertEq(loansNFT.ownerOf(tokenId), borrower);
    assertEq(loansNFT.totalSupply(), 1);
  }

  function test_Mint_UpdatesTotalSupply() public {
    assertEq(loansNFT.totalSupply(), 0);

    vm.prank(address(loans));
    loansNFT.mint(borrower, 1);
    assertEq(loansNFT.totalSupply(), 1);

    vm.prank(address(loans));
    loansNFT.mint(borrower, 2);
    assertEq(loansNFT.totalSupply(), 2);
  }

  function test_Mint_UpdatesTokenByIndex() public {
    vm.startPrank(address(loans));
    loansNFT.mint(borrower, 10);
    loansNFT.mint(borrower, 20);
    vm.stopPrank();

    assertEq(loansNFT.tokenByIndex(0), 10);
    assertEq(loansNFT.tokenByIndex(1), 20);
  }

  function test_Mint_Reverts_WhenCalledByAdmin() public {
    vm.prank(admin);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.mint(borrower, 1);
  }

  function test_Mint_Reverts_WhenCalledByRandomUser() public {
    vm.prank(randomUser);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.mint(borrower, 1);
  }

  function test_Mint_Reverts_WhenCalledByGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(ILockable.Unauthorized.selector);
    loansNFT.mint(borrower, 1);
  }
}
