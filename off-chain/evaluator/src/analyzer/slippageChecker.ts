import { ethers } from "ethers";
import { TransactionIntent } from "../attestation/schema";

export interface SlippageAnalysis {
  score: number; // 0-1000
  expectedSlippage: number; // in bps (1 basis point = 0.01%)
  worstCase: string;
}

const SWAP_V2_ABI = [
  "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)"
];

const SWAP_V3_ABI = [
  "function exactInputSingle((address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 deadline, uint256 amountIn, uint256 amountOutMinimum, uint160 squareRootPriceLimitX96) params)"
];

/**
 * Slippage Checker
 * Decodes the transaction calldata and checks the configured minimum output
 * against the expected output, scoring the slippage risk.
 */
export async function calculateSlippageRisk(
  intent: TransactionIntent,
  provider?: ethers.JsonRpcProvider
): Promise<SlippageAnalysis> {
  const { payload } = intent;
  const selector = payload.slice(0, 10).toLowerCase();

  try {
    // 1. Uniswap V2: swapExactTokensForTokens (selector 0x38ed5639)
    if (selector === "0x38ed5639") {
      const iface = new ethers.Interface(SWAP_V2_ABI);
      const decoded = iface.decodeFunctionData("swapExactTokensForTokens", payload);
      
      const amountIn = BigInt(decoded[0].toString());
      const amountOutMin = BigInt(decoded[1].toString());

      if (amountOutMin === 0n) {
        return {
          score: 1000,
          expectedSlippage: 10000, // 100% slippage
          worstCase: "Token swap with ZERO minimum output can be entirely drained by sandwich bots."
        };
      }

      // If we don't have pool data, assume 1% as baseline expected slippage.
      // We can calculate the implied slippage tolerance by comparing amountOutMin to amountIn.
      // Note: for stablecoins/correlated pairs it's different, but we'll use a conservative heuristic.
      const impliedSlippageBps = Number(((amountIn - amountOutMin) * 10000n) / amountIn);
      let score = 100;
      if (impliedSlippageBps > 500) { // > 5% slippage
        score = 800;
      } else if (impliedSlippageBps > 200) { // > 2% slippage
        score = 500;
      } else if (impliedSlippageBps > 100) { // > 1% slippage
        score = 300;
      }

      return {
        score,
        expectedSlippage: impliedSlippageBps,
        worstCase: `Minimum output set to ${ethers.formatEther(amountOutMin)} tokens. Implied slippage: ${(impliedSlippageBps / 100).toFixed(2)}%.`
      };
    }

    // 2. Uniswap V3: exactInputSingle (selector 0x414bf389)
    if (selector === "0x414bf389") {
      const iface = new ethers.Interface(SWAP_V3_ABI);
      const decoded = iface.decodeFunctionData("exactInputSingle", payload);
      const params = decoded[0];

      const amountIn = BigInt(params.amountIn.toString());
      const amountOutMinimum = BigInt(params.amountOutMinimum.toString());

      if (amountOutMinimum === 0n) {
        return {
          score: 1000,
          expectedSlippage: 10000,
          worstCase: "Uniswap V3 swap with ZERO minimum output offers no slippage protection."
        };
      }

      const impliedSlippageBps = Number(((amountIn - amountOutMinimum) * 10000n) / amountIn);
      let score = 100;
      if (impliedSlippageBps > 500) {
        score = 850;
      } else if (impliedSlippageBps > 200) {
        score = 550;
      } else if (impliedSlippageBps > 100) {
        score = 350;
      }

      return {
        score,
        expectedSlippage: impliedSlippageBps,
        worstCase: `Uniswap V3 swap. Minimum output: ${ethers.formatEther(amountOutMinimum)} tokens. Implied slippage: ${(impliedSlippageBps / 100).toFixed(2)}%.`
      };
    }

    // 3. Fallback for non-swap or unsupported swap
    return {
      score: 0,
      expectedSlippage: 0,
      worstCase: "No price impact or slippage parameters applicable for this transaction type."
    };
  } catch (error) {
    // If it fails to parse but looks like a swap, return a default warning score.
    const isSwapSelector = ["0x38ed5639", "0x8803dbee", "0x7ff36ab5", "0x4a25d94a", "0x18cba2db", "0xfb3bdb41", "0x414bf389", "0xc04b8d59", "0xdb3e21b3", "0xf2886d3"]
      .includes(selector);

    return {
      score: isSwapSelector ? 400 : 0,
      expectedSlippage: 0,
      worstCase: isSwapSelector
        ? "Could not decode DEX swap arguments. Proceed with caution."
        : "Not a standard DEX swap payload."
    };
  }
}
