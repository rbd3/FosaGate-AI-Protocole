// Type declarations for the FosaGate evaluator package
// The evaluator lives at ../../evaluator/src/index.ts (sibling off-chain package)

declare module "@fosagate/evaluator" {
  export interface TransactionIntent {
    agent: string;
    target: string;
    payload: string;
    value: string;
    nonce: string;
    chainId: number;
  }

  export interface SignedAttestation {
    attestation: string;
    decoded: {
      txId: string;
      riskScore: string;
      verdict: number;
      nonce: string;
      expiry: string;
    };
    signature: {
      r: string;
      s: string;
      v: number;
    };
  }

  export interface AnalysisResult {
    mevScore: number;
    slippageScore: number;
    contractScore: number;
    valueScore: number;
    compositeScore: number;
    matchedPatterns: string[];
    balanceChanges: { token: string; delta: string }[];
    reasoning: string;
    verdict: number;
  }

  export function evaluateTransaction(
    intent: TransactionIntent,
    evaluatorPrivateKey: string,
    providerRpcUrl?: string
  ): Promise<{ signedAttestation: SignedAttestation; analysis: AnalysisResult }>;
}
