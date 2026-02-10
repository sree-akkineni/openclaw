import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

type StressRequest = {
  id: string;
  bucket: string;
  topic: string;
  task: string;
  continuationCriteria: string;
  stopCriteria: string;
};

type ToolResult = {
  status?: string;
  loop?: {
    loopId: string;
  };
  loops?: Array<{
    loopId: string;
    state: "active" | "awaiting_decision" | "closed";
    lastPriorityScore?: number;
  }>;
};

function parseStressJsonl(raw: string): StressRequest[] {
  return raw
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line) as StressRequest);
}

describe("research_loop stress scenarios", () => {
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

  it("processes stress fixture requests into decision-ready loops", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-stress-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const tool = await createTool("agent:stress:main");

    const fixturePath = path.join(
      process.cwd(),
      "test",
      "fixtures",
      "research-loop-stress-requests.jsonl",
    );
    const requests = parseStressJsonl(await fs.readFile(fixturePath, "utf8"));
    expect(requests.length).toBe(40);

    for (const [idx, request] of requests.entries()) {
      const started = await tool.execute(`start-${request.id}`, {
        action: "start",
        topic: request.topic,
        priority: idx % 3 === 0 ? "high" : idx % 3 === 1 ? "normal" : "low",
        maxRounds: 3,
      });
      const loopId = (started.details as ToolResult).loop?.loopId;
      if (!loopId) {
        throw new Error(`missing loopId for ${request.id}`);
      }

      await tool.execute(`checkpoint-${request.id}`, {
        action: "checkpoint",
        loopId,
        summary: `Task: ${request.task}`,
        critique: `Continue if ${request.continuationCriteria}. Stop if ${request.stopCriteria}.`,
        recommendation: "needs_input",
        importance: (idx % 5) + 1,
        urgency: ((idx + 2) % 5) + 1,
        confidence: ((idx + 3) % 5) + 1,
        whyNow: `Bucket ${request.bucket}: decision needed before deeper automation.`,
      });
    }

    const queue = await tool.execute("list-needs-decision", {
      action: "list",
      view: "needs_decision",
      limit: 100,
    });
    const queueDetails = queue.details as ToolResult;
    expect(queueDetails.status).toBe("ok");
    expect(queueDetails.loops?.length).toBe(40);
    expect(queueDetails.loops?.every((entry) => entry.state === "awaiting_decision")).toBe(true);

    const hot = await tool.execute("list-hot", {
      action: "list",
      view: "hot",
      limit: 20,
    });
    const hotDetails = hot.details as ToolResult;
    const scores = (hotDetails.loops ?? []).map((entry) => entry.lastPriorityScore ?? 0);
    for (let i = 1; i < scores.length; i += 1) {
      expect(scores[i - 1]).toBeGreaterThanOrEqual(scores[i]);
    }
  });
});
