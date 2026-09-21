// Send one WhatsApp message - or, by default, rehearse one and send nothing.
//
//   node scripts/whatsapp-reply.mjs --chat <chat-id> --body "text"          # rehearsal: opens, types, clears
//   node scripts/whatsapp-reply.mjs --chat <chat-id> --body "text" --send   # sends, then verifies
//   node scripts/whatsapp-reply.mjs --to-self --label "note" --body "text" --send
//
// VERIFIED END TO END. A message was sent to the operator's own notes-to-self chat and confirmed in the
// app's store by its message id and ack level:
//
//   {"ok":true,"sent":true,"dispatch":"error: timeout: Input.dispatchKeyEvent",
//    "chat":"+55 19 99493-9204","verified":true,"message":{"id":"3EB0C6347441CB6B56B6B3","ack":3}}
//
// The route, and what each step cost to learn:
//   - the target (and "message yourself") is resolved from the app's own store, opening nothing;
//   - the chat is opened through the app's own action, `Cmd.openChatFromUnread({chat})` - not by
//     scrolling or clicking. The chat list is virtualised, this build's search does not filter it, and
//     scrollTop does not move it, so every DOM route reached a dead end; the name came from the adapter
//     (scripts/whatsapp-adapter.mjs) and the call shape from reading the app's own source;
//   - typing uses real input events (`Input.insertText`), because the app ignores synthetic ones;
//   - **the effect decides, never the keystroke.** This browser's input pipeline drops key dispatches
//     (measured: 56 of 112 backspaces landed; the successful send reported a *timeout* on Enter while
//     delivering). So Enter is retried a bounded number of times and every attempt is settled against
//     the store - a send that cannot be found is reported as not sent;
//   - **an unsent draft is never overwritten.** WhatsApp restores a chat's draft, so "the composer
//     contains my text" is not enough: the composer must hold exactly the body or nothing is sent. A
//     human's draft is not the job's to destroy.
//
// KNOWN LIMIT, stated plainly: this route *opens* the chat, and opening a chat is what marks it read.
// For notes-to-self there is nothing to lose. For a third-party reply it breaks the operator's unread
// marker, so the honest options are the store send (no opening - needs the Msg model, still unknown in
// this build) or an explicit unread repair (UI-only here: no unread *action* exists among the ~6000
// module names the adapter recorded).
//
// stdout is JSON. Exit codes: 0 ok, 3 no endpoint/tab, 4 chat not found, 5 a step failed, 6 crashed.
//
// The deterministic half of the reply job. Route, and why:
//
//   - The chat is opened through the left pane's **search**, not by matching a row: the list is
//     virtualised, so an unrendered row cannot be clicked at all. Search filters the list, the match
//     renders, and then a click opens it.
//   - Typing goes through **real input events** (`Input.insertText`, `Input.dispatchKeyEvent`), not
//     synthetic ones: the app ignores a dispatched 'input' event on its React-controlled search - the
//     value lands and nothing filters, which is exactly how this was discovered.
//   - The composer's own `aria-label` **asserts which chat is open** before anything is typed, so a
//     failed click cannot type into whatever happened to be on screen.
//   - A rehearsal clears the composer and asserts it is empty: a rehearsal that leaves text behind is
//     not a rehearsal.
//   - After sending, the message is looked for **in the store** (that chat, mine, that body). "I
//     pressed Enter" is not "it went", and the report carries the chat's unread count before and
//     after, because opening a chat is what marks it read - so the unread consequence is reported as
//     a measurement, not promised away.
//
// stdout is JSON. Exit codes: 0 ok, 3 no endpoint/tab, 4 chat not found, 5 a step failed, 6 crashed.
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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---- page expressions -------------------------------------------------------
// NOTE: each of these is a template literal. A backtick anywhere inside - including in a comment -
// ends the string and breaks the file; that has bitten this repo twice already.

// Resolve the target in the store: read-only, and where "message yourself" is decided. The self chat
// is proved, not guessed - my number's @c.us form is not a chat in this build, the account also has a
// LID identity, and "message yourself" lives under one of them.
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
      self_id: selfId, unread: found.unreadCount || 0, messages: msgs.length,
      archived: !!(found.archive || found.isArchived),
    });
  })()`;
}

function focusExpression(which) {
  return `(() => {
    const WHICH = ${JSON.stringify(which)};
    let node = null;
    if (WHICH === 'search') {
      const container = document.querySelector('[data-testid="chat-list-search-container"]');
      node = (container && container.querySelector('input[type="text"]'))
        || document.querySelector('#side input[type="text"]');
    } else {
      node = document.querySelector('footer div[contenteditable="true"]')
        || document.querySelector('div[contenteditable="true"][role="textbox"]');
    }
    if (!node) return JSON.stringify({ error: WHICH + '_missing' });
    node.focus();
    return JSON.stringify({
      focused: document.activeElement === node,
      tag: node.tagName,
      label: String(node.getAttribute('aria-label') || '').slice(0, 48),
    });
  })()`;
}

// Open a chat through the app's own action, by id. This replaces scrolling and clicking entirely: the
// chat list is virtualised (only rendered rows exist), this build's search does not filter it, and
// scrollTop does not move it - but `Cmd.openChatFromUnread({chat})` is what the app itself calls to open
// a conversation, and it needs nothing on screen. The name came from the adapter's module list; the
// call shape came from reading `WAWebOpenChatWithContactAction`'s own source:
//   findOrCreateLatestChat -> Cmd.openChatFromUnread({chat, chatEntryPoint}) -> ComposeBoxActions.focus
function openExpression(chatId) {
  return `(() => {
    const chats = window.require('WAWebChatCollection').ChatCollection.getModelsArray() || [];
    const chat = chats.find((c) => String(c.id) === ${JSON.stringify(chatId)});
    if (!chat) return JSON.stringify({ error: 'chat_not_found' });
    let cmd = null;
    try { cmd = window.require('WAWebCmd').Cmd; } catch (e) { cmd = null; }
    if (!cmd || typeof cmd.openChatFromUnread !== 'function') return JSON.stringify({ error: 'open_action_missing' });
    const before = { unread: chat.unreadCount || 0 };
    try { cmd.openChatFromUnread({ chat: chat, chatEntryPoint: undefined }); }
    catch (e) { return JSON.stringify({ error: 'open_threw', detail: String(e).slice(0, 120) }); }
    return JSON.stringify({ opened: true, before: before });
  })()`;
}

// Scroll the chat list by one viewport. The list is virtualised, so a chat that is not rendered cannot
// be clicked at all; scrolling is how a row is brought into existence. For a reply job the target is a
// chat that just spoke, so it is normally at or near the top - but the loop is bounded rather than
// assumed, and gives up with what it saw.
// The chat list is virtualised, so a row that is not rendered cannot be clicked. `scrollTop` does not
// move it (the app uses its own virtualiser and ignores a synthetic scroll), so the scroll is a real
// wheel event over the list - the same thing a hand on the mouse produces.
function chatListRectExpression() {
  return `(() => {
    const list = document.querySelector('[data-testid="chat-list"]');
    if (!list) return JSON.stringify({ error: 'no_chat_list' });
    const rect = list.getBoundingClientRect();
    return JSON.stringify({
      x: Math.round(rect.left + rect.width / 2),
      y: Math.round(rect.top + Math.min(rect.height, 300) / 2),
      height: Math.round(rect.height),
    });
  })()`;
}

function composerTextExpression() {
  return `(() => {
    const composer = document.querySelector('footer div[contenteditable="true"]')
      || document.querySelector('div[contenteditable="true"][role="textbox"]');
    if (!composer) return JSON.stringify({ error: 'composer_missing' });
    const text = String(composer.innerText || '');
    return JSON.stringify({ text: text.slice(0, 160), empty: text.trim() === '', label: String(composer.getAttribute('aria-label') || '') });
  })()`;
}

// The message must exist in the store: that chat, mine, that body. A send nobody can see did not
// happen, and saying so is the only honest report.
function verifyExpression(chatId, body) {
  return `(() => {
    const chats = window.require('WAWebChatCollection').ChatCollection.getModelsArray() || [];
    const msgs = window.require('WAWebMsgCollection').MsgCollection.getModelsArray() || [];
    const CHAT = ${JSON.stringify(chatId)};
    const BODY = ${JSON.stringify(body)};
    let found = null;
    for (let index = msgs.length - 1; index >= 0; index -= 1) {
      const message = msgs[index];
      if (String((message.id && message.id.remote) || '') !== CHAT) continue;
      if (!(message.id && message.id.fromMe)) continue;
      if (String(message.body || '') !== BODY) continue;
      found = { id: String((message.id && message.id.id) || ''), t: message.t || 0, ack: message.ack };
      break;
    }
    const chat = chats.find((c) => String(c.id) === CHAT) || null;
    return JSON.stringify({
      verified: !!found, message: found,
      after: { unread: chat ? (chat.unreadCount || 0) : null, t: chat ? (chat.t || 0) : null, messages: msgs.length },
    });
  })()`;
}

// ---- the flow ---------------------------------------------------------------

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
    // on Windows, and a scary line in the output of a tool that can send messages is exactly the noise
    // that hides a real failure.
    ws.close();
    process.exitCode = code;
    return;
  };
  const typeText = async (value) => { await call(ws, "Input.insertText", { text: value }, args.timeoutMs); };
  // A key event's *reply* is not the point: `Input.dispatchKeyEvent` can go unanswered for reasons that
  // have nothing to do with whether the key landed (Enter makes the app encrypt and persist, and those
  // calls have timed out here while the page stayed responsive). So a dispatch that does not come back
  // is recorded as unknown and the *effect* is what decides - the store is checked either way.
  const pressKey = async (key, code, vk, modifiers = 0, text = undefined) => {
    let outcome = "ok";
    try {
      const params = { type: "keyDown", key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers };
      if (text !== undefined) params.text = text;
      const sent = await Promise.race([
        call(ws, "Input.dispatchKeyEvent", params),
        new Promise((resolve) => setTimeout(() => resolve("timeout"), 8000)),
      ]);
      if (sent === "timeout") outcome = "timeout";
      await call(ws, "Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers });
    } catch (error) {
      outcome = "error: " + String(error.message).slice(0, 60);
    }
    return outcome;
  };

  // 1. Resolve the target.
  const target = await page(lookupExpression(args.chat, args.toSelf));
  if (target.error) return done({ ok: false, ...target }, 4);
  const body = args.label ? `${args.label}\n\n${args.body}` : args.body;
  const before = { unread: target.unread, messages: target.messages };

  // Sending refuses *before* any UI work, because the route is not implemented (see the header): a
  // 2. Open the chat through the app's own action (no row, no scroll, no search), then require the
  //    composer to confirm *which* chat opened - the difference between a reply and a message typed
  //    into whatever was on screen.
  const opened = await page(openExpression(target.chat.id));
  if (opened.error) return done({ ok: false, ...opened, chat: target.chat, before }, 5);
  await sleep(1000);
  const composer = await page(composerTextExpression());
  const label = String(composer.label || "");
  const digits = (value) => String(value).replace(/[^0-9]/g, "");
  const rightChat = label.indexOf(target.chat.name.slice(0, 12)) >= 0
    || (digits(target.chat.name).length > 6 && digits(label).indexOf(digits(target.chat.name)) >= 0);
  if (!rightChat) {
    return done({
      ok: false, error: "opened_the_wrong_chat", chat: target.chat, composer_label: label,
      observed: "the composer's label does not name the chat that was opened",
      next: "nothing was typed",
    }, 5);
  }

  // 3. Type into the composer, with real input events.
  const composerFocus = await page(focusExpression("composer"));
  if (composerFocus.error) return done({ ok: false, ...composerFocus, chat: target.chat }, 5);
  await typeText(body);
  await sleep(400);
  const typed = await page(composerTextExpression());
  const normalise = (value) => String(value || "").replace(/\s+/g, " ").trim();
  // WhatsApp restores a chat's unsent draft, so "the composer contains my text" is not enough: a
  // leftover draft would be sent *with* the reply. Either it is my body and nothing else, or nothing is
  // sent at all.
  if (normalise(typed.text) !== normalise(body)) {
    return done({
      ok: false, error: "composer_not_exactly_the_body", typed, chat: target.chat, body, before,
      observed: "the composer holds something other than the exact reply (a restored draft is the usual reason)",
      next: "the job must clear the draft before sending; nothing was sent",
    }, 5);
  }

  if (!args.send) {
    // A rehearsal leaves nothing behind: clear the composer, then assert it.
    await pressKey("a", "KeyA", 65, 2); // 2 = Ctrl
    await pressKey("Backspace", "Backspace", 8);
    await sleep(600);
    const cleared = await page(composerTextExpression());
    return done({
      ok: !!cleared.empty, dry_run: true, cleared: !!cleared.empty, chat: target.chat,
      composer_label: label, body, before, typed,
    }, cleared.empty ? 0 : 5);
  }

  // 4. Send, and let the *effect* decide. This browser's input pipeline drops key dispatches (measured:
  //    of 112 backspaces, 56 landed; Enter timed out twice), so the send is retried a bounded number of
  //    times and each attempt is settled against the store. The dispatch's own reply is recorded, never
  //    trusted.
  let dispatch = "not_attempted";
  let verified = { verified: false };
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    dispatch = await pressKey("Enter", "Enter", 13, 0, "\r");
    await sleep(3500);
    verified = await page(verifyExpression(target.chat.id, body));
    if (verified.verified) break;
  }
  return done({
    ok: !!verified.verified, sent: true, dispatch, chat: target.chat, composer_label: label, body,
    ...verified, unread_before: before.unread,
  }, verified.verified ? 0 : 5);
}

main().catch((error) => {
  console.log(JSON.stringify({ ok: false, error: "reply_failed", detail: String((error && error.message) || error) }));
  process.exitCode = 6;
});
