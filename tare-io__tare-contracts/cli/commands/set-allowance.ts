import type { Command } from "commander"
import { resolveDeployment, readContractAddress, castSend } from "../lib/cast.js"
import { outputResult } from "../lib/output.js"
import {
  checkAllowance,
  setAllowanceViaSafe,
  resolveCurrency,
  checkNFTAllowance,
  setNFTAllowanceViaSafe,
  resolveLoansNft,
} from "../lib/allowance.js"
import { isMaxUint208Allowance } from "../lib/onchain.js"
import { MAX_UINT208, NO_EXPIRY, displayAmount, displayExpiry } from "../lib/constants.js"

export function registerSetAllowance(program: Command): void {
  const cmd = program.command("set-allowance").description("Manage TrustedSpender allowances")

  cmd
    .command("set")
    .description("Set a TrustedSpender allowance for a token/from/to route")
    .requiredOption("--from <address>", "Source smart account address")
    .requiredOption("--to <address>", "Trusted recipient address")
    .option("--token <address>", "Token address (defaults to Loans currency)")
    .option("--amount <uint208>", "Allowance amount (defaults to max uint208)", MAX_UINT208)
    .option("--valid-until <uint48>", "Validity timestamp (defaults to no expiry)", NO_EXPIRY)
    .option("--smart-account <address>", "Execute via Safe (sender must be an owner)")
    .action(function (
      this: Command,
      opts: { from: string; to: string; token?: string; amount: string; validUntil: string; smartAccount?: string }
    ) {
      const deployment = resolveDeployment(this)
      const trustedSpender = readContractAddress(deployment.root, deployment.config, "accounts", "TrustedSpender")
      const token = opts.token ?? resolveCurrency(deployment)

      if (opts.smartAccount) {
        const { txHashes } = setAllowanceViaSafe(
          opts.smartAccount,
          trustedSpender,
          token,
          opts.from,
          opts.to,
          opts.amount,
          opts.validUntil,
          deployment
        )
        outputResult(this, {
          status: "ok",
          command: "set-allowance set",
          data: {
            token,
            from: opts.from,
            to: opts.to,
            amount: displayAmount(opts.amount, MAX_UINT208),
            validUntil: displayExpiry(opts.validUntil),
            trustedSpender,
            smartAccount: opts.smartAccount,
            txHashes,
          },
        })
      } else {
        const { txHash } = castSend(
          trustedSpender,
          "setAllowance(address,address,address,uint208,uint48)",
          [token, opts.from, opts.to, opts.amount, opts.validUntil],
          deployment
        )
        outputResult(this, {
          status: "ok",
          command: "set-allowance set",
          data: {
            token,
            from: opts.from,
            to: opts.to,
            amount: displayAmount(opts.amount, MAX_UINT208),
            validUntil: displayExpiry(opts.validUntil),
            trustedSpender,
          },
          txHash,
        })
      }
    })

  cmd
    .command("check")
    .description("Check a TrustedSpender allowance for a token/from/to route")
    .requiredOption("--from <address>", "Source smart account address")
    .requiredOption("--to <address>", "Trusted recipient address")
    .option("--token <address>", "Token address (defaults to Loans currency)")
    .action(function (this: Command, opts: { from: string; to: string; token?: string }) {
      const deployment = resolveDeployment(this)
      const trustedSpender = readContractAddress(deployment.root, deployment.config, "accounts", "TrustedSpender")
      const token = opts.token ?? resolveCurrency(deployment)

      const allowance = checkAllowance(trustedSpender, token, opts.from, opts.to, deployment)

      outputResult(this, {
        status: "ok",
        command: "set-allowance check",
        data: {
          token,
          from: opts.from,
          to: opts.to,
          allowance,
          isMaxAllowance: isMaxUint208Allowance(allowance),
          trustedSpender,
        },
      })
    })

  cmd
    .command("set-nft")
    .description("Set a TrustedSpender NFT allowance for a collection/from/to route")
    .requiredOption("--from <address>", "Source smart account address")
    .requiredOption("--to <address>", "Destination address")
    .option("--collection <address>", "ERC721 collection (defaults to LoansNFT)")
    .option("--allowed <bool>", "Whether the route is allowed", "true")
    .option("--valid-until <uint48>", "Validity timestamp (defaults to no expiry)", NO_EXPIRY)
    .option("--smart-account <address>", "Execute via Safe (sender must be an owner)")
    .action(function (
      this: Command,
      opts: {
        from: string
        to: string
        collection?: string
        allowed: string
        validUntil: string
        smartAccount?: string
      }
    ) {
      const deployment = resolveDeployment(this)
      const trustedSpender = readContractAddress(deployment.root, deployment.config, "accounts", "TrustedSpender")
      const collection = opts.collection ?? resolveLoansNft(deployment)

      // `setNFTAllowance` is `safeOrGuardian(from)`, so the owning Safe has to be the sender.
      let txHash: string | undefined
      let txHashes: string[] | undefined
      if (opts.smartAccount) {
        ;({ txHashes } = setNFTAllowanceViaSafe(
          opts.smartAccount,
          trustedSpender,
          collection,
          opts.from,
          opts.to,
          opts.allowed,
          opts.validUntil,
          deployment
        ))
      } else {
        ;({ txHash } = castSend(
          trustedSpender,
          "setNFTAllowance(address,address,address,bool,uint48)",
          [collection, opts.from, opts.to, opts.allowed, opts.validUntil],
          deployment
        ))
      }

      outputResult(this, {
        status: "ok",
        command: "set-allowance set-nft",
        data: {
          collection,
          from: opts.from,
          to: opts.to,
          allowed: opts.allowed,
          validUntil: displayExpiry(opts.validUntil),
          trustedSpender,
          smartAccount: opts.smartAccount ?? null,
          ...(txHashes ? { txHashes } : {}),
        },
        txHash,
      })
    })

  cmd
    .command("check-nft")
    .description("Check a TrustedSpender NFT allowance for a collection/from/to route")
    .requiredOption("--from <address>", "Source smart account address")
    .requiredOption("--to <address>", "Destination address")
    .option("--collection <address>", "ERC721 collection (defaults to LoansNFT)")
    .action(function (this: Command, opts: { from: string; to: string; collection?: string }) {
      const deployment = resolveDeployment(this)
      const trustedSpender = readContractAddress(deployment.root, deployment.config, "accounts", "TrustedSpender")
      const collection = opts.collection ?? resolveLoansNft(deployment)

      const allowance = checkNFTAllowance(trustedSpender, collection, opts.from, opts.to, deployment)

      outputResult(this, {
        status: "ok",
        command: "set-allowance check-nft",
        data: { collection, from: opts.from, to: opts.to, allowance, trustedSpender },
      })
    })
}
