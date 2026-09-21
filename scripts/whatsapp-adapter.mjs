// The adapter route (a) needs: reach the app's own modules, which is what lets a reply be sent through
// the app's action instead of by driving its UI.
//
//   node scripts/whatsapp-adapter.mjs install      # add the document-start hook, then reload the tab
//   node scripts/whatsapp-adapter.mjs dump <file>  # write the module names the hook recorded
//   node scripts/whatsapp-adapter.mjs find <regex> # names matching a pattern
//
// Why this and not a DLL injector: the blocker was never "we cannot get code into the page" - CDP's
// `Page.addScriptToEvaluateOnNewDocument` runs a script in the page's own world before any of the app's
// code, which is the same layer an injected DLL would have to reach for, with none of the cost: no
// injection, no sandbox escape, no 64-bit/32-bit problem, nothing foreign in the process that holds the
// session. The blocker was that this build is **not webpack**: it uses Meta's Comet module system
// (`__d(name, deps, factory)`, plus `require`, `requireLazy`, `requireInterop`, `requireDynamic`), so
// `window.require` resolves a name but exposes no cache to enumerate - there is nothing to walk.
//
// `__d` is the define call, so wrapping it lists every module the bundle defines, including the ones
// whose names cannot be guessed (the Msg model, the unread command, the send action). And because the
// wrapper sees the *factory*, `String(factory)` is the module's own source: the call shape can be read
// instead of guessed.
//
// Two lessons are baked into the hook, both learned by getting them wrong first:
//   - trap the **property**, not the value. webpack created its registry and pushed into it in one
//     tick, and this bundle re-assigns `__d` later, so a wrapper installed on the value is silently
//     replaced: 189 modules recorded instead of thousands.
//   - it must **fail open**: if WhatsApp changes, the page must keep working. Every trap swallows its
//     own errors and does nothing but record.
//
// STATE: the *value* wrapper around `__d` records real module names (a first pass recorded 189, e.g.
// `WAWebVoipIncomingCallQpl`, `VultureJSSampleRatesLoader`), which proves the surface is reachable from
// a document-start script. The property trap below records **nothing** in this build: the bundle
// installs `__d` with `Object.defineProperty`, which replaces a configurable accessor without calling
// its setter. So the next step is the hybrid - value-wrap, then poll every few hundred milliseconds and
// re-wrap when the bundle has replaced it - rather than either variant alone.
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
          if (out.exceptionDetails) throw new Error(out.exceptionDetails.text || "page_threw");
          return JSON.parse(out.result.value);
        };
        return { ws, call, evaluate, host, port };
      } catch { /* next */ }
    }
  }
  console.log(JSON.stringify({ error: "no_cdp_endpoint" }));
  process.exit(3);
}

// The hook. Property traps that re-wrap on every assignment, so a later re-assignment cannot bypass
// them; every failure is recorded and swallowed so the page keeps working.
const HOOK = [
  "(() => {",
  "  const state = window.__wa_adapter = window.__wa_adapter || { names: [], wrapped: 0, errors: [] };",
  "  const note = (name) => { if (typeof name === 'string' && state.names.length < 30000) state.names.push(name); };",
  "  const trap = (property, wrap) => {",
  "    let stored;",
  "    try {",
  "      const descriptor = Object.getOwnPropertyDescriptor(window, property);",
  "      if (descriptor && descriptor.set && descriptor.get && descriptor.configurable === false) return;",
  "      Object.defineProperty(window, property, {",
  "        configurable: true,",
  "        get() { return stored; },",
  "        set(value) { try { stored = wrap(value) || value; } catch (e) { state.errors.push(property + ': ' + String(e).slice(0, 60)); stored = value; } },",
  "      });",
  "      if (descriptor && descriptor.value !== undefined) { stored = wrap(descriptor.value) || descriptor.value; }",
  "    } catch (e) { state.errors.push('trap ' + property + ': ' + String(e).slice(0, 60)); }",
  "  };",
  "  const wrapDefine = (original) => {",
  "    if (typeof original !== 'function' || original.__wa_wrapped) return original;",
  "    const wrapped = function (name) { note(name); return original.apply(this, arguments); };",
  "    wrapped.__wa_wrapped = true;",
  "    state.wrapped += 1;",
  "    return wrapped;",
  "  };",
  "  const wrapRequire = (original) => {",
  "    if (typeof original !== 'function' || original.__wa_wrapped) return original;",
  "    const wrapped = function (name) { note('require:' + name); return original.apply(this, arguments); };",
  "    wrapped.__wa_wrapped = true;",
  "    state.wrapped += 1;",
  "    return wrapped;",
  "  };",
  "  trap('__d', wrapDefine);",
  "  trap('require', wrapRequire);",
  "  // the bundle replaces __d with defineProperty (bypassing a setter), but it calls these.",
  "  trap('__onAfterModuleFactory', (original) => {",
  "    if (typeof original !== 'function' || original.__wa_wrapped) return original;",
  "    const wrapped = function (name) { note('module:' + name); return original.apply(this, arguments); };",
  "    wrapped.__wa_wrapped = true;",
  "    state.wrapped += 1;",
  "    return wrapped;",
  "  });",
  "  trap('__onBeforeModuleFactory', (original) => {",
  "    if (typeof original !== 'function' || original.__wa_wrapped) return original;",
  "    const wrapped = function (name) { note('before:' + name); return original.apply(this, arguments); };",
  "    wrapped.__wa_wrapped = true;",
  "    state.wrapped += 1;",
  "    return wrapped;",
  "  });",
  "})();",
].join("\n");

const command = process.argv[2] || "dump";
const argument = process.argv[3] || "";

const connection = await connect();
if (command === "install") {
  await connection.call("Page.enable", {});
  await connection.call("Page.addScriptToEvaluateOnNewDocument", { source: HOOK });
  await connection.call("Page.reload", { ignoreCache: false });
  console.log(JSON.stringify({ ok: true, installed: true, reloaded: true, note: "wait for the page, then run dump" }));
} else {
  const stateName = "window.__wa_adapter || null";
  const summary = await connection.evaluate(`JSON.stringify({ state: ${stateName}, names: (window.__wa_adapter ? window.__wa_adapter.names.length : 0), dWrapped: !!(window.__d && window.__d.__wa_wrapped) })`);
  if (command === "find" || command === "dump") {
    const all = await connection.evaluate(`JSON.stringify(window.__wa_adapter ? window.__wa_adapter.names : [])`);
    const names = Array.from(new Set(all));
    if (command === "dump") {
      const fs = await import("node:fs");
      const target = argument || "wa-module-names.json";
      fs.writeFileSync(target, JSON.stringify(names, null, 1));
      console.log(JSON.stringify({ ok: true, wrote: target, names: names.length, wrapped: summary.dWrapped, errors: (summary.state && summary.state.errors) || [] }));
    } else {
      const pattern = new RegExp(argument || ".");
      const hits = names.filter((name) => pattern.test(name));
      console.log(JSON.stringify({ matching: hits.length, names: hits.slice(0, 60) }, null, 1));
    }
  } else {
    console.log(JSON.stringify(summary, null, 1));
  }
}
connection.ws.close();
