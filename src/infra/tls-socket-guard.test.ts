import tls from "node:tls";
import { describe, expect, it } from "vitest";
// Importing the guard patches TLSSocket.prototype.
import "./tls-socket-guard.js";

describe("tls-socket-guard", () => {
  it("setServername does not throw when _handle is null", () => {
    const socket = new tls.TLSSocket(null as never);
    // biome-ignore lint/suspicious/noExplicitAny: simulating destroyed socket
    (socket as any)._handle = null;
    expect(() => socket.setServername("example.com")).not.toThrow();
  });

  it("setSession does not throw when _handle is null", () => {
    const socket = new tls.TLSSocket(null as never);
    // biome-ignore lint/suspicious/noExplicitAny: simulating destroyed socket
    (socket as any)._handle = null;
    expect(() => socket.setSession(Buffer.from("test"))).not.toThrow();
  });
});
