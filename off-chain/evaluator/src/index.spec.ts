import { ethers } from "ethers";
import { evaluateTransaction } from "./index";
import { generateTxId, verifyAttestation } from "./attestation/signer";
import { TransactionIntent, Verdict } from "./attestation/schema";

describe("FosaGate Off-chain Evaluator Tests", () => {
  // Test Private Key (deterministic for testing)
  const TEST_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
  let evaluatorAddress: string;

  beforeAll(() => {
    const wallet = new ethers.Wallet(TEST_PRIVATE_KEY);
    evaluatorAddress = wallet.address;
  });

  test("Should successfully evaluate intent and sign correct 225-byte attestation", async () => {
    // 1. Arrange: Define a swap transaction intent
    const intent: TransactionIntent = {
      agent: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", // Mock Agent Address
      target: "0xE592427A0AEce92De3EdF7a9Cd9373d5D72483d4", // Uniswap V3 Router
      // Uniswap V3 exactInputSingle selector and payload
      payload: "0x414bf389000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000000000bb800000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c80000000000000000000000000000000000000000000000000000000063f582000000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
      value: "0",
      nonce: "42",
      chainId: 421614 // Arbitrum Sepolia
    };

    // 2. Act: Run evaluation
    const result = await evaluateTransaction(intent, TEST_PRIVATE_KEY);

    // 3. Assert
    const { signedAttestation, analysis } = result;

    // Verify attestation length is exactly 225 bytes
    // (A 225-byte hex string starts with '0x' and contains 450 hex characters -> total length 452)
    expect(signedAttestation.attestation.startsWith("0x")).toBe(true);
    expect(signedAttestation.attestation.length).toBe(452);

    // Verify transaction ID matches
    const expectedTxId = generateTxId(intent);
    expect(signedAttestation.decoded.txId).toBe(expectedTxId);

    // Verify decoded values
    expect(signedAttestation.decoded.nonce).toBe("42");
    expect(Number(signedAttestation.decoded.verdict)).toBe(Verdict.APPROVED);

    // Verify cryptographic signature recovers to evaluatorAddress
    const isValid = verifyAttestation(signedAttestation.attestation, evaluatorAddress);
    expect(isValid).toBe(true);

    // Verify analysis matches
    expect(analysis.compositeScore).toBeGreaterThanOrEqual(0);
    expect(analysis.compositeScore).toBeLessThanOrEqual(1000);
  });

  test("Should identify high risk and reject for dangerous transaction intent", async () => {
    // Phishing style intent: unlimited approval (MaxUint256) to a target
    const intent: TransactionIntent = {
      agent: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      target: "0xdAC17F958D2ee523a2206206994597C13D831ec7", // Blacklisted or untrusted EOA
      payload: "0x095ea7b300000000000000000000000095aD61b0a150d79219dCF64E1E6Cc01f0B64C4cEffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", // Unlimited approve
      value: "0",
      nonce: "100",
      chainId: 421614
    };

    const result = await evaluateTransaction(intent, TEST_PRIVATE_KEY);
    const { signedAttestation, analysis } = result;

    expect(Number(signedAttestation.decoded.verdict)).toBe(Verdict.REJECTED_POLICY_VIOLATION);
    expect(analysis.compositeScore).toBeGreaterThanOrEqual(500);
    expect(analysis.matchedPatterns).toContain("BLACKLISTED_MALICIOUS_CONTRACT");
  });
});
