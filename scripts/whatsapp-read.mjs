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

import { eligibility } from "./whatsapp-eligibility.mjs";
import { deriveLeft } from "./whatsapp-read-core.mjs";
import { WebSocket } from "./lib/websocket-runtime.mjs";
// A message whose body is media is stored as base64 by the app; keeping that would put megabytes in
// the ledger per photo, so the body is a marker and the caption only.
const MAX_BODY = 4000;
// The store is not a history: it holds a window per chat. Deep history needs per-chat loading, which
// the parallel readings work owns; this depends only on what the client already has in memory.
const STATUS_CHAT = "status@broadcast";

function parseArgs(argv) {
  const args = { since: 0, limit: 2000, ports: DEFAULT_PORTS, out: "", operator: process.env.WA_WHATSAPP_OPERATOR || "" };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--since") { args.since = Number(value) || 0; index += 1; }
    else if (flag === "--limit") { args.limit = Number(value) || 2000; index += 1; }
    else if (flag === "--port") { args.ports = [Number(value)]; index += 1; }
    else if (flag === "--out") { args.out = String(value || ""); index += 1; }
    // The operator's own ids are a *local binding*, not part of any portable artifact: they are how a
    // group mention is verified. Passed as a comma-separated list, or via WA_WHATSAPP_OPERATOR.
    else if (flag === "--operator") { args.operator = String(value || ""); index += 1; }
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
    // Metadata is tri-state on purpose: true, false, or null when this build does not expose the field.
    // A missing field is *unknown*, and an unknown archived/left state must fail closed, not read as
    // "not archived".
    const firstBool = (obj, keys) => { for (const key of keys) { if (typeof obj[key] === 'boolean') return obj[key]; } return null; };
    let meId = '';
    try {
      const me = window.require('WAWebUserPrefsMeUser');
      const candidate = (me && me.getMaybeMeLidUser && me.getMaybeMeLidUser())
        || (me && me.getMaybeMePnUser && me.getMaybeMePnUser())
        || (me && me.getMeUser && me.getMeUser());
      meId = String((candidate && ((candidate.id && candidate.id._serialized) || candidate._serialized)) || '');
    } catch (error) { meId = ''; }
    // Membership, as this build exposes it. It has no isLeft/left/hasLeft/isExited, so left is
    // derived in Node (deriveLeft, tested) from these two signals rather than staying unknown for
    // every chat - which refused the whole inbox and emitted nothing.
    const widOf = (value) => String((value && value.id && value.id._serialized) || (value && value._serialized) || value || '');
    const sameUser = (a, b) => {
      const x = widOf(a), y = widOf(b);
      if (!x || !y) return false;
      if (x === y) return true;
      const domain = (v) => { const at = v.indexOf('@'); return at < 0 ? '' : v.slice(at + 1).toLowerCase(); };
      const phone = (v) => domain(v) === 'c.us' || domain(v) === 's.whatsapp.net';
      if (!phone(x) || !phone(y)) return false;
      const dx = x.replace(/[^0-9]/g, ''), dy = y.replace(/[^0-9]/g, '');
      return !!dx && dx === dy;
    };
    const memberOf = (chat) => {
      try {
        const list = chat.groupMetadata && chat.groupMetadata.participants;
        const arr = list ? (list.getModelsArray ? list.getModelsArray() : (Array.isArray(list) ? list : null)) : null;
        if (!arr || !meId) return null;
        return arr.some((participant) => sameUser(participant, meId));
      } catch (error) { return null; }
    };
    const conversations = [];
    for (const chat of chats) {
      const id = String((chat.id && chat.id._serialized) || "");
      if (!id || id === STATUS) continue;
      conversations.push({
        id: id,
        title: String(chat.formattedTitle || chat.name || ''),
        // From the id, not from chat.isGroup: in this build isGroup is false even for a @g.us
        // chat, so every group was stored as a direct conversation (217 of them here).
        kind: id.endsWith('@g.us') ? 'group'
          : id.endsWith('@broadcast') ? 'broadcast'
          : id.endsWith('@c.us') ? 'direct'
          : id.endsWith('@lid') ? 'direct'
          : 'unknown',
        // Verified adapter metadata. null means this build did not expose the field: unknown, not false.
        archived: firstBool(chat, ['archive', 'isArchived', 'archived']),
        left: firstBool(chat, ['isLeft', 'left', 'hasLeft', 'isExited']),
        // The signals deriveLeft needs when no explicit flag exists (on this build: always).
        can_send: typeof chat.canSend === 'boolean' ? chat.canSend : null,
        me_in_participants: memberOf(chat),
        // A real number is an unread count; absent or non-numeric stays unknown (null), never 0.
        unread: typeof chat.unreadCount === 'number' ? chat.unreadCount : null,
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
      // Mention evidence, for group eligibility. Coerce Wid-like objects at the boundary once.
      const mentioned = message.mentionedJidList || message.mentionedJids || null;
      const mentionedIds = Array.isArray(mentioned)
        ? mentioned.map((value) => String((value && value._serialized) || value)) : null;
      const mentionedMe = meId && Array.isArray(mentionedIds) ? mentionedIds.indexOf(meId) >= 0 : null;
      out.push({
        conversation_id: remote,
        message_id: id,
        sender_id: (message.from && message.from._serialized) || (key.participant || '') || '',
        direction: key.fromMe ? 'outgoing' : 'incoming',
        sent_at: at,
        body: body,
        mentioned_ids: mentionedIds,
        mentioned_me: mentionedMe,
        media: [{ type: kind, caption: caption ? caption.slice(0, 200) : null }],
      });
    }
    return JSON.stringify({ conversations: conversations, messages: out, skipped_no_timestamp: skipped, newest: newest, me_id: meId,
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
  // Deterministic eligibility, in Node, on the adapter's verified metadata. The reply job never spends a
  // model turn on a message that a rule already excludes, and an unverifiable chat fails closed here.
  // `left` is derived first: the app exposes no explicit membership flag, and passing its null through
  // refused every chat (`left_unknown`), which is what kept this pipeline silent.
  payload.conversations = (payload.conversations || []).map((chat) => ({ ...chat, left: deriveLeft(chat) }));
  const chatById = new Map((payload.conversations || []).map((chat) => [String(chat.id), chat]));
  const operatorIds = String(args.operator || "").split(",").map((value) => value.trim()).filter(Boolean);
  // The window, measured against one clock: epoch seconds from this process, which is the same unit the
  // store's `sent_at` is in. Never a local wall clock - an epoch has no zone, so no time zone can shift
  // the verdict in either direction. The defaults live in the rule; the environment can widen or tighten
  // them, which is how an operator tunes this without a code change (and what the test drives).
  const envSeconds = (name) => {
    const value = Number(process.env[name]);
    return Number.isFinite(value) && value >= 0 ? value : null;
  };
  const eligibilityOptions = {
    operator: { ids: operatorIds, phones: operatorIds },
    now: Math.floor(Date.now() / 1000),
  };
  const maxAge = envSeconds("WA_WHATSAPP_MAX_AGE_SECONDS");
  if (maxAge !== null) eligibilityOptions.max_seconds = maxAge;
  const grace = envSeconds("WA_WHATSAPP_GRACE_SECONDS");
  if (grace !== null) eligibilityOptions.grace_seconds = grace;
  let eligible = 0;
  let ineligible = 0;
  for (const message of messages) {
    const conversation = chatById.get(String(message.conversation_id)) || {
      id: message.conversation_id, title: "", archived: null, left: null,
    };
    const verdict = eligibility({ conversation, message }, eligibilityOptions);
    message.eligibility = verdict;
    if (verdict.eligible) eligible += 1;
    else ineligible += 1;
  }
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
    eligible,
    ineligible,
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
      eligible: full.eligible,
      ineligible: full.ineligible,
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
