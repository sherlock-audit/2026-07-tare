// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Minimal ERC-721 mock with public minting for tests.
contract MockERC721 is ERC721 {
  constructor() ERC721("MockNFT", "MNFT") {}

  function mint(address to, uint256 tokenId) external {
    _mint(to, tokenId);
  }
}
