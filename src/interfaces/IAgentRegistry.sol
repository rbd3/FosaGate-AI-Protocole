// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentRegistry — Interface for the Agent Registry Contract
/// @author rbd3
/// @notice FosaGate AI Protocol — Pre-Flight Evaluation Layer for Agent Transactions
/// @dev Defines the external interface for AgentRegistry.sol.
///      Used by FosaGateRouter to check agent registration and tiers.

interface IAgentRegistry {
    // ═══════════════════════════════════════════════════════════════════════
    //                              ENUMS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Trust tiers for registered agents
    /// @dev Higher tiers receive lower fees and higher risk tolerance
    ///      UNVERIFIED → BASIC → TRUSTED → PREMIUM
    enum Tier {
        UNVERIFIED, // Default tier on registration — strictest evaluation
        BASIC,      // Verified agent — slightly relaxed thresholds
        TRUSTED,    // Proven track record — moderate tolerance bonus
        PREMIUM     // Top-tier agent — maximum tolerance, lowest fees
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Core data for a registered agent
    struct AgentInfo {
        Tier tier;              // Current trust tier
        uint64 registeredAt;    // Block timestamp of registration
        bool isSuspended;       // True if agent is currently suspended
        string metadata;        // Agent description / identifier URI
    }

    /// @notice Performance statistics for a registered agent
    struct AgentStats {
        uint256 totalTransactions;  // Total evaluations submitted
        uint256 totalApproved;      // Total transactions approved
        uint256 totalRejected;      // Total transactions rejected
        uint256 cumulativeRiskScore; // Sum of all risk scores (for avg calculation)
        uint256 totalVolume;        // Total USD value processed (if tracked)
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new agent is registered
    event AgentRegistered(address indexed agent, string metadata);

    /// @notice Emitted when an agent's trust tier is updated
    event AgentTierUpdated(address indexed agent, Tier oldTier, Tier newTier);

    /// @notice Emitted when an agent is suspended for malicious behavior
    event AgentSuspended(address indexed agent, string reason);

    /// @notice Emitted when a previously suspended agent is reinstated
    event AgentReinstated(address indexed agent);

    // ═══════════════════════════════════════════════════════════════════════
    //                          WRITE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Register a new AI agent in the protocol
    /// @dev Sets initial tier to UNVERIFIED. Agent address must not already be registered.
    ///      Emits AgentRegistered event.
    /// @param agent The address of the AI agent to register
    /// @param metadata Description or URI for the agent (e.g., IPFS hash of agent manifest)
    function registerAgent(address agent, string calldata metadata) external;

    /// @notice Update an agent's trust tier
    /// @dev Only callable by owner/governance. Tier upgrades/downgrades affect fee rates
    ///      and risk tolerance multipliers in the RiskEngine.
    /// @param agent The address of the agent to update
    /// @param tier The new trust tier to assign
    function updateAgentTier(address agent, Tier tier) external;

    /// @notice Suspend an agent, blocking all transaction processing
    /// @dev Only callable by owner/governance or emergency admin. Used when
    ///      malicious or anomalous behavior is detected. Emits AgentSuspended.
    /// @param agent The address of the agent to suspend
    /// @param reason Human-readable reason for the suspension
    function suspendAgent(address agent, string calldata reason) external;

    /// @notice Reinstate a previously suspended agent
    /// @dev Only callable by owner/governance. Emits AgentReinstated.
    /// @param agent The address of the agent to reinstate
    function reinstateAgent(address agent) external;

    /// @notice Update agent stats after an evaluation
    /// @dev Only callable by FosaGateRouter. Increments transaction counters
    ///      and accumulates risk scores for performance tracking.
    /// @param agent The address of the agent
    /// @param riskScore The risk score from this evaluation (0-1000)
    /// @param approved Whether the transaction was approved
    function incrementStats(address agent, uint256 riskScore, bool approved) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get core info for a registered agent
    /// @param agent The address of the agent to query
    /// @return info The AgentInfo struct containing tier, registration time, suspension status, metadata
    function getAgent(address agent) external view returns (AgentInfo memory info);

    /// @notice Check if an agent is registered and not suspended
    /// @dev Used by FosaGateRouter as a gate check before processing any transaction
    /// @param agent The address to check
    /// @return True if the agent is registered AND not suspended
    function isRegistered(address agent) external view returns (bool);

    /// @notice Get performance stats for an agent
    /// @param agent The address of the agent
    /// @return stats The AgentStats struct with transaction counts and risk score history
    function getAgentStats(address agent) external view returns (AgentStats memory stats);
}
