import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

type ToolResultDetails = {
  status?: string;
  error?: string;
  canContinue?: boolean;
  spawnAdvice?: {
    shouldSpawn: boolean;
    reason: string;
    suggestedTask?: string;
  };
  loop?: {
    loopId: string;
    topic: string;
    state: "active" | "awaiting_decision" | "closed";
    currentRound: number;
    maxRounds: number;
    priority: "low" | "normal" | "high";
    lastCheckpoint?: {
      importance?: number;
      urgency?: number;
      confidence?: number;
      evidenceQuality?: number;
      whyNow?: string;
      citationLinks?: string[];
      counterpoints?: string[];
      analysisQualityScore?: number;
      priorityScore?: number;
    };
  };
  loops?: Array<{
    loopId: string;
    state: string;
    lastAnalysisQualityScore?: number;
    lastPriorityScore?: number;
    needsReview?: boolean;
  }>;
};

describe("research_loop tool", () => {
  const previousStateDir = process.env.OPENCLAW_STATE_DIR;
  let tempStateDir: string | null = null;

  async function createTool(agentSessionKey?: string) {
    vi.resetModules();
    const mod = await import("./research-loop-tool.js");
    return mod.createResearchLoopTool({ agentSessionKey });
  }

  afterEach(async () => {
    vi.resetModules();
    if (tempStateDir) {
      await fs.rm(tempStateDir, { recursive: true, force: true });
      tempStateDir = null;
    }
    if (previousStateDir === undefined) {
      delete process.env.OPENCLAW_STATE_DIR;
    } else {
      process.env.OPENCLAW_STATE_DIR = previousStateDir;
    }
  });

  it("supports start/checkpoint/continue/close lifecycle with round caps", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const tool = await createTool();

    const started = await tool.execute("call-start", {
      action: "start",
      topic: "Track frontier model launches",
      priority: "high",
      maxRounds: 2,
    });
    const startDetails = started.details as ToolResultDetails;
    expect(startDetails.status).toBe("started");
    expect(startDetails.loop?.state).toBe("active");
    expect(startDetails.loop?.currentRound).toBe(1);
    expect(startDetails.loop?.maxRounds).toBe(2);
    expect(startDetails.loop?.priority).toBe("high");
    const loopId = startDetails.loop?.loopId;
    expect(typeof loopId).toBe("string");
    if (!loopId) {
      throw new Error("missing loopId");
    }

    const checkpoint1 = await tool.execute("call-checkpoint-1", {
      action: "checkpoint",
      loopId,
      summary: "Top launch had strong benchmark gains.",
      critique: "Evidence is still mostly vendor-supplied.",
      recommendation: "continue",
      proposedTasks: ["Collect third-party replications", "Compare cost/latency claims"],
    });
    const checkpoint1Details = checkpoint1.details as ToolResultDetails;
    expect(checkpoint1Details.status).toBe("checkpointed");
    expect(checkpoint1Details.loop?.state).toBe("awaiting_decision");
    expect(checkpoint1Details.canContinue).toBe(true);

    const continued = await tool.execute("call-continue", {
      action: "continue",
      loopId,
      reason: "Proceed with round 2 validation.",
    });
    const continuedDetails = continued.details as ToolResultDetails;
    expect(continuedDetails.status).toBe("continued");
    expect(continuedDetails.loop?.currentRound).toBe(2);
    expect(continuedDetails.loop?.state).toBe("active");

    const checkpoint2 = await tool.execute("call-checkpoint-2", {
      action: "checkpoint",
      loopId,
      summary: "Independent replications only partially matched headline results.",
      recommendation: "continue",
    });
    const checkpoint2Details = checkpoint2.details as ToolResultDetails;
    expect(checkpoint2Details.status).toBe("checkpointed");
    expect(checkpoint2Details.loop?.state).toBe("awaiting_decision");
    expect(checkpoint2Details.canContinue).toBe(false);

    const overLimit = await tool.execute("call-over-limit", {
      action: "continue",
      loopId,
    });
    const overLimitDetails = overLimit.details as ToolResultDetails;
    expect(overLimitDetails.status).toBe("error");
    expect(overLimitDetails.error).toContain("max rounds");

    const closed = await tool.execute("call-close", {
      action: "close",
      loopId,
      reason: "Enough signal for now.",
    });
    const closedDetails = closed.details as ToolResultDetails;
    expect(closedDetails.status).toBe("closed");
    expect(closedDetails.loop?.state).toBe("closed");

    const status = await tool.execute("call-status", {
      action: "status",
      loopId,
    });
    const statusDetails = status.details as ToolResultDetails;
    expect(statusDetails.status).toBe("ok");
    expect(statusDetails.loop?.state).toBe("closed");

    const listed = await tool.execute("call-list", {
      action: "list",
      state: "closed",
    });
    const listedDetails = listed.details as ToolResultDetails;
    expect(listedDetails.status).toBe("ok");
    expect(listedDetails.loops?.some((entry) => entry.loopId === loopId)).toBe(true);

    const registryPath = path.join(tempStateDir, "research", "loops.json");
    const raw = JSON.parse(await fs.readFile(registryPath, "utf8")) as {
      version?: number;
      loops?: Record<string, unknown>;
    };
    expect(raw.version).toBe(1);
    expect(raw.loops?.[loopId]).toBeDefined();
  });

  it("returns errors for invalid loop transitions", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const tool = await createTool();

    const missing = await tool.execute("call-missing-loop", {
      action: "checkpoint",
      loopId: "missing-loop",
      summary: "noop",
    });
    const missingDetails = missing.details as ToolResultDetails;
    expect(missingDetails.status).toBe("error");
    expect(missingDetails.error).toContain("not found");

    const started = await tool.execute("call-start", {
      action: "start",
      topic: "Monitor infra incidents",
    });
    const startedDetails = started.details as ToolResultDetails;
    const loopId = startedDetails.loop?.loopId;
    if (!loopId) {
      throw new Error("missing loopId");
    }

    const prematureContinue = await tool.execute("call-premature-continue", {
      action: "continue",
      loopId,
    });
    const prematureDetails = prematureContinue.details as ToolResultDetails;
    expect(prematureDetails.status).toBe("error");
    expect(prematureDetails.error).toContain("awaiting_decision");
  });

  it("scopes loops by requester agent id", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const alphaTool = await createTool("agent:alpha:main");
    const betaTool = await createTool("agent:beta:main");

    const started = await alphaTool.execute("call-alpha-start", {
      action: "start",
      topic: "Alpha-only research",
    });
    const startDetails = started.details as ToolResultDetails;
    const loopId = startDetails.loop?.loopId;
    if (!loopId) {
      throw new Error("missing loopId");
    }

    const betaStatus = await betaTool.execute("call-beta-status", {
      action: "status",
      loopId,
    });
    const betaStatusDetails = betaStatus.details as ToolResultDetails;
    expect(betaStatusDetails.status).toBe("error");
    expect(betaStatusDetails.error).toContain("not accessible");

    const betaList = await betaTool.execute("call-beta-list", {
      action: "list",
    });
    const betaListDetails = betaList.details as ToolResultDetails;
    expect(betaListDetails.loops?.some((entry) => entry.loopId === loopId)).toBe(false);

    const alphaStatus = await alphaTool.execute("call-alpha-status", {
      action: "status",
      loopId,
    });
    const alphaStatusDetails = alphaStatus.details as ToolResultDetails;
    expect(alphaStatusDetails.status).toBe("ok");
    expect(alphaStatusDetails.loop?.loopId).toBe(loopId);
  });

  it("supports triage scoring and list views", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const tool = await createTool("agent:triage:main");

    const high = await tool.execute("call-high-start", {
      action: "start",
      topic: "High urgency model reliability shift",
    });
    const highLoopId = (high.details as ToolResultDetails).loop?.loopId;
    if (!highLoopId) {
      throw new Error("missing high loop");
    }
    const highCheckpoint = await tool.execute("call-high-checkpoint", {
      action: "checkpoint",
      loopId: highLoopId,
      summary: "Signals are mixed.",
      critique: "Replication evidence is weak.",
      recommendation: "continue",
      proposedTasks: [
        "Ask a sub-agent to verify third-party benchmarks",
        "Gather contradictory test results",
      ],
      importance: 5,
      urgency: 5,
      confidence: 3,
      evidenceQuality: 4,
      citationLinks: [
        "https://example.com/benchmark-report",
        "https://example.com/independent-analysis",
      ],
      counterpoints: ["Model benchmark setup may be cherry-picked."],
      whyNow: "This affects deployment this week.",
    });
    const highCheckpointDetails = highCheckpoint.details as ToolResultDetails;
    expect(highCheckpointDetails.status).toBe("checkpointed");
    expect(highCheckpointDetails.spawnAdvice?.shouldSpawn).toBe(true);
    expect(highCheckpointDetails.spawnAdvice?.suggestedTask).toContain("sub-agent");

    const highStatus = await tool.execute("call-high-status", {
      action: "status",
      loopId: highLoopId,
    });
    const highStatusDetails = highStatus.details as ToolResultDetails;
    expect(highStatusDetails.loop?.lastCheckpoint?.priorityScore).toBe(25);
    expect(highStatusDetails.loop?.lastCheckpoint?.importance).toBe(5);
    expect(highStatusDetails.loop?.lastCheckpoint?.urgency).toBe(5);
    expect(highStatusDetails.loop?.lastCheckpoint?.confidence).toBe(3);
    expect(highStatusDetails.loop?.lastCheckpoint?.evidenceQuality).toBe(4);
    expect(highStatusDetails.loop?.lastCheckpoint?.citationLinks?.length).toBe(2);
    expect((highStatusDetails.loop?.lastCheckpoint?.analysisQualityScore ?? 0) >= 65).toBe(true);

    const low = await tool.execute("call-low-start", {
      action: "start",
      topic: "Lower-priority tooling update",
    });
    const lowLoopId = (low.details as ToolResultDetails).loop?.loopId;
    if (!lowLoopId) {
      throw new Error("missing low loop");
    }
    await tool.execute("call-low-checkpoint", {
      action: "checkpoint",
      loopId: lowLoopId,
      summary: "Minor ecosystem movement.",
      recommendation: "continue",
      importance: 2,
      urgency: 2,
    });

    const stale = await tool.execute("call-stale-start", {
      action: "start",
      topic: "Background tracking topic",
    });
    const staleLoopId = (stale.details as ToolResultDetails).loop?.loopId;
    if (!staleLoopId) {
      throw new Error("missing stale loop");
    }

    const registryPath = path.join(tempStateDir, "research", "loops.json");
    const raw = JSON.parse(await fs.readFile(registryPath, "utf8")) as {
      loops?: Record<string, { updatedAt?: number }>;
    };
    if (raw.loops?.[staleLoopId]) {
      raw.loops[staleLoopId].updatedAt = Date.now() - 48 * 60 * 60 * 1000;
      await fs.writeFile(registryPath, `${JSON.stringify(raw, null, 2)}\n`, "utf8");
    }

    const hot = await tool.execute("call-hot-list", {
      action: "list",
      view: "hot",
      limit: 10,
    });
    const hotDetails = hot.details as ToolResultDetails;
    expect(hotDetails.status).toBe("ok");
    expect(hotDetails.loops?.[0]?.loopId).toBe(highLoopId);
    expect(hotDetails.loops?.[0]?.lastPriorityScore).toBe(25);
    expect(hotDetails.loops?.[1]?.loopId).toBe(lowLoopId);

    const needsDecision = await tool.execute("call-needs-decision-list", {
      action: "list",
      view: "needs_decision",
      limit: 10,
    });
    const needsDecisionDetails = needsDecision.details as ToolResultDetails;
    expect(needsDecisionDetails.loops?.some((entry) => entry.loopId === highLoopId)).toBe(true);
    expect(needsDecisionDetails.loops?.some((entry) => entry.loopId === lowLoopId)).toBe(true);
    expect(needsDecisionDetails.loops?.some((entry) => entry.loopId === staleLoopId)).toBe(false);

    const needsReview = await tool.execute("call-needs-review-list", {
      action: "list",
      view: "needs_review",
      limit: 10,
    });
    const needsReviewDetails = needsReview.details as ToolResultDetails;
    expect(needsReviewDetails.loops?.some((entry) => entry.loopId === lowLoopId)).toBe(true);
    expect(needsReviewDetails.loops?.some((entry) => entry.loopId === highLoopId)).toBe(false);

    const staleList = await tool.execute("call-stale-list", {
      action: "list",
      view: "stale",
      staleHours: 24,
      limit: 10,
    });
    const staleDetails = staleList.details as ToolResultDetails;
    expect(staleDetails.loops?.some((entry) => entry.loopId === staleLoopId)).toBe(true);
    expect(staleDetails.loops?.some((entry) => entry.loopId === highLoopId)).toBe(false);
  });

  it("persists concurrent starts without dropping loops", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const tool = await createTool("agent:parallel:main");

    const total = 25;
    await Promise.all(
      Array.from({ length: total }, (_, idx) =>
        tool.execute(`call-parallel-${idx}`, {
          action: "start",
          topic: `Parallel topic ${idx + 1}`,
        }),
      ),
    );

    const list = await tool.execute("call-parallel-list", {
      action: "list",
      limit: 100,
    });
    const listDetails = list.details as ToolResultDetails;
    expect(listDetails.status).toBe("ok");
    expect(listDetails.loops?.length).toBe(total);
  });
});
