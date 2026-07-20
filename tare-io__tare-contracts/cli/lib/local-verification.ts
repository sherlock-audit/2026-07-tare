import { existsSync, readFileSync } from "fs"
import { resolve } from "path"
import { sleep, loadDeploymentManifest } from "./utils.js"
import { LOCAL_VERIFICATION_TARGETS } from "./local-verification-targets.js"

interface LocalVerificationTarget {
  address: string
  contractIdentifier: string
  artifactPath: string
}

interface SourcifyVerificationResponse {
  verificationId: string
}

interface SourcifyVerificationJob {
  isJobCompleted: boolean
  contract?: { runtimeMatch: string | null }
  error?: { customCode?: string; message?: string }
}

function getLocalVerificationTargets(root: string, chain: string, shortName: string): LocalVerificationTarget[] {
  const loansDeployment = loadDeploymentManifest(root, chain, shortName, "loans")
  const accountsDeployment = loadDeploymentManifest(root, chain, shortName, "accounts")

  return LOCAL_VERIFICATION_TARGETS.map((target) => {
    const deployment = target.deploymentFile === "loans" ? loansDeployment : accountsDeployment
    const address = deployment.contracts[target.contractKey]
    if (!address) {
      throw new Error(`Missing ${target.contractKey} address in ${target.deploymentFile} deployment output`)
    }
    return { address, artifactPath: target.artifactPath, contractIdentifier: target.contractIdentifier }
  })
}

function buildSourcifyPayload(root: string, target: LocalVerificationTarget): { stdJsonInput: unknown; compilerVersion: string; contractIdentifier: string } {
  const artifact = JSON.parse(readFileSync(resolve(root, target.artifactPath), "utf8")) as {
    metadata: {
      compiler: { version: string }
      language: string
      settings: Record<string, unknown> & { compilationTarget?: unknown }
      sources: Record<string, unknown>
    }
  }

  const settings = { ...artifact.metadata.settings }
  delete settings.compilationTarget

  const sources = Object.fromEntries(
    Object.keys(artifact.metadata.sources).map((sourcePath) => {
      const fullPath = resolve(root, sourcePath)
      if (!existsSync(fullPath)) {
        throw new Error(`Source file ${sourcePath} not found at ${fullPath} (required by ${target.contractIdentifier})`)
      }
      return [sourcePath, { content: readFileSync(fullPath, "utf8") }]
    })
  )

  return {
    stdJsonInput: { language: artifact.metadata.language, sources, settings },
    compilerVersion: artifact.metadata.compiler.version,
    contractIdentifier: target.contractIdentifier,
  }
}

async function isAlreadyVerified(sourcifyBaseUrl: string, chainId: string, address: string): Promise<boolean> {
  try {
    const response = await fetch(`${sourcifyBaseUrl}/v2/contract/${chainId}/${address}`, {
      signal: AbortSignal.timeout(10_000),
    })
    if (!response.ok) return false
    const data = (await response.json()) as { runtimeMatch?: string }
    return data.runtimeMatch === "exact_match"
  } catch {
    return false
  }
}

const POLL_MAX_ATTEMPTS = 60
const POLL_INTERVAL_MS = 1_000

async function waitUntilVerified(sourcifyBaseUrl: string, chainId: string, address: string): Promise<void> {
  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    if (await isAlreadyVerified(sourcifyBaseUrl, chainId, address)) return
    await sleep(POLL_INTERVAL_MS)
  }
  throw new Error(`Timed out waiting for ${address} to be verified`)
}

async function submitVerification(
  sourcifyBaseUrl: string,
  chainId: string,
  root: string,
  target: LocalVerificationTarget
): Promise<string | null> {
  if (await isAlreadyVerified(sourcifyBaseUrl, chainId, target.address)) {
    console.log(`  ${target.contractIdentifier}: already verified`)
    return null
  }

  const response = await fetch(`${sourcifyBaseUrl}/v2/verify/${chainId}/${target.address}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(buildSourcifyPayload(root, target)),
    signal: AbortSignal.timeout(30_000),
  })

  if (!response.ok) {
    const text = await response.text()
    let parsed: { customCode?: string } | undefined
    try { parsed = JSON.parse(text) } catch {}

    if (parsed?.customCode === "already_verified") {
      console.log(`  ${target.contractIdentifier}: already verified`)
      return null
    }
    if (parsed?.customCode === "duplicate_verification_request") {
      console.log(`  ${target.contractIdentifier}: verification in progress, waiting...`)
      await waitUntilVerified(sourcifyBaseUrl, chainId, target.address)
      return null
    }
    throw new Error(`Submit failed for ${target.contractIdentifier}: ${text}`)
  }

  return ((await response.json()) as SourcifyVerificationResponse).verificationId
}

async function waitForVerification(sourcifyBaseUrl: string, verificationId: string): Promise<void> {
  for (let attempt = 0; attempt < POLL_MAX_ATTEMPTS; attempt++) {
    const response = await fetch(`${sourcifyBaseUrl}/v2/verify/${verificationId}`, {
      signal: AbortSignal.timeout(10_000),
    })
    if (!response.ok) throw new Error(`Poll failed for ${verificationId}: ${response.status}`)

    const job = (await response.json()) as SourcifyVerificationJob
    if (!job.isJobCompleted) {
      await sleep(POLL_INTERVAL_MS)
      continue
    }

    if (job.error) {
      if (job.error.customCode === "already_verified") return
      throw new Error(job.error.message ?? `Verification failed for job ${verificationId}`)
    }

    if (job.contract?.runtimeMatch === "exact_match") return

    throw new Error(`No exact match for job ${verificationId}`)
  }
  throw new Error(`Timed out waiting for job ${verificationId}`)
}

const MAX_RETRIES = 3

async function verifyContract(sourcifyBaseUrl: string, chainId: string, root: string, target: LocalVerificationTarget): Promise<void> {
  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      const id = await submitVerification(sourcifyBaseUrl, chainId, root, target)
      if (id) await waitForVerification(sourcifyBaseUrl, id)
      return
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      if (attempt < MAX_RETRIES) {
        console.warn(`  ${target.contractIdentifier}: attempt ${attempt}/${MAX_RETRIES} failed: ${msg}. Retrying...`)
        await sleep(2_000 * attempt)
      } else {
        throw new Error(`${target.contractIdentifier} failed after ${MAX_RETRIES} attempts: ${msg}`)
      }
    }
  }
}

export async function verifyLocalDeploymentWithSourcify(root: string, chain: string, shortName: string, chainId: string): Promise<void> {
  const sourcifyBaseUrl = process.env.SOURCIFY_URL?.replace(/\/+$/, "")
  if (!sourcifyBaseUrl) {
    console.warn("SOURCIFY_URL not set, skipping local verification")
    return
  }

  const targets = getLocalVerificationTargets(root, chain, shortName)
  console.log(`Verifying ${targets.length} contracts via Sourcify...`)

  await Promise.all(targets.map((t) => verifyContract(sourcifyBaseUrl, chainId, root, t)))

  console.log(`Verified ${targets.length} contracts via Sourcify.`)
}
