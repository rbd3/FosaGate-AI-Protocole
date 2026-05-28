// FosaGate AI — API Gateway / Verdict Query Routes
// GET /api/v1/verdicts/:txId         — Single verdict by txId
// GET /api/v1/verdicts?agent=0x...   — Paginated verdicts for an agent

import { Router, Request, Response } from "express";
import { ethers } from "ethers";
import { getVerdict, getVerdictsByAgent } from "./evaluate";

const router = Router();

// ── On-chain VerdictLog ABI (for fallback / enrichment) ──────────────────
const VERDICT_LOG_ABI = [
  "function getVerdict(bytes32 txId) view returns (tuple(bytes32 txId, address agent, address target, uint256 riskScore, uint8 verdict, bytes32 attestationHash, uint64 timestamp, uint256 blockNumber))",
  "function getVerdictsByAgent(address agent, uint256 offset, uint256 limit) view returns (tuple(bytes32 txId, address agent, address target, uint256 riskScore, uint8 verdict, bytes32 attestationHash, uint64 timestamp, uint256 blockNumber)[])",
  "function getVerdictCount() view returns (uint256)",
];

function getVerdictLogContract(): ethers.Contract | null {
  const rpc = process.env.ARBITRUM_RPC_URL;
  const addr = process.env.VERDICT_LOG_ADDRESS;
  if (!rpc || !addr || addr === "0x...") return null;

  const provider = new ethers.JsonRpcProvider(rpc);
  return new ethers.Contract(addr, VERDICT_LOG_ABI, provider);
}

// ── GET /api/v1/verdicts/:txId ───────────────────────────────────────────
router.get("/:txId", async (req: Request, res: Response) => {
  const { txId } = req.params;

  // Validate txId format (bytes32 hex)
  if (!/^0x[0-9a-fA-F]{64}$/.test(txId)) {
    res.status(400).json({ error: "Invalid txId format. Expected 0x-prefixed 32-byte hex." });
    return;
  }

  // 1. Check in-memory store first (fast path)
  const cached = getVerdict(txId);
  if (cached) {
    res.status(200).json({
      source: "evaluator-cache",
      verdict: cached,
    });
    return;
  }

  // 2. Fallback to on-chain query
  const contract = getVerdictLogContract();
  if (contract) {
    try {
      const record = await contract.getVerdict(txId);
      // If txId is zero, it means no record was found
      if (record.txId === ethers.ZeroHash) {
        res.status(404).json({ error: "Verdict not found for the given txId." });
        return;
      }

      res.status(200).json({
        source: "on-chain",
        verdict: {
          txId: record.txId,
          agent: record.agent,
          target: record.target,
          riskScore: Number(record.riskScore),
          verdict: Number(record.verdict),
          attestationHash: record.attestationHash,
          timestamp: Number(record.timestamp),
          blockNumber: Number(record.blockNumber),
        },
      });
      return;
    } catch (err: any) {
      console.error("[verdicts] On-chain lookup failed:", err.message);
    }
  }

  res.status(404).json({ error: "Verdict not found." });
});

// ── GET /api/v1/verdicts?agent=0x...&offset=0&limit=20 ──────────────────
router.get("/", async (req: Request, res: Response) => {
  const agent = req.query.agent as string | undefined;
  const offset = parseInt((req.query.offset as string) || "0", 10);
  const limit = Math.min(parseInt((req.query.limit as string) || "20", 10), 100);

  if (!agent || !ethers.isAddress(agent)) {
    res.status(400).json({ error: "Query parameter 'agent' (valid address) is required." });
    return;
  }

  // 1. In-memory lookup
  const { verdicts, total } = getVerdictsByAgent(agent, offset, limit);

  if (verdicts.length > 0) {
    res.status(200).json({
      source: "evaluator-cache",
      agent,
      total,
      offset,
      limit,
      verdicts,
    });
    return;
  }

  // 2. On-chain fallback
  const contract = getVerdictLogContract();
  if (contract) {
    try {
      const records = await contract.getVerdictsByAgent(agent, offset, limit);
      res.status(200).json({
        source: "on-chain",
        agent,
        offset,
        limit,
        verdicts: records.map((r: any) => ({
          txId: r.txId,
          agent: r.agent,
          target: r.target,
          riskScore: Number(r.riskScore),
          verdict: Number(r.verdict),
          attestationHash: r.attestationHash,
          timestamp: Number(r.timestamp),
          blockNumber: Number(r.blockNumber),
        })),
      });
      return;
    } catch (err: any) {
      console.error("[verdicts] On-chain agent query failed:", err.message);
    }
  }

  res.status(200).json({
    source: "evaluator-cache",
    agent,
    total: 0,
    offset,
    limit,
    verdicts: [],
  });
});

export default router;
