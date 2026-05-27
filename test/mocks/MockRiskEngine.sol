// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRiskEngine} from "../../src/interfaces/IRiskEngine.sol";

contract MockRiskEngine is IRiskEngine {
    struct VerifyResult {
        bytes32 attTxId;
        uint256 riskScore;
        uint8 verdict;
        bool valid;
    }

    bytes32 public nextAttTxId;
    uint256 public nextRiskScore;
    uint8 public nextVerdict;
    bool public nextValid;

    mapping(bytes32 => VerifyResult) private _attestationResults;

    function setNextVerifyResult(
        bytes32 attTxId,
        uint256 riskScore,
        uint8 verdict,
        bool valid
    ) external {
        nextAttTxId = attTxId;
        nextRiskScore = riskScore;
        nextVerdict = verdict;
        nextValid = valid;
    }

    function setVerifyResultForAttestation(
        bytes calldata attestation,
        bytes32 attTxId,
        uint256 riskScore,
        uint8 verdict,
        bool valid
    ) external {
        _attestationResults[keccak256(attestation)] = VerifyResult({
            attTxId: attTxId,
            riskScore: riskScore,
            verdict: verdict,
            valid: valid
        });
    }

    function verifyAttestation(
        bytes calldata attestation,
        address /* evaluatorPubkey */
    )
        external
        view
        override
        returns (bytes32 attTxId, uint256 riskScore, uint8 verdict, bool valid)
    {
        bytes32 key = keccak256(attestation);
        VerifyResult memory res = _attestationResults[key];
        if (res.valid || res.attTxId != bytes32(0)) {
            return (res.attTxId, res.riskScore, res.verdict, res.valid);
        }
        return (nextAttTxId, nextRiskScore, nextVerdict, nextValid);
    }

    function batchVerify(
        bytes[] calldata attestations,
        address /* evaluatorPubkey */
    )
        external
        view
        override
        returns (bytes32[] memory txIds, uint256[] memory riskScores, uint8[] memory verdicts, bool allValid)
    {
        txIds = new bytes32[](attestations.length);
        riskScores = new uint256[](attestations.length);
        verdicts = new uint8[](attestations.length);
        allValid = true;

        for (uint256 i = 0; i < attestations.length; i++) {
            bytes32 key = keccak256(attestations[i]);
            VerifyResult memory res = _attestationResults[key];
            if (res.valid || res.attTxId != bytes32(0)) {
                txIds[i] = res.attTxId;
                riskScores[i] = res.riskScore;
                verdicts[i] = res.verdict;
                if (!res.valid) {
                    allValid = false;
                }
            } else {
                txIds[i] = nextAttTxId;
                riskScores[i] = nextRiskScore;
                verdicts[i] = nextVerdict;
                if (!nextValid) {
                    allValid = false;
                }
            }
        }
    }

    function validateRiskParams(
        uint256 riskScore,
        uint256 policyMax,
        uint8 /* agentTier */
    ) external pure override returns (bool acceptable, uint256 adjustedMax) {
        return (riskScore <= policyMax, policyMax);
    }

    function computeCompositeScore(
        uint256 mevScore,
        uint256 slippageScore,
        uint256 contractScore,
        uint256 valueScore,
        uint256[4] calldata /* weights */
    ) external pure override returns (uint256 compositeScore) {
        return (mevScore + slippageScore + contractScore + valueScore) / 4;
    }

    function checkPatternHash(
        bytes32 /* calldataHash */,
        bytes32 /* blacklistRoot */,
        bytes32[] calldata /* proof */
    ) external pure override returns (bool notBlacklisted) {
        return true;
    }
}
