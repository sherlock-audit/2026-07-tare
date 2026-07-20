// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansNFTTestBase} from "../setup/LoansNFTTestBase.t.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// ============================================================================
// supportsInterface
// ============================================================================

contract LoansNFT_SupportsInterfaceTest is LoansNFTTestBase {
  function test_SupportsInterface_ERC721() public view {
    assertTrue(loansNFT.supportsInterface(type(IERC721).interfaceId));
  }

  function test_SupportsInterface_ERC721Enumerable() public view {
    assertTrue(loansNFT.supportsInterface(type(IERC721Enumerable).interfaceId));
  }

  function test_SupportsInterface_ERC165() public view {
    assertTrue(loansNFT.supportsInterface(0x01ffc9a7));
  }

  function test_SupportsInterface_ReturnsFalse_ForUnsupportedInterface() public view {
    assertFalse(loansNFT.supportsInterface(0xffffffff));
  }
}

// ============================================================================
// tokenURI
// ============================================================================

contract LoansNFT_TokenURITest is LoansNFTTestBase {
  function testFuzz_TokenURI_ReturnsBaseURIPlusTokenId(uint256 tokenId) public {
    vm.prank(address(loans));
    loansNFT.mint(borrower, tokenId);

    assertEq(loansNFT.tokenURI(tokenId), string.concat(BASE_URI, vm.toString(tokenId)));
  }

  function test_TokenURI_RevertsForNonExistentToken() public {
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(999)));
    loansNFT.tokenURI(999);
  }

  function test_TokenURI_ReflectsUpdatedBaseURI() public {
    uint64 id = _createTestLoan(PRINCIPAL);

    vm.prank(admin);
    loansNFT.setBaseURI(NEW_BASE_URI);

    assertEq(loansNFT.tokenURI(uint256(id)), string.concat(NEW_BASE_URI, vm.toString(uint256(id))));
  }
}
