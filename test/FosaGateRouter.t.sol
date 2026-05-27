// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {VerdictLog} from "../src/VerdictLog.sol";
import {FosaGateRouter} from "../src/FosaGateRouter.sol";
import {IFosaGateRouter} from "../src/interfaces/IFosaGateRouter.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {IVerdictLog} from "../src/interfaces/IVerdictLog.sol";
import {MockRiskEngine} from "./mocks/MockRiskEngine.sol";
import {MockTarget} from "./mocks/MockTarget.sol";

contract FosaGateRouterTest is Test {
    AgentRegistry public registry;
    VerdictLog public verdictLog;
    FosaGateRouter public router;
    MockRiskEngine public riskEngine;
    MockTarget public target;

    address public owner = address(0xAA);
    address public evaluator = address(0xBB);
    address public agent = address(0xCC);
    address public emergencyAdmin = address(0xDD);

    bytes public defaultAttestation = hex"12345678";

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy Core Contracts
        registry = new AgentRegistry(owner);
        verdictLog = new VerdictLog(owner);
        riskEngine = new MockRiskEngine();
        target = new MockTarget();

        // 2. Deploy FosaGateRouter with initial 500 riskThreshold (0-1000 range)
        router = new FosaGateRouter(
            owner,
            evaluator,
            address(registry),
            address(verdictLog),
            500
        );

        // 3. Link Dependencies
        router.setRiskEngine(address(riskEngine));
        router.setEmergencyAdmin(emergencyAdmin);
        registry.setRouter(address(router));
        verdictLog.setRouter(address(router));

        vm.stopPrank();

        // Deal ETH to the agent for value transfers
        vm.deal(agent, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      AGENT REGISTRY LIFE-CYCLE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function testAgentRegistration() public {
        // Register agent
        registry.registerAgent(agent, "agent_metadata");

        IAgentRegistry.AgentInfo memory info = registry.getAgent(agent);
        assertEq(uint256(info.tier), uint256(IAgentRegistry.Tier.UNVERIFIED));
        assertEq(info.metadata, "agent_metadata");
        assertTrue(registry.isRegistered(agent));

        // Attempting to register again should revert
        vm.expectRevert("AgentRegistry: agent already registered");
        registry.registerAgent(agent, "new_metadata");
    }

    function testAgentSuspensionAndReinstatement() public {
        registry.registerAgent(agent, "metadata");

        // Suspend
        vm.prank(owner);
        registry.suspendAgent(agent, "violating behavior");

        assertFalse(registry.isRegistered(agent));
        assertTrue(registry.getAgent(agent).isSuspended);

        // Reinstate
        vm.prank(owner);
        registry.reinstateAgent(agent);

        assertTrue(registry.isRegistered(agent));
        assertFalse(registry.getAgent(agent).isSuspended);
    }

    function testTierUpdates() public {
        registry.registerAgent(agent, "metadata");

        // Update to TRUSTED
        vm.prank(owner);
        registry.updateAgentTier(agent, IAgentRegistry.Tier.TRUSTED);

        assertEq(uint256(registry.getAgent(agent).tier), uint256(IAgentRegistry.Tier.TRUSTED));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    SINGLE TRANSACTION CLEARANCE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function testExecutionWithInvalidAttestationFails() public {
        // Register agent
        registry.registerAgent(agent, "metadata");

        // Calculate expected txId
        uint256 nonce = router.agentNonces(agent);
        bytes memory payload = abi.encodeWithSignature("executeAction(uint256)", 42);
        bytes32 expectedTxId = keccak256(abi.encodePacked(agent, address(target), payload, nonce, block.chainid));

        // Configure MockRiskEngine to return valid = false
        riskEngine.setNextVerifyResult(expectedTxId, 200, 0, false);

        // Execute should fail because attestation is invalid
        vm.startPrank(agent);
        (bytes32 txId, bool success) = router.executeWithClearance(address(target), payload, defaultAttestation);
        vm.stopPrank();

        assertEq(txId, expectedTxId);
        assertFalse(success);

        // Check that stats show rejected transaction
        IAgentRegistry.AgentStats memory stats = registry.getAgentStats(agent);
        assertEq(stats.totalTransactions, 1);
        assertEq(stats.totalRejected, 1);
        assertEq(stats.totalApproved, 0);

        // Check that verdict was logged as REJECTED_INVALID_ATTESTATION
        bytes32 recordedTxId = keccak256(abi.encodePacked(agent, address(target), payload, nonce, block.chainid));
        IVerdictLog.VerdictRecord memory verdict = verdictLog.getVerdict(recordedTxId);
        assertEq(uint256(verdict.verdict), uint256(IVerdictLog.Verdict.REJECTED_INVALID_ATTESTATION));
    }

    function testExecutionWithHighRiskFails() public {
        registry.registerAgent(agent, "metadata");

        uint256 nonce = router.agentNonces(agent);
        bytes memory payload = abi.encodeWithSignature("executeAction(uint256)", 42);
        bytes32 expectedTxId = keccak256(abi.encodePacked(agent, address(target), payload, nonce, block.chainid));

        // Risk score of 600 exceeds default threshold of 500
        riskEngine.setNextVerifyResult(expectedTxId, 600, 0, true);

        vm.startPrank(agent);
        (bytes32 txId, bool success) = router.executeWithClearance(address(target), payload, defaultAttestation);
        vm.stopPrank();

        assertEq(txId, expectedTxId);
        assertFalse(success);

        // Stats should show rejection
        IAgentRegistry.AgentStats memory stats = registry.getAgentStats(agent);
        assertEq(stats.totalTransactions, 1);
        assertEq(stats.totalRejected, 1);

        // Verdict logged as REJECTED_HIGH_RISK
        IVerdictLog.VerdictRecord memory verdict = verdictLog.getVerdict(expectedTxId);
        assertEq(uint256(verdict.verdict), uint256(IVerdictLog.Verdict.REJECTED_HIGH_RISK));
    }

    function testSuccessfulExecutionClearance() public {
        registry.registerAgent(agent, "metadata");

        uint256 nonce = router.agentNonces(agent);
        bytes memory payload = abi.encodeWithSignature("executeAction(uint256)", 42);
        bytes32 expectedTxId = keccak256(abi.encodePacked(agent, address(target), payload, nonce, block.chainid));

        // Valid, risk score 150 (below 500)
        riskEngine.setNextVerifyResult(expectedTxId, 150, 1, true);

        vm.startPrank(agent);
        (bytes32 txId, bool success) = router.executeWithClearance{value: 1 ether}(
            address(target),
            payload,
            defaultAttestation
        );
        vm.stopPrank();

        assertEq(txId, expectedTxId);
        assertTrue(success);

        // Nonce should be incremented
        assertEq(router.agentNonces(agent), nonce + 1);

        // Stats should show approved transaction
        IAgentRegistry.AgentStats memory stats = registry.getAgentStats(agent);
        assertEq(stats.totalTransactions, 1);
        assertEq(stats.totalApproved, 1);

        // Target should be called successfully with native value
        assertTrue(target.wasCalled());
        assertEq(target.lastValue(), 1 ether);

        // Verdict logged as APPROVED
        IVerdictLog.VerdictRecord memory verdict = verdictLog.getVerdict(expectedTxId);
        assertEq(uint256(verdict.verdict), uint256(IVerdictLog.Verdict.APPROVED));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     BATCH EXECUTION CLEARANCE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function testBatchExecution() public {
        registry.registerAgent(agent, "metadata");

        uint256 startNonce = router.agentNonces(agent);

        // Build 2 requests
        IFosaGateRouter.ExecutionRequest[] memory requests = new IFosaGateRouter.ExecutionRequest[](2);

        // Request 1: will be rejected because of high risk (score 700)
        bytes memory payload1 = abi.encodeWithSignature("executeAction(uint256)", 100);
        bytes32 expectedTxId1 = keccak256(abi.encodePacked(agent, address(target), payload1, startNonce, block.chainid));
        bytes memory attestation1 = hex"aaaa";

        requests[0] = IFosaGateRouter.ExecutionRequest({
            target: address(target),
            payload: payload1,
            value: 0.1 ether,
            attestation: attestation1
        });

        // Request 2: will be approved and succeed (score 100)
        bytes memory payload2 = abi.encodeWithSignature("executeAction(uint256)", 200);
        // Note: request 2's expected nonce will be startNonce + 1 because request 1 is processed first and increments the nonce!
        bytes32 expectedTxId2 = keccak256(abi.encodePacked(agent, address(target), payload2, startNonce + 1, block.chainid));
        bytes memory attestation2 = hex"bbbb";

        requests[1] = IFosaGateRouter.ExecutionRequest({
            target: address(target),
            payload: payload2,
            value: 0.2 ether,
            attestation: attestation2
        });

        // Configure riskEngine for request 1 and 2 mapped to their respective attestations
        riskEngine.setVerifyResultForAttestation(attestation1, expectedTxId1, 700, 1, true);
        riskEngine.setVerifyResultForAttestation(attestation2, expectedTxId2, 100, 1, true);

        vm.startPrank(agent);
        (bytes32[] memory txIds, bool[] memory successes) = router.batchExecuteWithClearance{value: 0.3 ether}(requests);
        vm.stopPrank();

        assertEq(txIds.length, 2);
        assertEq(successes.length, 2);

        // First request: rejected but doesn't revert batch
        assertEq(txIds[0], expectedTxId1);
        assertFalse(successes[0]);

        // Second request: approved and executed successfully
        assertEq(txIds[1], expectedTxId2);
        assertTrue(successes[1]);

        // Nonces should increment by 2
        assertEq(router.agentNonces(agent), startNonce + 2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         CIRCUIT BREAKER TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function testCircuitBreakerEmergencyStop() public {
        registry.registerAgent(agent, "metadata");

        // Emergency admin pauses router
        vm.prank(emergencyAdmin);
        router.pause();

        assertTrue(router.paused());

        // Attempting to execute while paused should revert
        bytes memory payload = abi.encodeWithSignature("executeAction(uint256)", 42);
        vm.startPrank(agent);
        vm.expectRevert(); // EnforcedPause
        router.executeWithClearance(address(target), payload, defaultAttestation);
        vm.stopPrank();

        // Non-owner cannot unpause
        vm.prank(emergencyAdmin);
        vm.expectRevert(); // OwnableUnauthorizedAccount or custom check
        router.unpause();

        // Owner can unpause
        vm.prank(owner);
        router.unpause();

        assertFalse(router.paused());
    }
}
