import { ethers } from "ethers";
import { TransactionIntent } from "../attestation/schema";

export interface MevAnalysis {
  score: number; // 0-1000
  details: string;
}

// Known DEX Router function selectors (e.g. Uniswap V2 & V3)
const DEX_SELECTORS = {
  swapExactTokensForTokens: "0x38ed5639",
  swapTokensForExactTokens: "0x8803dbee",
  swapExactETHForTokens: "0x7ff36ab5",
  swapTokensForExactETH: "0x4a25d94a",
  swapExactTokensForETH: "0x18cba2db",
  swapETHForExactTokens: "0xfb3bdb41",
  exactInputSingle: "0x414bf389", // Uniswap V3
  exactInput: "0xc04b8d59",       // Uniswap V3
  exactOutputSingle: "0xdb3e21b3",// Uniswap V3
  exactOutput: "0xf2886d3"        // Uniswap V3
};

/**
 * MEV Exposure Detector
 * Evaluates the risk of frontrunning, backrunning, or sandwich attacks.
 */
export async function analyzeMevExposure(
  intent: TransactionIntent,
  provider?: ethers.JsonRpcProvider
): Promise<MevAnalysis> {
  const { target, payload } = intent;
  const selector = payload.slice(0, 10).toLowerCase();

  // 1. Check if the target or selector is related to known DEX swap routers
  const isDexSwap = Object.values(DEX_SELECTORS).includes(selector);
  
  if (!isDexSwap) {
    // If not a swap, check if it's interacting with common MEV targets like raw token approvals
    if (selector === "0x095ea7b3") { // approve(address,uint256)
      return {
        score: 50,
        details: "Standard ERC20 approval. Low direct MEV risk, but opens potential vector."
      };
    }
    return {
      score: 0,
      details: "No DEX swap or standard MEV-vulnerable patterns detected."
    };
  }

  // 2. Perform deeper inspection on the swap parameters if payload length allows
  try {
    let details = "DEX swap detected. ";
    let score = 200; // Base score for any swap due to inherent arbitrage opportunities

    // Parse slippage or value arguments depending on the selector
    if (selector === DEX_SELECTORS.swapExactTokensForTokens || selector === DEX_SELECTORS.exactInputSingle) {
      // High-slippage swaps are heavily targeted by sandwich bots.
      // If we have a provider, we can inspect mempool or gas price trends
      if (provider) {
        const feeData = await provider.getFeeData();
        const gasPriceGwei = feeData.gasPrice ? Number(ethers.formatUnits(feeData.gasPrice, "gwei")) : 0;
        
        if (gasPriceGwei > 100) {
          score += 150;
          details += "High network congestion detected (gas price > 100 Gwei), increasing frontrunning likelihood. ";
        }
      }
      
      // Look at the length of payload. If it's a multihop swap, risk is slightly higher due to multiple hops.
      if (payload.length > 500) {
        score += 100;
        details += "Multi-hop path swap increases execution latency and arbitrage surface. ";
      } else {
        details += "Single-hop swap detected. ";
      }

      score = Math.min(score, 1000);
      return { score, details: details.trim() };
    }

    return {
      score: 250,
      details: "Generic swap transaction. Moderate MEV risk."
    };
  } catch (error) {
    return {
      score: 300,
      details: `Failed to fully parse swap payload. Defaulting to moderate-high risk. Error: ${(error as Error).message}`
    };
  }
}
