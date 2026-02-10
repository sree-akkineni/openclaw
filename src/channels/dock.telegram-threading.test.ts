import { describe, expect, it } from "vitest";
import { getChannelDock } from "./dock.js";

describe("telegram dock buildToolContext threading", () => {
  const dock = getChannelDock("telegram");
  const buildToolContext = dock!.threading!.buildToolContext!;

  it("uses MessageThreadId for forum topic threads", () => {
    const result = buildToolContext({
      context: {
        To: "telegram:123",
        MessageThreadId: 42,
        ReplyToId: "999",
      } as never,
      hasRepliedRef: { current: false },
    });
    expect(result.currentThreadTs).toBe("42");
    expect(result.currentChannelId).toBe("telegram:123");
  });

  it("does NOT use ReplyToId as thread ID in DMs", () => {
    // In DMs, MessageThreadId is undefined. ReplyToId is a regular message ID
    // (for reply chains), NOT a forum topic ID. Using it as message_thread_id
    // causes "400: Bad Request: message thread not found" from Telegram.
    const result = buildToolContext({
      context: {
        To: "telegram:5944352446",
        MessageThreadId: undefined,
        ReplyToId: "12345",
      } as never,
      hasRepliedRef: { current: false },
    });
    expect(result.currentThreadTs).toBeUndefined();
  });

  it("returns undefined currentThreadTs when both MessageThreadId and ReplyToId are absent", () => {
    const result = buildToolContext({
      context: {
        To: "telegram:123",
      } as never,
      hasRepliedRef: { current: false },
    });
    expect(result.currentThreadTs).toBeUndefined();
  });
});
