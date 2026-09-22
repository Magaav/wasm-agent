// Send one WhatsApp message through the app's own store action - or, by default, inspect and send
// nothing.
//
//   node scripts/whatsapp-store-send.mjs --chat <id> --expect-browser-endpoint <ws://...> [--body-file f]
//   node scripts/whatsapp-store-send.mjs --chat <id> --expect-browser-endpoint <ws://...> --expect-account <id> --body-file f --send
//
// This is the store route: it calls the app's own
//   WAWebSendTextMsgChatAction.sendTextMsgToChat(chatModel, body, options = {})
// and never opens the chat, never focuses or types into the composer, and never marks anything read.
// The route is conservative on purpose: only the verified self chat is sent to until the ordinary/group
// metadata contract is verified, and both identity bindings are required for a send.
//
// Safety rules, each learned from a failure:
//   - **The effect decides.** A new message in the store, in this chat, mine, with the exact body and a
//     server ack >= 1, is the only proof. A local optimistic insertion (ack 0) is not a send.
//   - **One dispatch, never a retry.** The app action is called once. A throw or a timeout is an
//     ambiguous post-dispatch outcome; it is never retried, because a retry can duplicate an effect.
//   - **A human's draft is not the job's to destroy.** A target draft or link-preview state refuses the
//     send before the action runs, and the route never restores anything.
//   - **The bound identity is proven, not assumed.** Both the account and the browser endpoint must be
//     bound and match exactly; a non-loopback endpoint or an unbound send is refused.
//
// stdout is JSON. Exit codes: 0 ok, 1 usage/body, 3 endpoint, 5 refused, 6 crashed, 7 send resource
// busy, 8 ambiguous post-dispatch outcome.
import { readFileSync } from "node:fs";

import { acquire as acquireSendLock, defaultLockPath } from "./whatsapp-sendlock.mjs";
import {
  parseStoreArgs, parseEndpoint, isLoopbackEndpoint, endpointMatches,
  storeIdentityGuard, routeGuard, stateGuard, classifyStoreAttempt, normalizeBody,
  lookupExpression, actionExpression, verifyExpression,
} from "./whatsapp-store-core.mjs";

let sendLock = null;
let socket = null;
process.on("exit", () => {
  if (sendLock) { try { sendLock.release(); } catch { /* already gone */ } }
});

function call(ws, method, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = (call.next = (call.next || 0) + 1);
    const timer = setTimeout(() => reject(new Error(`timeout: ${method}`)), timeoutMs);
    const onMessage = (event) => {
      let message = null;
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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const args = parseStoreArgs(process.argv.slice(2));
  if (!args.body && args.bodyFile) {
    try { args.body = readFileSync(args.bodyFile, "utf8"); } catch { args.body = ""; }
  }
  const body = normalizeBody(args.body);
  if (body.empty && args.send) {
    console.log(JSON.stringify({ ok: false, error: "body_required" }));
    process.exitCode = 1;
    return;
  }

  // Connect only the explicitly bound endpoint. No discovery, no fallback to a default 9222, and
  // loopback only: a route that can be pointed at a browser nobody named is not a bound route.
  const expectedEndpoint = String(args.expectBrowserEndpoint || "");
  const bound = parseEndpoint(expectedEndpoint);
  if (!bound) {
    const reason = expectedEndpoint === "" ? "endpoint_required" : (isLoopbackEndpoint(expectedEndpoint) ? "endpoint_invalid" : "endpoint_not_loopback");
    console.log(JSON.stringify({ ok: false, error: reason, browser_endpoint: expectedEndpoint || null,
      observed: "the store route connects only an explicitly bound loopback WebSocket page endpoint" }));
    process.exitCode = 3;
    return;
  }

  const ws = new WebSocket(expectedEndpoint);
  socket = ws;
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket refused")), { once: true });
  });
  const actualEndpoint = expectedEndpoint;
  const page = async (expression) => {
    const result = await call(ws, "Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, args.timeoutMs);
    if (result && result.exceptionDetails) throw new Error(result.exceptionDetails.text || "page_threw");
    return JSON.parse(result.result.value);
  };
  const done = (payload, code) => {
    if (sendLock) { sendLock.release(); sendLock = null; }
    console.log(JSON.stringify(payload));
    ws.close();
    process.exitCode = code;
    return;
  };

  // 1. Read-only target resolution: identity, kind, unread, draft, link-preview state, composer.
  const target = await page(lookupExpression(args.chat));
  if (target.error) return done({ ok: false, error: target.error, chat: { id: args.chat }, browser_endpoint: actualEndpoint }, 5);

  const base = {
    chat: { id: target.chat.id, name: target.chat.name, kind: target.chat.kind },
    account: target.account || "",
    browser_endpoint: actualEndpoint,
  };

  if (!args.send) {
    // A rehearsal inspects and reports; it opens nothing and calls no action.
    return done({ ok: true, dry_run: true, ...base, action_available: target.action_available === true,
      target: {
        unread: target.unread, draft: target.draft, url_text: target.url_text, url_number: target.url_number,
        active_chat_id: target.active_chat_id, active_composer: target.active_composer, selection: target.selection,
        is_me: target.is_me === true, account_known: target.account_known === true,
      } }, 0);
  }

  // 2. The bound identity must be proven before anything runs. A send requires both bindings.
  const identity = storeIdentityGuard({
    send: true,
    expectedAccount: args.expectAccount,
    expectedEndpoint: expectedEndpoint,
    actualAccount: target.account || "",
    actualEndpoint,
  });
  if (identity) {
    return done({ ok: false, error: identity, ...base, expected_account: args.expectAccount || null,
      expected_browser_endpoint: expectedEndpoint,
      observed: "the store route is not acting as the locally bound account/endpoint" }, 5);
  }

  // 3. The conservative self-only route. Ordinary/group metadata is not verified here, so a non-self
  //    send is refused by name rather than guessed; the limitation is explicit.
  const route = routeGuard({ send: true, isMe: target.is_me === true });
  if (route) {
    return done({ ok: false, error: route, ...base,
      limitation: "the store route sends only to the verified self chat until the ordinary/group metadata contract is verified; it does not claim all-chat support",
      observed: "the target is not proven to be the account's own chat" }, 5);
  }

  // 4. The pre-effect state guard: refuse a known draft/link-preview state; unknown metadata fails closed.
  const state = stateGuard({ send: true, target: {
    id: target.chat.id,
    unread: target.unread,
    draft: target.draft,
    urlText: target.url_text,
    urlNumber: target.url_number,
    activeChatId: target.active_chat_id,
    activeComposer: target.active_composer,
  } });
  if (state) {
    return done({ ok: false, error: state, ...base,
      target: { unread: target.unread, draft: target.draft, url_text: target.url_text, url_number: target.url_number,
        active_chat_id: target.active_chat_id, active_composer: target.active_composer, selection: target.selection },
      observed: "the target's pre-effect state is not safe to send from; nothing was dispatched" }, 5);
  }

  // 5. The composer is one shared resource; serialise with the other senders. The path can be
  //    overridden so an isolated fixture never writes the operator's real lock directory.
  const lockPath = process.env.WA_WHATSAPP_SEND_LOCK || defaultLockPath();
  sendLock = await acquireSendLock(lockPath, { waitMs: args.lockWaitMs });
  if (!sendLock.ok) {
    return done({ ok: false, error: "send_resource_busy", holder: sendLock.holder, ...base }, 7);
  }

  // 6. Snapshot the newest matching message id, so an identical earlier message cannot be mistaken for
  //    this send, then dispatch the app action exactly once.
  let priorId = "";
  try {
    const snapshot = await page(verifyExpression(target.chat.id, body.effective, ""));
    priorId = snapshot && snapshot.message ? String(snapshot.message.id || "") : "";
  } catch { priorId = ""; }

  let dispatched = false;
  let timedOut = false;
  let actionResult = null;
  try {
    // `attempted` is set before the evaluate is sent: once the app action may have run, a failure is
    // ambiguous, not a pre-dispatch refusal.
    dispatched = true;
    actionResult = await page(actionExpression(target.chat.id, body.effective));
    if (actionResult && actionResult.error && !actionResult.dispatched) {
      // The action refused before doing anything (chat or module missing): a definite refusal.
      dispatched = false;
      return done({ ok: false, error: actionResult.error, ...base, body: body.effective, dispatch: "store_action" }, 5);
    }
  } catch (error) {
    timedOut = true;
  }

  await sleep(1500);
  let verified = null;
  try {
    verified = await page(verifyExpression(target.chat.id, body.effective, priorId));
  } catch { verified = null; }

  const message = verified && verified.message ? verified.message : null;
  const ack = message ? Number(message.ack || 0) : 0;
  const verdict = classifyStoreAttempt({ send: true, dispatched, verified: !!(verified && verified.verified), ack, timedOut });

  if (verdict === "sent") {
    return done({
      ok: true, sent: true, verified: true, ...base, body: body.effective,
      message: { id: message.id, recipient: message.recipient, body: message.body, from_me: message.from_me, ack: message.ack, t: message.t },
      dispatch: "store_action",
    }, 0);
  }

  // A post-dispatch failure is ambiguous: the message may be in flight or already stored. It is never
  // retried, and it never claims no-effect.
  return done({
    ok: false, error: "ambiguous_send", ...base, body: body.effective,
    dispatch: timedOut ? "store_action_timeout" : "store_action",
    verified: false, ack: ack,
    observed: timedOut
      ? "the app action was dispatched and its result did not come back; the message may have been sent"
      : "the app action was dispatched but no new message with a server ack >= 1 is in the store; the send may have happened",
    next: "no retry was dispatched; reconcile the store before trying again",
  }, 8);
}

main().catch((error) => {
  if (socket) { try { socket.close(); } catch { /* closing */ } }
  console.log(JSON.stringify({ ok: false, error: "store_send_failed", detail: String((error && error.message) || error) }));
  process.exitCode = 6;
});
