import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { STATE_DIR } from "../config/paths.js";
import { loadJsonFile, saveJsonFile } from "../infra/json-file.js";
import { DEFAULT_AGENT_ID, normalizeAgentId } from "../routing/session-key.js";

export type ResearchLoopState = "active" | "awaiting_decision" | "closed";
export type ResearchLoopPriority = "low" | "normal" | "high";
export type ResearchLoopRecommendation = "continue" | "stop" | "needs_input";

export type ResearchLoopCheckpointRecord = {
  round: number;
  summary: string;
  critique?: string;
  recommendation: ResearchLoopRecommendation;
  proposedTasks?: string[];
  importance?: number;
  urgency?: number;
  confidence?: number;
  evidenceQuality?: number;
  citationLinks?: string[];
  counterpoints?: string[];
  whyNow?: string;
  analysisQualityScore?: number;
  priorityScore?: number;
  createdAt: number;
};

export type ResearchLoopDecisionRecord = {
  round: number;
  decision: "continue" | "close";
  reason?: string;
  createdAt: number;
};

export type ResearchLoopRecord = {
  loopId: string;
  topic: string;
  ownerAgentId: string;
  state: ResearchLoopState;
  currentRound: number;
  maxRounds: number;
  priority: ResearchLoopPriority;
  createdAt: number;
  updatedAt: number;
  startedBySessionKey?: string;
  closedAt?: number;
  closeReason?: string;
  checkpoints: ResearchLoopCheckpointRecord[];
  decisions: ResearchLoopDecisionRecord[];
};

type PersistedResearchLoopRegistry = {
  version: 1;
  loops: Record<string, ResearchLoopRecord>;
};

const REGISTRY_VERSION = 1 as const;

export function resolveResearchLoopRegistryPath(): string {
  return path.join(STATE_DIR, "research", "loops.json");
}

function serializeResearchLoopRegistry(
  runs: Map<string, ResearchLoopRecord>,
): PersistedResearchLoopRegistry {
  const serialized: Record<string, ResearchLoopRecord> = {};
  for (const [loopId, entry] of runs.entries()) {
    serialized[loopId] = entry;
  }
  return {
    version: REGISTRY_VERSION,
    loops: serialized,
  };
}

function normalizeRating(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return undefined;
  }
  const rounded = Math.floor(value);
  if (rounded < 1) {
    return 1;
  }
  if (rounded > 5) {
    return 5;
  }
  return rounded;
}

function normalizeWhyNow(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  if (!trimmed) {
    return undefined;
  }
  return trimmed.slice(0, 280);
}

function normalizeStringList(
  value: unknown,
  opts: { maxItems: number; maxChars: number },
): string[] | undefined {
  if (!Array.isArray(value)) {
    return undefined;
  }
  const normalized = value
    .filter((entry) => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .slice(0, opts.maxItems)
    .map((entry) => entry.slice(0, opts.maxChars));
  return normalized.length > 0 ? normalized : undefined;
}

function normalizeQualityScore(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return undefined;
  }
  const rounded = Math.round(value);
  if (rounded < 0) {
    return 0;
  }
  if (rounded > 100) {
    return 100;
  }
  return rounded;
}

export function computeResearchLoopAnalysisQualityScore(input: {
  summary: string;
  critique?: string;
  proposedTasks?: string[];
  evidenceQuality?: number;
  citationLinks?: string[];
  counterpoints?: string[];
  whyNow?: string;
}): number {
  const summaryLength = input.summary.trim().length;
  const citationCount = input.citationLinks?.length ?? 0;
  const counterpointCount = input.counterpoints?.length ?? 0;
  const proposedTaskCount = input.proposedTasks?.length ?? 0;

  let score = 0;
  if (summaryLength >= 160) {
    score += 20;
  } else if (summaryLength >= 80) {
    score += 16;
  } else if (summaryLength >= 40) {
    score += 12;
  } else if (summaryLength >= 20) {
    score += 8;
  }

  if (input.critique?.trim()) {
    score += 20;
  }

  if (citationCount >= 3) {
    score += 25;
  } else if (citationCount >= 1) {
    score += 15;
  }

  if (counterpointCount >= 2) {
    score += 15;
  } else if (counterpointCount === 1) {
    score += 10;
  }

  if (proposedTaskCount >= 2) {
    score += 10;
  } else if (proposedTaskCount === 1) {
    score += 6;
  }

  if (input.evidenceQuality !== undefined) {
    score += input.evidenceQuality * 2;
  }

  if (input.whyNow?.trim()) {
    score += 5;
  }

  if (score < 0) {
    return 0;
  }
  if (score > 100) {
    return 100;
  }
  return Math.round(score);
}

export function loadResearchLoopRegistryFromDisk(): Map<string, ResearchLoopRecord> {
  const pathname = resolveResearchLoopRegistryPath();
  const raw = loadJsonFile(pathname);
  if (!raw || typeof raw !== "object") {
    return new Map();
  }
  const parsed = raw as Partial<PersistedResearchLoopRegistry>;
  if (parsed.version !== 1 || !parsed.loops || typeof parsed.loops !== "object") {
    return new Map();
  }
  const out = new Map<string, ResearchLoopRecord>();
  for (const [loopId, entry] of Object.entries(parsed.loops)) {
    if (!entry || typeof entry !== "object") {
      continue;
    }
    const typed = entry as Partial<ResearchLoopRecord>;
    if (!typed.loopId || typeof typed.loopId !== "string") {
      continue;
    }
    if (!typed.topic || typeof typed.topic !== "string") {
      continue;
    }
    const state: ResearchLoopState =
      typed.state === "active" || typed.state === "awaiting_decision" || typed.state === "closed"
        ? typed.state
        : "active";
    const priority: ResearchLoopPriority =
      typed.priority === "low" || typed.priority === "normal" || typed.priority === "high"
        ? typed.priority
        : "normal";
    const checkpoints = Array.isArray(typed.checkpoints)
      ? typed.checkpoints.filter((value) => value && typeof value === "object")
      : [];
    const decisions = Array.isArray(typed.decisions)
      ? typed.decisions.filter((value) => value && typeof value === "object")
      : [];
    out.set(loopId, {
      loopId: typed.loopId,
      topic: typed.topic,
      ownerAgentId: normalizeAgentId(
        typeof typed.ownerAgentId === "string" ? typed.ownerAgentId : DEFAULT_AGENT_ID,
      ),
      state,
      currentRound:
        typeof typed.currentRound === "number" && Number.isFinite(typed.currentRound)
          ? Math.max(1, Math.floor(typed.currentRound))
          : 1,
      maxRounds:
        typeof typed.maxRounds === "number" && Number.isFinite(typed.maxRounds)
          ? Math.max(1, Math.floor(typed.maxRounds))
          : 2,
      priority,
      createdAt:
        typeof typed.createdAt === "number" && Number.isFinite(typed.createdAt)
          ? typed.createdAt
          : Date.now(),
      updatedAt:
        typeof typed.updatedAt === "number" && Number.isFinite(typed.updatedAt)
          ? typed.updatedAt
          : Date.now(),
      startedBySessionKey:
        typeof typed.startedBySessionKey === "string" && typed.startedBySessionKey
          ? typed.startedBySessionKey
          : undefined,
      closedAt:
        typeof typed.closedAt === "number" && Number.isFinite(typed.closedAt)
          ? typed.closedAt
          : undefined,
      closeReason:
        typeof typed.closeReason === "string" && typed.closeReason ? typed.closeReason : undefined,
      checkpoints: checkpoints.map((value) => {
        const checkpoint = value as Partial<ResearchLoopCheckpointRecord>;
        const importance = normalizeRating(checkpoint.importance);
        const urgency = normalizeRating(checkpoint.urgency);
        const confidence = normalizeRating(checkpoint.confidence);
        const evidenceQuality = normalizeRating(checkpoint.evidenceQuality);
        const citationLinks = normalizeStringList(checkpoint.citationLinks, {
          maxItems: 20,
          maxChars: 500,
        });
        const counterpoints = normalizeStringList(checkpoint.counterpoints, {
          maxItems: 10,
          maxChars: 280,
        });
        const proposedTasks = normalizeStringList(checkpoint.proposedTasks, {
          maxItems: 20,
          maxChars: 280,
        });
        const whyNow = normalizeWhyNow(checkpoint.whyNow);
        const analysisQualityScoreRaw = normalizeQualityScore(checkpoint.analysisQualityScore);
        const normalized: ResearchLoopCheckpointRecord = {
          round:
            typeof checkpoint.round === "number" && Number.isFinite(checkpoint.round)
              ? Math.max(1, Math.floor(checkpoint.round))
              : 1,
          summary: typeof checkpoint.summary === "string" ? checkpoint.summary : "",
          critique: typeof checkpoint.critique === "string" ? checkpoint.critique : undefined,
          recommendation:
            checkpoint.recommendation === "continue" ||
            checkpoint.recommendation === "stop" ||
            checkpoint.recommendation === "needs_input"
              ? checkpoint.recommendation
              : "needs_input",
          proposedTasks,
          importance,
          urgency,
          confidence,
          evidenceQuality,
          citationLinks,
          counterpoints,
          whyNow,
          analysisQualityScore:
            analysisQualityScoreRaw ??
            computeResearchLoopAnalysisQualityScore({
              summary: typeof checkpoint.summary === "string" ? checkpoint.summary : "",
              critique: typeof checkpoint.critique === "string" ? checkpoint.critique : undefined,
              proposedTasks,
              evidenceQuality,
              citationLinks,
              counterpoints,
              whyNow,
            }),
          priorityScore:
            typeof checkpoint.priorityScore === "number" &&
            Number.isFinite(checkpoint.priorityScore)
              ? checkpoint.priorityScore
              : importance !== undefined && urgency !== undefined
                ? importance * urgency
                : undefined,
          createdAt:
            typeof checkpoint.createdAt === "number" && Number.isFinite(checkpoint.createdAt)
              ? checkpoint.createdAt
              : Date.now(),
        };
        return normalized;
      }),
      decisions: decisions as ResearchLoopDecisionRecord[],
    });
  }
  return out;
}

export function saveResearchLoopRegistryToDisk(runs: Map<string, ResearchLoopRecord>) {
  const pathname = resolveResearchLoopRegistryPath();
  saveJsonFile(pathname, serializeResearchLoopRegistry(runs));
}

async function saveResearchLoopRegistryUnlocked(
  pathname: string,
  runs: Map<string, ResearchLoopRecord>,
): Promise<void> {
  const payload = `${JSON.stringify(serializeResearchLoopRegistry(runs), null, 2)}\n`;
  await fs.promises.mkdir(path.dirname(pathname), { recursive: true });
  if (process.platform === "win32") {
    await fs.promises.writeFile(pathname, payload, "utf8");
    return;
  }

  const tmp = `${pathname}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await fs.promises.writeFile(tmp, payload, { mode: 0o600, encoding: "utf8" });
  await fs.promises.rename(tmp, pathname);
  await fs.promises.chmod(pathname, 0o600);
  await fs.promises.rm(tmp, { force: true });
}

type ResearchLoopRegistryLockOptions = {
  timeoutMs?: number;
  pollIntervalMs?: number;
  staleMs?: number;
};

async function withResearchLoopRegistryLock<T>(
  pathname: string,
  fn: () => Promise<T>,
  opts: ResearchLoopRegistryLockOptions = {},
): Promise<T> {
  const timeoutMs = opts.timeoutMs ?? 10_000;
  const pollIntervalMs = opts.pollIntervalMs ?? 25;
  const staleMs = opts.staleMs ?? 30_000;
  const lockPath = `${pathname}.lock`;
  const startedAt = Date.now();

  await fs.promises.mkdir(path.dirname(pathname), { recursive: true });

  while (true) {
    try {
      const handle = await fs.promises.open(lockPath, "wx");
      await handle.writeFile(JSON.stringify({ pid: process.pid, startedAt: Date.now() }), "utf8");
      await handle.close();
      break;
    } catch (error) {
      const code =
        error && typeof error === "object" && "code" in error
          ? String((error as { code?: unknown }).code)
          : null;
      if (code !== "EEXIST") {
        throw error;
      }
      if (Date.now() - startedAt > timeoutMs) {
        throw new Error(`timeout acquiring research loop registry lock: ${lockPath}`);
      }
      try {
        const st = await fs.promises.stat(lockPath);
        if (Date.now() - st.mtimeMs > staleMs) {
          await fs.promises.unlink(lockPath);
          continue;
        }
      } catch {
        // ignore stale lock check failures
      }
      await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
    }
  }

  try {
    return await fn();
  } finally {
    await fs.promises.unlink(lockPath).catch(() => undefined);
  }
}

export async function updateResearchLoopRegistry<T>(
  mutator: (runs: Map<string, ResearchLoopRecord>) => Promise<T> | T,
): Promise<T> {
  const pathname = resolveResearchLoopRegistryPath();
  return await withResearchLoopRegistryLock(pathname, async () => {
    const runs = loadResearchLoopRegistryFromDisk();
    const result = await mutator(runs);
    await saveResearchLoopRegistryUnlocked(pathname, runs);
    return result;
  });
}
