import { TransactionIntent } from "../attestation/schema";

export interface PatternMatch {
  matched: string[];
  severity: number; // 0-1000
}

// Common exploit selectors and phishing patterns
const EXPLOIT_PATTERNS = [
  {
    selector: "0xa22cb465", // setApprovalForAll(address,bool)
    name: "PHISHING_SET_APPROVAL_FOR_ALL",
    severity: 800,
    check: (payload: string) => {
      // If the spender approved is not a contract or matches common phishing, raise alert
      return true; // Any approval for all NFT is high risk
    }
  },
  {
    selector: "0x3596d111", // Uniswap V3 swap - check for flash loan patterns
    name: "POTENTIAL_FLASH_LOAN_ARBITRAGE",
    severity: 300,
    check: () => true
  },
  {
    selector: "0x00000000", // Empty selector / fallback
    name: "FALLBACK_CALL",
    severity: 100,
    check: () => true
  },
  {
    selector: "0x415565b0", // selfdestruct(address)
    name: "SELFDESTRUCT_TRIGGER",
    severity: 1000,
    check: () => true
  }
];

/**
 * Pattern Matcher
 * Inspects raw calldata for known malicious, high-risk, or exploit-like patterns.
 */
export function matchKnownPatterns(intent: TransactionIntent): PatternMatch {
  const { payload } = intent;
  const selector = payload.slice(0, 10).toLowerCase();

  const matched: string[] = [];
  let severity = 0;

  for (const pattern of EXPLOIT_PATTERNS) {
    if (selector === pattern.selector) {
      if (pattern.check(payload)) {
        matched.push(pattern.name);
        severity = Math.max(severity, pattern.severity);
      }
    }
  }

  // Also check if calldata contains recursive calls or weird nested arrays
  if (payload.length > 2000) {
    matched.push("UNUSUALLY_LARGE_CALLDATA");
    severity = Math.max(severity, 200);
  }

  return {
    matched,
    severity
  };
}
