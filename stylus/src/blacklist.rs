// FosaGate AI Protocol — RiskEngine / Blacklist Module
// Author: rbd3
//
// Merkle proof verification for the malicious calldata pattern blacklist.
// Verifies non-membership: proves a transaction's calldata is NOT in the blacklist.

use stylus_sdk::alloy_primitives::B256;
use tiny_keccak::{Hasher, Keccak};

/// Helper for Keccak256 hashing
fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    let mut result = [0u8; 32];
    hasher.update(data);
    hasher.finalize(&mut result);
    result
}

/// Verify a Merkle non-membership proof.
///
/// The off-chain evaluator maintains a sorted Merkle tree of keccak256 hashes
/// of known-malicious calldata patterns (reentrancy, flash loan setups,
/// approval phishing, etc). The root is stored on-chain in RiskEngine.
///
/// This function verifies that a given calldata hash is NOT a leaf in the tree.
///
/// # Parameters
/// - `calldata_hash`: keccak256 of the transaction's calldata to check
/// - `blacklist_root`: Current Merkle root from on-chain storage
/// - `proof`: Vector of 32-byte sibling hashes for the Merkle proof
///
/// # Returns
/// - `true` if calldata_hash is confirmed NOT in the blacklist
/// - `true` if blacklist_root is zero (no blacklist configured)
/// - `false` if proof shows calldata_hash IS in the blacklist
pub fn verify_not_blacklisted(
    calldata_hash: B256,
    blacklist_root: B256,
    proof: &[B256],
) -> bool {
    // 1. If blacklist_root is zero, return true (no blacklist active)
    if blacklist_root == B256::ZERO {
        return true;
    }

    // 2. Walk the Merkle proof from leaf to root
    let mut computed_hash = calldata_hash;
    for sibling in proof {
        computed_hash = hash_pair(computed_hash, *sibling);
    }

    // 3. If computed root == blacklist_root, the hash IS blacklisted → return false
    // 4. Otherwise → return true
    computed_hash != blacklist_root
}

/// Compute keccak256 of two concatenated 32-byte values (sorted).
/// Helper for Merkle proof traversal.
///
/// If a < b: returns keccak256(a ++ b)
/// If a >= b: returns keccak256(b ++ a)
///
/// Sorting ensures consistent hashing regardless of proof direction.
pub fn hash_pair(a: B256, b: B256) -> B256 {
    let mut concat = [0u8; 64];
    if a < b {
        concat[0..32].copy_from_slice(a.as_slice());
        concat[32..64].copy_from_slice(b.as_slice());
    } else {
        concat[0..32].copy_from_slice(b.as_slice());
        concat[32..64].copy_from_slice(a.as_slice());
    }
    B256::from_slice(&keccak256(&concat))
}
