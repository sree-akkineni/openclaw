// Formats a concise, human-readable notification for research loop state changes.
// Used by handleToolExecutionEnd to notify users regardless of verbose level.

const NOTIFIABLE_STATUSES = new Set(["started", "checkpointed", "continued", "closed"]);
const MAX_TOPIC_LENGTH = 60;

function truncateTopic(topic: string): string {
  const trimmed = topic.trim();
  if (trimmed.length <= MAX_TOPIC_LENGTH) {
    return trimmed;
  }
  return `${trimmed.slice(0, MAX_TOPIC_LENGTH - 3)}...`;
}

export function formatResearchLoopNotification(result: unknown): string | undefined {
  if (!result || typeof result !== "object") {
    return undefined;
  }
  const record = result as Record<string, unknown>;
  const details = record.details;
  if (!details || typeof details !== "object") {
    return undefined;
  }
  const d = details as Record<string, unknown>;
  const status = typeof d.status === "string" ? d.status : undefined;
  if (!status || !NOTIFIABLE_STATUSES.has(status)) {
    return undefined;
  }

  const loop =
    d.loop && typeof d.loop === "object" ? (d.loop as Record<string, unknown>) : undefined;
  const topic = typeof loop?.topic === "string" ? truncateTopic(loop.topic) : "research";
  const round = typeof loop?.currentRound === "number" ? loop.currentRound : undefined;
  const maxRounds = typeof loop?.maxRounds === "number" ? loop.maxRounds : undefined;
  const roundInfo =
    round !== undefined && maxRounds !== undefined ? ` (${round}/${maxRounds})` : "";

  switch (status) {
    case "started":
      return `🔬 Research started: ${topic}${roundInfo}`;
    case "checkpointed":
      return `📋 Research checkpoint: ${topic}${roundInfo}`;
    case "continued":
      return `🔄 Research continuing: ${topic}${roundInfo}`;
    case "closed":
      return `✅ Research closed: ${topic}`;
    default:
      return undefined;
  }
}
