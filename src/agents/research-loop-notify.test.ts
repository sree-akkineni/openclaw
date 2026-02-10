import { describe, expect, it } from "vitest";
import { formatResearchLoopNotification } from "./research-loop-notify.js";

describe("formatResearchLoopNotification", () => {
  const makeResult = (
    status: string,
    loop?: { topic?: string; currentRound?: number; maxRounds?: number },
  ) => ({
    details: { status, loop },
  });

  it("returns notification for started status", () => {
    const result = makeResult("started", {
      topic: "Track frontier model launches",
      currentRound: 1,
      maxRounds: 3,
    });
    expect(formatResearchLoopNotification(result)).toBe(
      "🔬 Research started: Track frontier model launches (1/3)",
    );
  });

  it("returns notification for checkpointed status", () => {
    const result = makeResult("checkpointed", {
      topic: "Benchmark analysis",
      currentRound: 2,
      maxRounds: 5,
    });
    expect(formatResearchLoopNotification(result)).toBe(
      "📋 Research checkpoint: Benchmark analysis (2/5)",
    );
  });

  it("returns notification for continued status", () => {
    const result = makeResult("continued", {
      topic: "API pricing survey",
      currentRound: 3,
      maxRounds: 4,
    });
    expect(formatResearchLoopNotification(result)).toBe(
      "🔄 Research continuing: API pricing survey (3/4)",
    );
  });

  it("returns notification for closed status without round info", () => {
    const result = makeResult("closed", {
      topic: "Completed research",
      currentRound: 2,
      maxRounds: 3,
    });
    expect(formatResearchLoopNotification(result)).toBe("✅ Research closed: Completed research");
  });

  it("returns undefined for ok status (query actions)", () => {
    expect(formatResearchLoopNotification(makeResult("ok"))).toBeUndefined();
  });

  it("returns undefined for error status", () => {
    expect(formatResearchLoopNotification(makeResult("error"))).toBeUndefined();
  });

  it("returns undefined for null input", () => {
    expect(formatResearchLoopNotification(null)).toBeUndefined();
  });

  it("returns undefined for undefined input", () => {
    expect(formatResearchLoopNotification(undefined)).toBeUndefined();
  });

  it("returns undefined when details is missing", () => {
    expect(formatResearchLoopNotification({ other: true })).toBeUndefined();
  });

  it("truncates long topics at 60 chars", () => {
    const longTopic =
      "A very long research topic that exceeds the sixty character limit by quite a lot of text";
    const result = makeResult("started", { topic: longTopic, currentRound: 1, maxRounds: 2 });
    const notification = formatResearchLoopNotification(result)!;
    expect(notification).toContain("...");
    // Topic portion should be max 60 chars
    const topicPart = notification.replace("🔬 Research started: ", "").replace(" (1/2)", "");
    expect(topicPart.length).toBeLessThanOrEqual(60);
  });

  it("falls back to 'research' when topic is missing", () => {
    const result = makeResult("started", { currentRound: 1, maxRounds: 2 });
    expect(formatResearchLoopNotification(result)).toBe("🔬 Research started: research (1/2)");
  });

  it("omits round info when currentRound or maxRounds is missing", () => {
    const result = makeResult("started", { topic: "Test" });
    expect(formatResearchLoopNotification(result)).toBe("🔬 Research started: Test");
  });

  it("handles missing loop object gracefully", () => {
    const result = { details: { status: "started" } };
    expect(formatResearchLoopNotification(result)).toBe("🔬 Research started: research");
  });
});
