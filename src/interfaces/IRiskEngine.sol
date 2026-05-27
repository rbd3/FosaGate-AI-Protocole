// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRiskEngine — Interface for the Stylus RiskEngine Contract
/// @author rbd3
/// @notice FosaGate AI Protocol — Pre-Flight Evaluation Layer for Agent Transactions
/// @dev This interface is implemented by the Rust/Stylus contract (Phase 2).
///      It handles compute-intensive operations: attestation verification, risk scoring,
///      and pattern blacklist checks. Runs as WASM on Arbitrum for ~10x gas savings.

interface IRiskEngine {
    // ═══════════════════════════════════════════════════════════════════════
    //                        ATTESTATION VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verifies the cryptographic signature of an off-chain evaluator's attestation
    /// @dev Performs ECDSA signature recovery. The attestation contains:
    ///      - txId (bytes32): unique transaction identifier
    ///      - riskScore (uint256): computed risk score (0-1000)
    ///      - verdict (uint8): APPROVED / REJECTED_*
    ///      - nonce (uint256): replay protection
    ///      - expiry (uint256): attestation expiration timestamp
    ///      - signature (bytes): ECDSA signature from evaluator
    /// @param attestation ABI-encoded attestation data + signature from the off-chain evaluator
    /// @param evaluatorPubkey Address of the authorized off-chain evaluator (signer)
    /// @return txId The unique transaction identifier extracted from the attestation
    /// @return riskScore The risk score (0-1000) extracted from the attestation
    /// @return verdict The verdict code extracted from the attestation
    /// @return valid True if the signature is valid and the attestation has not expired
    function verifyAttestation(
        bytes calldata attestation,
        address evaluatorPubkey
    )
        external
        view
        returns (bytes32 txId, uint256 riskScore, uint8 verdict, bool valid);

    /// @notice Batch verification of multiple attestations in one call
    /// @dev Used by FosaGateRouter.batchExecuteWithClearance() for gas efficiency.
    ///      Each attestation is independently verified against the same evaluator key.
    /// @param attestations Array of ABI-encoded attestation data + signatures
    /// @param evaluatorPubkey Address of the authorized off-chain evaluator
    /// @return txIds Array of transaction identifiers
    /// @return riskScores Array of risk scores
    /// @return verdicts Array of verdict codes
    /// @return allValid True only if ALL attestations are valid
    function batchVerify(
        bytes[] calldata attestations,
        address evaluatorPubkey
    )
        external
        view
        returns (bytes32[] memory txIds, uint256[] memory riskScores, uint8[] memory verdicts, bool allValid);

    // ═══════════════════════════════════════════════════════════════════════
    //                          RISK VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Validates that a risk score is within acceptable bounds given policy and agent tier
    /// @dev Applies tier-based multipliers:
    ///      - UNVERIFIED: no tolerance bonus (strict)
    ///      - BASIC:      +5% tolerance on policyMax
    ///      - TRUSTED:    +10% tolerance on policyMax
    ///      - PREMIUM:    +15% tolerance on policyMax
    /// @param riskScore The risk score to validate (0-1000)
    /// @param policyMax The maximum acceptable risk score from the active policy
    /// @param agentTier The agent's trust tier (0=UNVERIFIED, 1=BASIC, 2=TRUSTED, 3=PREMIUM)
    /// @return acceptable True if the risk score passes validation
    /// @return adjustedMax The effective max threshold after tier adjustment
    function validateRiskParams(
        uint256 riskScore,
        uint256 policyMax,
        uint8 agentTier
    ) external pure returns (bool acceptable, uint256 adjustedMax);

    /// @notice Computes a weighted composite risk score from individual analysis dimensions
    /// @dev Formula: score = (mev * w[0] + slippage * w[1] + contract * w[2] + value * w[3]) / sum(w)
    ///      All scores and weights use uint256 for precision. Final score normalized to 0-1000.
    /// @param mevScore MEV exposure risk score (0-1000) from MEV detector
    /// @param slippageScore Slippage risk score (0-1000) from slippage checker
    /// @param contractScore Target contract risk score (0-1000) from contract scorer
    /// @param valueScore Value-at-risk score (0-1000) from balance impact analysis
    /// @param weights Array of 4 weights [mevWeight, slippageWeight, contractWeight, valueWeight]
    /// @return compositeScore The final weighted risk score (0-1000)
    function computeCompositeScore(
        uint256 mevScore,
        uint256 slippageScore,
        uint256 contractScore,
        uint256 valueScore,
        uint256[4] calldata weights
    ) external pure returns (uint256 compositeScore);

    // ═══════════════════════════════════════════════════════════════════════
    //                         PATTERN BLACKLIST
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verifies a Merkle proof that a transaction's calldata pattern is NOT blacklisted
    /// @dev Uses a Merkle tree of known-malicious calldata hashes. The proof demonstrates
    ///      non-membership (absence from the blacklist). Efficient for large blacklists.
    /// @param calldataHash Keccak256 hash of the transaction's calldata
    /// @param blacklistRoot Merkle root of the current known-malicious pattern blacklist
    /// @param proof Merkle proof of non-membership
    /// @return notBlacklisted True if the calldata hash is NOT in the blacklist
    function checkPatternHash(
        bytes32 calldataHash,
        bytes32 blacklistRoot,
        bytes32[] calldata proof
    ) external pure returns (bool notBlacklisted);
}
