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

for (const method of TLS_METHODS) {
  const original = tls.TLSSocket.prototype[method] as ((...args: unknown[]) => unknown) | undefined;
  if (!original) continue;

  (tls.TLSSocket.prototype as Record<string, unknown>)[method] = function (
    this: tls.TLSSocket,
    ...args: unknown[]
  ) {
    // biome-ignore lint/suspicious/noExplicitAny: accessing internal Node field
    if (!(this as any)._handle) return;
    return original.apply(this, args);
  };
}
