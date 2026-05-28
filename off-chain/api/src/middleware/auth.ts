// FosaGate AI — API Gateway / Authentication Middleware
// Supports two modes:
//   1. API Key auth for agents (header: x-api-key)
//   2. Bearer token for dashboard users (header: Authorization: Bearer <token>)

import { Request, Response, NextFunction } from "express";

// ── In-memory API key store (loaded from env) ────────────────────────────
let validApiKeys: Set<string> = new Set();

export function loadApiKeys(): void {
  const raw = process.env.API_KEYS || "";
  validApiKeys = new Set(
    raw
      .split(",")
      .map((k) => k.trim())
      .filter(Boolean)
  );
  console.log(`[auth] Loaded ${validApiKeys.size} API key(s)`);
}

// ── Types ────────────────────────────────────────────────────────────────

export interface AuthenticatedRequest extends Request {
  /** The API key or token used to authenticate this request */
  apiKey?: string;
  /** The agent address associated with this key (for future mapping) */
  agentAddress?: string;
}

// ── Middleware ────────────────────────────────────────────────────────────

/**
 * Authenticate incoming requests.
 *
 * Checks `x-api-key` header first (agent mode).
 * Falls back to `Authorization: Bearer <token>` (dashboard mode).
 *
 * Public endpoints (e.g. health check) should be mounted BEFORE this middleware.
 */
export function authMiddleware(
  req: AuthenticatedRequest,
  res: Response,
  next: NextFunction
): void {
  // 1. Try API key header
  const apiKey = req.headers["x-api-key"] as string | undefined;
  if (apiKey && validApiKeys.has(apiKey)) {
    req.apiKey = apiKey;
    return next();
  }

  // 2. Try Bearer token (simplified — in production use JWT verification)
  const authHeader = req.headers.authorization;
  if (authHeader?.startsWith("Bearer ")) {
    const token = authHeader.slice(7);
    // For the buildathon, accept any non-empty token as valid dashboard auth.
    // In production, verify a JWT signed by the dashboard auth service.
    if (token.length > 0) {
      req.apiKey = `bearer:${token.slice(0, 8)}`;
      return next();
    }
  }

  // 3. Reject
  res.status(401).json({
    error: "Unauthorized",
    message: "Provide a valid x-api-key header or Authorization: Bearer <token>.",
  });
}
