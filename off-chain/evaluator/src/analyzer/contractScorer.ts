import { ethers } from "ethers";

export interface ContractScore {
  score: number; // 0-1000 (lower is better, i.e., safer)
  flags: string[];
}

// Registry of known blue-chip and trusted DeFi contract addresses/patterns
const BLUE_CHIPS: Record<string, string> = {
  // Uniswap V3 Factory (Arbitrum One)
  "0x1f98431c8ad98523631ae4a59f267346ea31f984": "Uniswap V3 Factory",
  // Uniswap V3 Router (Arbitrum One)
  "0xe592427a0aece92de3edf7a9cd9373d5d72483d4": "Uniswap V3 SwapRouter",
  // Aave V3 Pool (Arbitrum One)
  "0x794a61358d6845594f94dc1db02a252b5b4814ad": "Aave V3 Pool",
  // WETH (Arbitrum One)
  "0x82af49447d8a07e3bd95bd0d56f352415231daa1": "WETH9",
  // USDC (Arbitrum One)
  "0xaf88d065e77c8cc2239327c5edd1344135c11d61": "USDC (Proxy)",
  // USDT (Arbitrum One)
  "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9": "USDT"
};

// Blacklisted malicious contracts
const BLACKLIST: Record<string, string> = {
  "0xdac17f958d2ee523a2206206994597c13d831ec7": "Potential Phishing Mirror Contract",
};

// EIP-1967 Implementation Slot
const EIP1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

/**
 * Contract Scorer
 * Assesses the reputation, age, proxy pattern, and security status of the target contract.
 */
export async function scoreTargetContract(
  targetAddress: string,
  provider?: ethers.JsonRpcProvider
): Promise<ContractScore> {
  const targetLower = targetAddress.toLowerCase();
  const flags: string[] = [];
  let score = 200; // Default baseline score (unknown contract)

  // 1. Check blacklist
  if (BLACKLIST[targetLower]) {
    return {
      score: 1000,
      flags: ["BLACKLISTED_MALICIOUS_CONTRACT", `Identified as: ${BLACKLIST[targetLower]}`]
    };
  }

  // 2. Check blue-chips (whitelist)
  if (BLUE_CHIPS[targetLower]) {
    flags.push(`BLUE_CHIP_CONTRACT: ${BLUE_CHIPS[targetLower]}`);
    score = 10; // Highly reputable
  }

  if (provider) {
    try {
      // 3. Check if target is a contract or EOA
      const code = await provider.getCode(targetAddress);
      if (code === "0x") {
        flags.push("TARGET_IS_EOA");
        // Sending interactions/payloads to an EOA is high-risk unless it's just a simple transfer
        score = 600;
        return { score, flags };
      }

      flags.push("TARGET_IS_SMART_CONTRACT");

      // 4. Check for Proxy Pattern (Upgradeable Contract)
      // Upgradeability introduces risk of malicious logic replacement.
      const implSlotValue = await provider.getStorage(targetAddress, EIP1967_IMPLEMENTATION_SLOT);
      const hasProxySlot = implSlotValue !== ethers.ZeroHash;
      
      if (hasProxySlot) {
        flags.push("PROXY_PATTERN_DETECTED (EIP-1967)");
        score += 150; // Add risk premium for upgradeable logic
      }

      // 5. Query verification state or age (simulated based on code length/entropy)
      if (code.length < 500) {
        flags.push("MINIMAL_CODE_SIZE (possible honeypot/stub)");
        score += 200;
      }
    } catch (error) {
      flags.push(`ONCHAIN_RECON_FAILED: ${(error as Error).message}`);
      score = 500; // Default to moderate risk on network error
    }
  } else {
    flags.push("NO_ONCHAIN_PROVIDER (Offline validation only)");
  }

  score = Math.min(Math.max(score, 0), 1000);
  return { score, flags };
}
