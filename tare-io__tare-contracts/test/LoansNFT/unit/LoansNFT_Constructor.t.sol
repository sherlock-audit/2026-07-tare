// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansNFTTestBase} from "../setup/LoansNFTTestBase.t.sol";
import {LoansNFT} from "contracts/LoansNFT.sol";
import {ILoansNFT, ILockable} from "contracts/interfaces/ILoansNFT.sol";

contract LoansNFT_ConstructorTest is LoansNFTTestBase {
  function test_Constructor_SetsLoansContract() public view {
    assertEq(loansNFT.LOANS_CONTRACT(), address(loans));
  }

  function test_Constructor_SetsName() public view {
    assertEq(loansNFT.name(), NFT_COLLECTION_NAME);
  }

  function test_Constructor_SetsSymbol() public view {
    assertEq(loansNFT.symbol(), "LOAN");
  }

  function test_Constructor_SetsInitialBaseURI() public {
    uint64 id = _createTestLoan(PRINCIPAL);
    assertEq(loansNFT.tokenURI(uint256(id)), string.concat(BASE_URI, vm.toString(uint256(id))));
  }

  function test_Constructor_Reverts_WhenLoansContractIsZero() public {
    vm.expectRevert(ILockable.Unauthorized.selector);
    new LoansNFT(address(0), "Test", "https://test.com/");
  }
}
