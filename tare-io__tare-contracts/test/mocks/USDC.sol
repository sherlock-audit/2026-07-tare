// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";

contract MockUSDC is ERC20 {
  constructor() ERC20("USD Coin", "USDC", 6) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}
