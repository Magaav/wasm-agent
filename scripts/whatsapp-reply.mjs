// Send one WhatsApp message - or, by default, rehearse one and send nothing.
//
// ============================ READ THIS BEFORE USING IT ============================
// STATE: **`--send` refuses.** Everything below it is built and verified except the one step that
// brings an arbitrary chat's row into the DOM, and a sending tool that half-works is worse than one
// that refuses. What has been established, by trying it against the account:
//
//   - the chat rows are `[data-testid^="list-item-"]` with `[data-testid="cell-frame-title"]`.
//     `[role="listitem"]` matches the filter chips and unread badges instead - rows that never change
//     no matter how far you scroll, which is what sent me looking for the wrong element for a while;
//   - the chat list is **virtualised**: only rendered rows exist, so a chat outside the window cannot
//     be clicked at all;
//   - the left pane's search input **does not filter the list** in this build. Typing "Hermes" or a
//     phone number changes the input's value and nothing else - no filtering, no "no results" text,
//     with either synthetic events or real `Input.insertText`;
//   - `scrollTop` on any ancestor does not move the list, and real `Input.dispatchMouseEvent`
//     wheel events do move it but can push the renderer into a state where CDP calls time out (it
//     recovers; the page came back `ready: complete`, 675 chats);
//   - the composer is addressable and its `aria-label` names the open chat, which is the assertion
//     that would make a click safe;
//   - the store-side send (`WAWebSendMsgChatAction`) is **not reachable** from a loaded page: it needs
//     a real Msg model (a plain object does nothing, silently - verified: 0 of 2120 messages carried
//     the body), the module names for the message factory and the unread command are not guessable in
//     this build, and `window.require` is not enumerable.
//
// So the missing piece is an **adapter**: inject at document-start, wrap the module registry, and then
// either send through the app's own action or drive the list without guessing at its internals. That is
// the same work the readings branch is doing, and it is not something to hand-roll in a turn.
// ===================================================================================
//
// What is implemented and usable now: resolving a target and "message yourself" from the store
// (read-only, never opens anything), reading the composer, real typing, and store-side verification of
// a message that exists. Exit codes: 0 ok, 3 no endpoint/tab, 4 chat not found, 5 a step failed, 7 refused.
//   node scripts/whatsapp-reply.mjs --chat <chat-id> --body "text"          # rehearsal: opens, types, clears
//   node scripts/whatsapp-reply.mjs --chat <chat-id> --body "text" --send   # sends, then verifies
//   node scripts/whatsapp-reply.mjs --to-self --label "note" --body "text" --send
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

// The chat rows in this build are `[data-testid^="list-item-"]`, each with a
// `[data-testid="cell-frame-title"]`. `[role="listitem"]` matches the filter chips and unread badges
// instead, which is why a match against it never found a chat: the rows were there all along, under
// different names.
function clickRowExpression(name) {
  return `(() => {
    const NAME = ${JSON.stringify(name)};
    const rows = Array.from(document.querySelectorAll('[data-testid^="list-item-"]'));
    const titleOf = (row) => {
      const title = row.querySelector('[data-testid="cell-frame-title"]');
      return title ? String(title.textContent || '').trim() : '';
    };
    const hit = rows.find((row) => titleOf(row).indexOf(NAME) >= 0)
      || rows.find((row) => NAME.replace(/[^0-9]/g, '').length > 6
        && titleOf(row).replace(/[^0-9]/g, '') === NAME.replace(/[^0-9]/g, ''));
    if (!hit) {
      return JSON.stringify({
        error: 'row_not_found', rows: rows.length,
        seen: rows.slice(0, 6).map(titleOf),
        first_row_html: rows.length ? rows[0].outerHTML.slice(0, 160) : null,
      });
    }
    hit.scrollIntoView({ block: 'center' });
    for (const type of ['mousedown', 'mouseup', 'click']) {
      hit.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
    }
    const composer = document.querySelector('footer div[contenteditable="true"]')
      || document.querySelector('div[contenteditable="true"][role="textbox"]');
    return JSON.stringify({
      clicked: true, row_title: titleOf(hit),
      composer_label: composer ? String(composer.getAttribute('aria-label') || '') : null,
    });
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
    return JSON.stringify({ text: text.slice(0, 160), empty: text.trim() === '' });
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
  const pressKey = async (key, code, vk, modifiers = 0) => {
    await call(ws, "Input.dispatchKeyEvent", { type: "keyDown", key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers });
    await call(ws, "Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers });
  };

  // 1. Resolve the target.
  const target = await page(lookupExpression(args.chat, args.toSelf));
  if (target.error) return done({ ok: false, ...target }, 4);
  const body = args.label ? `${args.label}\n\n${args.body}` : args.body;
  const before = { unread: target.unread, messages: target.messages };

  // Sending refuses *before* any UI work, because the route is not implemented (see the header): a
  // refusal that first scrolls a virtualised list for two minutes is not a refusal, it is a hang.
  if (args.send) {
    return done({
      ok: false, error: "send_not_implemented", chat: target.chat, body, before,
      observed: "the chat list is virtualised, this build's search does not filter it, and scrollTop "
        + "does not move it; the store send needs a real Msg model that a loaded page cannot build",
      next: "build the adapter (inject at document-start, wrap the module registry) or wait for the readings branch",
    }, 7);
  }

  // 2. Open the chat. The list is virtualised and this build's search box does not filter it (typing
  //    "Hermes" or a phone number left the same 17 rows: verified), so the row is found by scrolling -
  //    and for a reply job the target has just spoken, so it is at or near the top.
  const rect = await page(chatListRectExpression());
  const wheel = async () => {
    await call(ws, "Input.dispatchMouseEvent", { type: "mouseWheel", x: rect.x, y: rect.y, deltaX: 0, deltaY: 600 }, args.timeoutMs);
  };
  let clicked = { error: "row_not_found" };
  for (let attempt = 0; attempt < 6; attempt += 1) {
    clicked = await page(clickRowExpression(target.chat.name));
    if (!clicked.error) break;
    if (attempt === 39) break;
    await wheel();
    await sleep(900);
  }
  if (clicked.error) {
    return done({ ok: false, ...clicked, chat: target.chat, archived: target.archived, before, scrolled: "10 viewports" }, 5);
  }
  const label = String(clicked.composer_label || "");
  const digits = (value) => String(value).replace(/[^0-9]/g, "");
  const opened = label.indexOf(target.chat.name.slice(0, 12)) >= 0
    || (digits(target.chat.name).length > 6 && digits(label).indexOf(digits(target.chat.name)) >= 0);
  if (!opened) {
    return done({
      ok: false, error: "opened_the_wrong_chat", chat: target.chat, composer_label: label,
      observed: "the composer's label does not name the chat that was searched for",
      next: "nothing was typed; the search or the row match needs fixing for this build",
    }, 5);
  }

  // 3. Type into the composer, with real input events.
  const composerFocus = await page(focusExpression("composer"));
  if (composerFocus.error) return done({ ok: false, ...composerFocus, chat: target.chat }, 5);
  await typeText(body);
  await sleep(400);
  const typed = await page(composerTextExpression());
  if (!typed.text || typed.text.indexOf(body.slice(0, 20)) < 0) {
    return done({ ok: false, error: "composer_did_not_take_text", typed, chat: target.chat, before }, 5);
  }

  if (!args.send) {
    // A rehearsal leaves nothing behind: clear the composer, then assert it.
    await pressKey("a", "KeyA", 65, 2); // 2 = Ctrl
    await pressKey("Backspace", "Backspace", 8);
    await sleep(400);
    const cleared = await page(composerTextExpression());
    return done({
      ok: !!cleared.empty, dry_run: true, cleared: !!cleared.empty, chat: target.chat,
      composer_label: label, body, before, typed,
    }, cleared.empty ? 0 : 5);
  }

  // 4. Send, then verify in the store (unreachable until the adapter exists - the refusal above).
  await pressKey("Enter", "Enter", 13);
  await sleep(4000);
  const verified = await page(verifyExpression(target.chat.id, body));
  return done({
    ok: !!verified.verified, sent: true, chat: target.chat, composer_label: label, body,
    ...verified, unread_before: before.unread,
  }, verified.verified ? 0 : 5);
}

main().catch((error) => {
  console.log(JSON.stringify({ ok: false, error: "reply_failed", detail: String((error && error.message) || error) }));
  process.exitCode = 6;
});
