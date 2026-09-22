// The pure half of the store send route: identity/endpoint binding, the conservative self-only route
// rule, the pre-effect state guard, the send reconciliation, and the page expressions the CLI evaluates.
//
// Kept separate from the browser code so the rules that decide whether a message is sent are testable
// without a browser, and so they can be evaluated against adversarial fake app stores.
//
// The contract this route is built on (read from the app, not guessed):
//   WAWebSendTextMsgChatAction.sendTextMsgToChat(chatModel, body, options = {})
//     -> createTextMsgData (trims the body; empty body returns null)
//     -> maybeShowBizBot1pTos, maybeDisableEphemeralityForMsg
//     -> addAndSendTextMsg (Msg model, storeMessages, sendMsgRecord)
//   It clears the target chat's `urlText`/`urlNumber` and clears presence. It is the app's own send
//   pipeline; a lower-level helper is not equivalent and is never used here.
//
// The route never opens the chat, never types, never focuses and never marks read. That is what makes
// it the safe route for an ordinary conversation; the app's own action is still the only sender.

// ---- arguments ---------------------------------------------------------------

export function parseStoreArgs(argv) {
  const args = {
    chat: "",
    body: "",
    bodyFile: "",
    send: false,
    expectAccount: "",
    expectBrowserEndpoint: "",
    lockWaitMs: 30000,
    timeoutMs: 20000,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--chat") { args.chat = String(value || ""); index += 1; }
    else if (flag === "--body") { args.body = String(value || ""); index += 1; }
    // A body arrives from a file so untrusted text never travels through a shell command line.
    else if (flag === "--body-file") { args.bodyFile = String(value || ""); index += 1; }
    else if (flag === "--send") { args.send = true; }
    // The locally bound identity the route must prove it is acting as. Only the profile passes these;
    // an event or a model argument never does.
    else if (flag === "--expect-account") { args.expectAccount = String(value || ""); index += 1; }
    else if (flag === "--expect-browser-endpoint") { args.expectBrowserEndpoint = String(value || ""); index += 1; }
    else if (flag === "--lock-wait-ms") { args.lockWaitMs = Number(value) || 0; index += 1; }
    else if (flag === "--timeout-ms") { args.timeoutMs = Number(value) || 0; index += 1; }
  }
  return args;
}

// ---- endpoint binding --------------------------------------------------------
// Only a loopback WebSocket page endpoint is accepted, and only as an exact binding: protocol, host,
// port and page id must all match. There is deliberately no discovery and no fallback to a default
// 9222, so a test (or an operator) can never be redirected to a real browser it did not name.

export function normalizeLoopbackHost(host) {
  const value = String(host || "").trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (value === "localhost" || value === "127.0.0.1" || value === "::1" || value === "0:0:0:0:0:0:0:1") {
    return "127.0.0.1";
  }
  return null;
}

export function parseEndpoint(value) {
  let url = null;
  try { url = new URL(String(value || "")); } catch { return null; }
  if (url.protocol !== "ws:" && url.protocol !== "wss:") return null;
  const host = normalizeLoopbackHost(url.hostname);
  if (!host) return null;
  const pageId = (url.pathname.split("/devtools/page/")[1] || "").split("/")[0];
  if (!pageId) return null;
  return { protocol: url.protocol, host, port: url.port || (url.protocol === "wss:" ? "443" : "80"), pageId };
}

export function endpointMatches(expected, actual) {
  const want = parseEndpoint(expected), got = parseEndpoint(actual);
  if (!want || !got) return false;
  return want.protocol === got.protocol && want.host === got.host && want.port === got.port && want.pageId === got.pageId;
}

export function isLoopbackEndpoint(value) {
  return parseEndpoint(value) !== null;
}

// ---- account binding ---------------------------------------------------------
// A typed id is a PN (`@s.whatsapp.net`, `@c.us`, or a bare all-digits number) or a LID (`@lid`).
// Anything else is a label. A LID is not a PN, and a label that happens to contain the same digits is
// not the account: only two PNs compare by phone digits, and only two LIDs compare by exact id. This is
// stricter than stripping every non-digit character, which made "Me (+55 11 99999-9999)" match a real
// number and made a LID with the same digits match a PN.

const PN_SUFFIXES = ["@s.whatsapp.net", "@c.us"];

export function parseAccount(value) {
  const text = String(value == null ? "" : value).trim();
  if (text === "") return { kind: "unknown", id: "" };
  const lower = text.toLowerCase();
  if (lower.endsWith("@lid")) {
    const local = lower.slice(0, -4);
    return local === "" ? { kind: "unknown", id: text } : { kind: "lid", id: lower };
  }
  for (const suffix of PN_SUFFIXES) {
    if (lower.endsWith(suffix)) {
      const digits = lower.slice(0, -suffix.length).replace(/[^0-9]/g, "");
      return digits.length >= 8 ? { kind: "pn", id: lower, digits } : { kind: "unknown", id: text };
    }
  }
  // A bare all-digits string is a PN. A formatted label (`+55 11 99999-9999`, a title) is not.
  if (/^[0-9]{8,20}$/.test(text)) return { kind: "pn", id: text, digits: text };
  return { kind: "unknown", id: text };
}

export function accountMatches(expected, actual) {
  const want = parseAccount(expected), got = parseAccount(actual);
  if (!want.id || !got.id) return false;
  if (want.kind === "pn" && got.kind === "pn") return want.digits === got.digits;
  if (want.kind === "lid" && got.kind === "lid") return want.id === got.id;
  // Different kinds (a LID is not a PN), or a label on either side: only an exact typed id qualifies.
  return want.id === got.id;
}

// ---- guards ------------------------------------------------------------------
// For a send, both bindings are required: a profile that binds an account or an endpoint is not
// satisfied by a script that ignores it, and a route with no binding cannot prove who it is.

export function storeIdentityGuard({ send, expectedAccount, expectedEndpoint, actualAccount, actualEndpoint }) {
  if (send) {
    // A send requires both bindings, and both must be proven to match.
    if (!expectedAccount) return "account_unbound";
    if (!expectedEndpoint) return "endpoint_unbound";
    if (!actualAccount) return "account_unproven";
    if (!accountMatches(expectedAccount, actualAccount)) return "account_mismatch";
    if (!actualEndpoint) return "endpoint_unproven";
    if (!endpointMatches(expectedEndpoint, actualEndpoint)) return "endpoint_mismatch";
    return null;
  }
  // A rehearsal has no effect: a mismatch the app actually reported is still visible, but an unproven
  // identity does not block a read-only inspection.
  if (expectedAccount && actualAccount && !accountMatches(expectedAccount, actualAccount)) return "account_mismatch";
  if (expectedEndpoint && actualEndpoint && !endpointMatches(expectedEndpoint, actualEndpoint)) return "endpoint_mismatch";
  return null;
}

// The conservative initial route: only the verified self chat is sent to. Ordinary/group/business
// metadata contracts are not verified here, so a non-self send is refused by name rather than guessed.
// The route can be widened only after the metadata contract is verified.
export function routeGuard({ send, isMe }) {
  if (!send) return null;
  if (isMe === true) return null;
  return "ordinary_chat_unverified";
}

// The pre-effect state guard. A send is refused when the target is known to hold a draft or a link
// preview (the action clears `urlText`/`urlNumber`), and when the metadata needed to know that is
// missing: unknown fails closed. A rehearsal is never blocked.
export function stateGuard({ send, target }) {
  if (!send) return null;
  if (!target || typeof target !== "object") return "target_unknown";
  if (target.unread === null || target.unread === undefined) return "unread_unknown";
  if (target.draft === null || target.draft === undefined) return "draft_unknown";
  if (target.urlText === null || target.urlText === undefined) return "link_preview_unknown";
  if (target.urlNumber === null || target.urlNumber === undefined) return "link_preview_unknown";
  if (target.draft !== "") return "target_draft_present";
  if (target.urlText !== "" || target.urlNumber !== "") return "link_preview_present";
  // A known active composer on the target with content is a human's newer draft; never overwrite it.
  if (target.activeChatId === target.id && typeof target.activeComposer === "string" && target.activeComposer !== "") {
    return "target_composer_occupied";
  }
  return null;
}

// The action's outcome. Once the action has been dispatched, no failure proves no-effect: the message
// may be in flight or already stored. A proof (a new message with the exact recipient, body and fromMe,
// and a server ack >= 1) is `sent` even if the action call itself timed out; a local optimistic
// insertion (ack 0) is not proof, and a dispatched action with no proof is `ambiguous`.
export function classifyStoreAttempt({ send, dispatched, verified, ack, timedOut }) {
  if (!send) return "dry_run";
  if (!dispatched) return "refused";
  if (verified === true && Number(ack) >= 1) return "sent";
  if (timedOut) return "ambiguous";
  return "ambiguous";
}

// The body the action will actually send: it trims. An empty trimmed body is refused; a body whose
// whitespace was trimmed is reported as normalized so the caller can see the difference.
export function normalizeBody(body) {
  const raw = String(body == null ? "" : body);
  const trimmed = raw.trim();
  return { raw, effective: trimmed, normalized: trimmed !== raw, empty: trimmed === "" };
}

// ---- page expressions --------------------------------------------------------
// Each is a string for `Runtime.evaluate`. A backtick inside - including in a comment - ends the
// template literal and breaks the file, so none appears below.

// Read-only: resolve the target, the app's own self identity, the target's draft and link-preview
// state, the active composer/selection, and whether the store action exists. It opens nothing.
export function lookupExpression(chatId) {
  return `(() => {
    const grab = (name) => { try { return window.require(name); } catch (error) { return null; } };
    const chatModule = grab('WAWebChatCollection');
    if (!chatModule || !chatModule.ChatCollection) return JSON.stringify({ error: 'no_chat_collection' });
    const chats = chatModule.ChatCollection.getModelsArray() || [];
    const CHAT = ${JSON.stringify(chatId)};
    const serialize = (value) => {
      if (value === null || value === undefined) return '';
      if (typeof value === 'string') return value;
      if (value._serialized) return String(value._serialized);
      if (value.id && value.id._serialized) return String(value.id._serialized);
      return String(value);
    };
    let me = null;
    try { me = grab('WAWebUserPrefsMeUser'); } catch (error) { me = null; }
    const call = (name, arg) => { try { return me && typeof me[name] === 'function' ? me[name](arg) : undefined; } catch (error) { return undefined; } };
    const meIds = [];
    for (const value of [call('getMaybeMePnUser'), call('getMaybeMeLidUser')]) {
      const id = serialize(value);
      if (id && meIds.indexOf(id) < 0) meIds.push(id);
    }
    const accountKnown = meIds.length > 0 || typeof (me && me.isMeAccount) === 'function';
    const isMe = (id) => {
      const value = String(id || '');
      if (!value) return false;
      if (call('isMeAccount', value) === true) return true;
      if (call('isSerializedWidMe', value) === true) return true;
      return meIds.indexOf(value) >= 0;
    };
    const chat = chats.find((candidate) => String(candidate.id) === CHAT) || null;
    if (!chat) return JSON.stringify({ error: 'chat_not_found', account: meIds[0] || '', account_known: accountKnown });
    const kind = CHAT.endsWith('@g.us') ? 'group' : CHAT.endsWith('@broadcast') ? 'broadcast'
      : (CHAT.endsWith('@c.us') || CHAT.endsWith('@lid') || CHAT.endsWith('@s.whatsapp.net')) ? 'direct' : 'unknown';
    const maybe = (value) => value === undefined || value === null ? null : String(value);
    let active = null;
    try {
      const composer = grab('WAWebComposerActions') || grab('WAWebComposeBoxActions');
      if (composer && typeof composer.getActiveComposer === 'function') active = composer.getActiveComposer();
    } catch (error) { active = null; }
    const activeChatId = active ? String(active.chatId || (active.chat && active.chat.id) || '') : '';
    const activeComposer = active ? String(active.text || '') : '';
    const selection = active && active.selectionStart !== undefined && active.selectionStart !== null ? String(active.selectionStart) : null;
    const action = grab('WAWebSendTextMsgChatAction');
    return JSON.stringify({
      ok: true,
      chat: { id: String(chat.id), name: String(chat.formattedTitle || chat.name || ''), kind },
      is_me: isMe(String(chat.id)),
      account: meIds[0] || '',
      account_ids: meIds,
      account_known: accountKnown,
      unread: Number(chat.unreadCount || 0),
      draft: maybe(chat.draft),
      url_text: maybe(chat.urlText),
      url_number: maybe(chat.urlNumber),
      active_chat_id: activeChatId,
      active_composer: activeComposer,
      selection: selection,
      action_available: !!(action && typeof action.sendTextMsgToChat === 'function'),
      chats: chats.length,
    });
  })()`;
}

// The one action call. `dispatched` is set before the app action runs, so a throw or a timeout is
// reported as an ambiguous post-dispatch outcome, never as a pre-dispatch refusal.
export function actionExpression(chatId, body) {
  return `(async () => {
    const chats = window.require('WAWebChatCollection').ChatCollection.getModelsArray() || [];
    const chat = chats.find((candidate) => String(candidate.id) === ${JSON.stringify(chatId)});
    if (!chat) return JSON.stringify({ error: 'chat_not_found' });
    let action = null;
    try { action = window.require('WAWebSendTextMsgChatAction'); } catch (error) { action = null; }
    if (!action || typeof action.sendTextMsgToChat !== 'function') return JSON.stringify({ error: 'store_action_missing' });
    try {
      const result = await action.sendTextMsgToChat(chat, ${JSON.stringify(body)}, {});
      return JSON.stringify({ dispatched: true, result: result === undefined || result === null ? null : String((result && result.id) || result) });
    } catch (error) {
      return JSON.stringify({ dispatched: true, error: String((error && error.message) || error) });
    }
  })()`;
}

// The proof: a *new* message in the store, in this chat, mine, with the exact body, and a server ack
// of at least 1. `excludeId` is the newest matching id from before the action, so an identical earlier
// message cannot be mistaken for this send. A local optimistic insertion (ack 0) is not proof.
export function verifyExpression(chatId, body, excludeId) {
  return `(() => {
    const grab = (name) => { try { return window.require(name); } catch (error) { return null; } };
    const msgModule = grab('WAWebMsgCollection');
    const msgs = (msgModule && msgModule.MsgCollection) ? (msgModule.MsgCollection.getModelsArray() || []) : [];
    const CHAT = ${JSON.stringify(chatId)};
    const BODY = ${JSON.stringify(body)};
    const EXCLUDE = ${JSON.stringify(excludeId || "")};
    let found = null;
    for (let index = msgs.length - 1; index >= 0; index -= 1) {
      const message = msgs[index];
      const key = message.id || {};
      if (String(key.remote || '') !== CHAT) continue;
      if (!key.fromMe) continue;
      if (String(message.body || '') !== BODY) continue;
      const id = String(key.id || '');
      if (!id || (EXCLUDE && id === EXCLUDE)) continue;
      found = {
        id: id,
        recipient: String(key.remote || ''),
        body: String(message.body || ''),
        from_me: true,
        ack: Number(message.ack || 0),
        t: Number(message.t || 0),
      };
      break;
    }
    return JSON.stringify({ verified: !!found, message: found });
  })()`;
}
