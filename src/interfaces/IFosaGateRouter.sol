// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFosaGateRouter — Interface for the FosaGate Main Gateway
/// @author rbd3
/// @notice FosaGate AI Protocol — Pre-Flight Evaluation Layer for Agent Transactions
/// @dev Defines the external interface for FosaGateRouter.sol.
///      This is the single entry point for all agent-submitted transactions.

interface IFosaGateRouter {
    // ═══════════════════════════════════════════════════════════════════════
    //                              ENUMS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Status of a transaction in the FosaGate pipeline
    enum TransactionStatus {
        UNKNOWN,    // Transaction ID not found
        APPROVED,   // Evaluation passed — awaiting execution or already executed
        REJECTED,   // Evaluation failed — transaction blocked
        EXECUTED    // Transaction was approved and successfully forwarded to target
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Request payload for batch execution
    struct ExecutionRequest {
        address target;         // Target contract to call
        bytes payload;          // Encoded function call data
        bytes attestation;      // Signed attestation from off-chain evaluator
        uint256 value;          // ETH value to forward with the call (if any)
    }

    /// @notice Complete record of a processed transaction
    struct TransactionRecord {
        address agent;              // Agent that submitted the transaction
        address target;             // Target contract
        uint256 riskScore;          // Risk score from evaluation
        TransactionStatus status;   // Current status
        uint64 evaluatedAt;         // Timestamp of evaluation
        uint64 executedAt;          // Timestamp of execution (0 if not executed)
        bool success;               // Whether the forwarded call succeeded
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted after a transaction is evaluated (approved or rejected)
    event TransactionEvaluated(
        bytes32 indexed txId,
        address indexed agent,
        address target,
        uint256 riskScore,
        bool approved
    );

    /// @notice Emitted after an approved transaction is forwarded and executed
    event TransactionExecuted(
        bytes32 indexed txId,
        address target,
        bool success
    );

    /// @notice Emitted when the global risk threshold is updated
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when the RiskEngine contract address is updated
    event RiskEngineUpdated(address oldEngine, address newEngine);

    /// @notice Emitted when the evaluator address is rotated
    event EvaluatorUpdated(address oldEvaluator, address newEvaluator);

    // ═══════════════════════════════════════════════════════════════════════
    //                          WRITE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Submit a single transaction with a signed evaluation attestation
    /// @dev Main entry point for agents. Flow:
    ///      1. Verify attestation signature via RiskEngine (Stylus)
    ///      2. Validate risk score against threshold
    ///      3. Check agent is registered and not suspended
    ///      4. Collect evaluation fee via FeeManager
    ///      5. Log verdict via VerdictLog
    ///      6. If approved → forward call to target via target.call{value}(payload)
    ///      7. Emit TransactionEvaluated + TransactionExecuted events
    /// @param target Address of the contract to call if approved
    /// @param payload ABI-encoded function call to forward to target
    /// @param attestation Signed attestation from the off-chain evaluator containing
    ///                    risk score, verdict, nonce, expiry, and ECDSA signature
    /// @return txId The unique identifier assigned to this transaction
    /// @return success True if the forwarded call to target succeeded (false if rejected or call reverted)
    function executeWithClearance(
        address target,
        bytes calldata payload,
        bytes calldata attestation
    ) external payable returns (bytes32 txId, bool success);

    /// @notice Submit multiple transactions with attestations in a single call
    /// @dev Batch version of executeWithClearance. Each request is independently evaluated.
    ///      Uses RiskEngine.batchVerify() for gas-efficient batch attestation verification.
    ///      If one request fails evaluation, others can still proceed (no atomic revert).
    /// @param requests Array of ExecutionRequest structs (target + payload + attestation + value)
    /// @return txIds Array of transaction identifiers (one per request)
    /// @return successes Array of booleans (one per request, true if forwarded call succeeded)
    function batchExecuteWithClearance(
        ExecutionRequest[] calldata requests
    ) external payable returns (bytes32[] memory txIds, bool[] memory successes);

    // ═══════════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set the global maximum acceptable risk score
    /// @dev Transactions with risk scores above this threshold are rejected.
    ///      Score range: 0-1000 (0 = no risk, 1000 = maximum risk).
    ///      Only callable by owner.
    /// @param threshold The new risk threshold (0-1000)
    function setRiskThreshold(uint256 threshold) external;

    /// @notice Set the RiskEngine (Stylus) contract address
    /// @dev Only callable by owner. Used to deploy/upgrade the Stylus contract.
    /// @param engine Address of the deployed RiskEngine Stylus contract
    function setRiskEngine(address engine) external;

    /// @notice Set the authorized evaluator address
    /// @dev The evaluator is the off-chain service whose signatures are accepted.
    ///      Only callable by owner. Used for key rotation in case of compromise.
    /// @param evaluator Address of the new authorized evaluator
    function setEvaluator(address evaluator) external;

    /// @notice Set the emergency admin address
    /// @dev Emergency admin can pause the router but cannot change config.
    ///      Only callable by owner.
    /// @param admin Address of the emergency admin
    function setEmergencyAdmin(address admin) external;

    /// @notice Pause all transaction processing (emergency circuit breaker)
    /// @dev Callable by owner OR emergency admin. No transactions can be processed while paused.
    function pause() external;

    /// @notice Resume transaction processing after a pause
    /// @dev Only callable by owner (not emergency admin, for safety).
    function unpause() external;

    // ═══════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get the full record of a processed transaction
    /// @param txId The unique transaction identifier
    /// @return record The TransactionRecord struct
    function getTransactionStatus(bytes32 txId) external view returns (TransactionRecord memory record);

    /// @notice Get the current global risk threshold
    /// @return threshold The current risk score threshold (0-1000)
    function getRiskThreshold() external view returns (uint256 threshold);

    /// @notice Get the current authorized evaluator address
    /// @return evaluator The evaluator address whose attestation signatures are accepted
    function getEvaluator() external view returns (address evaluator);
}
