// @ts-check
import { foundry, actions } from "@wagmi/cli/plugins"
import { base, baseSepolia } from "@wagmi/core/chains"
import { defineConfig, loadEnv } from "@wagmi/cli"
import { erc20Abi } from "viem"
import { type FoundryConfig } from "@wagmi/cli/plugins"
import baseSepoliaDeployment from "./deployments/baseSepolia/dev/loans/latest.json" with { type: "json" }

export default defineConfig(() => {
  const env = loadEnv({
    mode: process.env.NODE_ENV,
    envDir: process.cwd(),
  })

  return {
    out: "src/abis.ts",
    contracts: [
      {
        name: "USDC",
        address: baseSepoliaDeployment.contracts.USDC as `0x${string}`,
        abi: erc20Abi,
      },
    ],
    plugins: [
      actions(),
      foundry({
        project: "./",
        include: [
          "Loans.sol/*.json",
          "LoansExchange.sol/LoansExchange.json",
          "LoansNFT.sol/LoansNFT.json",
          "SmartAccountFactory.sol/SmartAccountFactory.json",
          "TrustedSpender.sol/*.json",
          "TrustedCalls.sol/*.json",
          "MultiSendCallOnly.sol/MultiSendCallOnly.json",
          "PortfolioVault.sol/PortfolioVault.json",
          "VaultShareToken.sol/VaultShareToken.json",
          "NavCalculator.sol/NavCalculator.json",
        ],
      } as FoundryConfig),
    ],
  }
})
