// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FosaGate AI Protocol
 * @notice Pre-Flight Evaluation Layer for Agent Transactions
 * @dev Contract : FosaGateRouter
 *      Author   : rbd3
 *      Chain    : Arbitrum One / Arbitrum Sepolia
 *      Version  : 1.0.0
 */

import {IFosaGateRouter} from "./interfaces/IFosaGateRouter.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IVerdictLog} from "./interfaces/IVerdictLog.sol";
import {IRiskEngine} from "./interfaces/IRiskEngine.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title FosaGateRouter — Main Gateway for Agent Transaction Evaluation
/// @author rbd3
/// @notice The single entry point for all AI agent transactions. Agents submit
///         transactions with a signed attestation from the off-chain evaluator.
///         The router verifies the attestation via RiskEngine (Stylus), checks
///         the risk score, and either forwards the transaction or rejects it.
/// @dev Uses ReentrancyGuard on executeWithClearance. Pausable for emergencies.
///      Coordinates with AgentRegistry, VerdictLog, and RiskEngine (Stylus).
contract FosaGateRouter is IFosaGateRouter, ReentrancyGuard, Pausable {

    // ═══════════════════════════════════════════════════════════════════════
    //                         STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Protocol owner address
    address public owner;

    /// @notice Pending owner address for two-step transfer
    address public pendingOwner;

    /// @notice Emergency admin — can pause but not configure
    address public emergencyAdmin;

    /// @notice Global risk threshold (0-1000). Txs with risk > threshold are rejected
    /// @dev Default: 500 (moderate risk tolerance). Adjustable by owner.
    uint256 public riskThreshold;

    /// @notice Address of the authorized off-chain evaluator (signer of attestations)
    address public evaluator;

    /// @notice Reference to the AgentRegistry contract
    IAgentRegistry public agentRegistry;

    /// @notice Reference to the VerdictLog contract
    IVerdictLog public verdictLog;

    /// @notice Reference to the RiskEngine Stylus contract
    IRiskEngine public riskEngine;

    /// @notice Mapping from txId → transaction record (status, scores, timestamps)
    mapping(bytes32 => TransactionRecord) private _transactions;

    /// @notice Nonce tracking per agent to prevent attestation replay
    /// @dev agent → last used nonce. Each attestation must use nonce > last used.
    mapping(address => uint256) public agentNonces;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when ownership transfer is initiated
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when ownership transfer is completed
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ═══════════════════════════════════════════════════════════════════════
    //                           MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Restricts to owner only
    modifier onlyOwner() {
        require(msg.sender == owner, "FosaGateRouter: caller is not the owner");
        _;
    }

    /// @dev Restricts to owner or emergency admin
    modifier onlyOwnerOrAdmin() {
        require(msg.sender == owner || msg.sender == emergencyAdmin, "FosaGateRouter: caller is not owner or admin");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy FosaGateRouter with core dependencies
    /// @param _owner Protocol owner address
    /// @param _evaluator Authorized off-chain evaluator address
    /// @param _agentRegistry Deployed AgentRegistry contract address
    /// @param _verdictLog Deployed VerdictLog contract address
    /// @param _riskThreshold Initial global risk threshold (0-1000)
    constructor(
        address _owner,
        address _evaluator,
        address _agentRegistry,
        address _verdictLog,
        uint256 _riskThreshold
    ) {
        require(_owner != address(0), "FosaGateRouter: owner cannot be zero address");
        require(_evaluator != address(0), "FosaGateRouter: evaluator cannot be zero address");
        require(_agentRegistry != address(0), "FosaGateRouter: registry cannot be zero address");
        require(_verdictLog != address(0), "FosaGateRouter: log cannot be zero address");
        require(_riskThreshold <= 1000, "FosaGateRouter: risk threshold out of range");

        owner = _owner;
        evaluator = _evaluator;
        agentRegistry = IAgentRegistry(_agentRegistry);
        verdictLog = IVerdictLog(_verdictLog);
        riskThreshold = _riskThreshold;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFosaGateRouter
    /// @dev Full execution flow:
    ///      1. Check not paused (whenNotPaused)
    ///      2. Check reentrancy guard (nonReentrant)
    ///      3. Verify agent is registered via agentRegistry.isRegistered(msg.sender)
    ///      4. Call riskEngine.verifyAttestation(attestation, evaluator)
    ///         → returns (txId, riskScore, verdict, valid)
    ///      5. If !valid → log REJECTED_INVALID_ATTESTATION verdict, revert
    ///      6. If riskScore > riskThreshold → log REJECTED_HIGH_RISK, revert
    ///      7. Store TransactionRecord with status = APPROVED
    ///      8. Log verdict via verdictLog.logVerdict(...)
    ///      9. Update agent stats via agentRegistry.incrementStats(...)
    ///     10. Forward call: (bool success, ) = target.call{value: msg.value}(payload)
    ///     11. Update status to EXECUTED, store success flag
    ///     12. Emit TransactionEvaluated + TransactionExecuted events
    ///     13. Return (txId, success)
    function executeWithClearance(
        address target,
        bytes calldata payload,
        bytes calldata attestation
    ) external payable override whenNotPaused nonReentrant returns (bytes32 txId, bool success) {
        require(agentRegistry.isRegistered(msg.sender), "FosaGateRouter: agent not registered");

        return _processExecution(msg.sender, target, payload, attestation, msg.value);
    }

    /// @inheritdoc IFosaGateRouter
    /// @dev Iterates over requests array. Each request is independently evaluated.
    ///      Uses riskEngine.batchVerify() for gas-efficient attestation checking.
    ///      Failed evaluations don't revert the batch — they emit rejection events
    ///      and continue to the next request.
    ///      ETH value distribution: each request specifies its own value amount.
    ///      Total msg.value must equal sum of all request values.
    function batchExecuteWithClearance(
        ExecutionRequest[] calldata requests
    ) external payable override whenNotPaused nonReentrant returns (bytes32[] memory txIds, bool[] memory successes) {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalValue += requests[i].value;
        }
        require(msg.value == totalValue, "FosaGateRouter: msg.value mismatch");

        txIds = new bytes32[](requests.length);
        successes = new bool[](requests.length);

        bytes[] memory attestations = new bytes[](requests.length);
        for (uint256 i = 0; i < requests.length; i++) {
            attestations[i] = requests[i].attestation;
        }

        bytes32[] memory attTxIds;
        uint256[] memory riskScores;
        uint8[] memory verdicts;
        bool allValid;

        try riskEngine.batchVerify(attestations, evaluator) returns (
            bytes32[] memory _attTxIds,
            uint256[] memory _riskScores,
            uint8[] memory _verdicts,
            bool _allValid
        ) {
            attTxIds = _attTxIds;
            riskScores = _riskScores;
            verdicts = _verdicts;
            allValid = _allValid;
        } catch {
            allValid = false;
        }

        for (uint256 i = 0; i < requests.length; i++) {
            ExecutionRequest calldata req = requests[i];

            if (!agentRegistry.isRegistered(msg.sender)) {
                txIds[i] = bytes32(0);
                successes[i] = false;
                continue;
            }

            bytes32 txId;
            bool success;

            uint256 nonce = agentNonces[msg.sender];
            txId = _generateTxId(msg.sender, req.target, req.payload, nonce);
            txIds[i] = txId;

            bytes32 attestationHash = keccak256(req.attestation);
            bool isThisValid = false;
            uint256 riskScore = 0;

            if (allValid && attTxIds.length == requests.length) {
                isThisValid = (attTxIds[i] == txId);
                riskScore = riskScores[i];
            } else {
                try riskEngine.verifyAttestation(req.attestation, evaluator) returns (
                    bytes32 _attTxId,
                    uint256 _riskScore,
                    uint8 /* _verdict */,
                    bool _valid
                ) {
                    isThisValid = _valid && (_attTxId == txId);
                    riskScore = _riskScore;
                } catch {
                    isThisValid = false;
                }
            }

            if (!isThisValid) {
                verdictLog.logVerdict(
                    txId,
                    msg.sender,
                    req.target,
                    riskScore,
                    IVerdictLog.Verdict.REJECTED_INVALID_ATTESTATION,
                    attestationHash
                );

                _transactions[txId] = TransactionRecord({
                    agent: msg.sender,
                    target: req.target,
                    riskScore: riskScore,
                    status: TransactionStatus.REJECTED,
                    evaluatedAt: uint64(block.timestamp),
                    executedAt: 0,
                    success: false
                });

                agentRegistry.incrementStats(msg.sender, riskScore, false);
                emit TransactionEvaluated(txId, msg.sender, req.target, riskScore, false);
                successes[i] = false;
                continue;
            }

            if (riskScore > riskThreshold) {
                verdictLog.logVerdict(
                    txId,
                    msg.sender,
                    req.target,
                    riskScore,
                    IVerdictLog.Verdict.REJECTED_HIGH_RISK,
                    attestationHash
                );

                _transactions[txId] = TransactionRecord({
                    agent: msg.sender,
                    target: req.target,
                    riskScore: riskScore,
                    status: TransactionStatus.REJECTED,
                    evaluatedAt: uint64(block.timestamp),
                    executedAt: 0,
                    success: false
                });

                agentNonces[msg.sender] = nonce + 1;
                agentRegistry.incrementStats(msg.sender, riskScore, false);
                emit TransactionEvaluated(txId, msg.sender, req.target, riskScore, false);
                successes[i] = false;
                continue;
            }

            agentNonces[msg.sender] = nonce + 1;

            _transactions[txId] = TransactionRecord({
                agent: msg.sender,
                target: req.target,
                riskScore: riskScore,
                status: TransactionStatus.APPROVED,
                evaluatedAt: uint64(block.timestamp),
                executedAt: 0,
                success: false
            });

            verdictLog.logVerdict(
                txId,
                msg.sender,
                req.target,
                riskScore,
                IVerdictLog.Verdict.APPROVED,
                attestationHash
            );

            agentRegistry.incrementStats(msg.sender, riskScore, true);
            emit TransactionEvaluated(txId, msg.sender, req.target, riskScore, true);

            (success, ) = req.target.call{value: req.value}(req.payload);

            _transactions[txId].status = TransactionStatus.EXECUTED;
            _transactions[txId].executedAt = uint64(block.timestamp);
            _transactions[txId].success = success;

            emit TransactionExecuted(txId, req.target, success);
            successes[i] = success;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFosaGateRouter
    /// @dev Validates threshold <= 1000. Emits ThresholdUpdated.
    function setRiskThreshold(uint256 threshold) external override onlyOwner {
        require(threshold <= 1000, "FosaGateRouter: threshold out of range");
        uint256 oldThreshold = riskThreshold;
        riskThreshold = threshold;
        emit ThresholdUpdated(oldThreshold, threshold);
    }

    /// @inheritdoc IFosaGateRouter
    /// @dev Validates non-zero address. Emits RiskEngineUpdated.
    function setRiskEngine(address engine) external override onlyOwner {
        require(engine != address(0), "FosaGateRouter: engine cannot be zero address");
        address oldEngine = address(riskEngine);
        riskEngine = IRiskEngine(engine);
        emit RiskEngineUpdated(oldEngine, engine);
    }

    /// @inheritdoc IFosaGateRouter
    /// @dev Validates non-zero address. Emits EvaluatorUpdated.
    function setEvaluator(address _evaluator) external override onlyOwner {
        require(_evaluator != address(0), "FosaGateRouter: evaluator cannot be zero address");
        address oldEvaluator = evaluator;
        evaluator = _evaluator;
        emit EvaluatorUpdated(oldEvaluator, _evaluator);
    }

    /// @inheritdoc IFosaGateRouter
    function setEmergencyAdmin(address admin) external override onlyOwner {
        require(admin != address(0), "FosaGateRouter: admin cannot be zero address");
        emergencyAdmin = admin;
    }

    /// @inheritdoc IFosaGateRouter
    /// @dev Callable by owner OR emergency admin
    function pause() external override onlyOwnerOrAdmin {
        _pause();
    }

    /// @inheritdoc IFosaGateRouter
    /// @dev Only owner can unpause (not emergency admin, for safety)
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @notice Set the AgentRegistry contract address
    /// @param _agentRegistry New AgentRegistry contract address
    function setAgentRegistry(address _agentRegistry) external onlyOwner {
        require(_agentRegistry != address(0), "FosaGateRouter: registry cannot be zero address");
        agentRegistry = IAgentRegistry(_agentRegistry);
    }

    /// @notice Set the VerdictLog contract address
    /// @param _verdictLog New VerdictLog contract address
    function setVerdictLog(address _verdictLog) external onlyOwner {
        require(_verdictLog != address(0), "FosaGateRouter: log cannot be zero address");
        verdictLog = IVerdictLog(_verdictLog);
    }

    /// @notice Transfer ownership
    /// @param newOwner New owner address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "FosaGateRouter: pending owner cannot be zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership (second step of two-step transfer)
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "FosaGateRouter: caller is not the pending owner");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFosaGateRouter
    function getTransactionStatus(bytes32 txId) external view override returns (TransactionRecord memory record) {
        return _transactions[txId];
    }

    /// @inheritdoc IFosaGateRouter
    function getRiskThreshold() external view override returns (uint256 threshold) {
        return riskThreshold;
    }

    /// @inheritdoc IFosaGateRouter
    function getEvaluator() external view override returns (address) {
        return evaluator;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Generate a unique transaction ID
    /// @dev txId = keccak256(agent, target, payload, nonce, block.chainid)
    /// @param agent The agent submitting the transaction
    /// @param target The target contract
    /// @param payload The encoded call data
    /// @param nonce The agent's current nonce
    /// @return txId The unique transaction identifier
    function _generateTxId(
        address agent,
        address target,
        bytes calldata payload,
        uint256 nonce
    ) internal view returns (bytes32 txId) {
        return keccak256(abi.encodePacked(agent, target, payload, nonce, block.chainid));
    }

    /// @notice Execute a single evaluated transaction (internal)
    /// @dev Shared logic between executeWithClearance and batchExecuteWithClearance.
    ///      Handles: attestation verification, risk check, verdict logging, call forwarding.
    /// @param agent The agent address (msg.sender from external call)
    /// @param target Target contract to call
    /// @param payload Encoded call data
    /// @param attestation Signed evaluator attestation
    /// @param value ETH value to forward
    /// @return txId Generated transaction ID
    /// @return success Whether the forwarded call succeeded
    function _processExecution(
        address agent,
        address target,
        bytes calldata payload,
        bytes calldata attestation,
        uint256 value
    ) internal returns (bytes32 txId, bool success) {
        uint256 nonce = agentNonces[agent];
        txId = _generateTxId(agent, target, payload, nonce);

        bytes32 attestationHash = keccak256(attestation);

        (bytes32 attTxId, uint256 riskScore, , bool valid) = riskEngine.verifyAttestation(attestation, evaluator);

        bool isThisValid = valid && (attTxId == txId);

        if (!isThisValid) {
            verdictLog.logVerdict(
                txId,
                agent,
                target,
                riskScore,
                IVerdictLog.Verdict.REJECTED_INVALID_ATTESTATION,
                attestationHash
            );

            _transactions[txId] = TransactionRecord({
                agent: agent,
                target: target,
                riskScore: riskScore,
                status: TransactionStatus.REJECTED,
                evaluatedAt: uint64(block.timestamp),
                executedAt: 0,
                success: false
            });

            agentRegistry.incrementStats(agent, riskScore, false);
            emit TransactionEvaluated(txId, agent, target, riskScore, false);
            return (txId, false);
        }

        if (riskScore > riskThreshold) {
            verdictLog.logVerdict(
                txId,
                agent,
                target,
                riskScore,
                IVerdictLog.Verdict.REJECTED_HIGH_RISK,
                attestationHash
            );

            _transactions[txId] = TransactionRecord({
                agent: agent,
                target: target,
                riskScore: riskScore,
                status: TransactionStatus.REJECTED,
                evaluatedAt: uint64(block.timestamp),
                executedAt: 0,
                success: false
            });

            agentNonces[agent] = nonce + 1;
            agentRegistry.incrementStats(agent, riskScore, false);
            emit TransactionEvaluated(txId, agent, target, riskScore, false);
            return (txId, false);
        }

        agentNonces[agent] = nonce + 1;

        _transactions[txId] = TransactionRecord({
            agent: agent,
            target: target,
            riskScore: riskScore,
            status: TransactionStatus.APPROVED,
            evaluatedAt: uint64(block.timestamp),
            executedAt: 0,
            success: false
        });

        verdictLog.logVerdict(
            txId,
            agent,
            target,
            riskScore,
            IVerdictLog.Verdict.APPROVED,
            attestationHash
        );

        agentRegistry.incrementStats(agent, riskScore, true);
        emit TransactionEvaluated(txId, agent, target, riskScore, true);

        (success, ) = target.call{value: value}(payload);

        _transactions[txId].status = TransactionStatus.EXECUTED;
        _transactions[txId].executedAt = uint64(block.timestamp);
        _transactions[txId].success = success;

        emit TransactionExecuted(txId, target, success);
    }

    /// @dev ETH receive function — allows contract to receive ETH for forwarding
    receive() external payable {}
}
