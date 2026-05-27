// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVerdictLog — Interface for the Verdict Log Contract
/// @author rbd3
/// @notice FosaGate AI Protocol — Pre-Flight Evaluation Layer for Agent Transactions
/// @dev Defines the external interface for VerdictLog.sol.
///      Provides an immutable on-chain audit trail of all evaluation verdicts.

interface IVerdictLog {
    // ═══════════════════════════════════════════════════════════════════════
    //                              ENUMS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Possible verdict outcomes for a transaction evaluation
    enum Verdict {
        APPROVED,                       // Transaction passed all risk checks
        REJECTED_HIGH_RISK,             // Risk score exceeded threshold
        REJECTED_POLICY_VIOLATION,      // Transaction violated an active policy rule
        REJECTED_INVALID_ATTESTATION    // Evaluator attestation signature was invalid or expired
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Complete record of an evaluation verdict
    struct VerdictRecord {
        bytes32 txId;               // Unique transaction identifier
        address agent;              // Address of the agent that submitted the transaction
        address target;             // Target contract the transaction was aimed at
        uint256 riskScore;          // Risk score computed by the evaluation (0-1000)
        Verdict verdict;            // The evaluation outcome
        bytes32 attestationHash;    // Keccak256 hash of the evaluator's attestation (for reference)
        uint64 timestamp;           // Block timestamp when verdict was logged
        uint256 blockNumber;        // Block number when verdict was logged
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a verdict is logged on-chain
    event VerdictLogged(
        bytes32 indexed txId,
        address indexed agent,
        Verdict verdict,
        uint256 riskScore
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                          WRITE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Store an evaluation verdict on-chain
    /// @dev Only callable by FosaGateRouter. Creates an immutable audit record.
    ///      The same txId cannot be logged twice (prevents duplicate entries).
    /// @param txId Unique identifier for this transaction (keccak256 of agent + target + payload + nonce)
    /// @param agent Address of the agent that submitted the transaction
    /// @param target Address of the target contract
    /// @param riskScore Risk score from the evaluation (0-1000)
    /// @param verdict The evaluation outcome (APPROVED / REJECTED_*)
    /// @param attestationHash Keccak256 hash of the evaluator's signed attestation
    function logVerdict(
        bytes32 txId,
        address agent,
        address target,
        uint256 riskScore,
        Verdict verdict,
        bytes32 attestationHash
    ) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get a verdict record by transaction ID
    /// @param txId The unique transaction identifier to look up
    /// @return record The full VerdictRecord struct
    function getVerdict(bytes32 txId) external view returns (VerdictRecord memory record);

    /// @notice Get a paginated list of verdicts for a specific agent
    /// @dev Returns verdicts ordered by submission time (oldest first within the page).
    ///      Use offset + limit for pagination.
    /// @param agent The agent address to query verdicts for
    /// @param offset Number of records to skip (for pagination)
    /// @param limit Maximum number of records to return
    /// @return records Array of VerdictRecord structs
    function getVerdictsByAgent(
        address agent,
        uint256 offset,
        uint256 limit
    ) external view returns (VerdictRecord[] memory records);

    /// @notice Get the total number of verdicts stored in the log
    /// @return count Total verdict count
    function getVerdictCount() external view returns (uint256 count);
}
