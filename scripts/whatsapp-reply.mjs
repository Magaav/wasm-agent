// Send one WhatsApp message - or, by default, do not.
//
// ============================ READ THIS BEFORE USING IT ============================
// STATE: the *reading* half is done and verified (the target chat and "message yourself" are both
// resolved from the store; see scripts/whatsapp-read.mjs, which is what the ingest job runs). The
// *sending* half is NOT finished, and this file therefore refuses to send. What is known:
//
//   - the store send action (`WAWebSendMsgChatAction.addAndSendMsgToChat`) needs a real Msg model,
//     not a plain object: passing one does nothing, silently. Verified: nothing was sent, and nothing
//     was left behind in the account (0 of 2120 messages carried the body);
//   - the UI route (open the chat by clicking its row, type into the composer, press Enter) needs the
//     chat list's row for a chat id, and in this build rows carry no id attribute and their title is
//     not always the store's name, so the match has to be built on evidence rather than on a name;
//   - opening a chat is what marks it read, so the UI route needs a *repair* step ("mark as unread")
//     that this build does not expose as a store call, and whose only known mechanism is the chat
//     list's context menu.
//
// Until those three are settled, `--send` exits non-zero without touching the page. A sending tool
// that half-works is worse than one that refuses: the dangerous half is the one that cannot be undone.
// ===================================================================================
//
//   node scripts/whatsapp-reply.mjs --chat <chat-id> --body "text"          # resolves the target
//   node scripts/whatsapp-reply.mjs --to-self --body "summary"              # resolves "message yourself"
//   node scripts/whatsapp-reply.mjs --chat <id> --body "text" --send        # refuses, for now
//
// stdout is JSON. Exit codes: 0 ok, 3 no endpoint/tab, 4 chat not found, 7 sending not implemented.
const HOSTS = ["127.0.0.1", "[::1]"];
const WHATSAPP_URL = "web.whatsapp.com";

function parseArgs(argv) {
  const args = { chat: "", body: "", send: false, toSelf: false, label: "", timeoutMs: 20000 };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--chat") { args.chat = String(value || ""); index += 1; }
    else if (flag === "--body") { args.body = String(value || ""); index += 1; }
    else if (flag === "--label") { args.label = String(value || ""); index += 1; }
    else if (flag === "--send") { args.send = true; }
    else if (flag === "--to-self") { args.toSelf = true; }
  }
  return args;
}

async function text(url, init, timeoutMs = 4000) {
  try {
    const response = await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    return await response.text();
  } catch { return ""; }
}

async function discover() {
  for (const port of [9222]) {
    for (const host of HOSTS) {
      const body = await text(`http://${host}:${port}/json/version`);
      try {
        const version = JSON.parse(body);
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

// The UI route: the path the app itself takes. Opening a chat is what marks it read, so this is only
// used when a reply is actually being sent, and the dry run below is the same sequence without the
// Enter - which is the part that cannot be taken back.
// Kept for the UI route when its row matching is built: it opens a chat by row, and the composer's
// own label is the assertion that the right chat opened. Currently unreferenced.
function uiExpression(chatTitle, body, shouldSend) {
  return `(() => {
    const TITLE = ${JSON.stringify(chatTitle)};
    const BODY = ${JSON.stringify(body)};
    const SEND = ${shouldSend ? "true" : "false"};
    const rows = Array.from(document.querySelectorAll('#pane-side [role="listitem"], #pane-side [role="row"]'));
    const row = rows.find((candidate) => String(candidate.innerText || '').split('\\n')[0].trim() === TITLE)
      || rows.find((candidate) => String(candidate.innerText || '').indexOf(TITLE) === 0);
    if (!row) return JSON.stringify({ error: 'row_not_found', rows: rows.length, title: TITLE });
    row.scrollIntoView({ block: 'center' });
    row.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
    row.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
    row.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
    const composer = document.querySelector('footer div[contenteditable="true"]')
      || document.querySelector('div[contenteditable="true"][role="textbox"]');
    if (!composer) return JSON.stringify({ error: 'composer_missing', title: TITLE });
    return JSON.stringify({ clicked: true, title: TITLE, aria_before: composer.getAttribute('aria-label') });
  })()`;
}

// Typing is a second step because the chat has to open first; this asserts the composer took the text,
// which is what makes a dry run a real rehearsal rather than a no-op.
// Kept for the UI route: types the body and asserts the composer took it, clearing it when not sending.
function typeExpression(body, shouldSend) {
  return `(() => {
    const BODY = ${JSON.stringify(body)};
    const composer = document.querySelector('footer div[contenteditable="true"]')
      || document.querySelector('div[contenteditable="true"][role="textbox"]');
    if (!composer) return JSON.stringify({ error: 'composer_missing' });
    composer.focus();
    document.execCommand('insertText', false, BODY);
    const holds = String(composer.innerText || '').indexOf(BODY) >= 0;
    const result = { typed: holds, composer_text: String(composer.innerText || '').slice(0, 120), aria: composer.getAttribute('aria-label') };
    if (!holds) return JSON.stringify(result);
    if (!SEND) {
      // Clear it: a rehearsal must leave nothing behind, in the composer or in the chat.
      document.execCommand('selectAll', false, null);
      document.execCommand('delete', false, null);
      result.cleared = String(composer.innerText || '').trim() === '';
      result.sent = false;
      return JSON.stringify(result);
    }
    return JSON.stringify(Object.assign(result, { ready_to_send: true }));
  })()`;
}
// NOTE: this builds a template literal, so a backtick anywhere inside it - including in a comment -
// ends the string and breaks the file. It has happened twice in this repo already.
// Resolve the target in the store - read-only, no side effects. Everything the send needs to know
// (which chat, whether it exists, what it is called, where "message yourself" is) is decided here, so
// the sending route below never has to guess at a target.
function lookupExpression(chat, toSelf) {
  return `(() => {
    const chats = window.require('WAWebChatCollection').ChatCollection.getModelsArray() || [];
    const msgs = window.require('WAWebMsgCollection').MsgCollection.getModelsArray() || [];
    const CHAT = ${JSON.stringify(chat)};
    const TO_SELF = ${toSelf ? "true" : "false"};
    let selfId = '';
    const counts = {};
    for (const message of msgs) {
      if (message.id && message.id.fromMe) {
        const from = String(message.from || '');
        if (from) counts[from] = (counts[from] || 0) + 1;
      }
    }
    const ranked = Object.keys(counts).sort((a, b) => counts[b] - counts[a]);
    const byChat = chats.filter((c) => ranked.indexOf(String(c.id)) >= 0).map((c) => String(c.id));
    const mine = msgs.filter((m) => m.id && m.id.fromMe).map((m) => String(m.id.remote || ''));
    const selfOnly = byChat.find((id) => mine.indexOf(id) >= 0
      && msgs.filter((m) => String((m.id && m.id.remote) || '') === id && !(m.id && m.id.fromMe)).length === 0);
    selfId = selfOnly || byChat[0] || '';
    const targetId = TO_SELF ? selfId : CHAT;
    const found = chats.find((c) => String(c.id) === targetId) || null;
    if (!found) return JSON.stringify({ error: 'chat_not_found', target_id: targetId, self_id: selfId });
    return JSON.stringify({
      chat: { id: String(found.id), name: String(found.formattedTitle || found.name || '') },
      self_id: selfId,
      unread: found.unreadCount || 0,
      messages: msgs.length,
    });
  })()`;
}

// Read back: the message must exist in the store, in that chat, mine, with that body. A send nobody
// can see did not happen, and saying so is the only honest report.
// Read-back for a send: the message must exist in the store, in that chat, mine, with that body.
function verifyExpression(chatId, body, sinceMsgs) {
  return `(() => {
    const chats = window.require('WAWebChatCollection').ChatCollection.getModelsArray() || [];
    const msgs = window.require('WAWebMsgCollection').MsgCollection.getModelsArray() || [];
    const CHAT = ${JSON.stringify(chatId)};
    const BODY = ${JSON.stringify(body)};
    const SINCE = ${sinceMsgs};
    let found = null;
    for (let index = msgs.length - 1; index >= 0; index -= 1) {
      const message = msgs[index];
      const remote = message.id && String(message.id.remote || '');
      if (remote !== CHAT) continue;
      if (!(message.id && message.id.fromMe)) continue;
      if (String(message.body || '') !== BODY) continue;
      found = { id: String((message.id && message.id.id) || ''), t: message.t || 0 };
      break;
    }
    const chat = chats.find((c) => String(c.id) === CHAT) || null;
    return JSON.stringify({
      verified: !!found, message: found,
      after: { unread: chat ? (chat.unreadCount || 0) : null, t: chat ? (chat.t || 0) : null, msgs: msgs.length },
    });
  })()`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.body) { console.log(JSON.stringify({ error: "body_required" })); process.exitCode = 1; return; }
  const endpoint = await discover();
  if (!endpoint) { console.log(JSON.stringify({ ok: false, error: "no_cdp_endpoint" })); process.exitCode = 3; return; }
  const targets = JSON.parse(await text(`http://${endpoint.host}:${endpoint.port}/json/list`));
  const tab = (targets || []).filter((t) => t.type === "page").find((t) => (t.url || "").includes(WHATSAPP_URL));
  if (!tab) { console.log(JSON.stringify({ ok: false, error: "no_whatsapp_tab" })); process.exitCode = 3; return; }

  const ws = new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket refused")), { once: true });
  });
  const page = async (expression) => {
    const result = await call(ws, "Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, args.timeoutMs);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || "page_threw");
    return JSON.parse(result.result.value);
  };
  const done = (payload, code) => {
    console.log(JSON.stringify({ endpoint, ...payload }));
    // exitCode rather than process.exit: exiting while the socket is closing trips a libuv assertion
    // on Windows, and a scary line in the output of a tool that can send messages is exactly the
    // noise that hides a real failure.
    ws.close();
    process.exitCode = code;
    return;
  };

  // 1. Resolve the target in the store. Read-only: this is also where "message yourself" is decided.
  const target = await page(lookupExpression(args.chat, args.toSelf));
  if (target.error) return done({ ok: false, ...target }, 4);

  const body = args.label ? `${args.label}\n\n${args.body}` : args.body;
  const before = { unread: target.unread, messages: target.messages };

  // Sending is refused, with the reason, until the route is settled (see the header). The resolution
  // above still runs, so the *target* is verifiable now: that part is done.
  if (args.send) {
    return done({
      ok: false, error: "send_not_implemented", chat: target.chat, body, self_id: target.self_id,
      observed: "the store send action needs a real Msg model (a plain object does nothing, silently), "
        + "and the UI route needs the chat row for an id plus a way to restore unread",
      next: "settle the send route (store Msg model, or UI row match + mark-unread) before anything sends",
    }, 7);
  }
  return done({ ok: true, would_send: true, chat: target.chat, body, self_id: target.self_id, before }, 0);
}

main().catch((error) => {
  console.log(JSON.stringify({ ok: false, error: "reply_failed", detail: String((error && error.message) || error) }));
  process.exitCode = 6;
});
