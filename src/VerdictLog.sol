// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FosaGate AI Protocol
 * @notice Pre-Flight Evaluation Layer for Agent Transactions
 * @dev Contract : VerdictLog
 *      Author   : rbd3
 *      Chain    : Arbitrum One / Arbitrum Sepolia
 *      Version  : 1.0.0
 */

import {IVerdictLog} from "./interfaces/IVerdictLog.sol";

/// @title VerdictLog — Immutable On-Chain Evaluation Audit Trail
/// @author rbd3
/// @notice Stores every evaluation verdict on-chain for full auditability.
/// @dev Only FosaGateRouter can write. Verdicts are stored by txId and indexed per agent.
contract VerdictLog is IVerdictLog {

    /// @notice Protocol owner
    address public owner;

    /// @notice Pending owner address for two-step transfer
    address public pendingOwner;

    /// @notice FosaGateRouter address (only writer)
    address public router;

    /// @notice txId → full verdict record
    mapping(bytes32 => VerdictRecord) private _verdicts;

    /// @notice agent → ordered array of their txIds (for pagination)
    mapping(address => bytes32[]) private _agentVerdicts;

    /// @notice Total verdicts stored
    uint256 private _totalVerdicts;

    /// @notice Duplicate prevention: txId → logged flag
    mapping(bytes32 => bool) private _exists;

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

    modifier onlyOwner() {
        require(msg.sender == owner, "VerdictLog: caller is not the owner");
        _;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "VerdictLog: caller is not the router");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @param _owner Protocol owner address
    constructor(address _owner) {
        require(_owner != address(0), "VerdictLog: owner cannot be zero address");
        owner = _owner;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        WRITE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVerdictLog
    /// @dev Only router. txId must not already exist.
    ///      Creates VerdictRecord with block.timestamp and block.number.
    ///      Appends txId to _agentVerdicts[agent]. Emits VerdictLogged.
    function logVerdict(
        bytes32 txId,
        address agent,
        address target,
        uint256 riskScore,
        Verdict verdict,
        bytes32 attestationHash
    ) external override onlyRouter {
        require(!_exists[txId], "VerdictLog: verdict already exists");

        _verdicts[txId] = VerdictRecord({
            txId: txId,
            agent: agent,
            target: target,
            riskScore: riskScore,
            verdict: verdict,
            attestationHash: attestationHash,
            timestamp: uint64(block.timestamp),
            blockNumber: block.number
        });

        _agentVerdicts[agent].push(txId);
        _totalVerdicts++;
        _exists[txId] = true;

        emit VerdictLogged(txId, agent, verdict, riskScore);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVerdictLog
    function getVerdict(bytes32 txId) external view override returns (VerdictRecord memory record) {
        return _verdicts[txId];
    }

    /// @inheritdoc IVerdictLog
    /// @dev Pagination: skip `offset`, return up to `limit` records.
    function getVerdictsByAgent(
        address agent,
        uint256 offset,
        uint256 limit
    ) external view override returns (VerdictRecord[] memory records) {
        uint256 totalCount = _agentVerdicts[agent].length;
        if (offset >= totalCount || limit == 0) {
            return new VerdictRecord[](0);
        }

        uint256 size = limit;
        if (offset + limit > totalCount) {
            size = totalCount - offset;
        }

        records = new VerdictRecord[](size);
        for (uint256 i = 0; i < size; i++) {
            records[i] = _verdicts[_agentVerdicts[agent][offset + i]];
        }
    }

    /// @inheritdoc IVerdictLog
    function getVerdictCount() external view override returns (uint256 count) {
        return _totalVerdicts;
    }

    /// @notice Check if a verdict exists for a txId
    function verdictExists(bytes32 txId) external view returns (bool) {
        return _exists[txId];
    }

    /// @notice Get verdict count for a specific agent
    function getAgentVerdictCount(address agent) external view returns (uint256) {
        return _agentVerdicts[agent].length;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set the FosaGateRouter address (only writer)
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "VerdictLog: router cannot be zero address");
        router = _router;
    }

    /// @notice Transfer ownership to a new address (two-step for safety)
    /// @param newOwner Address of the pending new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "VerdictLog: pending owner cannot be zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership (second step of two-step transfer)
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "VerdictLog: caller is not the pending owner");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }
}
