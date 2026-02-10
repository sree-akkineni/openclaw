import { Type } from "@sinclair/typebox";
import crypto from "node:crypto";
import type { AnyAgentTool } from "./common.js";
import { resolveAgentIdFromSessionKey } from "../../routing/session-key.js";
import {
  computeResearchLoopAnalysisQualityScore,
  loadResearchLoopRegistryFromDisk,
  updateResearchLoopRegistry,
  type ResearchLoopPriority,
  type ResearchLoopRecord,
  type ResearchLoopRecommendation,
  type ResearchLoopState,
} from "../research-loop-registry.store.js";
import { optionalStringEnum, stringEnum } from "../schema/typebox.js";
import { jsonResult, readNumberParam, readStringArrayParam, readStringParam } from "./common.js";

const LOOP_ACTIONS = ["start", "checkpoint", "continue", "status", "list", "close"] as const;
const LOOP_PRIORITIES = ["low", "normal", "high"] as const;
const LOOP_RECOMMENDATIONS = ["continue", "stop", "needs_input"] as const;
const LOOP_STATES = ["active", "awaiting_decision", "closed"] as const;
const LOOP_VIEWS = ["all", "needs_decision", "needs_review", "hot", "stale"] as const;

const ResearchLoopToolSchema = Type.Object({
  action: stringEnum(LOOP_ACTIONS),
  loopId: Type.Optional(Type.String()),
  topic: Type.Optional(Type.String()),
  priority: optionalStringEnum(LOOP_PRIORITIES),
  maxRounds: Type.Optional(Type.Number({ minimum: 1, maximum: 20 })),
  summary: Type.Optional(Type.String()),
  critique: Type.Optional(Type.String()),
  recommendation: optionalStringEnum(LOOP_RECOMMENDATIONS),
  proposedTasks: Type.Optional(Type.Array(Type.String())),
  importance: Type.Optional(Type.Number({ minimum: 1, maximum: 5 })),
  urgency: Type.Optional(Type.Number({ minimum: 1, maximum: 5 })),
  confidence: Type.Optional(Type.Number({ minimum: 1, maximum: 5 })),
  evidenceQuality: Type.Optional(Type.Number({ minimum: 1, maximum: 5 })),
  citationLinks: Type.Optional(Type.Array(Type.String())),
  counterpoints: Type.Optional(Type.Array(Type.String())),
  whyNow: Type.Optional(Type.String()),
  reason: Type.Optional(Type.String()),
  state: optionalStringEnum(LOOP_STATES),
  view: optionalStringEnum(LOOP_VIEWS),
  limit: Type.Optional(Type.Number({ minimum: 1, maximum: 100 })),
  staleHours: Type.Optional(Type.Number({ minimum: 1, maximum: 720 })),
});

type ResearchLoopListView = (typeof LOOP_VIEWS)[number];

function normalizePriority(value: unknown): ResearchLoopPriority {
  if (value === "low" || value === "high") {
    return value;
  }
  return "normal";
}

function normalizeRecommendation(value: unknown): ResearchLoopRecommendation {
  if (value === "continue" || value === "stop") {
    return value;
  }
  return "needs_input";
}

function normalizeStateFilter(value: unknown): ResearchLoopState | undefined {
  if (value === "active" || value === "awaiting_decision" || value === "closed") {
    return value;
  }
  return undefined;
}

function normalizeListView(value: unknown): ResearchLoopListView {
  if (
    value === "needs_decision" ||
    value === "needs_review" ||
    value === "hot" ||
    value === "stale"
  ) {
    return value;
  }
  return "all";
}

function normalizeMaxRounds(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return 2;
  }
  const rounded = Math.floor(value);
  if (rounded < 1) {
    return 1;
  }
  if (rounded > 20) {
    return 20;
  }
  return rounded;
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

function normalizeStaleHours(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return 24;
  }
  const rounded = Math.floor(value);
  if (rounded < 1) {
    return 1;
  }
  if (rounded > 720) {
    return 720;
  }
  return rounded;
}

function sanitizeStringList(
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

function sanitizeProposedTasks(value: unknown): string[] | undefined {
  return sanitizeStringList(value, { maxItems: 20, maxChars: 280 });
}

function sanitizeWhyNow(value: string | undefined): string | undefined {
  if (!value) {
    return undefined;
  }
  return value.slice(0, 280);
}

function resolveLatestPriorityScore(loop: ResearchLoopRecord): number {
  const latest = loop.checkpoints.at(-1);
  return latest?.priorityScore ?? 0;
}

function resolveLatestAnalysisQualityScore(loop: ResearchLoopRecord): number {
  const latest = loop.checkpoints.at(-1);
  return latest?.analysisQualityScore ?? 0;
}

function checkpointNeedsReview(loop: ResearchLoopRecord): boolean {
  const latest = loop.checkpoints.at(-1);
  if (!latest) {
    return false;
  }
  if ((latest.analysisQualityScore ?? 0) < 65) {
    return true;
  }
  if (!latest.critique?.trim()) {
    return true;
  }
  if ((latest.citationLinks?.length ?? 0) < 1) {
    return true;
  }
  return false;
}

function buildSpawnAdvice(params: { loop: ResearchLoopRecord; canContinue: boolean }): {
  shouldSpawn: boolean;
  reason: string;
  suggestedTask?: string;
} {
  const latest = params.loop.checkpoints.at(-1);
  if (!latest) {
    return { shouldSpawn: false, reason: "No checkpoint available." };
  }
  if (latest.recommendation !== "continue") {
    return { shouldSpawn: false, reason: "Checkpoint recommendation is not continue." };
  }
  if (!params.canContinue) {
    return { shouldSpawn: false, reason: "Max rounds reached; review or close." };
  }
  const task = latest.proposedTasks?.[0];
  if (!task) {
    return { shouldSpawn: false, reason: "No proposed tasks to delegate." };
  }
  if ((latest.analysisQualityScore ?? 0) < 40) {
    return {
      shouldSpawn: false,
      reason: "Analysis quality is too low; improve checkpoint quality first.",
    };
  }
  if (latest.confidence !== undefined && latest.confidence >= 4) {
    return { shouldSpawn: false, reason: "Confidence is already high; delegation is optional." };
  }
  const highPriority = (latest.priorityScore ?? 0) >= 12 || params.loop.priority === "high";
  if (!highPriority) {
    return {
      shouldSpawn: false,
      reason: "Priority score is below delegation threshold.",
    };
  }
  return {
    shouldSpawn: true,
    reason: "High-priority, unresolved checkpoint with clear follow-up task.",
    suggestedTask: task,
  };
}

function toLoopDetails(loop: ResearchLoopRecord) {
  return {
    loopId: loop.loopId,
    topic: loop.topic,
    ownerAgentId: loop.ownerAgentId,
    state: loop.state,
    currentRound: loop.currentRound,
    maxRounds: loop.maxRounds,
    priority: loop.priority,
    createdAt: loop.createdAt,
    updatedAt: loop.updatedAt,
    closedAt: loop.closedAt,
    closeReason: loop.closeReason,
    remainingRounds: Math.max(0, loop.maxRounds - loop.currentRound),
    startedBySessionKey: loop.startedBySessionKey,
    lastCheckpoint: loop.checkpoints.at(-1),
    checkpoints: loop.checkpoints,
    decisions: loop.decisions,
  };
}

type LoopLookup =
  | {
      ok: true;
      loop: ResearchLoopRecord;
    }
  | {
      ok: false;
      error: string;
    };

function getLoopOrError(
  registry: Map<string, ResearchLoopRecord>,
  loopId: string | undefined,
  requesterAgentId: string,
): LoopLookup {
  if (!loopId) {
    return { ok: false, error: "loopId required" };
  }
  const loop = registry.get(loopId);
  if (!loop) {
    return { ok: false, error: `research loop not found: ${loopId}` };
  }
  if (loop.ownerAgentId !== requesterAgentId) {
    return { ok: false, error: `research loop not accessible: ${loopId}` };
  }
  return { ok: true, loop };
}

export function createResearchLoopTool(opts?: { agentSessionKey?: string }): AnyAgentTool {
  return {
    label: "Sessions",
    name: "research_loop",
    description:
      "Manage multi-round research loops with explicit checkpoints, critical synthesis, and user-gated continuation.",
    parameters: ResearchLoopToolSchema,
    execute: async (_toolCallId, args) => {
      const params = args as Record<string, unknown>;
      try {
        const action = readStringParam(params, "action", { required: true });
        const requesterAgentId = resolveAgentIdFromSessionKey(opts?.agentSessionKey);

        if (action === "start") {
          const topic = readStringParam(params, "topic", { required: true });
          const maxRounds = normalizeMaxRounds(readNumberParam(params, "maxRounds"));
          const priority = normalizePriority(params.priority);
          return await updateResearchLoopRegistry((registry) => {
            const now = Date.now();
            const loopId = crypto.randomUUID();
            const loop: ResearchLoopRecord = {
              loopId,
              topic,
              ownerAgentId: requesterAgentId,
              state: "active",
              currentRound: 1,
              maxRounds,
              priority,
              createdAt: now,
              updatedAt: now,
              startedBySessionKey: opts?.agentSessionKey,
              checkpoints: [],
              decisions: [],
            };
            registry.set(loopId, loop);
            return jsonResult({
              status: "started",
              loop: toLoopDetails(loop),
            });
          });
        }

        if (action === "checkpoint") {
          const loopId = readStringParam(params, "loopId", { required: true });
          const summary = readStringParam(params, "summary", { required: true });
          const critique = readStringParam(params, "critique");
          const recommendation = normalizeRecommendation(params.recommendation);
          const proposedTasks =
            sanitizeProposedTasks(params.proposedTasks) ??
            readStringArrayParam(params, "proposedTasks", { allowEmpty: false });
          const importance = normalizeRating(readNumberParam(params, "importance"));
          const urgency = normalizeRating(readNumberParam(params, "urgency"));
          const confidence = normalizeRating(readNumberParam(params, "confidence"));
          const evidenceQuality = normalizeRating(readNumberParam(params, "evidenceQuality"));
          const citationLinks =
            sanitizeStringList(params.citationLinks, { maxItems: 20, maxChars: 500 }) ??
            readStringArrayParam(params, "citationLinks", { allowEmpty: false });
          const counterpoints =
            sanitizeStringList(params.counterpoints, { maxItems: 10, maxChars: 280 }) ??
            readStringArrayParam(params, "counterpoints", { allowEmpty: false });
          const whyNow = sanitizeWhyNow(readStringParam(params, "whyNow"));
          const priorityScore =
            importance !== undefined && urgency !== undefined ? importance * urgency : undefined;
          const analysisQualityScore = computeResearchLoopAnalysisQualityScore({
            summary,
            critique,
            proposedTasks,
            evidenceQuality,
            citationLinks,
            counterpoints,
            whyNow,
          });
          return await updateResearchLoopRegistry((registry) => {
            const loopLookup = getLoopOrError(registry, loopId, requesterAgentId);
            if (!loopLookup.ok) {
              return jsonResult({ status: "error", error: loopLookup.error });
            }
            const loop = loopLookup.loop;
            if (loop.state === "closed") {
              return jsonResult({ status: "error", error: "loop is closed" });
            }
            if (loop.state !== "active") {
              return jsonResult({
                status: "error",
                error: `loop must be active to checkpoint (current state: ${loop.state})`,
              });
            }
            const now = Date.now();
            loop.checkpoints.push({
              round: loop.currentRound,
              summary,
              critique,
              recommendation,
              proposedTasks,
              importance,
              urgency,
              confidence,
              evidenceQuality,
              citationLinks,
              counterpoints,
              whyNow,
              analysisQualityScore,
              priorityScore,
              createdAt: now,
            });
            loop.state = "awaiting_decision";
            loop.updatedAt = now;
            const canContinue = recommendation === "continue" && loop.currentRound < loop.maxRounds;
            return jsonResult({
              status: "checkpointed",
              loop: toLoopDetails(loop),
              canContinue,
              spawnAdvice: buildSpawnAdvice({ loop, canContinue }),
            });
          });
        }

        if (action === "continue") {
          const loopId = readStringParam(params, "loopId", { required: true });
          const reason = readStringParam(params, "reason");
          return await updateResearchLoopRegistry((registry) => {
            const loopLookup = getLoopOrError(registry, loopId, requesterAgentId);
            if (!loopLookup.ok) {
              return jsonResult({ status: "error", error: loopLookup.error });
            }
            const loop = loopLookup.loop;
            if (loop.state === "closed") {
              return jsonResult({ status: "error", error: "loop is closed" });
            }
            if (loop.state !== "awaiting_decision") {
              return jsonResult({
                status: "error",
                error: `loop is not awaiting_decision (current state: ${loop.state})`,
              });
            }
            if (loop.currentRound >= loop.maxRounds) {
              return jsonResult({
                status: "error",
                error: `cannot continue: max rounds reached (${loop.maxRounds})`,
              });
            }
            const now = Date.now();
            const decisionRound = loop.currentRound;
            loop.decisions.push({
              round: decisionRound,
              decision: "continue",
              reason,
              createdAt: now,
            });
            loop.currentRound = decisionRound + 1;
            loop.state = "active";
            loop.updatedAt = now;
            return jsonResult({
              status: "continued",
              loop: toLoopDetails(loop),
            });
          });
        }

        if (action === "status") {
          const loopId = readStringParam(params, "loopId", { required: true });
          const registry = loadResearchLoopRegistryFromDisk();
          const loopLookup = getLoopOrError(registry, loopId, requesterAgentId);
          if (!loopLookup.ok) {
            return jsonResult({ status: "error", error: loopLookup.error });
          }
          return jsonResult({
            status: "ok",
            loop: toLoopDetails(loopLookup.loop),
          });
        }

        if (action === "list") {
          const state = normalizeStateFilter(params.state);
          const view = normalizeListView(params.view);
          const staleHours = normalizeStaleHours(readNumberParam(params, "staleHours"));
          const limitRaw = readNumberParam(params, "limit");
          const limit =
            limitRaw && Number.isFinite(limitRaw) ? Math.min(100, Math.max(1, limitRaw)) : 20;
          const staleCutoff = Date.now() - staleHours * 60 * 60 * 1000;
          let loops = Array.from(loadResearchLoopRegistryFromDisk().values()).filter(
            (loop) => loop.ownerAgentId === requesterAgentId,
          );
          if (state) {
            loops = loops.filter((loop) => loop.state === state);
          }
          if (view === "needs_decision") {
            loops = loops.filter((loop) => loop.state === "awaiting_decision");
          } else if (view === "needs_review") {
            loops = loops.filter(
              (loop) => loop.state === "awaiting_decision" && checkpointNeedsReview(loop),
            );
          } else if (view === "hot") {
            loops = loops.filter((loop) => loop.state === "awaiting_decision");
          } else if (view === "stale") {
            loops = loops.filter(
              (loop) => loop.state === "active" && loop.updatedAt <= staleCutoff,
            );
          }
          if (view === "hot") {
            loops.sort((a, b) => {
              const scoreDelta = resolveLatestPriorityScore(b) - resolveLatestPriorityScore(a);
              if (scoreDelta !== 0) {
                return scoreDelta;
              }
              const qualityDelta =
                resolveLatestAnalysisQualityScore(b) - resolveLatestAnalysisQualityScore(a);
              if (qualityDelta !== 0) {
                return qualityDelta;
              }
              return b.updatedAt - a.updatedAt;
            });
          } else {
            loops.sort((a, b) => b.updatedAt - a.updatedAt);
          }
          return jsonResult({
            status: "ok",
            loops: loops.slice(0, limit).map((loop) => {
              const lastCheckpoint = loop.checkpoints.at(-1);
              return {
                loopId: loop.loopId,
                topic: loop.topic,
                state: loop.state,
                currentRound: loop.currentRound,
                maxRounds: loop.maxRounds,
                priority: loop.priority,
                updatedAt: loop.updatedAt,
                lastCheckpointAt: lastCheckpoint?.createdAt,
                lastRecommendation: lastCheckpoint?.recommendation,
                lastAnalysisQualityScore: lastCheckpoint?.analysisQualityScore,
                lastCitationCount: lastCheckpoint?.citationLinks?.length ?? 0,
                lastPriorityScore: lastCheckpoint?.priorityScore,
                needsReview: checkpointNeedsReview(loop),
              };
            }),
          });
        }

        if (action === "close") {
          const loopId = readStringParam(params, "loopId", { required: true });
          const reason = readStringParam(params, "reason");
          return await updateResearchLoopRegistry((registry) => {
            const loopLookup = getLoopOrError(registry, loopId, requesterAgentId);
            if (!loopLookup.ok) {
              return jsonResult({ status: "error", error: loopLookup.error });
            }
            const loop = loopLookup.loop;
            if (loop.state !== "closed") {
              const now = Date.now();
              loop.state = "closed";
              loop.closedAt = now;
              loop.closeReason = reason;
              loop.updatedAt = now;
              loop.decisions.push({
                round: loop.currentRound,
                decision: "close",
                reason,
                createdAt: now,
              });
            }
            return jsonResult({
              status: "closed",
              loop: toLoopDetails(loop),
            });
          });
        }

        return jsonResult({
          status: "error",
          error: `unsupported action: ${action}`,
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return jsonResult({
          status: "error",
          error: message,
        });
      }
    },
  };
}
