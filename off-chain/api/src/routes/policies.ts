// FosaGate AI — API Gateway / Policy Routes
// GET  /api/v1/policies       — List all active policies
// POST /api/v1/policies       — Create a new policy (owner only)

import { Router, Request, Response } from "express";
import { v4 as uuidv4 } from "uuid";

const router = Router();

// ── Policy data model (in-memory store for buildathon) ───────────────────

export interface PolicyParams {
  maxSlippageBps: number;
  maxValueAtRisk: string;        // uint256 as string
  allowedTargets: string[];      // address[]
  blockedMethods: string[];      // bytes4 selectors
  mevProtection: boolean;
  requireSimulation: boolean;
  maxRiskScore: number;
}

export interface Policy {
  id: string;
  name: string;
  creator: string;
  active: boolean;
  createdAt: number;
  updatedAt: number;
  params: PolicyParams;
  assignedTargets: string[];     // contracts this policy is assigned to
}

// ── In-memory store ──────────────────────────────────────────────────────
const policies = new Map<string, Policy>();
let defaultPolicyId: string | null = null;

// Seed a default global policy
(function seedDefaultPolicy() {
  const id = "default-global-policy";
  const policy: Policy = {
    id,
    name: "FosaGate Default Global Policy",
    creator: "system",
    active: true,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    params: {
      maxSlippageBps: 100,         // 1% max slippage
      maxValueAtRisk: "10000000000000000000", // 10 ETH
      allowedTargets: [],          // empty = all allowed
      blockedMethods: [],
      mevProtection: true,
      requireSimulation: true,
      maxRiskScore: 500,
    },
    assignedTargets: [],
  };
  policies.set(id, policy);
  defaultPolicyId = id;
})();

// ── GET /api/v1/policies ─────────────────────────────────────────────────
router.get("/", (_req: Request, res: Response) => {
  const all = Array.from(policies.values()).filter((p) => p.active);
  res.status(200).json({
    total: all.length,
    defaultPolicyId,
    policies: all,
  });
});

// ── GET /api/v1/policies/:id ─────────────────────────────────────────────
router.get("/:id", (req: Request, res: Response) => {
  const policy = policies.get(req.params.id);
  if (!policy) {
    res.status(404).json({ error: "Policy not found." });
    return;
  }
  res.status(200).json(policy);
});

// ── POST /api/v1/policies ────────────────────────────────────────────────
router.post("/", (req: Request, res: Response) => {
  const { name, params, assignedTargets } = req.body;

  if (!name || typeof name !== "string") {
    res.status(400).json({ error: "Missing or invalid 'name'." });
    return;
  }
  if (!params || typeof params !== "object") {
    res.status(400).json({ error: "Missing or invalid 'params' object." });
    return;
  }

  const id = uuidv4();
  const policy: Policy = {
    id,
    name,
    creator: "api", // In production, extract from auth context
    active: true,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    params: {
      maxSlippageBps: params.maxSlippageBps ?? 100,
      maxValueAtRisk: params.maxValueAtRisk ?? "0",
      allowedTargets: params.allowedTargets ?? [],
      blockedMethods: params.blockedMethods ?? [],
      mevProtection: params.mevProtection ?? true,
      requireSimulation: params.requireSimulation ?? true,
      maxRiskScore: params.maxRiskScore ?? 500,
    },
    assignedTargets: assignedTargets ?? [],
  };

  policies.set(id, policy);

  res.status(201).json({
    message: "Policy created.",
    policy,
  });
});

// ── PUT /api/v1/policies/:id ─────────────────────────────────────────────
router.put("/:id", (req: Request, res: Response) => {
  const policy = policies.get(req.params.id);
  if (!policy) {
    res.status(404).json({ error: "Policy not found." });
    return;
  }

  const { name, params, active, assignedTargets } = req.body;
  if (name) policy.name = name;
  if (params) {
    policy.params = { ...policy.params, ...params };
  }
  if (active !== undefined) policy.active = active;
  if (assignedTargets) policy.assignedTargets = assignedTargets;
  policy.updatedAt = Date.now();

  res.status(200).json({ message: "Policy updated.", policy });
});

export default router;
