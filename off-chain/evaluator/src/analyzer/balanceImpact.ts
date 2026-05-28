import { ethers } from "ethers";
import { TransactionIntent } from "../attestation/schema";

export interface BalanceChange {
  token: string; // "ETH" or ERC20 address
  delta: string; // Hex or decimal representation of delta (+/-)
}

export interface BalanceImpactAnalysis {
  changes: BalanceChange[];
  netValueChange: string; // USD equivalent approximation
  score: number; // 0-1000
}

const ERC20_TRANSFER_SELECTOR = "0xa9059cbb";
const ERC20_APPROVE_SELECTOR = "0x095ea7b3";

/**
 * Balance Impact Simulator
 * Predicts balance changes and detects potential capital drains or high-value approval risks.
 */
export async function simulateBalanceImpact(
  intent: TransactionIntent,
  provider?: ethers.JsonRpcProvider
): Promise<BalanceImpactAnalysis> {
  const { agent, target, payload, value } = intent;
  const selector = payload.slice(0, 10).toLowerCase();
  
  const changes: BalanceChange[] = [];
  let score = 0;
  let netValueChange = "0.00";

  // 1. Check native ETH transfer
  const ethValue = BigInt(value);
  if (ethValue > 0n) {
    changes.push({
      token: "ETH",
      delta: `-${ethers.formatEther(ethValue)}`
    });

    // Score based on native value transfer size
    if (ethValue > ethers.parseEther("10")) { // > 10 ETH
      score += 400;
    } else if (ethValue > ethers.parseEther("1")) { // > 1 ETH
      score += 200;
    } else {
      score += 50;
    }
  }

  // 2. Parse ERC20 Transfers and Approvals
  if (selector === ERC20_TRANSFER_SELECTOR && payload.length >= 138) {
    try {
      const to = ethers.getAddress("0x" + payload.slice(34, 74));
      const amount = BigInt("0x" + payload.slice(74, 138));
      
      changes.push({
        token: target, // The ERC20 token contract is the target
        delta: `-${ethers.formatUnits(amount, 18)}` // Assume default 18 decimals for display
      });

      // Score based on transfer size
      if (amount > ethers.parseUnits("100000", 18)) {
        score += 500;
      } else if (amount > ethers.parseUnits("1000", 18)) {
        score += 200;
      } else {
        score += 100;
      }
    } catch (e) {
      score += 100;
    }
  } else if (selector === ERC20_APPROVE_SELECTOR && payload.length >= 138) {
    try {
      const spender = ethers.getAddress("0x" + payload.slice(34, 74));
      const amount = BigInt("0x" + payload.slice(74, 138));

      // Unlimited approval is highly dangerous (approval hijacking)
      const isUnlimited = amount === ethers.MaxUint256;
      changes.push({
        token: target,
        delta: isUnlimited ? "UNLIMITED_ALLOWANCE" : `APPROVE_${ethers.formatUnits(amount, 18)}`
      });

      if (isUnlimited) {
        score += 600; // Major security hazard if spender is not a trusted contract
      } else if (amount > 0n) {
        score += 200;
      }
    } catch (e) {
      score += 100;
    }
  }

  // 3. Perform on-chain transaction simulation (gas estimation / call)
  if (provider) {
    try {
      // Use estimateGas as a lightweight simulator of success vs failure.
      // If it reverts, gas estimation will fail.
      await provider.estimateGas({
        from: agent,
        to: target,
        data: payload,
        value: ethValue
      });
    } catch (error) {
      // Reverting transactions are scored high risk
      score += 500;
      changes.push({
        token: "SYSTEM",
        delta: `SIMULATION_REVERTED: ${(error as Error).message.slice(0, 100)}`
      });
    }
  }

  score = Math.min(score, 1000);
  
  return {
    changes,
    netValueChange,
    score
  };
}
