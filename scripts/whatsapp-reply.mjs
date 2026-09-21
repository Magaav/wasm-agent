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

import { acquire as acquireSendLock, defaultLockPath } from "./whatsapp-sendlock.mjs";
import { composerMatches, classifySendAttempt, sendGuard, identityGuard, lookupExpression } from "./whatsapp-reply-core.mjs";

// The composer lock is released by `done`, but a crash between acquiring and sending must not leave the
// lock for the stale timeout. One process-wide handler covers every abnormal exit.
let sendLock = null;
process.on("exit", () => {
  if (sendLock) { try { sendLock.release(); } catch { /* already gone */ } }
});

function parseArgs(argv) {
  const args = { chat: "", body: "", bodyFile: "", send: false, toSelf: false, label: "", timeoutMs: 20000, lockWaitMs: 30000, allowMarkRead: process.env.WA_WHATSAPP_ALLOW_MARK_READ === "1", lookupOnly: false, expectAccount: "", expectBrowserEndpoint: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--chat") { args.chat = String(value || ""); index += 1; }
    else if (flag === "--body") { args.body = String(value || ""); index += 1; }
    // A body can arrive from a file so an untrusted message never travels through a shell command line.
    else if (flag === "--body-file") { args.bodyFile = String(value || ""); index += 1; }
    else if (flag === "--label") { args.label = String(value || ""); index += 1; }
    else if (flag === "--lock-wait-ms") { args.lockWaitMs = Number(value) || 0; index += 1; }
    // Explicit acceptance that opening this chat will clear its unread marker. Without it a non-self
    // `--send` is refused before the chat is opened.
    else if (flag === "--allow-mark-read") { args.allowMarkRead = true; }
    // Read-only resolution: report the target and the self chat id without opening anything.
    else if (flag === "--lookup-only") { args.lookupOnly = true; }
    // The locally bound identity the route must prove it is acting as. Only the profile passes these; an
    // event or a model argument never does.
    else if (flag === "--expect-account") { args.expectAccount = String(value || ""); index += 1; }
    else if (flag === "--expect-browser-endpoint") { args.expectBrowserEndpoint = String(value || ""); index += 1; }
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

// `lookupExpression` lives in the pure core module so the verified-self resolver can be evaluated against
// an adversarial fake store in tests. See scripts/whatsapp-reply-core.mjs.

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
    return JSON.stringify({ text: text, preview: text.slice(0, 160), length: text.length, empty: text.trim() === '', label: String(composer.getAttribute('aria-label') || '') });
  })()`;
}

// The message must exist in the store: that chat, mine, that body, and *new since the snapshot*. The
// `excludeId` is the newest matching message id taken before the send, so an identical body sent earlier
// cannot be mistaken for this send. A send nobody can see did not happen, and saying so is the only
// honest report.
function verifyExpression(chatId, body, excludeId) {
  return `(() => {
    const chats = window.require('WAWebChatCollection').ChatCollection.getModelsArray() || [];
    const msgs = window.require('WAWebMsgCollection').MsgCollection.getModelsArray() || [];
    const CHAT = ${JSON.stringify(chatId)};
    const BODY = ${JSON.stringify(body)};
    const EXCLUDE = ${JSON.stringify(excludeId || "")};
    let found = null;
    for (let index = msgs.length - 1; index >= 0; index -= 1) {
      const message = msgs[index];
      if (String((message.id && message.id.remote) || '') !== CHAT) continue;
      if (!(message.id && message.id.fromMe)) continue;
      if (String(message.body || '') !== BODY) continue;
      const id = String((message.id && message.id.id) || '');
      if (EXCLUDE && id === EXCLUDE) continue;
      found = { id: id, t: message.t || 0, ack: message.ack };
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
  if (!args.body && args.bodyFile) {
    const { readFileSync } = await import("node:fs");
    try { args.body = readFileSync(args.bodyFile, "utf8"); } catch (error) { args.body = ""; }
  }
  if (!args.body && !args.lookupOnly) { console.log(JSON.stringify({ error: "body_required" })); process.exitCode = 1; return; }
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
    if (sendLock) { sendLock.release(); sendLock = null; }
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

  // Read-only resolution: no lock, no open, no type, no send. This is how an operator or a proof script
  // discovers the notes-to-self chat id (`self_id`) and the account (`account`) before binding them.
  const actualEndpoint = `ws://${endpoint.host}:${endpoint.port}/devtools/page/${tab.id}`;
  const actualAccount = target.account || target.self_id || "";
  if (args.lookupOnly) {
    return done({ ok: true, lookup_only: true, chat: target.chat, self_id: target.self_id || null,
      account: actualAccount, is_me: target.is_me === true, account_known: target.account_known === true,
      browser_endpoint: actualEndpoint, before }, 0);
  }

  // The locally bound identity must be proven by the route before it opens anything. A profile that binds
  // an account or a browser endpoint is not satisfied by a script that ignores it.
  const identity = identityGuard({
    expectedAccount: args.expectAccount,
    expectedEndpoint: args.expectBrowserEndpoint,
    actualAccount,
    actualEndpoint,
  });
  if (identity) {
    return done({
      ok: false, error: identity, chat: target.chat, account: actualAccount, browser_endpoint: actualEndpoint,
      expected_account: args.expectAccount || null, expected_browser_endpoint: args.expectBrowserEndpoint || null,
      observed: "the route is not acting as the locally bound account/endpoint",
      next: "bind the account and browser_endpoint the session actually uses",
    }, 9);
  }

  // Opening the chat is what clears the unread marker, and this applies to a rehearsal too (it opens and
  // types). `isMe` is not a bypass: a manually-marked-unread notes-to-self can have unread. Nonself keeps
  // the stricter approval rule; self may open without approval only when unread is a proven zero.
  const guard = sendGuard({
    isMe: target.is_me === true,
    unread: target.unread,
    allowMarkRead: args.allowMarkRead,
  });
  if (guard) {
    return done({
      ok: false, error: guard, chat: target.chat, before, account: actualAccount, browser_endpoint: actualEndpoint,
      observed: "opening this chat would clear an unread marker that is nonzero or unproven",
      next: "pass --allow-mark-read to accept that, or use an approved store route that opens nothing",
    }, 8);
  }

  // The composer is one shared resource, and two jobs (or two sentinel processes) can each want it. The
  // lock serialises them; a live holder is reported as `send_resource_busy` rather than typed over. The
  // target lookup above is read-only and does not need the lock.
  sendLock = await acquireSendLock(defaultLockPath(), { waitMs: args.lockWaitMs });
  if (!sendLock.ok) {
    return done({ ok: false, error: "send_resource_busy", holder: sendLock.holder, chat: target.chat }, 7);
  }

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

  // A human's draft is not the job's to destroy. Before anything is typed, the composer must be empty;
  // if it holds a restored draft or a half-written message, the tool refuses and leaves it exactly as it
  // was. This is what makes "clean only proven own residue" true: from here on, anything in the composer
  // was typed by this process.
  if (!composer.empty) {
    return done({
      ok: false, error: "composer_preoccupied", chat: target.chat, composer: { preview: composer.preview, length: composer.length },
      observed: "the composer already holds text (a restored draft or an unsent human message)",
      next: "nothing was typed and nothing was cleared; a human's draft is not the job's to destroy",
      before,
    }, 5);
  }

  // 3. Type into the composer, with real input events.
  const composerFocus = await page(focusExpression("composer"));
  if (composerFocus.error) return done({ ok: false, ...composerFocus, chat: target.chat }, 5);
  await typeText(body);
  await sleep(400);
  const typed = await page(composerTextExpression());
  // WhatsApp restores a chat's unsent draft, so "the composer contains my text" is not enough: a
  // leftover draft would be sent *with* the reply. Either it is my body and nothing else, or nothing is
  // sent at all. The comparison sees the *whole* composer - a 160-character preview once made a correct
  // labelled note look like "something other than the exact reply" and the tool refused to send.
  const expected = args.label ? `${args.label}\n\n${body}` : body;
  if (!composerMatches(typed.text, expected)) {
    return done({
      ok: false, error: "composer_not_exactly_the_body", typed: { preview: typed.preview, length: typed.length }, chat: target.chat, body: expected, before,
      observed: "the composer holds something other than the exact reply",
      next: "nothing was sent; the composer was left untouched",
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
      composer_label: label, body, before, account: actualAccount, browser_endpoint: actualEndpoint,
      typed: { preview: typed.preview, length: typed.length },
    }, cleared.empty ? 0 : 5);
  }

  // 4. Send, and let the *effect* decide. This browser's input pipeline drops key dispatches (measured:
  //    of 112 backspaces, 56 landed; Enter timed out twice), so a send is retried - but only when the
  //    effect proves it did not happen. The snapshot id is taken first so an identical body sent earlier
  //    cannot be mistaken for this send, and a dispatch whose outcome is ambiguous is never retried.
  const snapshot = await page(verifyExpression(target.chat.id, body, ""));
  const priorId = snapshot.message ? snapshot.message.id : "";
  let dispatch = "not_attempted";
  let verified = { verified: false };
  let ambiguous = false;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    dispatch = await pressKey("Enter", "Enter", 13, 0, "\r");
    await sleep(3500);
    verified = await page(verifyExpression(target.chat.id, body, priorId));
    if (verified.verified) break;
    // Reconcile before retrying: only a composer that still holds exactly our body proves the send did
    // not happen. An empty composer with no message in the store is ambiguous - it may be in flight - so
    // the loop stops rather than dispatching a second Enter.
    const composerAfter = await page(composerTextExpression());
    const verdict = classifySendAttempt({ verified: false, composerText: composerAfter.text, expectedText: expected });
    if (verdict === "retry") continue;
    if (verdict === "ambiguous") ambiguous = true;
    break;
  }
  if (!verified.verified && ambiguous) {
    return done({
      ok: false, error: "ambiguous_send", dispatch, chat: target.chat, composer_label: label, body: expected,
      ...verified, unread_before: before.unread,
      observed: "Enter was dispatched and the store has no matching message, but the composer is empty; the send may have happened",
      next: "no retry was dispatched; reconcile the store before trying again",
    }, 5);
  }
  if (!verified.verified) {
    // A safe abort: the precheck proved the composer was empty before typing, so content equal to our
    // body is proven our own residue and can be cleared. Anything else is left untouched.
    const composerAfter = await page(composerTextExpression());
    let cleared = false;
    if (composerMatches(composerAfter.text, expected)) {
      await pressKey("a", "KeyA", 65, 2); // 2 = Ctrl
      await pressKey("Backspace", "Backspace", 8);
      await sleep(600);
      cleared = !!(await page(composerTextExpression())).empty;
    }
    return done({
      ok: false, error: "not_verified", dispatch, chat: target.chat, composer_label: label, body: expected,
      ...verified, unread_before: before.unread, cleared_own_residue: cleared,
      observed: "the store does not hold the sent message",
      next: "no further retry; reconcile before trying again",
    }, 5);
  }
  return done({
    ok: true, sent: true, dispatch, chat: target.chat, composer_label: label, body: expected,
    ...verified, unread_before: before.unread, account: actualAccount, browser_endpoint: actualEndpoint,
  }, 0);
}

main().catch((error) => {
  console.log(JSON.stringify({ ok: false, error: "reply_failed", detail: String((error && error.message) || error) }));
  process.exitCode = 6;
});
