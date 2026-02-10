import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

type StressRequest = {
  id: string;
  topic: string;
  task: string;
  continuationCriteria: string;
};

type ToolResult = {
  status?: string;
  loop?: { loopId: string };
  loops?: Array<{ loopId: string; state: string }>;
};

const maybeIt = process.env.OPENCLAW_LIVE_RESEARCH_LOOP === "1" ? it : it.skip;

describe("research_loop live smoke", () => {
  const previousStateDir = process.env.OPENCLAW_STATE_DIR;
  let tempStateDir: string | null = null;

  async function createTool(agentSessionKey?: string) {
    vi.resetModules();
    const mod = await import("./research-loop-tool.js");
    return mod.createResearchLoopTool({ agentSessionKey });
  }

  function parseStressJsonl(raw: string): StressRequest[] {
    return raw
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => JSON.parse(line) as StressRequest);
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

  maybeIt("runs a gated stress subset for manual soak checks", async () => {
    tempStateDir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-research-loop-live-"));
    process.env.OPENCLAW_STATE_DIR = tempStateDir;
    const tool = await createTool("agent:live:main");
    const fixturePath = path.join(
      process.cwd(),
      "test",
      "fixtures",
      "research-loop-stress-requests.jsonl",
    );
    const requests = parseStressJsonl(await fs.readFile(fixturePath, "utf8")).slice(0, 5);
    expect(requests.length).toBe(5);

    for (const [idx, request] of requests.entries()) {
      const started = await tool.execute(`start-live-${request.id}`, {
        action: "start",
        topic: request.topic,
      });
      const loopId = (started.details as ToolResult).loop?.loopId;
      if (!loopId) {
        throw new Error(`missing loopId for ${request.id}`);
      }
      await tool.execute(`checkpoint-live-${request.id}`, {
        action: "checkpoint",
        loopId,
        summary: request.task,
        critique: request.continuationCriteria,
        recommendation: "needs_input",
        importance: 5 - (idx % 5),
        urgency: (idx % 5) + 1,
      });
    }

    const queue = await tool.execute("list-live-needs-decision", {
      action: "list",
      view: "needs_decision",
      limit: 20,
    });
    const details = queue.details as ToolResult;
    expect(details.status).toBe("ok");
    expect(details.loops?.length).toBe(5);
  });
});
