import { Type } from "@sinclair/typebox";
import type { OpenClawConfig } from "../../config/config.js";
import type { AnyAgentTool } from "./common.js";
import { wrapWebContent } from "../../security/external-content.js";
import { jsonResult, readNumberParam, readStringParam } from "./common.js";
import {
  CacheEntry,
  DEFAULT_CACHE_TTL_MINUTES,
  DEFAULT_TIMEOUT_SECONDS,
  normalizeCacheKey,
  readCache,
  readResponseText,
  resolveCacheTtlMs,
  resolveTimeoutSeconds,
  withTimeout,
  writeCache,
} from "./web-shared.js";

const X_SEARCH_ENDPOINT = "https://api.x.com/2/tweets/search/recent";
const DEFAULT_X_SEARCH_COUNT = 10;
const MIN_X_SEARCH_COUNT = 10;
const MAX_X_SEARCH_COUNT = 100;
const DEFAULT_X_CACHE_TTL_MINUTES = 5;
const DEFAULT_X_TIMEOUT_SECONDS = 15;

const X_SEARCH_CACHE = new Map<string, CacheEntry<Record<string, unknown>>>();

const XSearchSchema = Type.Object({
  query: Type.String({
    description:
      "Search query string. Supports X search operators like from:, is:reply, has:links, etc.",
  }),
  count: Type.Optional(
    Type.Number({
      description: "Number of tweets to return (10-100, default 10).",
      minimum: MIN_X_SEARCH_COUNT,
      maximum: MAX_X_SEARCH_COUNT,
    }),
  ),
  sort_order: Type.Optional(
    Type.String({
      description: 'Sort order: "recency" (default) or "relevancy".',
    }),
  ),
});

type XSearchConfig = NonNullable<NonNullable<OpenClawConfig["tools"]>["web"]>["x"];

type XTweetData = {
  id: string;
  text: string;
  author_id?: string;
  created_at?: string;
  public_metrics?: {
    like_count?: number;
    retweet_count?: number;
    reply_count?: number;
    impression_count?: number;
  };
};

type XUserData = {
  id: string;
  name: string;
  username: string;
};

type XSearchApiResponse = {
  data?: XTweetData[];
  includes?: {
    users?: XUserData[];
  };
  meta?: {
    result_count?: number;
    newest_id?: string;
    oldest_id?: string;
  };
  errors?: Array<{ message?: string; title?: string }>;
};

function resolveXConfig(cfg?: OpenClawConfig): XSearchConfig {
  return cfg?.tools?.web?.x;
}

function resolveXEnabled(xConfig?: XSearchConfig, bearerToken?: string): boolean {
  if (typeof xConfig?.enabled === "boolean") {
    return xConfig.enabled;
  }
  // Enabled by default when a bearer token is available.
  return !!bearerToken;
}

function resolveXBearerToken(xConfig?: XSearchConfig): string | undefined {
  const fromConfig =
    xConfig && typeof xConfig.bearerToken === "string" ? xConfig.bearerToken.trim() : "";
  const fromEnv = (process.env.X_BEARER_TOKEN ?? "").trim();
  return fromConfig || fromEnv || undefined;
}

function resolveXSearchCount(value: unknown, fallback: number): number {
  const parsed = typeof value === "number" && Number.isFinite(value) ? value : fallback;
  return Math.max(MIN_X_SEARCH_COUNT, Math.min(MAX_X_SEARCH_COUNT, Math.floor(parsed)));
}

function resolveSortOrder(value: string | undefined): "recency" | "relevancy" {
  if (value === "relevancy") {
    return "relevancy";
  }
  return "recency";
}

async function runXSearch(params: {
  query: string;
  count: number;
  sortOrder: "recency" | "relevancy";
  bearerToken: string;
  timeoutSeconds: number;
  cacheTtlMs: number;
}): Promise<Record<string, unknown>> {
  const cacheKey = normalizeCacheKey(`x:${params.query}:${params.count}:${params.sortOrder}`);
  const cached = readCache(X_SEARCH_CACHE, cacheKey);
  if (cached) {
    return { ...cached.value, cached: true };
  }

  const start = Date.now();

  const url = new URL(X_SEARCH_ENDPOINT);
  url.searchParams.set("query", params.query);
  url.searchParams.set("max_results", String(params.count));
  url.searchParams.set("sort_order", params.sortOrder);
  url.searchParams.set("tweet.fields", "text,author_id,created_at,public_metrics");
  url.searchParams.set("expansions", "author_id");
  url.searchParams.set("user.fields", "name,username");

  const res = await fetch(url.toString(), {
    method: "GET",
    headers: {
      Authorization: `Bearer ${params.bearerToken}`,
      "User-Agent": "OpenClaw/1.0",
    },
    signal: withTimeout(undefined, params.timeoutSeconds * 1000),
  });

  if (!res.ok) {
    const detail = await readResponseText(res);
    throw new Error(`X API error (${res.status}): ${detail || res.statusText}`);
  }

  const data = (await res.json()) as XSearchApiResponse;

  if (data.errors?.length) {
    const msg = data.errors.map((e) => e.message ?? e.title ?? "unknown").join("; ");
    throw new Error(`X API returned errors: ${msg}`);
  }

  // Build a user lookup map from expansions.
  const userMap = new Map<string, XUserData>();
  if (data.includes?.users) {
    for (const user of data.includes.users) {
      userMap.set(user.id, user);
    }
  }

  const tweets = (data.data ?? []).map((tweet) => {
    const user = tweet.author_id ? userMap.get(tweet.author_id) : undefined;
    return {
      id: tweet.id,
      text: wrapWebContent(tweet.text, "x_search"),
      author: user
        ? { name: user.name, username: user.username }
        : { name: "unknown", username: "unknown" },
      created_at: tweet.created_at ?? "",
      metrics: {
        likes: tweet.public_metrics?.like_count ?? 0,
        retweets: tweet.public_metrics?.retweet_count ?? 0,
        replies: tweet.public_metrics?.reply_count ?? 0,
      },
    };
  });

  const payload = {
    query: params.query,
    count: tweets.length,
    tweets,
    tookMs: Date.now() - start,
  };

  writeCache(X_SEARCH_CACHE, cacheKey, payload, params.cacheTtlMs);
  return payload;
}

export function createXSearchTool(options?: { config?: OpenClawConfig }): AnyAgentTool | null {
  const xConfig = resolveXConfig(options?.config);
  const bearerToken = resolveXBearerToken(xConfig);

  if (!resolveXEnabled(xConfig, bearerToken)) {
    return null;
  }

  if (!bearerToken) {
    return null;
  }

  return {
    label: "X Search",
    name: "x_search",
    description:
      "Search recent tweets on X/Twitter. Supports X search operators (from:user, is:reply, has:links, #hashtag, etc.). Returns tweet text, author, timestamp, and engagement metrics.",
    parameters: XSearchSchema,
    execute: async (_toolCallId, args) => {
      const params = args as Record<string, unknown>;
      const query = readStringParam(params, "query", { required: true });
      const count = readNumberParam(params, "count", { integer: true });
      const sortOrderRaw = readStringParam(params, "sort_order");

      try {
        const result = await runXSearch({
          query,
          count: resolveXSearchCount(count, DEFAULT_X_SEARCH_COUNT),
          sortOrder: resolveSortOrder(sortOrderRaw),
          bearerToken,
          timeoutSeconds: resolveTimeoutSeconds(xConfig?.timeoutSeconds, DEFAULT_X_TIMEOUT_SECONDS),
          cacheTtlMs: resolveCacheTtlMs(xConfig?.cacheTtlMinutes, DEFAULT_X_CACHE_TTL_MINUTES),
        });
        return jsonResult(result);
      } catch (error) {
        return jsonResult({
          error: "x_search_failed",
          message: error instanceof Error ? error.message : "Unknown error",
        });
      }
    },
  };
}

export const __testing = {
  resolveXBearerToken,
  resolveXEnabled,
  resolveXSearchCount,
  resolveSortOrder,
} as const;
