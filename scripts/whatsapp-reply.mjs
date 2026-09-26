// Read-only compatibility shim for resolving a WhatsApp chat/self id. Message sends and rehearsals
// must use whatsapp-store-send.mjs, which invokes the app action directly and never dispatches input.
//
//   node scripts/whatsapp-reply.mjs --to-self --lookup-only
//   node scripts/whatsapp-reply.mjs --chat <chat-id> --lookup-only

import { lookupExpression } from "./whatsapp-reply-core.mjs";
import { WebSocket } from "./lib/websocket-runtime.mjs";

const HOSTS = ["127.0.0.1", "[::1]"];
const WHATSAPP_URL = "web.whatsapp.com";

function parseArgs(argv) {
  const args = { chat: "", toSelf: false, lookupOnly: false, timeoutMs: 20000 };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index], value = argv[index + 1];
    if (flag === "--chat") { args.chat = String(value || ""); index += 1; }
    else if (flag === "--to-self") args.toSelf = true;
    else if (flag === "--lookup-only") args.lookupOnly = true;
    else if (flag === "--timeout-ms") { args.timeoutMs = Number(value) || 20000; index += 1; }
  }
  return args;
}

async function text(url, timeoutMs = 4000) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
    return await response.text();
  } catch { return ""; }
}

async function discover() {
  for (const port of [9222]) {
    for (const host of HOSTS) {
      try {
        const version = JSON.parse(await text(`http://${host}:${port}/json/version`));
        if (version.webSocketDebuggerUrl && version.Browser) return { host, port };
      } catch { /* not DevTools */ }
    }
  }
  return null;
}

function call(ws, method, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = (call.next = (call.next || 0) + 1);
    const timer = setTimeout(() => reject(new Error(`timeout: ${method}`)), timeoutMs);
    const onMessage = (event) => {
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      if (message.id !== id) return;
      clearTimeout(timer);
      ws.removeEventListener("message", onMessage);
      message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result);
    };
    ws.addEventListener("message", onMessage);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.lookupOnly) {
    console.log(JSON.stringify({ ok: false, error: "ui_input_route_retired",
      next: "Use scripts/whatsapp-store-send.mjs with bound account/page identity; no UI/input fallback is available" }));
    process.exitCode = 5;
    return;
  }
  if (!args.toSelf && !args.chat) {
    console.log(JSON.stringify({ ok: false, error: "chat_required" }));
    process.exitCode = 1;
    return;
  }

  const endpoint = await discover();
  if (!endpoint) {
    console.log(JSON.stringify({ ok: false, error: "no_cdp_endpoint" }));
    process.exitCode = 3;
    return;
  }
  let targets;
  try { targets = JSON.parse(await text(`http://${endpoint.host}:${endpoint.port}/json/list`)); }
  catch {
    console.log(JSON.stringify({ ok: false, error: "target_list_unreadable" }));
    process.exitCode = 3;
    return;
  }
  const tab = (targets || []).filter((target) => target.type === "page")
    .find((target) => String(target.url || "").includes(WHATSAPP_URL));
  if (!tab || !tab.webSocketDebuggerUrl) {
    console.log(JSON.stringify({ ok: false, error: "no_whatsapp_tab" }));
    process.exitCode = 3;
    return;
  }

  const ws = new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket refused")), { once: true });
  });
  try {
    const result = await call(ws, "Runtime.evaluate", {
      expression: lookupExpression(args.chat, args.toSelf), returnByValue: true,
    }, args.timeoutMs);
    if (result && result.exceptionDetails) throw new Error(result.exceptionDetails.text || "page_threw");
    const found = JSON.parse(result.result.value);
    const browserEndpoint = `ws://${endpoint.host}:${endpoint.port}/devtools/page/${tab.id}`;
    const payload = found.error
      ? { ok: false, ...found, browser_endpoint: browserEndpoint }
      : { ok: true, lookup_only: true, ...found, browser_endpoint: browserEndpoint };
    console.log(JSON.stringify(payload));
    if (found.error) process.exitCode = 4;
  } finally {
    ws.close();
  }
}

main().catch((error) => {
  console.log(JSON.stringify({ ok: false, error: "lookup_failed", detail: String((error && error.message) || error) }));
  process.exitCode = 6;
});
