// FosaGate AI — API Gateway / Agent Management Routes
// GET  /api/v1/agents/:address   — Get agent profile + stats (on-chain query)
// POST /api/v1/agents/register   — Register a new agent (queues on-chain tx)

import { Router, Request, Response } from "express";
import { ethers } from "ethers";

const router = Router();

// ── ABI fragments for on-chain reads ─────────────────────────────────────
const AGENT_REGISTRY_ABI = [
  "function getAgent(address agent) view returns (tuple(uint8 tier, uint64 registeredAt, bool isSuspended, string metadata))",
  "function getAgentStats(address agent) view returns (tuple(uint256 totalTransactions, uint256 totalApproved, uint256 totalRejected, uint256 cumulativeRiskScore, uint256 totalVolume))",
  "function isRegistered(address agent) view returns (bool)",
  "function registerAgent(address agent, string metadata)",
];

const TIER_LABELS: Record<number, string> = {
  0: "UNVERIFIED",
  1: "BASIC",
  2: "TRUSTED",
  3: "PREMIUM",
};

// ── Helper: get provider + registry contract ─────────────────────────────
function getRegistry(): { provider: ethers.JsonRpcProvider; registry: ethers.Contract } | null {
  const rpc = process.env.ARBITRUM_RPC_URL;
  const addr = process.env.AGENT_REGISTRY_ADDRESS;
  if (!rpc || !addr || addr === "0x...") return null;

  const provider = new ethers.JsonRpcProvider(rpc);
  const registry = new ethers.Contract(addr, AGENT_REGISTRY_ABI, provider);
  return { provider, registry };
}

// ── GET /api/v1/agents/:address ──────────────────────────────────────────
router.get("/:address", async (req: Request, res: Response) => {
  const { address } = req.params;

  if (!ethers.isAddress(address)) {
    res.status(400).json({ error: "Invalid Ethereum address." });
    return;
  }

  const ctx = getRegistry();
  if (!ctx) {
    // Offline mode — return placeholder
    res.status(200).json({
      address,
      registered: false,
      note: "On-chain registry not configured. Set AGENT_REGISTRY_ADDRESS and ARBITRUM_RPC_URL.",
    });
    return;
  }

  try {
    const [info, stats, registered] = await Promise.all([
      ctx.registry.getAgent(address),
      ctx.registry.getAgentStats(address),
      ctx.registry.isRegistered(address),
    ]);

    const tierNum = Number(info.tier);
    const avgRisk =
      Number(stats.totalTransactions) > 0
        ? Math.round(Number(stats.cumulativeRiskScore) / Number(stats.totalTransactions))
        : 0;

    res.status(200).json({
      address,
      registered,
      tier: TIER_LABELS[tierNum] || `UNKNOWN(${tierNum})`,
      tierValue: tierNum,
      registeredAt: Number(info.registeredAt),
      isSuspended: info.isSuspended,
      metadata: info.metadata,
      stats: {
        totalTransactions: Number(stats.totalTransactions),
        totalApproved: Number(stats.totalApproved),
        totalRejected: Number(stats.totalRejected),
        approvalRate:
          Number(stats.totalTransactions) > 0
            ? ((Number(stats.totalApproved) / Number(stats.totalTransactions)) * 100).toFixed(1) + "%"
            : "N/A",
        averageRiskScore: avgRisk,
        totalVolume: stats.totalVolume.toString(),
      },
    });
  } catch (err: any) {
    console.error("[agents] On-chain query failed:", err.message);
    res.status(502).json({
      error: "On-chain query failed",
      message: err.message,
    });
  }
});

// ── POST /api/v1/agents/register ─────────────────────────────────────────
router.post("/register", async (req: Request, res: Response) => {
  const { agent, metadata } = req.body;

  if (!agent || !ethers.isAddress(agent)) {
    res.status(400).json({ error: "Invalid or missing 'agent' address." });
    return;
  }

  const ctx = getRegistry();
  if (!ctx) {
    res.status(503).json({
      error: "On-chain registry not configured. Cannot submit registration tx.",
    });
    return;
  }

  try {
    const evaluatorKey = process.env.EVALUATOR_PRIVATE_KEY;
    if (!evaluatorKey) {
      res.status(500).json({ error: "Server misconfiguration: evaluator key not set." });
      return;
    }

    const signer = new ethers.Wallet(evaluatorKey, ctx.provider);
    const registryWithSigner = ctx.registry.connect(signer) as ethers.Contract;

    const tx = await registryWithSigner.registerAgent(agent, metadata || "");
    const receipt = await tx.wait();

    res.status(201).json({
      message: "Agent registration submitted on-chain.",
      agent,
      txHash: receipt.hash,
      blockNumber: receipt.blockNumber,
    });
  } catch (err: any) {
    console.error("[agents] Registration failed:", err.message);
    res.status(500).json({
      error: "Registration transaction failed",
      message: err.message,
    });
  }
});

export default router;
