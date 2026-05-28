// FosaGate AI — API Gateway / POST /api/v1/evaluate
// Main endpoint that agents call to submit a transaction intent for evaluation.
// Calls the off-chain evaluator pipeline, returns signed attestation + risk breakdown.

import { Router, Request, Response } from "express";
import { ethers } from "ethers";
import { broadcastVerdict } from "../websocket/liveVerdicts";

const router = Router();

// ── In-memory evaluator stats ────────────────────────────────────────────
let totalEvaluations = 0;
let totalApproved = 0;
let totalRejected = 0;
let cumulativeRisk = 0;

export function getEvaluatorStats() {
  return {
    totalEvaluations,
    totalApproved,
    totalRejected,
    approvalRate:
      totalEvaluations > 0
        ? ((totalApproved / totalEvaluations) * 100).toFixed(1) + "%"
        : "N/A",
    averageRiskScore:
      totalEvaluations > 0
        ? Math.round(cumulativeRisk / totalEvaluations)
        : 0,
  };
}

// ── In-memory verdict store (replaced by DB/indexer in production) ───────
export interface StoredVerdict {
  txId: string;
  agent: string;
  target: string;
  riskScore: number;
  verdict: number;
  verdictLabel: string;
  attestation: string;
  reasoning: string;
  timestamp: number;
  analysis: any;
}

const verdictStore = new Map<string, StoredVerdict>();
const verdictsByAgent = new Map<string, string[]>(); // agent → txId[]

export function getVerdict(txId: string): StoredVerdict | undefined {
  return verdictStore.get(txId);
}

export function getVerdictsByAgent(
  agent: string,
  offset: number,
  limit: number
): { verdicts: StoredVerdict[]; total: number } {
  const agentLower = agent.toLowerCase();
  const ids = verdictsByAgent.get(agentLower) || [];
  const total = ids.length;
  const page = ids.slice(offset, offset + limit);
  return {
    verdicts: page.map((id) => verdictStore.get(id)!).filter(Boolean),
    total,
  };
}

// ── Verdict label helper ─────────────────────────────────────────────────
const VERDICT_LABELS: Record<number, string> = {
  0: "APPROVED",
  1: "REJECTED_HIGH_RISK",
  2: "REJECTED_POLICY_VIOLATION",
  3: "REJECTED_INVALID_ATTESTATION",
};

// ── POST /api/v1/evaluate ────────────────────────────────────────────────
router.post("/", async (req: Request, res: Response) => {
  try {
    const { agent, target, payload, value, nonce, chainId } = req.body;

    // ── Input validation ──────────────────────────────────────────────
    if (!agent || !ethers.isAddress(agent)) {
      res.status(400).json({ error: "Invalid or missing 'agent' address." });
      return;
    }
    if (!target || !ethers.isAddress(target)) {
      res.status(400).json({ error: "Invalid or missing 'target' address." });
      return;
    }
    if (!payload || typeof payload !== "string" || !payload.startsWith("0x")) {
      res.status(400).json({ error: "Invalid or missing 'payload' (hex bytes)." });
      return;
    }
    if (nonce === undefined || nonce === null) {
      res.status(400).json({ error: "Missing 'nonce'." });
      return;
    }

    const evaluatorKey = process.env.EVALUATOR_PRIVATE_KEY;
    if (!evaluatorKey) {
      res.status(500).json({ error: "Server misconfiguration: evaluator key not set." });
      return;
    }

    // ── Dynamically import the evaluator engine ───────────────────────
    // The evaluator package is linked locally as @fosagate/evaluator.
    const { evaluateTransaction } = await import("@fosagate/evaluator");

    const intent = {
      agent,
      target,
      payload,
      value: value || "0",
      nonce: String(nonce),
      chainId: chainId || parseInt(process.env.CHAIN_ID || "421614", 10),
    };

    const result = await evaluateTransaction(
      intent,
      evaluatorKey,
      process.env.ARBITRUM_RPC_URL
    );

    // ── Update stats ──────────────────────────────────────────────────
    totalEvaluations++;
    const riskScore = result.analysis.compositeScore as number;
    cumulativeRisk += riskScore;
    const verdictNum = result.analysis.verdict as number;
    if (verdictNum === 0) totalApproved++;
    else totalRejected++;

    // ── Store verdict ─────────────────────────────────────────────────
    const stored: StoredVerdict = {
      txId: result.signedAttestation.decoded.txId,
      agent: agent.toLowerCase(),
      target: target.toLowerCase(),
      riskScore,
      verdict: verdictNum,
      verdictLabel: VERDICT_LABELS[verdictNum] || "UNKNOWN",
      attestation: result.signedAttestation.attestation,
      reasoning: result.analysis.reasoning,
      timestamp: Date.now(),
      analysis: result.analysis,
    };

    verdictStore.set(stored.txId, stored);
    const agentLower = agent.toLowerCase();
    if (!verdictsByAgent.has(agentLower)) verdictsByAgent.set(agentLower, []);
    verdictsByAgent.get(agentLower)!.push(stored.txId);

    // ── Broadcast to WebSocket subscribers ────────────────────────────
    broadcastVerdict(stored);

    // ── Response ──────────────────────────────────────────────────────
    res.status(200).json({
      txId: result.signedAttestation.decoded.txId,
      verdict: VERDICT_LABELS[verdictNum] || "UNKNOWN",
      riskScore,
      attestation: result.signedAttestation.attestation,
      signature: result.signedAttestation.signature,
      decoded: result.signedAttestation.decoded,
      analysis: {
        mevScore: result.analysis.mevScore,
        slippageScore: result.analysis.slippageScore,
        contractScore: result.analysis.contractScore,
        valueScore: result.analysis.valueScore,
        compositeScore: result.analysis.compositeScore,
        matchedPatterns: result.analysis.matchedPatterns,
        reasoning: result.analysis.reasoning,
      },
    });
  } catch (err: any) {
    console.error("[evaluate] Pipeline error:", err);
    res.status(500).json({
      error: "Evaluation failed",
      message: err.message || "Internal server error",
    });
  }
});

export default router;
