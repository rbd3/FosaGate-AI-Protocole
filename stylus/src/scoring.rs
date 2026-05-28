// FosaGate AI Protocol — RiskEngine / Scoring Module
// Author: rbd3
//
// Composite risk scoring and tier-based validation.
// Pure computation — no storage access needed (weights passed in or read from storage in lib.rs).

use stylus_sdk::alloy_primitives::U256;

/// Tier-based tolerance multipliers (basis points where 100 = 1x).
/// Higher tiers get more tolerance on risk thresholds as a reward for good behavior.
///
/// UNVERIFIED (0): 100 (no bonus, strict)
/// BASIC      (1): 105 (+5%)
/// TRUSTED    (2): 110 (+10%)
/// PREMIUM    (3): 115 (+15%)
const TIER_MULTIPLIERS: [u64; 4] = [100, 105, 110, 115];

/// Validates risk score against policy maximum with tier-based tolerance.
///
/// Formula: adjusted_max = min(policy_max * TIER_MULTIPLIERS[tier] / 100, 1000)
///          acceptable = risk_score <= adjusted_max
///
/// - `risk_score`: Evaluated score (0-1000)
/// - `policy_max`: Policy threshold (0-1000)
/// - `agent_tier`: 0=UNVERIFIED, 1=BASIC, 2=TRUSTED, 3=PREMIUM
///
/// Returns (acceptable, adjusted_max)
pub fn validate_risk(
    risk_score: U256,
    policy_max: U256,
    agent_tier: u8,
) -> (bool, U256) {
    // 1. Clamp agent_tier to 0-3
    let tier = if agent_tier > 3 { 3 } else { agent_tier };

    // 2. multiplier = TIER_MULTIPLIERS[tier]
    let multiplier = U256::from(TIER_MULTIPLIERS[tier as usize]);

    // 3. adjusted_max = min(policy_max * multiplier / 100, 1000)
    let raw_adjusted = policy_max.checked_mul(multiplier)
        .unwrap_or(U256::MAX)
        .checked_div(U256::from(100))
        .unwrap_or(U256::ZERO);

    let max_score = U256::from(1000);
    let adjusted_max = if raw_adjusted > max_score {
        max_score
    } else {
        raw_adjusted
    };

    // 4. return (risk_score <= adjusted_max, adjusted_max)
    (risk_score <= adjusted_max, adjusted_max)
}

/// Computes weighted composite risk score from 4 analysis dimensions.
///
/// Formula: composite = (mev*w0 + slippage*w1 + contract*w2 + value*w3) / (w0+w1+w2+w3)
/// Result clamped to 0-1000.
///
/// Default weights: [250, 300, 250, 200] → slippage weighted highest (30%)
///
/// Panics if sum of weights is zero.
pub fn compute_composite(
    mev: U256,
    slippage: U256,
    contract: U256,
    value: U256,
    weights: [U256; 4],
) -> U256 {
    // 1. weighted_sum = mev*w[0] + slippage*w[1] + contract*w[2] + value*w[3]
    let w0 = mev.checked_mul(weights[0]).unwrap_or(U256::MAX);
    let w1 = slippage.checked_mul(weights[1]).unwrap_or(U256::MAX);
    let w2 = contract.checked_mul(weights[2]).unwrap_or(U256::MAX);
    let w3 = value.checked_mul(weights[3]).unwrap_or(U256::MAX);

    let mut weighted_sum = U256::ZERO;
    weighted_sum = weighted_sum.checked_add(w0).unwrap_or(U256::MAX);
    weighted_sum = weighted_sum.checked_add(w1).unwrap_or(U256::MAX);
    weighted_sum = weighted_sum.checked_add(w2).unwrap_or(U256::MAX);
    weighted_sum = weighted_sum.checked_add(w3).unwrap_or(U256::MAX);

    // 2. total = w[0] + w[1] + w[2] + w[3]
    let mut total_weight = U256::ZERO;
    total_weight = total_weight.checked_add(weights[0]).unwrap_or(U256::MAX);
    total_weight = total_weight.checked_add(weights[1]).unwrap_or(U256::MAX);
    total_weight = total_weight.checked_add(weights[2]).unwrap_or(U256::MAX);
    total_weight = total_weight.checked_add(weights[3]).unwrap_or(U256::MAX);

    // 3. assert total > 0
    assert!(total_weight > U256::ZERO, "Sum of weights must be greater than zero");

    // 4. composite = weighted_sum / total
    let composite = weighted_sum.checked_div(total_weight).unwrap_or(U256::ZERO);

    // 5. return min(composite, 1000)
    let max_score = U256::from(1000);
    if composite > max_score {
        max_score
    } else {
        composite
    }
}
