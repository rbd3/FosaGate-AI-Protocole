// FosaGate AI Protocol — RiskEngine / Attestation Module
// Author: rbd3
//
// ECDSA signature verification of off-chain evaluator attestations.
// Rust/WASM gives ~10x gas savings over Solidity ecrecover for batch ops.

use stylus_sdk::alloy_primitives::{Address, B256, U256};
use tiny_keccak::{Hasher, Keccak};

// ATTESTATION BYTE LAYOUT (225 bytes total):
//   0x00  32B  txId (bytes32)
//   0x20  32B  riskScore (uint256, 0-1000)
//   0x40  32B  verdict (uint8 padded)
//   0x60  32B  nonce (uint256)
//   0x80  32B  expiry (uint256, unix timestamp)
//   0xA0  32B  r (ECDSA)
//   0xC0  32B  s (ECDSA)
//   0xE0   1B  v (27 or 28)
//
// Signed message: keccak256(abi.encodePacked(txId, riskScore, verdict, nonce, expiry))

pub struct DecodedAttestation {
    pub tx_id: B256,
    pub risk_score: U256,
    pub verdict: u8,     // 0=APPROVED, 1=HIGH_RISK, 2=POLICY, 3=INVALID
    pub nonce: U256,
    pub expiry: U256,
}

pub struct Signature {
    pub r: B256,
    pub s: B256,
    pub v: u8,
}

/// Helper for Keccak256 hashing
pub fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    let mut result = [0u8; 32];
    hasher.update(data);
    hasher.finalize(&mut result);
    result
}

/// Decode raw attestation bytes into structured fields + signature.
/// Validates length >= 225 bytes, extracts each field from fixed offsets.
pub fn decode_attestation(attestation: &[u8]) -> Result<(DecodedAttestation, Signature), &'static str> {
    if attestation.len() < 225 {
        return Err("Attestation too short");
    }

    let tx_id = B256::from_slice(&attestation[0..32]);
    let risk_score = U256::from_be_slice(&attestation[32..64]);
    let verdict = attestation[95]; // uint8 padded to 32 bytes
    let nonce = U256::from_be_slice(&attestation[96..128]);
    let expiry = U256::from_be_slice(&attestation[128..160]);

    let r = B256::from_slice(&attestation[160..192]);
    let s = B256::from_slice(&attestation[192..224]);
    let v = attestation[224];

    Ok((
        DecodedAttestation {
            tx_id,
            risk_score,
            verdict,
            nonce,
            expiry,
        },
        Signature { r, s, v },
    ))
}

/// Reconstruct the message hash: keccak256(abi.encodePacked(txId, riskScore, verdict, nonce, expiry))
/// Must match exactly how the off-chain evaluator constructs the message.
pub fn compute_message_hash(data: &DecodedAttestation) -> B256 {
    let score_bytes: [u8; 32] = data.risk_score.to_be_bytes();
    let nonce_bytes: [u8; 32] = data.nonce.to_be_bytes();
    let expiry_bytes: [u8; 32] = data.expiry.to_be_bytes();

    let mut packed = alloc::vec::Vec::with_capacity(32 + 32 + 1 + 32 + 32);
    packed.extend_from_slice(data.tx_id.as_slice());
    packed.extend_from_slice(&score_bytes);
    packed.push(data.verdict);
    packed.extend_from_slice(&nonce_bytes);
    packed.extend_from_slice(&expiry_bytes);

    let hash = keccak256(&packed);

    let mut eth_packed = alloc::vec::Vec::with_capacity(28 + 32);
    eth_packed.extend_from_slice(b"\x19Ethereum Signed Message:\n32");
    eth_packed.extend_from_slice(&hash);
    
    B256::from_slice(&keccak256(&eth_packed))
}

/// Recover signer address from ECDSA signature using k256 crate.
/// Steps: v→RecoveryId, recover VerifyingKey, keccak256(pubkey)[12..32]
pub fn recover_signer(message_hash: &B256, signature: &Signature) -> Result<Address, &'static str> {
    use k256::ecdsa::{RecoveryId, Signature as K256Signature, VerifyingKey};

    let rec_id = if signature.v >= 27 {
        signature.v - 27
    } else {
        signature.v
    };

    let recovery_id = RecoveryId::try_from(rec_id)
        .map_err(|_| "Invalid recovery ID")?;

    let mut sig_bytes = [0u8; 64];
    sig_bytes[0..32].copy_from_slice(signature.r.as_slice());
    sig_bytes[32..64].copy_from_slice(signature.s.as_slice());

    let sig = K256Signature::from_slice(&sig_bytes)
        .map_err(|_| "Invalid signature scalars")?;

    let verifying_key = VerifyingKey::recover_from_prehash(message_hash.as_slice(), &sig, recovery_id)
        .map_err(|_| "Recover key failed")?;

    let public_key_bytes = verifying_key.to_encoded_point(false);
    let public_key_bytes = public_key_bytes.as_bytes();
    let pubkey_hash = keccak256(&public_key_bytes[1..65]);

    Ok(Address::from_slice(&pubkey_hash[12..32]))
}

/// Full pipeline: decode → hash → recover → verify signer == evaluator → check expiry
pub fn verify_full(
    attestation: &[u8],
    expected_evaluator: Address,
    current_timestamp: U256,
) -> Result<DecodedAttestation, &'static str> {
    let (decoded, signature) = decode_attestation(attestation)?;

    if decoded.expiry < current_timestamp {
        return Err("Attestation expired");
    }

    let msg_hash = compute_message_hash(&decoded);
    let recovered = recover_signer(&msg_hash, &signature)?;

    if recovered != expected_evaluator {
        return Err("Invalid signature");
    }

    Ok(decoded)
}
