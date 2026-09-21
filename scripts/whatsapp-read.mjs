// Read WhatsApp Web's own store, from the node: conversations and messages, as JSON.
//
//   node scripts/whatsapp-read.mjs [--since <unix-seconds>] [--limit <n>]
//
// Deterministic by design, and the only part of the ingest that touches the browser. Three rules
// make it safe to run on a machine someone is using:
//
//   - **It opens nothing.** The messages come from the app's own in-memory collections, so no chat
//     is focused and nothing is marked read - which matters, because "the message stays unread" is a
//     requirement of the job this feeds, and any UI-driven reader would break it by looking.
//   - **It finds the browser by proof, not by port.** Both loopback stacks are probed and only an
//     endpoint that proves DevTools is used, because a stray process on 9222 is not a browser (one
//     on this machine answered 404 for hours).
//   - **It carries a cursor.** `--since` bounds what comes back, so a run reads the diff rather than
//     the whole store.
//
// stdout is JSON and nothing else; everything diagnostic goes to stderr. A missing browser or a
// missing tab is a *reported* condition (`ok:false`, `error`), not a crash, because the caller is a
// scheduled job that must stay quiet when the window is closed.
const DEFAULT_PORTS = [9222];
const WHATSAPP_URL = "web.whatsapp.com";
// A message whose body is media is stored as base64 by the app; keeping that would put megabytes in
// the ledger per photo, so the body is a marker and the caption only.
const MAX_BODY = 4000;
// The store is not a history: it holds a window per chat. Deep history needs per-chat loading, which
// the parallel readings work owns; this depends only on what the client already has in memory.
const STATUS_CHAT = "status@broadcast";

function parseArgs(argv) {
  const args = { since: 0, limit: 2000, ports: DEFAULT_PORTS, out: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--since") { args.since = Number(value) || 0; index += 1; }
    else if (flag === "--limit") { args.limit = Number(value) || 2000; index += 1; }
    else if (flag === "--port") { args.ports = [Number(value)]; index += 1; }
    else if (flag === "--out") { args.out = String(value || ""); index += 1; }
    else if (flag === "--print-expression") { args.printExpression = true; }
  }
  return args;
}

async function text(url, init, timeoutMs = 4000) {
  try {
    const response = await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    return await response.text();
  } catch {
    return "";
  }
}

// The endpoint, by proof: `/json/version` with a DevTools websocket URL, on either stack.
async function discover(ports) {
  const tried = [];
  for (const port of ports) {
    for (const host of ["127.0.0.1", "[::1]"]) {
      const body = await text(`http://${host}:${port}/json/version`);
      try {
        const version = JSON.parse(body);
        if (version.webSocketDebuggerUrl && version.Browser) {
          return { endpoint: { host, port, browser: version.Browser }, tried };
        }
      } catch { /* not DevTools: a squatter, a closed port, or something else entirely */ }
      tried.push(`${host}:${port}`);
    }
  }
  return { endpoint: null, tried };
}

function expression(since) {
  return `(() => {
    const grab = (name) => { try { return window.require(name); } catch (error) { return null; } };
    const chatModule = grab('WAWebChatCollection');
    const msgModule = grab('WAWebMsgCollection');
    if (!chatModule || !chatModule.ChatCollection) return JSON.stringify({ error: 'no_chat_collection' });
    const chats = chatModule.ChatCollection.getModelsArray() || [];
    const messages = (msgModule && msgModule.MsgCollection) ? (msgModule.MsgCollection.getModelsArray() || []) : [];
    const SINCE = ${Number(since)};
    const STATUS = ${JSON.stringify(STATUS_CHAT)};
    const MAX_BODY = ${MAX_BODY};
    const conversations = [];
    for (const chat of chats) {
      const id = String((chat.id && chat.id._serialized) || "");
      if (!id || id === STATUS) continue;
      conversations.push({
        id: id,
        title: String(chat.formattedTitle || chat.name || ''),
        // From the id, not from `chat.isGroup`: in this build `isGroup` is false even for a `@g.us`
        // chat, so every group was stored as a direct conversation (217 of them here).
        kind: id.endsWith('@g.us') ? 'group'
          : id.endsWith('@broadcast') ? 'broadcast'
          : id.endsWith('@c.us') ? 'direct'
          : id.endsWith('@lid') ? 'direct'
          : 'unknown',
        unread: chat.unreadCount || 0,
        updated_at: chat.t || null,
      });
    }
    const out = [];
    let skipped = 0;
    let newest = 0;
    for (const message of messages) {
      // remote, participant and id are Wid-like objects in this build, not strings: they compare
      // unequal to any string (remote === STATUS was silently false, so every status broadcast
      // arrived as if it were a chat) while still concatenating into a correct-looking id. Coerce at
      // the boundary, once.
      const key = message.id || {};
      const remote = String(key.remote || '');
      const participant = String(key.participant || '');
      const rawId = String(key.id || '');
      const id = String(key._serialized || (rawId
        ? ((key.fromMe ? 'true' : 'false') + '_' + remote + (participant ? '_' + participant : '') + '_' + rawId)
        : ''));
      const at = message.t || 0;
      if (!id || !remote || remote === STATUS) continue;
      if (at > newest) newest = at;
      if (!at) { skipped += 1; continue; }
      if (at <= SINCE) continue;
      const kind = String(message.type || 'chat');
      const isText = kind === 'chat' || kind === 'text' || kind === 'vcard';
      const caption = message.caption ? String(message.caption) : '';
      let body = isText ? String(message.body || '') : '[' + kind + ']';
      if (!isText && caption) body = '[' + kind + '] ' + caption;
      if (body.length > MAX_BODY) body = body.slice(0, MAX_BODY);
      out.push({
        conversation_id: remote,
        message_id: id,
        sender_id: (message.from && message.from._serialized) || (key.participant || '') || '',
        direction: key.fromMe ? 'outgoing' : 'incoming',
        sent_at: at,
        body: body,
        media: [{ type: kind, caption: caption ? caption.slice(0, 200) : null }],
      });
    }
    return JSON.stringify({ conversations: conversations, messages: out, skipped_no_timestamp: skipped, newest: newest,
      store: { chats: chats.length, messages: messages.length, msg_module: !!msgModule, chat_module: !!chatModule } });
  })()`;
}

function call(ws, method, params) {
  return new Promise((resolve, reject) => {
    const id = (call.next = (call.next || 0) + 1);
    const timer = setTimeout(() => reject(new Error(`timeout: ${method}`)), 30000);
    const onMessage = (event) => {
      const message = JSON.parse(event.data);
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
  // A debug flag, not a feature: when WhatsApp changes its build, the question is always "what did we
  // actually send", and the answer must not require editing this file to find out.
  if (args.printExpression) { console.log(expression(args.since)); return; }
  const { endpoint, tried } = await discover(args.ports);
  if (!endpoint) {
    console.log(JSON.stringify({ ok: false, error: "no_cdp_endpoint", tried }));
    process.exit(3);
  }
  const targets = JSON.parse(await text(`http://${endpoint.host}:${endpoint.port}/json/list`));
  const pages = (targets || []).filter((target) => target.type === "page");
  const tab = pages.find((page) => (page.url || "").includes(WHATSAPP_URL));
  if (!tab) {
    console.log(JSON.stringify({ ok: false, error: "no_whatsapp_tab", endpoint, pages: pages.map((page) => page.url) }));
    process.exit(3);
  }

  const ws = new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket refused")), { once: true });
  });
  const evaluated = await call(ws, "Runtime.evaluate", {
    expression: expression(args.since),
    returnByValue: true,
    awaitPromise: true,
  });
  ws.close();
  if (evaluated.exceptionDetails) {
    console.log(JSON.stringify({ ok: false, error: "evaluate_failed", detail: evaluated.exceptionDetails.text }));
    process.exit(4);
  }
  const payload = JSON.parse(evaluated.result.value);
  if (payload.error) {
    console.log(JSON.stringify({ ok: false, error: payload.error }));
    process.exit(5);
  }
  const messages = payload.messages.slice(0, args.limit);
  const full = {
    ok: true,
    endpoint,
    tab: { id: tab.id, title: tab.title, url: tab.url },
    since: args.since,
    conversations: payload.conversations,
    messages,
    skipped_no_timestamp: payload.skipped_no_timestamp || 0,
    store: payload.store || null,
    dropped_over_limit: payload.messages.length - messages.length,
    newest: payload.newest || 0,
  };
  // The inbox does not fit in a pipe: 700 conversations and their messages are hundreds of
  // kilobytes, and a caller that reads this through a shell gets a truncated string that parses as
  // nothing (which is exactly how it failed first). So `--out` writes the payload to a file and
  // stdout carries only the counts - small, greppable, and never the thing that breaks.
  if (args.out) {
    const fs = await import("node:fs");
    fs.writeFileSync(args.out, JSON.stringify(full));
    console.log(JSON.stringify({
      ok: true,
      out: args.out,
      conversations: full.conversations.length,
      messages: full.messages.length,
      dropped_over_limit: full.dropped_over_limit,
      skipped_no_timestamp: full.skipped_no_timestamp,
      store: full.store,
      newest: full.newest,
      endpoint: `${endpoint.host}:${endpoint.port}`,
      tab: tab.id,
    }));
    return;
  }
  console.log(JSON.stringify(full));
}

main().catch((error) => {
  console.log(JSON.stringify({ ok: false, error: "reader_failed", detail: String(error && error.message || error) }));
  process.exit(6);
});
