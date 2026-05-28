// FosaGate AI Protocol
// Pre-Flight Evaluation Layer for Agent Transactions
//
// Contract : RiskEngine (Stylus / Rust → WASM)
// Author   : rbd3
// Chain    : Arbitrum One / Arbitrum Sepolia
// Version  : 1.0.0
//
// Purpose  : Performance-critical operations compiled to WASM via
//            Arbitrum Stylus. Handles ECDSA attestation verification,
//            composite risk scoring, and Merkle-based blacklist checks.
//            ~10x gas savings vs equivalent Solidity for batch ops.

#![cfg_attr(not(feature = "export-abi"), no_main)]
extern crate alloc;

mod attestation;
mod scoring;
mod blacklist;

// Bring in HostAccess + BlockAccess + MessageAccess traits via prelude
use stylus_sdk::prelude::*;
use stylus_sdk::alloy_primitives::{Address, B256, U256};
use stylus_sdk::alloy_sol_types::sol;

// ═══════════════════════════════════════════════════════════════════════════
//                     SOLIDITY INTERFACE DEFINITION
// ═══════════════════════════════════════════════════════════════════════════

sol! {
    /// Decoded attestation data returned after successful verification
    struct AttestationData {
        bytes32 txId;
        uint256 riskScore;
        uint8 verdict;
        uint256 nonce;
        uint256 expiry;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//                         CONTRACT STORAGE
// ═══════════════════════════════════════════════════════════════════════════

sol_storage! {
    #[entrypoint]
    pub struct RiskEngine {
        /// Authorized off-chain evaluator address
        address evaluator;

        /// Contract owner
        address owner;

        /// Replay protection is handled by FosaGateRouter.agentNonces (monotonic counter).
        /// Attestation expiry is validated inside verify_full() in attestation.rs.

        /// Merkle root of known-malicious calldata blacklist
        bytes32 blacklist_root;

        /// Composite score weights [MEV, slippage, contract, value]
        /// Default: [250, 300, 250, 200]
        uint256[4] score_weights;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//                       EXTERNAL FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════

#[public]
impl RiskEngine {

    // ───────────────────────────────────────────────────────────────────
    //                   ATTESTATION VERIFICATION
    // ───────────────────────────────────────────────────────────────────

    /// Verifies the cryptographic signature of an off-chain evaluator attestation.
    ///
    /// The IRiskEngine interface passes evaluatorPubkey as a parameter so callers
    /// control which evaluator to validate against. We also cross-check it against
    /// the stored evaluator for extra safety.
    ///
    /// Returns: (txId, riskScore, verdict, valid)
    pub fn verify_attestation(
        &mut self,
        attestation: Vec<u8>,
        evaluator_pubkey: Address,
    ) -> (B256, U256, u8, bool) {
        let stored_evaluator = self.evaluator.get();

        // If stored evaluator is set, the passed key must match it
        if stored_evaluator != Address::ZERO && evaluator_pubkey != stored_evaluator {
            return (B256::ZERO, U256::ZERO, 0, false);
        }

        let current_timestamp = U256::from(self.vm().block_timestamp());

        match attestation::verify_full(&attestation, evaluator_pubkey, current_timestamp) {
            Ok(decoded) => (decoded.tx_id, decoded.risk_score, decoded.verdict, true),
            Err(_) => (B256::ZERO, U256::ZERO, 0, false),
        }
    }

    /// Batch verification of multiple attestations in a single call.
    ///
    /// Used by FosaGateRouter.batchExecuteWithClearance() for gas efficiency.
    /// Returns: (txIds, riskScores, verdicts, allValid)
    pub fn batch_verify(
        &mut self,
        attestations: Vec<Vec<u8>>,
        evaluator_pubkey: Address,
    ) -> (Vec<B256>, Vec<U256>, Vec<u8>, bool) {
        let mut tx_ids = alloc::vec::Vec::with_capacity(attestations.len());
        let mut risk_scores = alloc::vec::Vec::with_capacity(attestations.len());
        let mut verdicts = alloc::vec::Vec::with_capacity(attestations.len());
        let mut all_valid = true;

        let current_timestamp = U256::from(self.vm().block_timestamp());
        let stored_evaluator = self.evaluator.get();

        for attestation in attestations {
            // Validate evaluator key matches stored one (if set)
            if stored_evaluator != Address::ZERO && evaluator_pubkey != stored_evaluator {
                tx_ids.push(B256::ZERO);
                risk_scores.push(U256::ZERO);
                verdicts.push(0);
                all_valid = false;
                continue;
            }

            match attestation::verify_full(&attestation, evaluator_pubkey, current_timestamp) {
                Ok(decoded) => {
                    tx_ids.push(decoded.tx_id);
                    risk_scores.push(decoded.risk_score);
                    verdicts.push(decoded.verdict);
                }
                Err(_) => {
                    tx_ids.push(B256::ZERO);
                    risk_scores.push(U256::ZERO);
                    verdicts.push(0);
                    all_valid = false;
                }
            }
        }

        (tx_ids, risk_scores, verdicts, all_valid)
    }

    // ───────────────────────────────────────────────────────────────────
    //                      RISK VALIDATION
    // ───────────────────────────────────────────────────────────────────

    /// Validates risk score against policy maximum with tier-based tolerance.
    ///
    /// Tier multipliers: UNVERIFIED=100%, BASIC=105%, TRUSTED=110%, PREMIUM=115%
    /// Returns: (acceptable, adjustedMax)
    pub fn validate_risk_params(
        &self,
        risk_score: U256,
        policy_max: U256,
        agent_tier: u8,
    ) -> (bool, U256) {
        scoring::validate_risk(risk_score, policy_max, agent_tier)
    }

    /// Computes weighted composite risk score from 4 analysis dimensions.
    ///
    /// Formula: (mev*w0 + slippage*w1 + contract*w2 + value*w3) / sum(w)
    /// Caller supplies weights — matches IRiskEngine.sol (external pure).
    /// Call get_score_weights() first to read the protocol-recommended defaults.
    /// Returns score clamped to 0–1000.
    pub fn compute_composite_score(
        &self,
        mev_score: U256,
        slippage_score: U256,
        contract_score: U256,
        value_score: U256,
        weights: [U256; 4],
    ) -> U256 {
        let sum = weights[0] + weights[1] + weights[2] + weights[3];
        assert!(sum > U256::ZERO, "Sum of weights must be > 0");
        scoring::compute_composite(mev_score, slippage_score, contract_score, value_score, weights)
    }

    // ───────────────────────────────────────────────────────────────────
    //                     PATTERN BLACKLIST
    // ───────────────────────────────────────────────────────────────────

    /// Verifies via Merkle proof that calldata hash is NOT in the blacklist.
    ///
    /// Caller supplies blacklist_root — matches IRiskEngine.sol (external pure).
    /// Call get_blacklist_root() first to read the current on-chain root.
    /// Returns true if safe (not blacklisted) or if blacklist_root is B256::ZERO.
    pub fn check_pattern_hash(
        &self,
        calldata_hash: B256,
        blacklist_root: B256,
        proof: Vec<B256>,
    ) -> bool {
        blacklist::verify_not_blacklisted(calldata_hash, blacklist_root, &proof[..])
    }

    // ───────────────────────────────────────────────────────────────────
    //                      ADMIN FUNCTIONS
    // ───────────────────────────────────────────────────────────────────

    /// Initialize the contract with owner + evaluator and default score weights.
    ///
    /// Can only be called once (owner must be zero = uninitialized).
    pub fn init(&mut self, owner: Address, evaluator: Address) {
        let current_owner = self.owner.get();
        assert!(current_owner == Address::ZERO, "Already initialized");
        self.owner.set(owner);
        self.evaluator.set(evaluator);

        // Default weights: MEV=250, slippage=300, contract=250, value=200
        let defaults = [
            U256::from(250),
            U256::from(300),
            U256::from(250),
            U256::from(200),
        ];
        for i in 0..4usize {
            self.score_weights.setter(i).unwrap().set(defaults[i]);
        }
    }

    /// Update the authorized evaluator address. Owner only.
    pub fn set_evaluator(&mut self, new_evaluator: Address) {
        let caller = self.vm().msg_sender();
        assert_eq!(caller, self.owner.get(), "Only owner can set evaluator");
        self.evaluator.set(new_evaluator);
    }

    /// Update the blacklist Merkle root. Owner or evaluator.
    pub fn set_blacklist_root(&mut self, new_root: B256) {
        let caller = self.vm().msg_sender();
        let is_owner = caller == self.owner.get();
        let is_evaluator = caller == self.evaluator.get();
        assert!(is_owner || is_evaluator, "Unauthorized: owner or evaluator only");
        self.blacklist_root.set(new_root);
    }

    /// Update composite score weights. Owner only.
    ///
    /// weights: [mevWeight, slippageWeight, contractWeight, valueWeight]
    /// Sum must be > 0. Recommended: sum = 1000 for easy % reading.
    pub fn set_score_weights(&mut self, weights: [U256; 4]) {
        let caller = self.vm().msg_sender();
        assert_eq!(caller, self.owner.get(), "Only owner can set score weights");

        let mut sum = U256::ZERO;
        for w in &weights {
            sum = sum.checked_add(*w).expect("Weight sum overflow");
        }
        assert!(sum > U256::ZERO, "Sum of weights must be > 0");

        for i in 0..4usize {
            self.score_weights.setter(i).unwrap().set(weights[i]);
        }
    }

    /// Transfer contract ownership. Current owner only.
    pub fn transfer_ownership(&mut self, new_owner: Address) {
        let caller = self.vm().msg_sender();
        assert_eq!(caller, self.owner.get(), "Only owner can transfer ownership");
        self.owner.set(new_owner);
    }

    // ───────────────────────────────────────────────────────────────────
    //                       VIEW FUNCTIONS
    // ───────────────────────────────────────────────────────────────────

    /// Returns the current authorized evaluator address
    pub fn get_evaluator(&self) -> Address {
        self.evaluator.get()
    }

    /// Returns the current blacklist Merkle root
    pub fn get_blacklist_root(&self) -> B256 {
        self.blacklist_root.get()
    }

    /// Returns current score weights as 4 separate values
    pub fn get_score_weights(&self) -> (U256, U256, U256, U256) {
        (
            self.score_weights.getter(0).unwrap().get(),
            self.score_weights.getter(1).unwrap().get(),
            self.score_weights.getter(2).unwrap().get(),
            self.score_weights.getter(3).unwrap().get(),
        )
    }

    /// Returns the contract owner address
    pub fn get_owner(&self) -> Address {
        self.owner.get()
    }
}
