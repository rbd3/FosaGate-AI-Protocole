// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";

/// @title AgentRegistry — AI Agent Registration & Trust Management
/// @author rbd3
/// @notice Manages the lifecycle of AI agents that interact with FosaGate.
///         Every agent must be registered here before submitting transactions
///         through the FosaGateRouter. Tracks trust tiers and performance stats.
/// @dev Owned contract. FosaGateRouter is granted ROUTER_ROLE to call incrementStats().
contract AgentRegistry is IAgentRegistry {
    // ═══════════════════════════════════════════════════════════════════════
    //                         STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Role identifier for the FosaGateRouter (only address that can call incrementStats)
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    /// @notice Role identifier for admin operations (suspend, tier updates)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Protocol owner address
    address public owner;

    /// @notice Pending owner address for two-step transfer
    address public pendingOwner;

    /// @notice Address of the FosaGateRouter contract (granted ROUTER_ROLE)
    address public router;

    /// @notice Mapping from agent address → core agent info (tier, registration time, metadata)
    mapping(address => AgentInfo) private _agents;

    /// @notice Mapping from agent address → performance statistics
    mapping(address => AgentStats) private _stats;

    /// @notice Total number of registered agents (including suspended)
    uint256 public totalAgents;

    /// @notice Mapping from address → role → granted status
    mapping(address => mapping(bytes32 => bool)) private _roles;

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

    /// @dev Restricts function to protocol owner only
    modifier onlyOwner() {
        require(msg.sender == owner, "AgentRegistry: caller is not the owner");
        _;
    }

    /// @dev Restricts function to addresses with ADMIN_ROLE or owner
    modifier onlyAdmin() {
        require(_roles[msg.sender][ADMIN_ROLE] || msg.sender == owner, "AgentRegistry: caller is not an admin");
        _;
    }

    /// @dev Restricts function to the FosaGateRouter contract only
    modifier onlyRouter() {
        require(msg.sender == router || _roles[msg.sender][ROUTER_ROLE], "AgentRegistry: caller is not the router");
        _;
    }

    /// @dev Ensures the target agent is currently registered (exists in mapping)
    modifier agentExists(address agent) {
        require(_agents[agent].registeredAt != 0, "AgentRegistry: agent is not registered");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy AgentRegistry with initial owner
    /// @param _owner Address of the protocol owner
    constructor(address _owner) {
        require(_owner != address(0), "AgentRegistry: owner cannot be zero address");
        owner = _owner;
        _roles[_owner][ADMIN_ROLE] = true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        WRITE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAgentRegistry
    /// @dev Anyone can register an agent (self-registration or third-party).
    ///      - Agent address must not be address(0)
    ///      - Agent must not already be registered
    ///      - Sets tier to UNVERIFIED
    ///      - Sets registeredAt to block.timestamp
    ///      - Increments totalAgents counter
    ///      - Emits AgentRegistered event
    function registerAgent(address agent, string calldata metadata) external override {
        require(agent != address(0), "AgentRegistry: agent cannot be zero address");
        require(_agents[agent].registeredAt == 0, "AgentRegistry: agent already registered");

        _agents[agent] = AgentInfo({
            tier: Tier.UNVERIFIED,
            registeredAt: uint64(block.timestamp),
            isSuspended: false,
            metadata: metadata
        });

        totalAgents++;

        emit AgentRegistered(agent, metadata);
    }

    /// @inheritdoc IAgentRegistry
    /// @dev Only owner or ADMIN_ROLE can update tiers.
    ///      - Agent must exist
    ///      - Agent must not be suspended
    ///      - New tier must be different from current tier
    ///      - Emits AgentTierUpdated with old and new tier
    function updateAgentTier(address agent, Tier tier) external override onlyAdmin agentExists(agent) {
        require(!_agents[agent].isSuspended, "AgentRegistry: agent is suspended");
        Tier oldTier = _agents[agent].tier;
        require(oldTier != tier, "AgentRegistry: new tier must be identical");

        _agents[agent].tier = tier;

        emit AgentTierUpdated(agent, oldTier, tier);
    }

    /// @inheritdoc IAgentRegistry
    /// @dev Only owner or ADMIN_ROLE can suspend.
    ///      - Agent must exist
    ///      - Agent must not already be suspended
    ///      - Sets isSuspended = true
    ///      - Emits AgentSuspended event
    function suspendAgent(address agent, string calldata reason) external override onlyAdmin agentExists(agent) {
        require(!_agents[agent].isSuspended, "AgentRegistry: agent already suspended");

        _agents[agent].isSuspended = true;

        emit AgentSuspended(agent, reason);
    }

    /// @inheritdoc IAgentRegistry
    /// @dev Only owner can reinstate (more restrictive than suspend for safety).
    ///      - Agent must exist
    ///      - Agent must currently be suspended
    ///      - Sets isSuspended = false
    ///      - Emits AgentReinstated event
    function reinstateAgent(address agent) external override onlyOwner agentExists(agent) {
        require(_agents[agent].isSuspended, "AgentRegistry: agent is not suspended");

        _agents[agent].isSuspended = false;

        emit AgentReinstated(agent);
    }

    /// @inheritdoc IAgentRegistry
    /// @dev Only callable by FosaGateRouter (ROUTER_ROLE).
    ///      - Increments totalTransactions
    ///      - Increments totalApproved or totalRejected based on `approved` param
    ///      - Adds riskScore to cumulativeRiskScore (for average calculation)
    ///      - Does NOT revert if agent doesn't exist (router handles that check)
    function incrementStats(
        address agent,
        uint256 riskScore,
        bool approved
    ) external override onlyRouter {
        AgentStats storage stats = _stats[agent];
        stats.totalTransactions++;
        if (approved) {
            stats.totalApproved++;
        } else {
            stats.totalRejected++;
        }
        stats.cumulativeRiskScore += riskScore;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAgentRegistry
    function getAgent(address agent) external view override returns (AgentInfo memory info) {
        return _agents[agent];
    }

    /// @inheritdoc IAgentRegistry
    /// @dev Returns true ONLY if:
    ///      1. Agent has a non-zero registeredAt timestamp (is registered)
    ///      2. Agent is NOT suspended
    function isRegistered(address agent) external view override returns (bool) {
        return _agents[agent].registeredAt != 0 && !_agents[agent].isSuspended;
    }

    /// @inheritdoc IAgentRegistry
    function getAgentStats(address agent) external view override returns (AgentStats memory stats) {
        return _stats[agent];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set the FosaGateRouter address (grants ROUTER_ROLE)
    /// @dev Only callable by owner. Required during initial deployment to link contracts.
    /// @param _router Address of the deployed FosaGateRouter contract
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "AgentRegistry: router cannot be zero address");
        if (router != address(0)) {
            _roles[router][ROUTER_ROLE] = false;
        }
        router = _router;
        _roles[_router][ROUTER_ROLE] = true;
    }

    /// @notice Grant ADMIN_ROLE to an address
    /// @dev Only callable by owner. Admins can suspend agents and update tiers.
    /// @param admin Address to grant admin role to
    function grantAdminRole(address admin) external onlyOwner {
        require(admin != address(0), "AgentRegistry: admin cannot be zero address");
        _roles[admin][ADMIN_ROLE] = true;
    }

    /// @notice Revoke ADMIN_ROLE from an address
    /// @dev Only callable by owner.
    /// @param admin Address to revoke admin role from
    function revokeAdminRole(address admin) external onlyOwner {
        _roles[admin][ADMIN_ROLE] = false;
    }

    /// @notice Transfer ownership to a new address (two-step for safety)
    /// @param newOwner Address of the pending new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "AgentRegistry: pending owner cannot be zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership (second step of two-step transfer)
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "AgentRegistry: caller is not the pending owner");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }
}
