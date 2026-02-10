import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

type LoopEntry = {
  loopId: string;
  state: "active" | "awaiting_decision" | "closed";
  lastPriorityScore?: number;
};

type ToolResult = {
  status?: string;
  error?: string;
  loop?: {
    loopId: string;
    state: "active" | "awaiting_decision" | "closed";
  };
  loops?: LoopEntry[];
};

describe("research_loop deterministic evals", () => {
  const previousStateDir = process.env.OPENCLAW_STATE_DIR;
  let tempStateDir: string | null = null;

  async function createTool(agentSessionKey?: string) {
    vi.resetModules();
    const mod = await import("./research-loop-tool.js");
    return mod.createResearchLoopTool({ agentSessionKey });
  }

  async function startLoop(tool: Awaited<ReturnType<typeof createTool>>, topic: string) {
    const started = await tool.execute(`start-${topic}`, { action: "start", topic });
    const details = started.details as ToolResult;
    const loopId = details.loop?.loopId;
    if (!loopId) {
      throw new Error("missing loopId");
    }
    return loopId;
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

  it("orders hot queue by priority score and updated recency", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-eval-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const tool = await createTool("agent:eval:main");

    const first = await startLoop(tool, "First");
    await tool.execute("checkpoint-first", {
      action: "checkpoint",
      loopId: first,
      summary: "First",
      recommendation: "continue",
      importance: 5,
      urgency: 5,
    });

    const second = await startLoop(tool, "Second");
    await tool.execute("checkpoint-second", {
      action: "checkpoint",
      loopId: second,
      summary: "Second",
      recommendation: "continue",
      importance: 3,
      urgency: 3,
    });

    const third = await startLoop(tool, "Third");
    await tool.execute("checkpoint-third", {
      action: "checkpoint",
      loopId: third,
      summary: "Third",
      recommendation: "continue",
      importance: 1,
      urgency: 4,
    });

    const listed = await tool.execute("list-hot", {
      action: "list",
      view: "hot",
      limit: 10,
    });
    const details = listed.details as ToolResult;
    expect(details.status).toBe("ok");
    const loops = details.loops ?? [];
    expect(loops.length).toBe(3);
    expect(loops[0]?.loopId).toBe(first);
    expect(loops[0]?.lastPriorityScore).toBe(25);
    expect(loops[1]?.loopId).toBe(second);
    expect(loops[1]?.lastPriorityScore).toBe(9);
    expect(loops[2]?.loopId).toBe(third);
    expect(loops[2]?.lastPriorityScore).toBe(4);
  });

  it("keeps loops isolated by agent across status and list", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-eval-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const alpha = await createTool("agent:alpha:main");
    const beta = await createTool("agent:beta:main");

    const alphaLoopId = await startLoop(alpha, "Alpha private topic");
    await alpha.execute("checkpoint-alpha", {
      action: "checkpoint",
      loopId: alphaLoopId,
      summary: "Alpha summary",
      recommendation: "continue",
      importance: 5,
      urgency: 4,
    });

    const betaStatus = await beta.execute("beta-status", {
      action: "status",
      loopId: alphaLoopId,
    });
    expect((betaStatus.details as ToolResult).status).toBe("error");

    const betaList = await beta.execute("beta-list", { action: "list", limit: 100 });
    const betaLoops = ((betaList.details as ToolResult).loops ?? []).map((entry) => entry.loopId);
    expect(betaLoops).not.toContain(alphaLoopId);

    const alphaList = await alpha.execute("alpha-list", { action: "list", limit: 100 });
    const alphaLoops = ((alphaList.details as ToolResult).loops ?? []).map((entry) => entry.loopId);
    expect(alphaLoops).toContain(alphaLoopId);
  });
});
