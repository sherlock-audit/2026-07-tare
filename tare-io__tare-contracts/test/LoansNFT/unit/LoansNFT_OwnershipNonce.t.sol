// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansNFTTestBase} from "../setup/LoansNFTTestBase.t.sol";

contract LoansNFT_OwnershipNonceTest is LoansNFTTestBase {
  uint256 internal constant TOKEN_ID = 42;

  function test_OwnershipNonce_StartsAtZero() public view {
    assertEq(loansNFT.ownershipNonce(borrower), 0);
    assertEq(loansNFT.ownershipNonce(randomUser), 0);
  }

  function test_OwnershipNonce_IncrementsRecipient_OnMint() public {
    uint256 borrowerBefore = loansNFT.ownershipNonce(borrower);
    uint256 randomBefore = loansNFT.ownershipNonce(randomUser);

    vm.prank(address(loans));
    loansNFT.mint(borrower, TOKEN_ID);

    assertEq(loansNFT.ownershipNonce(borrower), borrowerBefore + 1, "recipient nonce bumped");
    assertEq(loansNFT.ownershipNonce(randomUser), randomBefore, "unrelated address untouched");
  }

  function test_OwnershipNonce_IncrementsBothParties_OnTransfer() public {
    vm.prank(address(loans));
    loansNFT.mint(borrower, TOKEN_ID);

    uint256 borrowerBefore = loansNFT.ownershipNonce(borrower);
    uint256 randomBefore = loansNFT.ownershipNonce(randomUser);

    vm.prank(borrower);
    loansNFT.transferFrom(borrower, randomUser, TOKEN_ID);

    assertEq(loansNFT.ownershipNonce(borrower), borrowerBefore + 1, "sender nonce bumped");
    assertEq(loansNFT.ownershipNonce(randomUser), randomBefore + 1, "receiver nonce bumped");
  }

  function test_OwnershipNonce_TracksPerAddress_AcrossMultipleOperations() public {
    uint256 borrowerStart = loansNFT.ownershipNonce(borrower);
    uint256 randomUserStart = loansNFT.ownershipNonce(randomUser);

    // 3 mints to borrower
    vm.startPrank(address(loans));
    loansNFT.mint(borrower, 1);
    loansNFT.mint(borrower, 2);
    loansNFT.mint(borrower, 3);
    vm.stopPrank();

    // 2 transfers from borrower
    vm.startPrank(borrower);
    loansNFT.transferFrom(borrower, randomUser, 1);
    loansNFT.transferFrom(borrower, randomUser, 2);
    vm.stopPrank();

    assertEq(
      loansNFT.ownershipNonce(borrower),
      borrowerStart + 5,
      "borrower bumped on each mint and outbound transfer"
    );
    assertEq(loansNFT.ownershipNonce(randomUser), randomUserStart + 2, "randomUser bumped only on inbound transfers");
  }
}
