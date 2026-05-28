// FosaGate AI — API Gateway / WebSocket Live Verdicts
// WS /ws/verdicts — Real-time stream of verdicts as they happen.

import { Server as HttpServer } from "http";
import { WebSocketServer, WebSocket } from "ws";
import { StoredVerdict } from "../routes/evaluate";

let wss: WebSocketServer | null = null;

/**
 * Attach a WebSocket server to the existing HTTP server.
 *
 * Clients connect to ws://host:port/ws/verdicts and receive JSON frames
 * for every new verdict produced by the evaluator pipeline.
 *
 * Supports optional query filter: ?agent=0x... to only receive verdicts
 * for a specific agent address.
 */
export function attachWebSocket(server: HttpServer): void {
  wss = new WebSocketServer({ server, path: "/ws/verdicts" });

  wss.on("connection", (ws: WebSocket, req) => {
    // Parse optional agent filter from query string
    const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    const filterAgent = url.searchParams.get("agent")?.toLowerCase() || null;

    // Tag the socket with the filter for broadcast filtering
    (ws as any).__filterAgent = filterAgent;

    console.log(
      `[ws] Client connected${filterAgent ? ` (filter: ${filterAgent})` : ""} — ` +
        `total: ${wss!.clients.size}`
    );

    // Send a welcome frame
    ws.send(
      JSON.stringify({
        type: "connected",
        message: "FosaGate AI — Live verdict stream",
        filter: filterAgent || "all",
        timestamp: Date.now(),
      })
    );

    // Heartbeat ping every 30s to keep connections alive
    const heartbeat = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.ping();
      }
    }, 30_000);

    ws.on("close", () => {
      clearInterval(heartbeat);
      console.log(`[ws] Client disconnected — total: ${wss!.clients.size}`);
    });

    ws.on("error", (err) => {
      console.error("[ws] Socket error:", err.message);
      clearInterval(heartbeat);
    });
  });

  console.log("[ws] WebSocket server attached at /ws/verdicts");
}

/**
 * Broadcast a new verdict to all connected WebSocket clients.
 * Respects per-client agent filters.
 */
export function broadcastVerdict(verdict: StoredVerdict): void {
  if (!wss) return;

  const frame = JSON.stringify({
    type: "verdict",
    data: {
      txId: verdict.txId,
      agent: verdict.agent,
      target: verdict.target,
      riskScore: verdict.riskScore,
      verdict: verdict.verdictLabel,
      reasoning: verdict.reasoning,
      timestamp: verdict.timestamp,
    },
  });

  for (const client of wss.clients) {
    if (client.readyState !== WebSocket.OPEN) continue;

    const filterAgent = (client as any).__filterAgent as string | null;
    if (filterAgent && verdict.agent !== filterAgent) continue;

    client.send(frame);
  }
}

/**
 * Returns the current count of connected WebSocket clients.
 */
export function getConnectedClients(): number {
  return wss?.clients.size ?? 0;
}
