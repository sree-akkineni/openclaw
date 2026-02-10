/**
 * Workaround for undici TLS race condition on Node 22.
 *
 * undici@7.x can trigger a reconnect (via `tls.connect`) on a socket whose
 * internal `_handle` has already been destroyed. Node's `_tls_wrap.js` then
 * calls `this._handle.setServername(...)` or `this._handle.setSession(...)`
 * on `null`, throwing an uncaught TypeError that crashes the process.
 *
 * This guard patches both methods to silently return when the handle is gone.
 * Import this module as early as possible (before any TLS connections).
 *
 * @see https://github.com/nodejs/undici/issues/3492
 */

import tls from "node:tls";

const TLS_METHODS = ["setServername", "setSession"] as const;
const tlsSocketPrototype = tls.TLSSocket.prototype as unknown as Record<string, unknown>;

for (const method of TLS_METHODS) {
  const original = tlsSocketPrototype[method];
  if (typeof original !== "function") {
    continue;
  }
  const originalMethod = original as (...args: unknown[]) => unknown;

  tlsSocketPrototype[method] = function (this: tls.TLSSocket, ...args: unknown[]) {
    if (!(this as unknown as { _handle?: unknown })._handle) {
      return;
    }
    return originalMethod.apply(this, args);
  };
}
