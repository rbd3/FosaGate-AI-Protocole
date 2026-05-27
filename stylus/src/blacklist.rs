// FosaGate AI Protocol — RiskEngine / Blacklist Module
// Author: rbd3
//
// Merkle proof verification for the malicious calldata pattern blacklist.
// Verifies non-membership: proves a transaction's calldata is NOT in the blacklist.

use alloy_primitives::B256;

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
///
/// # Merkle Proof Algorithm
/// 1. Start with leaf = calldata_hash
/// 2. For each proof element:
///    - If leaf < proof[i]: hash = keccak256(leaf ++ proof[i])
///    - Else:               hash = keccak256(proof[i] ++ leaf)
/// 3. If final hash == blacklist_root → leaf IS in tree → return false
/// 4. If final hash != blacklist_root → leaf NOT in tree → return true
pub fn verify_not_blacklisted(
    _calldata_hash: B256,
    _blacklist_root: B256,
    _proof: &[B256],
) -> bool {
    // TODO:
    // 1. If blacklist_root is zero, return true (no blacklist active)
    // 2. Walk the Merkle proof from leaf to root
    // 3. If computed root == blacklist_root, the hash IS blacklisted → return false
    // 4. Otherwise → return true
    todo!()
}

/// Compute keccak256 of two concatenated 32-byte values (sorted).
/// Helper for Merkle proof traversal.
///
/// If a < b: returns keccak256(a ++ b)
/// If a >= b: returns keccak256(b ++ a)
///
/// Sorting ensures consistent hashing regardless of proof direction.
pub fn hash_pair(_a: B256, _b: B256) -> B256 {
    // TODO: Concatenate in sorted order, keccak256
    todo!()
}
