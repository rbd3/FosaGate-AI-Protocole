// Set environment variables before any other imports so they are present during Express bootstrap
process.env.NODE_ENV = "test";
process.env.PORT = "3005";
process.env.API_KEYS = "test-key-123";
process.env.EVALUATOR_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

import http from "http";
import { server } from "./index";

async function runTests() {
  console.log("🚀 Starting FosaGate API Gateway Integration Tests...");

  const PORT = 3005;
  
  await new Promise<void>((resolve) => {
    server.listen(PORT, () => {
      console.log(`[test] Test server running on http://localhost:${PORT}`);
      resolve();
    });
  });

  const baseUrl = `http://localhost:${PORT}`;

  try {
    // Helper to send HTTP requests
    const request = (path: string, options: http.RequestOptions = {}, body?: any): Promise<{ status: number; data: any }> => {
      return new Promise((resolve, reject) => {
        const bodyStr = body ? JSON.stringify(body) : "";
        const mergedHeaders: Record<string, any> = {
          "Content-Type": "application/json",
          ...options.headers
        };

        if (bodyStr) {
          mergedHeaders["Content-Length"] = Buffer.byteLength(bodyStr);
        }

        const req = http.request(`${baseUrl}${path}`, {
          method: "GET",
          ...options,
          headers: mergedHeaders
        }, (res) => {
          let rawData = "";
          res.on("data", (chunk) => { rawData += chunk; });
          res.on("end", () => {
            try {
              resolve({
                status: res.statusCode || 0,
                data: JSON.parse(rawData)
              });
            } catch (e) {
              resolve({
                status: res.statusCode || 0,
                data: rawData
              });
            }
          });
        });

        req.on("error", reject);
        if (bodyStr) {
          req.write(bodyStr);
        }
        req.end();
      });
    };

    // Test 1: Health Check
    console.log("Testing GET /health...");
    const health = await request("/health");
    if (health.status !== 200 || health.data.status !== "ok") {
      throw new Error(`Health check failed: ${JSON.stringify(health)}`);
    }
    console.log("✅ Health Check Passed!");

    // Test 2: Analytics Overview
    console.log("Testing GET /api/v1/analytics/overview...");
    const analytics = await request("/api/v1/analytics/overview");
    if (analytics.status !== 200 || analytics.data.totalEvaluations !== 0) {
      throw new Error(`Analytics failed: ${JSON.stringify(analytics)}`);
    }
    console.log("✅ Analytics Overview Passed!");

    // Test 3: Unauthorized Evaluate Request
    console.log("Testing GET /api/v1/policies (unauthorized)...");
    const unauthorized = await request("/api/v1/policies");
    if (unauthorized.status !== 401) {
      throw new Error(`Expected 401 Unauthorized, got ${unauthorized.status}`);
    }
    console.log("✅ Unauthorized Check Passed!");

    // Test 4: Authorized Policies Fetch
    console.log("Testing GET /api/v1/policies (authorized)...");
    const policies = await request("/api/v1/policies", {
      headers: { "x-api-key": "test-key-123" }
    });
    if (policies.status !== 200 || !Array.isArray(policies.data.policies)) {
      throw new Error(`Policies check failed: ${JSON.stringify(policies)}`);
    }
    console.log("✅ Authorized Policies Passed!");

    // Test 5: Transaction Evaluation Pipeline
    console.log("Testing POST /api/v1/evaluate (authorized)...");
    const intentPayload = {
      agent: "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
      target: "0xe592427a0aece92de3edf7a9cd9373d5d72483d4",
      payload: "0x414bf389000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000000000bb800000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c80000000000000000000000000000000000000000000000000000000063f582000000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
      value: "0",
      nonce: 10,
      chainId: 421614
    };

    const evaluation = await request("/api/v1/evaluate", {
      method: "POST",
      headers: { "x-api-key": "test-key-123" }
    }, intentPayload);

    if (evaluation.status !== 200) {
      throw new Error(`Evaluation request failed: ${JSON.stringify(evaluation)}`);
    }

    const { txId, verdict, riskScore, attestation } = evaluation.data;
    if (!txId || verdict !== "APPROVED" || riskScore === undefined || !attestation) {
      throw new Error(`Unexpected evaluation output: ${JSON.stringify(evaluation.data)}`);
    }

    // Verify attestation length is exactly 225 bytes (452 hex characters with 0x)
    if (attestation.length !== 452) {
      throw new Error(`Expected 225-byte attestation (length 452), got ${attestation.length}`);
    }

    console.log("✅ Transaction Evaluation Passed!");
    console.log(`   txId: ${txId}`);
    console.log(`   verdict: ${verdict}`);
    console.log(`   riskScore: ${riskScore}`);
    console.log(`   attestation size: ${attestation.length / 2 - 1} bytes`);

    console.log("\n🎉 All API Gateway Integration Tests Passed Successfully!");
    
  } catch (error) {
    console.error("\n❌ Test Suite Failed:", error);
    process.exitCode = 1;
  } finally {
    console.log("Closing test server...");
    server.close(() => {
      console.log("Test server closed.");
      process.exit();
    });
  }
}

runTests();
