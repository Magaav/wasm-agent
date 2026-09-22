// The pure half of the reply route: the verified self resolver, composer comparison and send-attempt
// reconciliation.
//
// Kept separate from the browser code so the rules that cost the most to get wrong are testable without a
// browser:
//   - **self is proven by the app, never inferred.** The old resolver treated "a chat with outgoing
//     messages and no incoming" as notes-to-self, which an unanswered third party also satisfies. The
//     resolver now asks the app's own `WAWebUserPrefsMeUser` (`isMeAccount`/`isSerializedWidMe`/the
//     current PN and LID) and refuses when it cannot prove a single self chat.
//   - **compare the full composer, not a preview.**
//   - **reconcile before retrying a send.**

// The page-side target resolver. It runs in the app's own world (returned as a string for
// `Runtime.evaluate`) and is exported so a test can evaluate it against an adversarial fake store.
export function lookupExpression(chat, toSelf) {
  return `(() => {
    const chats = window.require('WAWebChatCollection').ChatCollection.getModelsArray() || [];
    const msgs = window.require('WAWebMsgCollection').MsgCollection.getModelsArray() || [];
    const CHAT = ${JSON.stringify(chat)};
    const TO_SELF = ${toSelf ? "true" : "false"};
    let me = null;
    try { me = window.require('WAWebUserPrefsMeUser'); } catch (e) { me = null; }
    const call = (name, arg) => {
      try { return me && typeof me[name] === 'function' ? me[name](arg) : undefined; } catch (e) { return undefined; }
    };
    const serialize = (value) => {
      if (!value) return '';
      if (typeof value === 'string') return value;
      if (value._serialized) return String(value._serialized);
      if (value.id && value.id._serialized) return String(value.id._serialized);
      return String(value);
    };
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
    // Metadata is tri-state: only a real boolean/number is known; anything else stays null (unknown) so a
    // caller cannot coerce an absent field to false or 0 and treat it as verified.
    const firstBool = (obj, keys) => { for (const key of keys) { if (typeof obj[key] === 'boolean') return obj[key]; } return null; };
    // Only chats the app itself identifies as the account are self. Message direction and display names
    // are never evidence: an unanswered stranger has outgoing-only history too.
    const selfChats = chats.filter((candidate) => isMe(String(candidate.id)));
    const selfAmbiguous = selfChats.length > 1;
    const selfId = selfChats.length === 1 ? String(selfChats[0].id) : '';
    const account = meIds.length ? meIds[0] : (selfId || '');
    const base = { self_id: selfId, self_ambiguous: selfAmbiguous, account: account,
      account_known: accountKnown, messages: msgs.length };
    if (TO_SELF && selfId === '') {
      return JSON.stringify({ error: selfAmbiguous ? 'self_chat_ambiguous' : 'self_chat_unresolved',
        ...base, is_me: false });
    }
    const targetId = TO_SELF ? selfId : CHAT;
    const found = chats.find((candidate) => String(candidate.id) === targetId) || null;
    if (!found) return JSON.stringify({ error: 'chat_not_found', target_id: targetId, ...base, is_me: false });
    return JSON.stringify({
      chat: { id: String(found.id), name: String(found.formattedTitle || found.name || '') },
      ...base, is_me: isMe(String(found.id)),
      // Only a real number is an unread count; absent or non-numeric stays unknown (null), never 0.
      unread: typeof found.unreadCount === 'number' ? found.unreadCount : null,
      archived: firstBool(found, ['archive', 'isArchived', 'archived']),
    });
  })()`;
}

export function normalise(text) {
  return String(text || "").replace(/\s+/g, " ").trim();
}

export function normalizeDigits(value) {
  return String(value || "").replace(/[^0-9]/g, "");
}

// A phone/PN identity is a bare/formatted phone, or a jid ending `@c.us` / `@s.whatsapp.net`. Anything
// else - notably a `@lid`, or a label with letters - is opaque and compares exactly. Stripping *all*
// non-digits made `operator1` equal `other1`, and a PN equal a LID with the same digits.
function phoneDigits(value) {
  const text = String(value || "").trim();
  if (!text) return null;
  const at = text.indexOf("@");
  if (at >= 0) {
    const domain = text.slice(at + 1).toLowerCase();
    if (domain !== "c.us" && domain !== "s.whatsapp.net") return null;
    const digits = text.slice(0, at).replace(/[^0-9]/g, "");
    return digits || null;
  }
  if (/[A-Za-z]/.test(text)) return null;
  const digits = text.replace(/[^0-9]/g, "");
  return digits.length >= 7 ? digits : null;
}

// The profile binds a local account identity; the route must prove it is acting as that identity. Two
// phone/PN shapes compare by digits; an opaque identity (LID, label) compares exactly.
export function accountMatches(expected, actual) {
  const want = phoneDigits(expected), got = phoneDigits(actual);
  if (want !== null && got !== null) return want === got;
  return String(expected) === String(actual);
}

function loopbackHost(host) {
  const value = String(host || "").toLowerCase();
  return value === "localhost" || value === "127.0.0.1" || value === "::1" || value === "[::1]";
}

// Compare two DevTools websocket endpoints. Only genuine loopback aliases are interchangeable; any other
// host, the protocol and the port must match exactly, as must the explicit page id. Comparing only
// port+id let a binding admit a page on a different host or a `wss` endpoint.
export function endpointMatches(expected, actual) {
  const parse = (value) => {
    try {
      const url = new URL(value);
      const id = (url.pathname.split("/devtools/page/")[1] || "").split("/")[0];
      return { protocol: url.protocol, host: url.hostname, port: url.port || (url.protocol === "wss:" ? "443" : "80"), id };
    } catch { return null; }
  };
  const a = parse(expected), b = parse(actual);
  if (!a || !b) return false;
  if (a.id === "" || a.id !== b.id) return false;
  if (a.protocol !== b.protocol || a.port !== b.port) return false;
  if (a.host === b.host) return true;
  return loopbackHost(a.host) && loopbackHost(b.host);
}

// Returns an error code when the route cannot prove the bound identity, null when it can. Only checks
// the expectations the profile actually bound.
export function identityGuard({ expectedAccount, expectedEndpoint, actualAccount, actualEndpoint }) {
  if (expectedAccount) {
    if (!actualAccount) return "account_unproven";
    if (!accountMatches(expectedAccount, actualAccount)) return "account_mismatch";
  }
  if (expectedEndpoint) {
    if (!actualEndpoint) return "endpoint_unproven";
    if (!endpointMatches(expectedEndpoint, actualEndpoint)) return "endpoint_mismatch";
  }
  return null;
}

// The UI route opens the chat, and opening a chat can clear a manually-set unread marker even on
// notes-to-self. This guard is therefore about *opening*, not sending: it applies to a rehearsal too,
// which types and opens the chat. `isMe` is not a bypass. Nonself keeps the stricter rule (always an
// explicit approval); self may open without approval only when unread is a proven zero.
export function sendGuard({ isMe, unread, allowMarkRead }) {
  if (allowMarkRead) return null;
  if (!isMe) return "unread_would_be_broken";
  if (unread === 0) return null;
  return "unread_would_be_broken";
}

export function composerMatches(composerText, expectedText) {
  return normalise(composerText) === normalise(expectedText);
}

// verified: the store now holds the exact message (the only proof a send happened).
// composerText: the composer as it stands after the attempt.
// expectedText: the body we typed, including any label.
// -> "sent" | "retry" | "ambiguous" | "stop"
export function classifySendAttempt({ verified, composerText, expectedText }) {
  if (verified) return "sent";
  const composer = String(composerText || "");
  if (composer.trim() === "") {
    // Nothing left in the composer but no message in the store: it may be in flight, or it may have
    // sent with an id we could not read. Both are ambiguous; neither is safe to retry.
    return "ambiguous";
  }
  if (composerMatches(composer, expectedText)) {
    // Our own body is still exactly in the composer, so the send demonstrably did not clear it. Retrying
    // cannot duplicate an effect that the store would then contain; it is the safe retry.
    return "retry";
  }
  return "stop";
}
