// The adapter: reach the app's own modules, so a reply is sent through the app's action instead of by
// driving its UI.
//
//   node scripts/whatsapp-adapter.mjs install           # add the document-start hook, reload the tab
//   node scripts/whatsapp-adapter.mjs find <regex>      # module names matching a pattern
//   node scripts/whatsapp-adapter.mjs dump <file>       # every recorded name (JSON)
//   node scripts/whatsapp-adapter.mjs source <name>     # the module's own factory source
//   node scripts/whatsapp-adapter.mjs eval <expr>       # evaluate in the page (for probing a module)
//
// Why this and not a DLL injector: the blocker was never "we cannot get code into the page" - CDP's
// `Page.addScriptToEvaluateOnNewDocument` runs a script in the page's own world before any of the app's
// code, which is the same layer an injected DLL would have to reach for, with none of the cost: no
// injection, no sandbox escape, no 64-bit/32-bit problem, nothing foreign in the process holding the
// session.
//
// This build is **not webpack**: it uses Meta's Comet module system (`__d(name, deps, factory)` plus
// `require`, `requireLazy`, `requireInterop`, `requireDynamic`), so `window.require` resolves a name
// but exposes no cache to enumerate. `__d` is the define call, so wrapping it lists every module the
// bundle defines - including the names that cannot be guessed (the Msg model, the unread command, the
// send action) - and the wrapper keeps the *factory*, whose source gives the call shape instead of
// leaving it to be guessed.
//
// Two lessons are baked in, both learned by getting them wrong first:
//   - **value-wrap, then re-wrap.** The bundle installs `__d` and later replaces it, and it uses
//     `Object.defineProperty`, which replaces a configurable accessor *without* calling its setter - so
//     a property trap records nothing (it recorded 0) while a value wrapper recorded 189 names before
//     being replaced. The hook therefore value-wraps and polls, re-wrapping whenever the bundle has put
//     its own function back.
//   - **fail open.** A hook that breaks the page is worse than no hook: it runs before the app does, so
//     every trap swallows its own errors and does nothing but record.
const PORTS = [9222];
const HOSTS = ["127.0.0.1", "[::1]"];

async function text(url, init, timeoutMs = 4000) {
  try {
    const response = await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    return await response.text();
  } catch { return ""; }
}

async function connect() {
  for (const port of PORTS) {
    for (const host of HOSTS) {
      const body = await text(`http://${host}:${port}/json/version`);
      try {
        const version = JSON.parse(body);
        if (!version.webSocketDebuggerUrl) continue;
        const targets = JSON.parse(await text(`http://${host}:${port}/json/list`));
        const tab = (targets || []).filter((t) => t.type === "page").find((t) => (t.url || "").includes("web.whatsapp.com"));
        if (!tab) { console.log(JSON.stringify({ error: "no_whatsapp_tab" })); process.exit(3); }
        const ws = new WebSocket(tab.webSocketDebuggerUrl);
        let id = 0; const pending = new Map();
        ws.addEventListener("message", (event) => {
          const message = JSON.parse(event.data);
          if (pending.has(message.id)) { pending.get(message.id)(message.result); pending.delete(message.id); }
        });
        await new Promise((resolve, reject) => {
          ws.addEventListener("open", resolve, { once: true });
          ws.addEventListener("error", () => reject(new Error("websocket refused")), { once: true });
        });
        const call = (method, params = {}, timeoutMs = 30000) => new Promise((resolve, reject) => {
          const n = ++id; pending.set(n, resolve);
          ws.send(JSON.stringify({ id: n, method, params }));
          setTimeout(() => reject(new Error(`timeout: ${method}`)), timeoutMs);
        });
        const evaluate = async (expression) => {
          const out = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
          if (out.exceptionDetails) throw new Error(String((out.exceptionDetails.exception && out.exceptionDetails.exception.description) || out.exceptionDetails.text).slice(0, 300));
          return out.result.value;
        };
        return { ws, call, evaluate, host, port };
      } catch { /* next candidate */ }
    }
  }
  console.log(JSON.stringify({ error: "no_cdp_endpoint" }));
  process.exit(3);
}

// The hook. Every line here runs before the app, on every page load.
const HOOK = [
  "(() => {",
  "  const state = window.__wa_adapter = window.__wa_adapter || { names: [], factories: {}, rewraps: 0, errors: [], polls: 0 };",
  "  const note = (name, factory) => {",
  "    if (typeof name !== 'string' || !name) return;",
  "    if (!(name in state.factories)) state.names.push(name);",
  "    state.factories[name] = factory;",
  "  };",
  "  const wrap = (original) => {",
  "    if (typeof original !== 'function') return original;",
  "    const wrapped = function (name, deps, factory) {",
  "      try { note(name, factory); } catch (e) { state.errors.push('note: ' + String(e).slice(0, 50)); }",
  "      return original.apply(this, arguments);",
  "    };",
  "    wrapped.__wa_wrapped = true;",
  "    return wrapped;",
  "  };",
  "  const install = () => {",
  "    const current = window.__d;",
  "    if (typeof current !== 'function') return false;",
  "    if (current.__wa_wrapped) return true;",
  "    const wrapped = wrap(current);",
  "    try { window.__d = wrapped; } catch (e) { state.errors.push('assign: ' + String(e).slice(0, 50)); return false; }",
  "    return window.__d === wrapped;",
  "  };",
  "  const tick = () => {",
  "    state.polls += 1;",
  "    try { if (install()) state.rewraps += 0; } catch (e) { state.errors.push('tick: ' + String(e).slice(0, 50)); }",
  "    if (state.polls < 1200) setTimeout(tick, 250);",
  "  };",
  "  tick();",
  "})();",
].join("\n");

const command = process.argv[2] || "status";
const argument = process.argv[3] || "";
const connection = await connect();

if (command === "install" || command === "learn") {
  await connection.call("Page.enable", {});
  await connection.call("Page.addScriptToEvaluateOnNewDocument", { source: HOOK });
  await connection.call("Page.reload", { ignoreCache: false });
  // The registered script belongs to *this* CDP session, so the session has to stay open while the page
  // loads or it is gone before the document-start script runs (which is exactly how this failed first:
  // `window.__wa_adapter` was null, the script never executed). Keeping the connection until the hook
  // reports in is the whole difference.
  let ready = false;
  for (let attempt = 0; attempt < 24 && !ready; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 2500));
    try {
      const probe = await connection.evaluate("JSON.stringify({ hook: typeof window.__wa_adapter, names: window.__wa_adapter ? window.__wa_adapter.names.length : 0, title: document.title })");
      const seen = JSON.parse(probe);
      console.log(`t+${(attempt + 1) * 2.5}s ${probe}`);
      ready = seen.names > 0;
    } catch (error) { console.log(`t+${(attempt + 1) * 2.5}s ${String(error.message).slice(0, 60)}`); }
  }
  if (!ready) { console.log(JSON.stringify({ ok: false, error: "hook_recorded_nothing" })); connection.ws.close(); process.exit(5); }
  // Give the app a moment to define the rest, then dump everything it saw.
  await new Promise((resolve) => setTimeout(resolve, 8000));
  const all = JSON.parse(await connection.evaluate("JSON.stringify(window.__wa_adapter.names)"));
  const names = Array.from(new Set(all));
  const fs = await import("node:fs");
  const target = command === "dump" && argument ? argument : "wa-module-names.json";
  fs.writeFileSync(target, JSON.stringify(names, null, 1));
  const interesting = names.filter((name) => /SendMsg|Unread|MarkRead|MsgKey|MsgModel|OpenChat|ChatOpen|ReadReceipt/i.test(name)).sort();
  console.log(JSON.stringify({ ok: true, wrote: target, names: names.length, interesting }, null, 1));
} else if (command === "eval") {
  console.log(await connection.evaluate(argument));
} else if (command === "source") {
  const source = await connection.evaluate(`(() => { const f = (window.__wa_adapter && window.__wa_adapter.factories[${JSON.stringify(argument)}]) || null; return f ? String(f) : 'not recorded'; })()`);
  console.log(typeof source === "string" ? source.slice(0, 6000) : JSON.stringify(source));
} else {
  const names = await connection.evaluate("JSON.stringify(window.__wa_adapter ? window.__wa_adapter.names : [])");
  const list = Array.from(new Set(JSON.parse(names || "[]")));
  if (command === "dump") {
    const fs = await import("node:fs");
    const target = argument || "wa-module-names.json";
    fs.writeFileSync(target, JSON.stringify(list, null, 1));
    console.log(JSON.stringify({ ok: true, wrote: target, names: list.length }));
  } else if (command === "find") {
    const pattern = new RegExp(argument || ".");
    const hits = list.filter((name) => pattern.test(name)).sort();
    console.log(JSON.stringify({ total: list.length, matching: hits.length, names: hits.slice(0, 60) }, null, 1));
  } else {
    const state = await connection.evaluate("JSON.stringify(window.__wa_adapter ? { names: window.__wa_adapter.names.length, rewraps: window.__wa_adapter.rewraps, polls: window.__wa_adapter.polls, errors: window.__wa_adapter.errors.slice(0, 5) } : null)");
    console.log(JSON.stringify({ recorded: list.length, state: JSON.parse(state || "null") }, null, 1));
  }
}
connection.ws.close();
