import { ethers } from "ethers";
import { TransactionIntent, AttestationData, SignedAttestation, Verdict } from "./schema";

/**
 * Generate the transaction ID (txId) for an agent transaction intent.
 * Formula: keccak256(abi.encodePacked(agent, target, payload, nonce, chainId))
 */
export function generateTxId(intent: TransactionIntent): string {
  const { agent, target, payload, nonce, chainId } = intent;

  // Emulate abi.encodePacked in Solidity:
  // - agent (address): 20 bytes
  // - target (address): 20 bytes
  // - payload (bytes): raw variable-length bytes
  // - nonce (uint256): 32 bytes
  // - chainId (uint256): 32 bytes
  return ethers.solidityPackedKeccak256(
    ["address", "address", "bytes", "uint256", "uint256"],
    [agent, target, payload, nonce, chainId]
  );
}

/**
 * Sign an attestation using the evaluator's private key.
 * Packs the data fields, hashes them, signs with standard Ethereum Signed Message format,
 * and formats the final 225-byte attestation string.
 */
export async function signAttestation(
  intent: TransactionIntent,
  riskScore: number,
  verdict: Verdict,
  expiryDurationSeconds: number = 300, // Default 5 mins validity
  evaluatorPrivateKey: string
): Promise<SignedAttestation> {
  const wallet = new ethers.Wallet(evaluatorPrivateKey);
  const txId = generateTxId(intent);

  const nonceBigInt = BigInt(intent.nonce);
  const riskScoreBigInt = BigInt(riskScore);
  const currentTimestamp = BigInt(Math.floor(Date.now() / 1000));
  const expiryBigInt = currentTimestamp + BigInt(expiryDurationSeconds);

  // Packed message to sign: keccak256(abi.encodePacked(txId, riskScore, verdict, nonce, expiry))
  // Data layout in solidityPacked:
  // - txId: bytes32 (32 bytes)
  // - riskScore: uint256 (32 bytes)
  // - verdict: uint8 (1 byte)
  // - nonce: uint256 (32 bytes)
  // - expiry: uint256 (32 bytes)
  const packedData = ethers.solidityPacked(
    ["bytes32", "uint256", "uint8", "uint256", "uint256"],
    [txId, riskScoreBigInt, verdict, nonceBigInt, expiryBigInt]
  );

  const messageHash = ethers.keccak256(packedData);

  // Sign message hash. wallet.signMessage automatically prefixes with "\x19Ethereum Signed Message:\n32"
  const signatureHex = await wallet.signMessage(ethers.getBytes(messageHash));
  const sig = ethers.Signature.from(signatureHex);

  // Serialize the full 225-byte attestation buffer:
  // [0..32]   txId (32B)
  // [32..64]  riskScore (32B)
  // [64..96]  verdict (32B padded uint8 -> 31 zero bytes + 1 byte verdict)
  // [96..128] nonce (32B)
  // [128..160]expiry (32B)
  // [160..192]r (32B)
  // [192..224]s (32B)
  // [224]     v (1B)
  const txIdBytes = ethers.getBytes(txId);
  const riskScoreBytes = ethers.toBeArray(ethers.zeroPadValue(ethers.toBeHex(riskScoreBigInt), 32));
  const verdictBytes = ethers.toBeArray(ethers.zeroPadValue(ethers.toBeHex(BigInt(verdict)), 32));
  const nonceBytes = ethers.toBeArray(ethers.zeroPadValue(ethers.toBeHex(nonceBigInt), 32));
  const expiryBytes = ethers.toBeArray(ethers.zeroPadValue(ethers.toBeHex(expiryBigInt), 32));
  const rBytes = ethers.getBytes(sig.r);
  const sBytes = ethers.getBytes(sig.s);
  const vByte = new Uint8Array([sig.v]);

  // Combine all buffers
  const attestationBuffer = new Uint8Array(225);
  attestationBuffer.set(txIdBytes, 0);
  attestationBuffer.set(riskScoreBytes, 32);
  attestationBuffer.set(verdictBytes, 64);
  attestationBuffer.set(nonceBytes, 96);
  attestationBuffer.set(expiryBytes, 128);
  attestationBuffer.set(rBytes, 160);
  attestationBuffer.set(sBytes, 192);
  attestationBuffer.set(vByte, 224);

  const attestationHex = ethers.hexlify(attestationBuffer);

  return {
    attestation: attestationHex,
    decoded: {
      txId,
      riskScore: riskScoreBigInt.toString(),
      verdict,
      nonce: nonceBigInt.toString(),
      expiry: expiryBigInt.toString(),
    },
    signature: {
      r: sig.r,
      s: sig.s,
      v: sig.v,
    },
  };
}

/**
 * Verify a signed attestation locally (off-chain check).
 * Recovers the signer address and returns true if it matches the expected evaluator address.
 */
export function verifyAttestation(
  attestationHex: string,
  expectedEvaluatorAddress: string
): boolean {
  try {
    const attestation = ethers.getBytes(attestationHex);
    if (attestation.length < 225) return false;

    // Extract fields
    const txId = ethers.hexlify(attestation.slice(0, 32));
    const riskScore = ethers.toBigInt(attestation.slice(32, 64));
    const verdict = attestation[95]; // 32 bytes padded, 95th byte is the uint8 value
    const nonce = ethers.toBigInt(attestation.slice(96, 128));
    const expiry = ethers.toBigInt(attestation.slice(128, 160));

    const r = ethers.hexlify(attestation.slice(160, 192));
    const s = ethers.hexlify(attestation.slice(192, 224));
    const v = attestation[224];

    // Compute packed hash
    const packedData = ethers.solidityPacked(
      ["bytes32", "uint256", "uint8", "uint256", "uint256"],
      [txId, riskScore, verdict, nonce, expiry]
    );
    const messageHash = ethers.keccak256(packedData);

    // Reconstruct signature
    const signature = ethers.Signature.from({ r, s, v });

    // Recover signer address
    const recoveredSigner = ethers.verifyMessage(ethers.getBytes(messageHash), signature);

    return recoveredSigner.toLowerCase() === expectedEvaluatorAddress.toLowerCase();
  } catch (error) {
    console.error("Local attestation verification failed:", error);
    return false;
  }
}
