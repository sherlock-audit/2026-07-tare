# Tare contest details

- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the **Issues** page in your private contest repo (label issues as **Medium** or **High**)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)

# Q&A

### Q: On what chains are the smart contracts going to be deployed?
Avalanche C-Chain.
___

### Q: If you are integrating tokens, are you allowing only whitelisted tokens to work with the codebase or any complying with the standard? Are they assumed to have certain properties, e.g. be non-reentrant? Are there any types of [weird tokens](https://github.com/d-xo/weird-erc20) you want to integrate?
In this first version, Tare only supports USDC: https://snowscan.xyz/token/0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e
___

### Q: Are there any limitations on values set by admins (or other roles) in the codebase, including restrictions on array lengths?
**Role trust assumptions**

- Guardian is fully trusted.
- Admin is trusted.
- Servicer is trusted.
- Originator is trusted.
- Portfolio Manager is trusted.
- Investor Manager is trusted.
- Calculating Agent is trusted to value the portfolio correctly.
- The Investor is identified by loan-NFT ownership which can potentially be untrusted
- Borrower, Investor and Servicer are trusted within their individual loan. However, if they can hurt other loans/users, this can be considered valid issue (if qualifies for Medium or Higher severity definitions).


**Limitations on values set by roles**

Because the value-setting functions below are reachable only by trusted roles, they intentionally do **not** enforce economic upper bounds. Specifically:

- **Loan accounting amounts (Servicer/Admin):** `accrue`, `chargeMiscFee`, `applyWaterfall`, and `createLedgerEntries` accept amounts that are computed off-chain, the servicer is trusted to submit correct figures.
- **NAV valuation factors (Calculating Agent / Guardian):** `setDiscountFactor` and `setPortfolioFactor` set the multipliers used to value the portfolio. Discount factors and the portfolio factor sit under fixed/Guardian-configured caps, but within those caps the Calculating Agent is trusted to choose values that are correct (including haircuts). Realistically portfolio factor will be ≤ 1.
- **NAV freshness / timing windows (Admin/Guardian):** `setMaxNavAge` and `setMaxNavComputationTime` accept any positive value; there is no upper bound preventing an unreasonably long staleness or computation window. In practice, maxNavAge and maxNavComputationTime will be set to ~4h/10h and ~30 mins / 1h respectively.
- **Exchange / offer limits (Admin/Guardian):** `setMaxLoansPerOffer` accepts any positive value with no upper bound. Realistically this will be set to ~100-200.
- **Allowances (Safe owner / Guardian):** `setAllowance` on the trusted-spender module accepts an arbitrary amount up to its type maximum; there is no economic cap.
- **Array-length inputs (trusted roles):** Functions that take arrays — NAV loan-set updates (`addLoansToNav` / `removeLoansFromNav`), smart-account configuration arrays (owners, delegates, currencies, NFT collections, trusted recipients), and trusted-call batch registration — do **not** impose a maximum array length. Any resulting gas/DoS exposure requires a trusted role to supply an oversized array and is therefore out of scope.

Any value or array-length input reachable by an **untrusted** party (Borrower, Investor, or an arbitrary caller) that is not adequately bounded **is in scope**.
___

### Q: Are there any limitations on values set by admins (or other roles) in protocols you integrate with, including restrictions on array lengths?
N/A.
___

### Q: Is the codebase expected to comply with any specific EIPs?
See specs.

Issues breaking EIPs can be considered valid only if they lead to Medium or higher impact and qualify for Medium or higher severity definitions
___

### Q: Are there any off-chain mechanisms involved in the protocol (e.g., keeper bots, arbitrage bots, etc.)? We assume these mechanisms will not misbehave, delay, or go offline unless otherwise specified.
There are no independent keeper bots, arbitrage bots, liquidation bots,… At the beginning most of the transactions will be submitted by Tare taking on different “roles” (see below).

## Offchain Systems

- **Loan engine**: computes interest accrual, servicing fees, payoff amounts, payment allocation, delinquency inputs, and status recommendations.
- **Backend transaction layer**: prepares authorized contract calls and tracks confirmation. Delegated calls use the HSM-backed hot wallet -> Hot Proxy Safe -> `TrustedCalls` -> role Smart Account path; the role Smart Account is the contract-visible caller.
- **Event/indexing layer**: consumes contract events for reporting, reconciliation, and UI state; contracts never trust this layer for authorization.
- **Payment/on-off-ramp providers**: today, the backend uses a ramp provider to disburse from the onchain `borrower` role to the end borrower's bank account. On repayment, the backend bridges borrower fiat back to the `borrower` Smart Account and calls `pay`; future deployments may assign the borrower role to a retail wallet/EVM address and accept payments more directly onchain.
- **Managers/operators**: trigger servicing, NAV, vault, exchange, migration, and governance operations. There are no autonomous keeper bots — every operational transaction is submitted by the backend or a human-operated multisig. Contracts enforce permissions and invariants, not business timing.

## Onchain Contact Points

| Area | Contract touchpoint | Trigger mode |
| --- | --- | --- |
| Servicing accrual | `Loans.accrue` | Human/API-triggered via backend for standalone accruals; automated when part of payment processing |
| Payment settlement | `Loans.pay`, `Loans.applyWaterfall` | Automated backend settlement after a payment intent and required payment-rail steps complete |
| Withdrawals | `investorWithdraw`, `servicerWithdraw`, `borrowerWithdraw`, `originatorWithdraw` | Human/operator-triggered via backend or authorized role account |
| Account setup/delegation | `SmartAccountFactory`, `TrustedCalls`, `TrustedSpender` config | Manual/multisig |
| Exchange | `LoansExchange.createOffer`, `acceptOffer`, `cancelOffer` | Human/operator-triggered via backend after offchain negotiation |
| Vault operations | loan curation, NAV updates, NAV factor configuration, deposit/redemption approvals | NAV updates, curation, and deposit/redemption approvals are vault-manager-triggered (`PORTFOLIO_MANAGER`/`INVESTOR_MANAGER`) via the backend; NAV factor configuration is `CALCULATING_AGENT`-triggered; other configuration is manual/timelocked |
| Governance/config | guardian/admin setters, timelock operations | Manual/multisig/timelock |

## Trust Model

- Servicer, originator, admin, guardian, portfolio-manager, investor-manager, and calculating-agent permissions are intentionally powerful and should be analyzed as trusted roles.
- Interest, fees, delinquency, payment schedules, payoff amounts, and many status decisions are computed offchain.
- Contracts validate permissions, ledger/accounting constraints, token custody, cash segregation, and configured invariants; they do not recompute consumer-loan business math.
- Ordinary loan servicing does not rely on an external oracle. Vault NAV is computed onchain from loan state plus discount and portfolio factors configured by the `CALCULATING_AGENT`; the NAV value is refreshed by a vault manager (`PORTFOLIO_MANAGER`/`INVESTOR_MANAGER`) calling `updateNav`(this must be done especially before any approving any deposit/redemption) and there is no automated NAV schedule today.
- Borrowers usually interact in fiat.
___

### Q: What properties/invariants do you want to hold even if breaking them has a low/unknown impact?
See specs/invariants.md in the repo.

Issues breaking Invariants can be considered valid only if they lead to Medium or higher impact and qualify for Medium or higher severity definitions
___

### Q: Please discuss any design choices you made.
See specs and in particular SECURITY.md at the root of the repo.
___

### Q: Please provide links to previous audits (if any) and all the known issues or acceptable risks.
See SECURITY.md and the reports of the previous audits here: https://drive.google.com/drive/folders/1mtasFc-19EDRivo8jTAEv56L6oZgmP7K?usp=sharing
___

### Q: Please list any relevant protocol resources.
All docs are in the repository directly under `/specs`. Additionally, architecture diagrams can be found here: https://drive.google.com/drive/folders/1mtasFc-19EDRivo8jTAEv56L6oZgmP7K?usp=sharing
___

### Q: Additional audit information.
This is a non-exhaustive list but we are interested in findings that relate to:
1. Funds loss: stolen or being stuck
2. Unintended or unfair fund distribution
3. Bypassing intended permissions and role based access control
4. Loans NFT being stuck
5. Going into a state that is unrecoverable (bricking)
6. Accounting issues in Loans ledger or Vault


# Audit scope

[tare-io__tare-contracts @ b215321b218aac7e7fc0072d97c74e93f23bdaf7](https://github.com/sherlock-scoping/tare-io__tare-contracts/tree/b215321b218aac7e7fc0072d97c74e93f23bdaf7)
- [tare-io__tare-contracts/contracts/interfaces/Accounts.sol](tare-io__tare-contracts/contracts/interfaces/Accounts.sol)
- [tare-io__tare-contracts/contracts/interfaces/IERC1404.sol](tare-io__tare-contracts/contracts/interfaces/IERC1404.sol)
- [tare-io__tare-contracts/contracts/interfaces/ILoansExchange.sol](tare-io__tare-contracts/contracts/interfaces/ILoansExchange.sol)
- [tare-io__tare-contracts/contracts/interfaces/ILoansNFT.sol](tare-io__tare-contracts/contracts/interfaces/ILoansNFT.sol)
- [tare-io__tare-contracts/contracts/interfaces/ILoans.sol](tare-io__tare-contracts/contracts/interfaces/ILoans.sol)
- [tare-io__tare-contracts/contracts/interfaces/INavCalculator.sol](tare-io__tare-contracts/contracts/interfaces/INavCalculator.sol)
- [tare-io__tare-contracts/contracts/interfaces/IPortfolioVault.sol](tare-io__tare-contracts/contracts/interfaces/IPortfolioVault.sol)
- [tare-io__tare-contracts/contracts/interfaces/ISmartAccountFactory.sol](tare-io__tare-contracts/contracts/interfaces/ISmartAccountFactory.sol)
- [tare-io__tare-contracts/contracts/interfaces/ITrustedCalls.sol](tare-io__tare-contracts/contracts/interfaces/ITrustedCalls.sol)
- [tare-io__tare-contracts/contracts/interfaces/ITrustedSpender.sol](tare-io__tare-contracts/contracts/interfaces/ITrustedSpender.sol)
- [tare-io__tare-contracts/contracts/interfaces/IVaultShareToken.sol](tare-io__tare-contracts/contracts/interfaces/IVaultShareToken.sol)
- [tare-io__tare-contracts/contracts/interfaces/LedgerEntries.sol](tare-io__tare-contracts/contracts/interfaces/LedgerEntries.sol)
- [tare-io__tare-contracts/contracts/LoansExchange.sol](tare-io__tare-contracts/contracts/LoansExchange.sol)
- [tare-io__tare-contracts/contracts/LoansLedger.sol](tare-io__tare-contracts/contracts/LoansLedger.sol)
- [tare-io__tare-contracts/contracts/LoansNFT.sol](tare-io__tare-contracts/contracts/LoansNFT.sol)
- [tare-io__tare-contracts/contracts/Loans.sol](tare-io__tare-contracts/contracts/Loans.sol)
- [tare-io__tare-contracts/contracts/misc/GuardianAccessControl.sol](tare-io__tare-contracts/contracts/misc/GuardianAccessControl.sol)
- [tare-io__tare-contracts/contracts/misc/interfaces/IERC7540.sol](tare-io__tare-contracts/contracts/misc/interfaces/IERC7540.sol)
- [tare-io__tare-contracts/contracts/misc/interfaces/IERC7575.sol](tare-io__tare-contracts/contracts/misc/interfaces/IERC7575.sol)
- [tare-io__tare-contracts/contracts/misc/interfaces/IGuardianAccessControl.sol](tare-io__tare-contracts/contracts/misc/interfaces/IGuardianAccessControl.sol)
- [tare-io__tare-contracts/contracts/misc/interfaces/ILoansAuth.sol](tare-io__tare-contracts/contracts/misc/interfaces/ILoansAuth.sol)
- [tare-io__tare-contracts/contracts/misc/interfaces/IModuleManager.sol](tare-io__tare-contracts/contracts/misc/interfaces/IModuleManager.sol)
- [tare-io__tare-contracts/contracts/misc/interfaces/IRescuable.sol](tare-io__tare-contracts/contracts/misc/interfaces/IRescuable.sol)
- [tare-io__tare-contracts/contracts/misc/interfaces/ISafe.sol](tare-io__tare-contracts/contracts/misc/interfaces/ISafe.sol)
- [tare-io__tare-contracts/contracts/misc/LoansAuth.sol](tare-io__tare-contracts/contracts/misc/LoansAuth.sol)
- [tare-io__tare-contracts/contracts/misc/Rescuable.sol](tare-io__tare-contracts/contracts/misc/Rescuable.sol)
- [tare-io__tare-contracts/contracts/NavCalculator.sol](tare-io__tare-contracts/contracts/NavCalculator.sol)
- [tare-io__tare-contracts/contracts/PortfolioVault.sol](tare-io__tare-contracts/contracts/PortfolioVault.sol)
- [tare-io__tare-contracts/contracts/SmartAccountFactory.sol](tare-io__tare-contracts/contracts/SmartAccountFactory.sol)
- [tare-io__tare-contracts/contracts/TrustedCalls.sol](tare-io__tare-contracts/contracts/TrustedCalls.sol)
- [tare-io__tare-contracts/contracts/TrustedSpender.sol](tare-io__tare-contracts/contracts/TrustedSpender.sol)
- [tare-io__tare-contracts/contracts/VaultShareToken.sol](tare-io__tare-contracts/contracts/VaultShareToken.sol)


