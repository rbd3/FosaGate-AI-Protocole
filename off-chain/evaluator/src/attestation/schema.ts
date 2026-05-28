export interface TransactionIntent {
  agent: string;
  target: string;
  payload: string;
  value: string; // uint256 string (wei)
  nonce: string; // uint256 string
  chainId: number;
}

export enum Verdict {
  APPROVED = 0,
  REJECTED_HIGH_RISK = 1,
  REJECTED_POLICY_VIOLATION = 2,
  REJECTED_INVALID_ATTESTATION = 3
}

export interface AnalysisResult {
  mevScore: number;       // 0-1000
  slippageScore: number;  // 0-1000
  contractScore: number;  // 0-1000
  valueScore: number;     // 0-1000
  compositeScore: number; // 0-1000
  matchedPatterns: string[];
  balanceChanges: {
    token: string;
    delta: string; // balance change (positive or negative)
  }[];
  reasoning: string;
  verdict: Verdict;
}

export interface AttestationData {
  txId: string;        // bytes32 hex
  riskScore: bigint;   // uint256 (0-1000)
  verdict: Verdict;    // uint8
  nonce: bigint;       // uint256
  expiry: bigint;      // uint256 (unix timestamp)
}

export interface SignedAttestation {
  attestation: string; // 225-byte hex string starting with 0x
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
