// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Loans} from "contracts/Loans.sol";
import {LoansNFT} from "contracts/LoansNFT.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Tests for Loans.setLoansNFT()
contract Loans_SetLoansNFTTest is LoansTestBase {
  Loans public freshLoans;

  function setUp() public override {
    super.setUp();
    // Deploy a fresh Loans contract without setLoansNFT called
    freshLoans = new Loans(IERC20(address(usdc)), guardian, recoveryAddress);
    vm.prank(guardian);
    freshLoans.grantRole(keccak256("ADMIN_ROLE"), admin);
  }

  function test_SetLoansNFT_Success() public {
    LoansNFT nft = new LoansNFT(address(freshLoans), "Test", "https://test/");

    vm.prank(admin);
    freshLoans.setLoansNFT(address(nft));

    assertEq(address(freshLoans.loansNFT()), address(nft));
  }

  function test_SetLoansNFT_RevertsWhenNotAdmin() public {
    LoansNFT nft = new LoansNFT(address(freshLoans), "Test", "https://test/");

    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        randomUser,
        keccak256("ADMIN_ROLE")
      )
    );
    freshLoans.setLoansNFT(address(nft));
  }

  function test_SetLoansNFT_RevertsWhenAlreadyInitialized() public {
    LoansNFT nft = new LoansNFT(address(freshLoans), "Test", "https://test/");

    vm.prank(admin);
    freshLoans.setLoansNFT(address(nft));

    LoansNFT nft2 = new LoansNFT(address(freshLoans), "Test2", "https://test2/");

    vm.prank(admin);
    vm.expectRevert(ILoans.AlreadyInitialized.selector);
    freshLoans.setLoansNFT(address(nft2));
  }

  function test_SetLoansNFT_RevertsWithZeroAddress() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.ZeroAddress.selector);
    freshLoans.setLoansNFT(address(0));
  }
}
