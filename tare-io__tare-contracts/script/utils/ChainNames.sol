// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/**
 * @title ChainNames
 * @notice Canonical chain-name registry used by deployment scripts for manifest paths and logs.
 */
library ChainNames {
  /** @notice Returns a canonical chain name for the known production/test chains. */
  function getChainName(uint256 chainId) internal pure returns (string memory) {
    if (chainId == 1) return "mainnet";
    if (chainId == 84532) return "baseSepolia";
    if (chainId == 8453) return "base";
    if (chainId == 11155111) return "sepolia";
    if (chainId == 43113) return "avalancheFuji";
    if (chainId == 31337) return "foundry";
    if (chainId == 43114) return "avalanche";
    return "unknown";
  }
}
