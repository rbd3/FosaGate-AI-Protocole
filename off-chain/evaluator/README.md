# FosaGate AI — Off-Chain Evaluator Engine

The **Off-Chain Evaluator Engine** serves as the AI-driven brain of the FosaGate protocol. It intercepts transaction intents from AI agents, performs real-time security and risk analysis across multiple dimensions, generates a cryptographic attestation, and signs it. The signed attestation is then passed back to the agent to be submitted to the on-chain `FosaGateRouter`.

---

## 1. Multi-Dimensional Risk Pipeline

The evaluator runs the following checks in parallel for every transaction intent:

1. **MEV Exposure Detector (`mevDetector.ts`)**: Simulates transaction details against current mempool states, detecting sandwich attacks, frontrunning, and backrunning hazards on DEX routers.
2. **Slippage Checker (`slippageChecker.ts`)**: Decodes standard DEX swap calldata (Uniswap V2/V3) to compare the minimum output parameter (`amountOutMinimum`) to the expected output, flagging high slippage thresholds (>1.5%) or lack of slippage protection.
3. **Contract Scorer (`contractScorer.ts`)**: Gauges the reputation of the target contract. Detects whether the address is an EOA or contract, checks EIP-1967 proxy implementation slots, and screens against blacklisted exploit addresses or whitelisted blue-chip protocols.
4. **Balance Impact Simulator (`balanceImpact.ts`)**: Simulates the transaction on-chain via `eth_call`/`estimateGas` to ensure it does not revert, calculates net value changes, and alerts on unlimited allowance approvals.
5. **Pattern Matcher (`patternMatcher.ts`)**: Screens raw calldata selectors and byte patterns for known exploit structures, reentrancy vectors, or self-destruct triggers.

The **AI Risk Model (`riskModel.ts`)** aggregates all analyzer scores using the protocol's default weighted score formula (matching the Stylus contract weights) to generate a composite score ($0$ to $1000$) and issues a final verdict (`APPROVED`, `REJECTED_HIGH_RISK`, or `REJECTED_POLICY_VIOLATION`).

---

## 2. Attestation Byte Layout (225 Bytes)

The cryptographic attestation returned to the agent has a precise, packed byte layout of exactly **225 bytes** to ensure highly efficient on-chain parsing by the Stylus-based `RiskEngine`:

| Offset | Size | Field | Solidity Type | Description |
|---|---|---|---|---|
| `0x00` | `32B` | `txId` | `bytes32` | `keccak256(abi.encodePacked(agent, target, payload, nonce, chainId))` |
| `0x20` | `32B` | `riskScore` | `uint256` | Composite risk score ($0$ to $1000$) |
| `0x40` | `32B` | `verdict` | `uint8` | `0` = APPROVED, `1` = HIGH_RISK, `2` = POLICY_VIOLATION |
| `0x60` | `32B` | `nonce` | `uint256` | Monotonically increasing agent transaction nonce |
| `0x80` | `32B` | `expiry` | `uint256` | Unix timestamp of expiration (default: $+300$ seconds) |
| `0xA0` | `32B` | `r` | `bytes32` | ECDSA signature $r$ parameter |
| `0xC0` | `32B` | `s` | `bytes32` | ECDSA signature $s$ parameter |
| `0xE0` | `1B` | `v` | `uint8` | ECDSA signature recovery ID $v$ ($27$ or $28$) |

The signed message prefix is standard Ethereum format: `keccak256("\x19Ethereum Signed Message:\n32" + keccak256(abi.encodePacked(txId, riskScore, verdict, nonce, expiry)))`.

---

## 3. Setup and Installation

### Prerequisites
- Node.js (v18+)
- npm or pnpm

### Configuration
1. Copy the example environment template:
   ```bash
   cp .env.example .env
   ```
2. Edit `.env` and provide your authorized evaluator private key:
   ```env
   EVALUATOR_PRIVATE_KEY=0x...
   ARBITRUM_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc
   ```

### Installation
Install dependencies:
```bash
npm install
```

### Running Tests
Execute the test suite to verify signing and decoding logic:
```bash
npm test
```
