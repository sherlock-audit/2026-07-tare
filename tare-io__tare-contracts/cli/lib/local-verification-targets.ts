
export const LOCAL_VERIFICATION_TARGETS: ReadonlyArray<{
  deploymentFile: "loans" | "accounts"
  contractKey: string
  artifactPath: string
  contractIdentifier: string
}> = [
  {
    deploymentFile: "loans",
    contractKey: "USDC",
    artifactPath: "out/USDC.sol/MockUSDC.json",
    contractIdentifier: "test/lib/USDC.sol:MockUSDC",
  },
  {
    deploymentFile: "loans",
    contractKey: "Loans",
    artifactPath: "out/Loans.sol/Loans.json",
    contractIdentifier: "contracts/Loans.sol:Loans",
  },
  {
    deploymentFile: "loans",
    contractKey: "LoansNFT",
    artifactPath: "out/LoansNFT.sol/LoansNFT.json",
    contractIdentifier: "contracts/LoansNFT.sol:LoansNFT",
  },
  {
    deploymentFile: "loans",
    contractKey: "HotSafe",
    artifactPath: "out/SafeProxy.sol/SafeProxy.json",
    contractIdentifier: "lib/safe-smart-account/contracts/proxies/SafeProxy.sol:SafeProxy",
  },
  {
    deploymentFile: "accounts",
    contractKey: "SafeProxyFactory",
    artifactPath: "out/SafeProxyFactory.sol/SafeProxyFactory.json",
    contractIdentifier: "lib/safe-smart-account/contracts/proxies/SafeProxyFactory.sol:SafeProxyFactory",
  },
  {
    deploymentFile: "accounts",
    contractKey: "MultiSendCallOnly",
    artifactPath: "out/MultiSendCallOnly.sol/MultiSendCallOnly.json",
    contractIdentifier: "lib/safe-smart-account/contracts/libraries/MultiSendCallOnly.sol:MultiSendCallOnly",
  },
  {
    deploymentFile: "accounts",
    contractKey: "SmartAccountFactory",
    artifactPath: "out/SmartAccountFactory.sol/SmartAccountFactory.json",
    contractIdentifier: "contracts/SmartAccountFactory.sol:SmartAccountFactory",
  },
  {
    deploymentFile: "accounts",
    contractKey: "TrustedSpender",
    artifactPath: "out/TrustedSpender.sol/TrustedSpender.json",
    contractIdentifier: "contracts/TrustedSpender.sol:TrustedSpender",
  },
  {
    deploymentFile: "accounts",
    contractKey: "TrustedCalls",
    artifactPath: "out/TrustedCalls.sol/TrustedCalls.json",
    contractIdentifier: "contracts/TrustedCalls.sol:TrustedCalls",
  },
]