# FosaGate AI — Architecture Document

> **Pre-Flight Evaluation Layer for Agent Transactions on Arbitrum**
> Intercept → Evaluate → Approve/Reject → Execute

---

## 1. High-Level Architecture

```
┌─────────────┐    ┌──────────────────┐    ┌────────────────────────────┐
│  AI Agent    │───▶│  Off-Chain        │───▶│  On-Chain (Arbitrum)       │
│  (any agent) │    │  Evaluator API    │    │                            │
└─────────────┘    │                    │    │  FosaGateRouter (Solidity) │
                   │  1. Receive intent │    │         │                  │
                   │  2. AI risk check  │    │         ▼                  │
                   │  3. MEV analysis   │    │  RiskEngine (Stylus/Rust)  │
                   │  4. Sign verdict   │    │         │                  │
                   │  5. Return attesta │    │         ▼                  │
                   │     tion to agent  │    │  Target Contract           │
                   └──────────────────┘    └────────────────────────────┘
```

### Transaction Flow (Step by Step)

1. **Agent** sends transaction intent to the **Off-Chain Evaluator API**
2. **Evaluator** runs AI risk analysis (MEV, slippage, contract reputation, balance impact)
3. **Evaluator** produces a verdict and signs it cryptographically (attestation)
4. **Agent** receives the signed attestation
5. **Agent** submits original transaction + attestation to **FosaGateRouter** on-chain
6. **FosaGateRouter** calls **RiskEngine** (Stylus) to verify attestation and validate risk
7. If approved → FosaGateRouter forwards tx to target contract
8. Verdict is logged on-chain for auditability

> **Why this flow?** Single on-chain transaction for the agent. Fast, cheap, auditable.

---

## 2. Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Repo structure | **Monorepo** with `on-chain/` and `off-chain/` folders | Shared types, easier buildathon demos, can split later |
| Smart contracts | **Solidity** (core logic) + **Stylus/Rust** (heavy compute) | Solidity for Arbitrum compatibility; Stylus for performance-critical risk scoring |
| Off-chain | **Node.js + TypeScript** | Fast to build, huge ecosystem, easy to integrate AI APIs |
| Frontend | **React + Vite** | Fast dev, great DX, widely understood |
| Package manager | **pnpm workspaces** | Fast installs, disk efficient, great monorepo support |

---

## 3. Project Structure

```
FosaGate-AI/
│
├── on-chain/                         # All blockchain code
│   ├── contracts/                    # Solidity smart contracts (Foundry)
│   │   ├── src/
│   │   │   ├── FosaGateRouter.sol    # Main gateway — entry point
│   │   │   ├── AgentRegistry.sol     # Agent registration & trust tiers
│   │   │   ├── PolicyRegistry.sol    # Evaluation rules/policies storage
│   │   │   ├── VerdictLog.sol        # On-chain verdict audit trail
│   │   │   ├── FeeManager.sol        # Fee collection & distribution
│   │   │   └── interfaces/
│   │   │       ├── IFosaGateRouter.sol
│   │   │       ├── IAgentRegistry.sol
│   │   │       ├── IPolicyRegistry.sol
│   │   │       ├── IVerdictLog.sol
│   │   │       ├── IFeeManager.sol
│   │   │       └── IRiskEngine.sol
│   │   ├── test/                     # Foundry tests
│   │   ├── script/                   # Deployment scripts
│   │   └── foundry.toml
│   │
│   └── stylus/                       # Rust Stylus contract
│       ├── src/
│       │   └── lib.rs                # RiskEngine — attestation verification + scoring
│       ├── Cargo.toml
│       └── tests/
│
├── off-chain/                        # All server-side code
│   ├── evaluator/                    # Core AI evaluation engine
│   │   ├── src/
│   │   │   ├── index.ts              # Entry point
│   │   │   ├── analyzer/
│   │   │   │   ├── mevDetector.ts    # MEV exposure analysis
│   │   │   │   ├── slippageChecker.ts # Slippage risk calculation
│   │   │   │   ├── contractScorer.ts # Target contract reputation
│   │   │   │   └── balanceImpact.ts  # Balance change simulation
│   │   │   ├── attestation/
│   │   │   │   ├── signer.ts         # Sign verdicts cryptographically
│   │   │   │   └── schema.ts         # Attestation data structures
│   │   │   └── ai/
│   │   │       ├── riskModel.ts      # AI risk scoring model
│   │   │       └── patternMatcher.ts # Known malicious pattern detection
│   │   └── package.json
│   │
│   ├── api/                          # API Gateway (REST + WebSocket)
│   │   ├── src/
│   │   │   ├── index.ts
│   │   │   ├── routes/
│   │   │   │   ├── evaluate.ts       # POST /evaluate
│   │   │   │   ├── agents.ts         # Agent management endpoints
│   │   │   │   ├── policies.ts       # Policy CRUD endpoints
│   │   │   │   └── verdicts.ts       # Verdict query endpoints
│   │   │   ├── middleware/
│   │   │   │   ├── auth.ts           # API key authentication
│   │   │   │   └── rateLimit.ts      # Rate limiting
│   │   │   └── websocket/
│   │   │       └── liveVerdicts.ts   # Real-time verdict streaming
│   │   └── package.json
│   │
│   └── indexer/                      # On-chain event indexer
│       ├── src/
│       │   ├── index.ts
│       │   ├── listeners/            # Event listeners per contract
│       │   └── db/                   # Database models (PostgreSQL)
│       └── package.json
│
├── frontend/                         # React dashboard (Vite)
│   ├── src/
│   │   ├── pages/
│   │   │   ├── Dashboard.tsx         # Overview & live feed
│   │   │   ├── Agents.tsx            # Agent management
│   │   │   ├── Policies.tsx          # Policy configuration
│   │   │   ├── History.tsx           # Transaction/verdict history
│   │   │   └── Analytics.tsx         # Charts & stats
│   │   ├── components/
│   │   ├── hooks/
│   │   ├── services/                 # API client
│   │   └── App.tsx
│   └── package.json
│
├── pnpm-workspace.yaml
├── package.json                      # Root monorepo config
└── README.md
```

---

## 4. On-Chain Smart Contracts (Solidity)

### 4.1 FosaGateRouter.sol

> **Purpose:** The main gateway. Every agent transaction enters here. Routes to RiskEngine for verification, then forwards approved transactions to their target.

| Function | Params | Description |
|----------|--------|-------------|
| `executeWithClearance` | `address target, bytes calldata payload, bytes calldata attestation` | Agent submits tx + signed attestation. Calls RiskEngine to verify. If valid and risk ≤ threshold → executes `target.call(payload)`. Emits `TransactionExecuted` event. Collects fee via FeeManager. |
| `batchExecuteWithClearance` | `ExecutionRequest[] calldata requests` | Same as above but for multiple transactions in one call. Each request contains target + payload + attestation. |
| `getTransactionStatus` | `bytes32 txId` | Returns status of a previously submitted transaction (Pending / Approved / Rejected / Executed). |
| `setRiskThreshold` | `uint256 threshold` | Owner sets the maximum acceptable risk score (0-1000). Transactions above this are rejected. |
| `setRiskEngine` | `address engine` | Owner sets the RiskEngine (Stylus) contract address. |
| `pause` / `unpause` | — | Emergency circuit breaker. Pauses all transaction processing. |
| `setEmergencyAdmin` | `address admin` | Owner sets an emergency admin who can also pause. |

**Events:**
- `TransactionEvaluated(bytes32 indexed txId, address indexed agent, address target, uint256 riskScore, bool approved)`
- `TransactionExecuted(bytes32 indexed txId, address target, bool success)`
- `ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold)`

---

### 4.2 AgentRegistry.sol

> **Purpose:** Tracks registered AI agents, their trust tiers, and historical behavior. Only registered agents can use FosaGate.

| Function | Params | Description |
|----------|--------|-------------|
| `registerAgent` | `address agent, string calldata metadata` | Register a new agent. Sets initial tier to UNVERIFIED. Emits `AgentRegistered`. |
| `updateAgentTier` | `address agent, Tier tier` | Owner/governance updates agent trust tier (UNVERIFIED → BASIC → TRUSTED → PREMIUM). Higher tiers get lower fees and higher risk thresholds. |
| `suspendAgent` | `address agent, string calldata reason` | Suspend an agent (blocks all transactions). Used when malicious behavior detected. |
| `reinstateAgent` | `address agent` | Reinstate a suspended agent. |
| `getAgent` | `address agent` | Returns agent details: tier, registration time, total txs, total rejected, suspension status. |
| `isRegistered` | `address agent` | Returns true if agent is registered and not suspended. |
| `getAgentStats` | `address agent` | Returns agent performance stats: approval rate, avg risk score, total volume. |
| `incrementStats` | `address agent, uint256 riskScore, bool approved` | Called by FosaGateRouter after each evaluation to update agent stats. Only callable by Router. |

**Enums:**
- `Tier { UNVERIFIED, BASIC, TRUSTED, PREMIUM }`

**Events:**
- `AgentRegistered(address indexed agent, string metadata)`
- `AgentTierUpdated(address indexed agent, Tier oldTier, Tier newTier)`
- `AgentSuspended(address indexed agent, string reason)`

---

### 4.3 PolicyRegistry.sol

> **Purpose:** Stores evaluation policies (rules) on-chain. Policies define what checks to run and what thresholds to apply. Protocols can register custom policies for their contracts.

| Function | Params | Description |
|----------|--------|-------------|
| `createPolicy` | `string calldata name, PolicyParams calldata params` | Create a new evaluation policy. Params include: maxSlippage, maxValueAtRisk, allowedTargets[], blockedMethods[], mevProtection (bool), requireSimulation (bool). |
| `updatePolicy` | `uint256 policyId, PolicyParams calldata params` | Update an existing policy. Only policy owner can update. |
| `activatePolicy` / `deactivatePolicy` | `uint256 policyId` | Toggle policy active state. |
| `assignPolicyToTarget` | `uint256 policyId, address target` | Assign a policy to a specific target contract. When agents interact with this target, this policy's rules apply. |
| `getPolicy` | `uint256 policyId` | Returns full policy details. |
| `getPolicyForTarget` | `address target` | Returns the active policy for a target contract. Falls back to default global policy if none assigned. |
| `setDefaultPolicy` | `uint256 policyId` | Owner sets the global default policy used when no target-specific policy exists. |

**Structs:**
```
PolicyParams {
    uint256 maxSlippageBps;       // Max slippage in basis points (e.g., 50 = 0.5%)
    uint256 maxValueAtRisk;       // Max USD value allowed per tx
    address[] allowedTargets;     // Whitelist of allowed target contracts (empty = all)
    bytes4[] blockedMethods;      // Blacklist of function selectors
    bool mevProtection;           // Require MEV exposure check
    bool requireSimulation;       // Require balance impact simulation
    uint256 maxRiskScore;         // Override risk threshold for this policy
}
```

**Events:**
- `PolicyCreated(uint256 indexed policyId, string name, address creator)`
- `PolicyAssigned(uint256 indexed policyId, address indexed target)`

---

### 4.4 VerdictLog.sol

> **Purpose:** Immutable on-chain log of all evaluation verdicts. Provides full auditability and enables dispute resolution.

| Function | Params | Description |
|----------|--------|-------------|
| `logVerdict` | `bytes32 txId, address agent, address target, uint256 riskScore, Verdict verdict, bytes32 attestationHash` | Store a verdict on-chain. Only callable by FosaGateRouter. |
| `getVerdict` | `bytes32 txId` | Returns full verdict details for a transaction ID. |
| `getVerdictsByAgent` | `address agent, uint256 offset, uint256 limit` | Paginated query of verdicts for a specific agent. |
| `getVerdictCount` | — | Total number of verdicts stored. |

**Enums:**
- `Verdict { APPROVED, REJECTED_HIGH_RISK, REJECTED_POLICY_VIOLATION, REJECTED_INVALID_ATTESTATION }`

**Events:**
- `VerdictLogged(bytes32 indexed txId, address indexed agent, Verdict verdict, uint256 riskScore)`

---

### 4.5 FeeManager.sol

> **Purpose:** Handles evaluation fee collection and distribution. Fees vary by agent tier and transaction complexity.

| Function | Params | Description |
|----------|--------|-------------|
| `collectFee` | `address agent, uint256 complexity` | Called by FosaGateRouter during evaluation. Calculates fee based on agent tier + tx complexity. Transfers from agent's pre-deposited balance. |
| `depositBalance` | — | Payable. Agent deposits ETH to cover future evaluation fees. |
| `withdrawBalance` | `uint256 amount` | Agent withdraws unused deposited balance. |
| `getBalance` | `address agent` | Returns agent's deposited balance. |
| `setFeeSchedule` | `Tier tier, uint256 baseFee, uint256 perComplexityFee` | Owner sets fee structure per agent tier. Higher tiers get discounts. |
| `getFeeEstimate` | `address agent, uint256 complexity` | View function: estimate fee before submitting. |
| `withdrawRevenue` | `address to, uint256 amount` | Owner withdraws accumulated protocol revenue. |
| `getRevenueStats` | — | Returns total fees collected, total evaluations, avg fee. |

**Events:**
- `FeeCollected(address indexed agent, uint256 amount, bytes32 txId)`
- `BalanceDeposited(address indexed agent, uint256 amount)`
- `RevenueWithdrawn(address indexed to, uint256 amount)`

---

## 5. On-Chain Stylus Contract (Rust)

### 5.1 RiskEngine (lib.rs)

> **Purpose:** Performance-critical computation written in Rust, compiled to WASM via Stylus. Handles attestation verification and risk score validation. Runs ~10x cheaper than equivalent Solidity for these operations.

| Function | Params | Description |
|----------|--------|-------------|
| `verify_attestation` | `attestation: Bytes, evaluator_pubkey: Address` | Verifies the cryptographic signature of the off-chain evaluator's attestation. Returns decoded verdict data if valid. ECDSA signature recovery. |
| `validate_risk_params` | `risk_score: u256, policy_max: u256, agent_tier: u8` | Validates that the risk score is within acceptable bounds given the policy and agent tier. Applies tier-based multipliers (TRUSTED agents get +10% tolerance). |
| `compute_composite_score` | `mev_score: u256, slippage_score: u256, contract_score: u256, value_score: u256, weights: [u256; 4]` | Computes a weighted composite risk score from individual analysis dimensions. Returns final score (0-1000). |
| `check_pattern_hash` | `calldata_hash: B256, blacklist_root: B256, proof: Vec<B256>` | Verifies a Merkle proof that a transaction's calldata pattern is NOT in the known-malicious pattern blacklist. Efficient on-chain blacklist checking. |
| `batch_verify` | `attestations: Vec<Bytes>, evaluator_pubkey: Address` | Batch verification of multiple attestations in one call. For `batchExecuteWithClearance`. |

**Why Stylus for this?**
- ECDSA recovery in Rust is ~10x cheaper than Solidity's `ecrecover` for batch operations
- Composite score math with fixed-point weights is more precise in Rust
- Merkle proof verification with large trees benefits from WASM performance

---

## 6. Off-Chain Services

### 6.1 Evaluator Service (`off-chain/evaluator/`)

> **Purpose:** The AI brain. Receives transaction intents, runs multi-dimensional risk analysis, and produces signed attestations.

| Module | File | Functions | Description |
|--------|------|-----------|-------------|
| **MEV Detector** | `mevDetector.ts` | `analyzeMevExposure(tx)` → `{ score, details }` | Simulates transaction against current mempool state. Detects sandwich attack vulnerability, frontrunning risk, and backrunning opportunities. Score: 0-1000. |
| **Slippage Checker** | `slippageChecker.ts` | `calculateSlippageRisk(tx)` → `{ score, expectedSlippage, worstCase }` | Queries DEX liquidity pools to estimate price impact. Compares against policy maxSlippage. Score: 0-1000. |
| **Contract Scorer** | `contractScorer.ts` | `scoreTargetContract(address)` → `{ score, flags[] }` | Checks target contract: verified on Arbiscan? Audit history? Age? TVL? Known exploits? Proxy pattern? Score: 0-1000. |
| **Balance Impact** | `balanceImpact.ts` | `simulateBalanceImpact(tx)` → `{ changes[], netValueChange }` | Uses `eth_call` simulation to predict exact token balance changes. Detects unexpected drains or approvals to unknown addresses. |
| **AI Risk Model** | `riskModel.ts` | `computeAIRiskScore(analysisResults)` → `{ finalScore, confidence, reasoning }` | Takes all analyzer outputs, runs through AI model (OpenAI / local model) for contextual risk assessment. Produces human-readable reasoning. |
| **Pattern Matcher** | `patternMatcher.ts` | `matchKnownPatterns(tx)` → `{ matched[], severity }` | Compares transaction calldata against database of known exploit patterns (reentrancy signatures, flash loan patterns, approval phishing). |
| **Attestation Signer** | `signer.ts` | `signVerdict(verdict)` → `{ attestation }` | Takes the final verdict (approve/reject + score + conditions) and signs it with the evaluator's private key. Produces the attestation bytes that go on-chain. |

**Evaluation Pipeline:**
```
Transaction Intent
    → MEV Detector ─────────────┐
    → Slippage Checker ─────────┤
    → Contract Scorer ──────────┤── All run in parallel
    → Balance Impact Simulator ─┤
    → Pattern Matcher ──────────┘
                                │
                                ▼
                        AI Risk Model (aggregate + contextualize)
                                │
                                ▼
                        Attestation Signer (sign verdict)
                                │
                                ▼
                        Return to Agent
```

---

### 6.2 API Gateway (`off-chain/api/`)

> **Purpose:** REST + WebSocket API for agents, frontend, and third-party integrations.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `POST /api/v1/evaluate` | POST | Submit a transaction intent for evaluation. Returns signed attestation + risk breakdown. Main endpoint agents call. |
| `GET /api/v1/verdicts/:txId` | GET | Get verdict details for a transaction. |
| `GET /api/v1/verdicts?agent=0x...` | GET | List verdicts for an agent (paginated). |
| `GET /api/v1/agents/:address` | GET | Get agent profile and stats. |
| `POST /api/v1/agents/register` | POST | Register a new agent (creates on-chain registration too). |
| `GET /api/v1/policies` | GET | List all active policies. |
| `POST /api/v1/policies` | POST | Create a new policy (owner only). |
| `GET /api/v1/analytics/overview` | GET | Dashboard stats: total evaluations, approval rate, avg risk, revenue. |
| `WS /ws/verdicts` | WebSocket | Real-time stream of verdicts as they happen. For live dashboard. |

**Middleware:**
- `auth.ts` — API key authentication for agents, JWT for dashboard users
- `rateLimit.ts` — Rate limiting per API key (prevent spam evaluations)

---

### 6.3 Indexer (`off-chain/indexer/`)

> **Purpose:** Listens to on-chain events, indexes them into PostgreSQL for fast querying by API and frontend.

| Listener | Events Indexed | Description |
|----------|---------------|-------------|
| `routerListener` | `TransactionEvaluated`, `TransactionExecuted` | Indexes all evaluations and executions with decoded params. |
| `agentListener` | `AgentRegistered`, `AgentTierUpdated`, `AgentSuspended` | Tracks agent lifecycle changes. |
| `feeListener` | `FeeCollected`, `BalanceDeposited` | Tracks fee revenue and agent balances. |
| `verdictListener` | `VerdictLogged` | Indexes verdicts for fast historical queries. |

**Database Tables:**
- `evaluations` — All transaction evaluations
- `agents` — Agent profiles and stats
- `policies` — Policy snapshots
- `fees` — Fee transactions
- `verdicts` — Verdict history

---

## 7. Frontend (React + Vite)

### Pages

| Page | Route | Description |
|------|-------|-------------|
| **Dashboard** | `/` | Live feed of evaluations, approval/rejection counts, risk score distribution chart, revenue ticker. |
| **Agents** | `/agents` | List of registered agents with trust tier, approval rate, total volume. Click to see agent detail. |
| **Policies** | `/policies` | Create/edit evaluation policies. Visual editor for policy params. Assign policies to target contracts. |
| **History** | `/history` | Searchable, filterable table of all past evaluations. Filter by agent, verdict, risk score range, date. |
| **Analytics** | `/analytics` | Charts: evaluations over time, risk score trends, top agents, fee revenue, most targeted contracts. |

---

## 8. Deployment Plan

| Component | Deploy To | Tool |
|-----------|----------|------|
| Solidity contracts | Arbitrum Sepolia (testnet) → Arbitrum One (mainnet) | Foundry `forge script` |
| Stylus contract | Arbitrum Sepolia → Arbitrum One | `cargo stylus deploy` |
| Evaluator + API | Railway / Render / VPS | Docker |
| Indexer + PostgreSQL | Railway / Render | Docker + managed DB |
| Frontend | Vercel | Vite build |

---

## 9. Security Considerations

- **Evaluator key management:** The evaluator's signing key is the trust anchor. Use HSM or AWS KMS in production. For buildathon, environment variable is acceptable.
- **Reentrancy:** FosaGateRouter uses checks-effects-interactions pattern + reentrancy guard on `executeWithClearance`.
- **Attestation replay:** Each attestation includes a nonce and expiry timestamp. RiskEngine rejects expired or replayed attestations.
- **Evaluator compromise:** If the evaluator key leaks, owner can `pause()` the router and rotate the evaluator address via `setEvaluatorAddress()` on RiskEngine.
- **Fee griefing:** Agents pre-deposit balance. Fees are deducted atomically during evaluation. No refund for rejected transactions (prevents spam).

---

## 10. Build Order (Recommended)

1. **Phase 1 — Core contracts:** FosaGateRouter + AgentRegistry + VerdictLog (Solidity)
2. **Phase 2 — RiskEngine:** Stylus contract with `verify_attestation` + `validate_risk_params`
3. **Phase 3 — Evaluator:** Off-chain evaluation pipeline + attestation signing
4. **Phase 4 — API Gateway:** REST endpoints for agents to submit intents
5. **Phase 5 — Frontend:** React dashboard with live verdict feed
6. **Phase 6 — Polish:** PolicyRegistry, FeeManager, Analytics, batch operations
