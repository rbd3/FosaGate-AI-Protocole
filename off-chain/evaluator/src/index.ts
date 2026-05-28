import { ethers } from "ethers";
import { TransactionIntent, SignedAttestation } from "./attestation/schema";
import { analyzeMevExposure } from "./analyzer/mevDetector";
import { calculateSlippageRisk } from "./analyzer/slippageChecker";
import { scoreTargetContract } from "./analyzer/contractScorer";
import { simulateBalanceImpact } from "./analyzer/balanceImpact";
import { matchKnownPatterns } from "./ai/patternMatcher";
import { computeAIRiskScore } from "./ai/riskModel";
import { signAttestation } from "./attestation/signer";

export * from "./attestation/schema";
export * from "./attestation/signer";
export * from "./analyzer/mevDetector";
export * from "./analyzer/slippageChecker";
export * from "./analyzer/contractScorer";
export * from "./analyzer/balanceImpact";
export * from "./ai/patternMatcher";
export * from "./ai/riskModel";

/**
 * Main off-chain evaluation pipeline entry point.
 * 
 * Takes a transaction intent, runs all risk analyses in parallel,
 * computes the composite score using the AI model, and produces
 * a cryptographically signed attestation if the transaction passes
 * risk validation.
 * 
 * @param intent The transaction parameters (agent, target, payload, value, nonce, chainId)
 * @param evaluatorPrivateKey The private key of the authorized evaluator signing authority
 * @param providerRpcUrl Optional RPC provider url (e.g. Arbitrum Sepolia RPC)
 * @returns The signed attestation details ready to submit on-chain
 */
export async function evaluateTransaction(
  intent: TransactionIntent,
  evaluatorPrivateKey: string,
  providerRpcUrl?: string
): Promise<{ signedAttestation: SignedAttestation; analysis: any }> {
  // Setup provider if RPC URL is available
  let provider: ethers.JsonRpcProvider | undefined;
  if (providerRpcUrl) {
    try {
      provider = new ethers.JsonRpcProvider(providerRpcUrl);
    } catch (e) {
      console.warn("Failed to initialize RPC provider. Running in offline fallback mode.");
    }
  }

  // 1. Run all sub-analyzers in parallel
  const [mevAnalysis, slippageAnalysis, contractAnalysis, balanceAnalysis] = await Promise.all([
    analyzeMevExposure(intent, provider),
    calculateSlippageRisk(intent, provider),
    scoreTargetContract(intent.target, provider),
    simulateBalanceImpact(intent, provider)
  ]);

  // 2. Run pattern matcher (instant synchronous check)
  const patternAnalysis = matchKnownPatterns(intent);

  // 3. Compute final AI risk score and verdict decision
  const finalAnalysis = await computeAIRiskScore(
    intent,
    mevAnalysis,
    slippageAnalysis,
    contractAnalysis,
    balanceAnalysis,
    patternAnalysis
  );

  // 4. Sign the final verdict and generate the 225-byte attestation payload
  const signedAttestation = await signAttestation(
    intent,
    finalAnalysis.compositeScore,
    finalAnalysis.verdict,
    300, // 5 minutes expiry
    evaluatorPrivateKey
  );

  return {
    signedAttestation,
    analysis: finalAnalysis
  };
}
