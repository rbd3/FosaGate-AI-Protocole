// ═══════════════════════════════════════════════════════════════════════════
//  FosaGate AI — API Gateway
//  REST + WebSocket server for agents, frontend, and third-party integrations.
//
//  Author  : rbd3
//  Stack   : Express + ws (WebSocket) + ethers
//  Phase   : 4 — API Gateway (per ARCHITECTURE.md)
// ═══════════════════════════════════════════════════════════════════════════

import "dotenv/config";
import express from "express";
import cors from "cors";
import { createServer } from "http";

// Middleware
import { authMiddleware, loadApiKeys } from "./middleware/auth";
import { rateLimitMiddleware, loadRateLimitConfig } from "./middleware/rateLimit";

// Routes
import evaluateRoutes from "./routes/evaluate";
import { getEvaluatorStats } from "./routes/evaluate";
import agentRoutes from "./routes/agents";
import verdictRoutes from "./routes/verdicts";
import policyRoutes from "./routes/policies";

// WebSocket
import { attachWebSocket, getConnectedClients } from "./websocket/liveVerdicts";

// ── Bootstrap ────────────────────────────────────────────────────────────
const app = express();
const PORT = parseInt(process.env.PORT || "3000", 10);

// ── Global middleware ────────────────────────────────────────────────────
app.use(cors());
app.use(express.json({ limit: "1mb" }));

// ── Public routes (no auth required) ─────────────────────────────────────

/** Health check */
app.get("/health", (_req, res) => {
  res.status(200).json({
    status: "ok",
    service: "FosaGate AI API Gateway",
    version: "1.0.0",
    uptime: Math.floor(process.uptime()),
    wsClients: getConnectedClients(),
  });
});

/** Analytics overview — dashboard stats */
app.get("/api/v1/analytics/overview", (_req, res) => {
  const stats = getEvaluatorStats();
  res.status(200).json({
    ...stats,
    wsClients: getConnectedClients(),
    serverUptime: Math.floor(process.uptime()),
  });
});

// ── Load config ──────────────────────────────────────────────────────────
loadApiKeys();
loadRateLimitConfig();

// ── Authenticated + rate-limited routes ──────────────────────────────────
app.use("/api/v1/evaluate", authMiddleware, rateLimitMiddleware, evaluateRoutes);
app.use("/api/v1/agents", authMiddleware, rateLimitMiddleware, agentRoutes);
app.use("/api/v1/verdicts", authMiddleware, rateLimitMiddleware, verdictRoutes);
app.use("/api/v1/policies", authMiddleware, rateLimitMiddleware, policyRoutes);

// ── 404 handler ──────────────────────────────────────────────────────────
app.use((_req, res) => {
  res.status(404).json({
    error: "Not Found",
    message: "The requested endpoint does not exist.",
    availableEndpoints: [
      "GET  /health",
      "POST /api/v1/evaluate",
      "GET  /api/v1/verdicts/:txId",
      "GET  /api/v1/verdicts?agent=0x...",
      "GET  /api/v1/agents/:address",
      "POST /api/v1/agents/register",
      "GET  /api/v1/policies",
      "POST /api/v1/policies",
      "GET  /api/v1/analytics/overview",
      "WS   /ws/verdicts",
    ],
  });
});

// ── Global error handler ─────────────────────────────────────────────────
app.use(
  (
    err: Error,
    _req: express.Request,
    res: express.Response,
    _next: express.NextFunction
  ) => {
    console.error("[server] Unhandled error:", err);
    res.status(500).json({
      error: "Internal Server Error",
      message: err.message,
    });
  }
);

// ── Start ────────────────────────────────────────────────────────────────
export const server = createServer(app);
attachWebSocket(server);

if (process.env.NODE_ENV !== "test") {
  server.listen(PORT, () => {
    console.log(`
  ╔══════════════════════════════════════════════════╗
  ║     FosaGate AI — API Gateway v1.0.0            ║
  ║     http://localhost:${PORT}                      ║
  ║     WebSocket: ws://localhost:${PORT}/ws/verdicts  ║
  ╚══════════════════════════════════════════════════╝

  Endpoints:
    POST /api/v1/evaluate          Submit transaction intent
    GET  /api/v1/verdicts/:txId    Query verdict by ID
    GET  /api/v1/verdicts?agent=   Query verdicts by agent
    GET  /api/v1/agents/:address   Agent profile + stats
    POST /api/v1/agents/register   Register new agent
    GET  /api/v1/policies          List policies
    POST /api/v1/policies          Create policy
    GET  /api/v1/analytics/overview Dashboard stats
    WS   /ws/verdicts              Live verdict stream
    GET  /health                   Health check
    `);
  });
}

export default app;
