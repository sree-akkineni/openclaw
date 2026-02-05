import { describe, expect, it } from "vitest";

import { __testing } from "./x-search.js";

const { resolveXBearerToken, resolveXEnabled, resolveXSearchCount, resolveSortOrder } = __testing;

describe("x_search bearer token resolution", () => {
  it("prefers config token over env", () => {
    const original = process.env.X_BEARER_TOKEN;
    process.env.X_BEARER_TOKEN = "env-token";
    try {
      expect(resolveXBearerToken({ bearerToken: "config-token" })).toBe("config-token");
    } finally {
      if (original === undefined) {
        delete process.env.X_BEARER_TOKEN;
      } else {
        process.env.X_BEARER_TOKEN = original;
      }
    }
  });

  it("falls back to env var", () => {
    const original = process.env.X_BEARER_TOKEN;
    process.env.X_BEARER_TOKEN = "env-token";
    try {
      expect(resolveXBearerToken(undefined)).toBe("env-token");
    } finally {
      if (original === undefined) {
        delete process.env.X_BEARER_TOKEN;
      } else {
        process.env.X_BEARER_TOKEN = original;
      }
    }
  });

  it("returns undefined when no token available", () => {
    const original = process.env.X_BEARER_TOKEN;
    delete process.env.X_BEARER_TOKEN;
    try {
      expect(resolveXBearerToken(undefined)).toBeUndefined();
    } finally {
      if (original !== undefined) {
        process.env.X_BEARER_TOKEN = original;
      }
    }
  });

  it("trims whitespace from tokens", () => {
    expect(resolveXBearerToken({ bearerToken: "  token  " })).toBe("token");
  });
});

describe("x_search enabled resolution", () => {
  it("respects explicit enabled=true", () => {
    expect(resolveXEnabled({ enabled: true }, undefined)).toBe(true);
  });

  it("respects explicit enabled=false", () => {
    expect(resolveXEnabled({ enabled: false }, "some-token")).toBe(false);
  });

  it("enables when bearer token is present", () => {
    expect(resolveXEnabled(undefined, "some-token")).toBe(true);
  });

  it("disables when no bearer token", () => {
    expect(resolveXEnabled(undefined, undefined)).toBe(false);
  });
});

describe("x_search count resolution", () => {
  it("clamps below minimum to 10", () => {
    expect(resolveXSearchCount(1, 10)).toBe(10);
  });

  it("clamps above maximum to 100", () => {
    expect(resolveXSearchCount(500, 10)).toBe(100);
  });

  it("uses fallback for non-numeric input", () => {
    expect(resolveXSearchCount("abc", 10)).toBe(10);
  });

  it("accepts valid count", () => {
    expect(resolveXSearchCount(50, 10)).toBe(50);
  });

  it("floors fractional values", () => {
    expect(resolveXSearchCount(25.7, 10)).toBe(25);
  });
});

describe("x_search sort order resolution", () => {
  it("returns relevancy when specified", () => {
    expect(resolveSortOrder("relevancy")).toBe("relevancy");
  });

  it("defaults to recency", () => {
    expect(resolveSortOrder(undefined)).toBe("recency");
    expect(resolveSortOrder("anything-else")).toBe("recency");
  });
});
