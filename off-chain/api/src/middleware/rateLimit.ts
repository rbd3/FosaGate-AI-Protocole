// FosaGate AI — API Gateway / Rate Limiting Middleware
// Sliding-window in-memory rate limiter keyed by API key (or IP).

import { Request, Response, NextFunction } from "express";
import { AuthenticatedRequest } from "./auth";

interface RateBucket {
  count: number;
  resetAt: number; // epoch ms
}

const buckets = new Map<string, RateBucket>();

let windowMs = 60_000;  // default 1 minute
let maxRequests = 30;   // default 30 req/window

export function loadRateLimitConfig(): void {
  windowMs = parseInt(process.env.RATE_LIMIT_WINDOW_MS || "60000", 10);
  maxRequests = parseInt(process.env.RATE_LIMIT_MAX_REQUESTS || "30", 10);
  console.log(
    `[rateLimit] Window ${windowMs}ms, max ${maxRequests} requests per key`
  );
}

/**
 * Rate-limit middleware.
 *
 * Key priority: authenticated API key → client IP.
 * Returns 429 when the limit is exceeded with a Retry-After header.
 */
export function rateLimitMiddleware(
  req: AuthenticatedRequest,
  res: Response,
  next: NextFunction
): void {
  const key = req.apiKey || req.ip || "unknown";
  const now = Date.now();

  let bucket = buckets.get(key);

  if (!bucket || now >= bucket.resetAt) {
    // New window
    bucket = { count: 1, resetAt: now + windowMs };
    buckets.set(key, bucket);
    setRateLimitHeaders(res, maxRequests - 1, bucket.resetAt);
    return next();
  }

  bucket.count++;

  if (bucket.count > maxRequests) {
    const retryAfterSec = Math.ceil((bucket.resetAt - now) / 1000);
    res.set("Retry-After", String(retryAfterSec));
    setRateLimitHeaders(res, 0, bucket.resetAt);
    res.status(429).json({
      error: "Too Many Requests",
      message: `Rate limit exceeded. Try again in ${retryAfterSec}s.`,
      retryAfter: retryAfterSec,
    });
    return;
  }

  setRateLimitHeaders(res, maxRequests - bucket.count, bucket.resetAt);
  next();
}

function setRateLimitHeaders(
  res: Response,
  remaining: number,
  resetAt: number
): void {
  res.set("X-RateLimit-Limit", String(maxRequests));
  res.set("X-RateLimit-Remaining", String(Math.max(remaining, 0)));
  res.set("X-RateLimit-Reset", String(Math.ceil(resetAt / 1000)));
}

// Periodic cleanup of stale buckets (runs every 5 minutes)
setInterval(() => {
  const now = Date.now();
  for (const [key, bucket] of buckets) {
    if (now >= bucket.resetAt) buckets.delete(key);
  }
}, 5 * 60_000);
