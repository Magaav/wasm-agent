// One Node runtime boundary for every CDP client. Node 20+ exposes WebSocket globally; the Node 18
// runtime used by the Linux gate exposes the same WHATWG interface through undici instead.
import { createRequire } from "node:module";

let RuntimeWebSocket = globalThis.WebSocket;
if (typeof RuntimeWebSocket !== "function") {
  try {
    RuntimeWebSocket = createRequire(import.meta.url)("undici").WebSocket;
  } catch (error) {
    throw new Error("a WHATWG WebSocket implementation is required (native WebSocket or undici)", { cause: error });
  }
}

export { RuntimeWebSocket as WebSocket };
