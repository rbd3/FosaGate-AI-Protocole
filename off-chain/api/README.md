# FosaGate AI — API Gateway

> REST + WebSocket API for agents, frontend, and third-party integrations.

This is **Phase 4** of the FosaGate AI protocol build order. The API Gateway sits between AI agents and the on-chain protocol, providing a clean HTTP interface to submit transaction intents for risk evaluation.

---

## Architecture

```
Agent / Frontend / Third-Party
        │
        ▼
  ┌─────────────────────────────┐
  │      API Gateway (Express)  │
  │                             │
  │  POST /api/v1/evaluate ─────┼──► Evaluator Engine (Phase 3)
  │  GET  /api/v1/verdicts      │         │
  │  GET  /api/v1/agents        │         ▼
  │  GET  /api/v1/policies      │    Signed Attestation
  │  WS   /ws/verdicts          │         │
  │                             │         ▼
  │  Middleware:                 │    On-Chain Contracts
  │    ├─ auth.ts (API keys)    │    (FosaGateRouter)
  │    └─ rateLimit.ts          │
  └─────────────────────────────┘
```

---

## Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/health` | GET | No | Health check + uptime + WS client count |
| `/api/v1/evaluate` | POST | Yes | Submit transaction intent → returns signed attestation + risk breakdown |
| `/api/v1/verdicts/:txId` | GET | Yes | Get verdict details by transaction ID |
| `/api/v1/verdicts?agent=0x...` | GET | Yes | Paginated verdicts for an agent |
| `/api/v1/agents/:address` | GET | Yes | Agent profile + on-chain stats |
| `/api/v1/agents/register` | POST | Yes | Register new agent on-chain |
| `/api/v1/policies` | GET | Yes | List active evaluation policies |
| `/api/v1/policies` | POST | Yes | Create a new policy |
| `/api/v1/analytics/overview` | GET | No | Dashboard stats (evaluations, approval rate, avg risk) |
| `/ws/verdicts` | WS | No | Real-time verdict stream (supports `?agent=0x...` filter) |

---

## Quick Start

### 1. Configure
```bash
cp .env.example .env
# Edit .env — set EVALUATOR_PRIVATE_KEY and API_KEYS at minimum
```

### 2. Install
```bash
npm install
```

### 3. Run
```bash
npm run dev
```

The server starts on `http://localhost:3000`.

---

## Example: Evaluate a Transaction

```bash
curl -X POST http://localhost:3000/api/v1/evaluate \
  -H "Content-Type: application/json" \
  -H "x-api-key: fosagate-test-key-001" \
  -d '{
    "agent": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "target": "0xE592427A0AEce92De3EdF7a9Cd9373d5D72483d4",
    "payload": "0x414bf389...",
    "value": "0",
    "nonce": "0",
    "chainId": 421614
  }'
```

**Response:**
```json
{
  "txId": "0x...",
  "verdict": "APPROVED",
  "riskScore": 45,
  "attestation": "0x...(225 bytes)...",
  "analysis": {
    "mevScore": 200,
    "slippageScore": 100,
    "contractScore": 10,
    "valueScore": 0,
    "compositeScore": 45,
    "reasoning": "..."
  }
}
```

---

## WebSocket: Live Verdict Feed

```javascript
const ws = new WebSocket("ws://localhost:3000/ws/verdicts");

// Filter by agent (optional):
// new WebSocket("ws://localhost:3000/ws/verdicts?agent=0x70997970...")

ws.onmessage = (event) => {
  const frame = JSON.parse(event.data);
  if (frame.type === "verdict") {
    console.log("New verdict:", frame.data);
  }
};
```

---

## Authentication

- **Agents**: Send `x-api-key: <key>` header. Keys configured in `.env` (`API_KEYS`).
- **Dashboard**: Send `Authorization: Bearer <token>` header.
- **Public endpoints**: `/health` and `/api/v1/analytics/overview` require no auth.

## Rate Limiting

Configurable per-key sliding window. Defaults: 30 requests per 60 seconds.
Returns `429 Too Many Requests` with `Retry-After` and `X-RateLimit-*` headers.
