// The pure half of the reply route: composer comparison and send-attempt reconciliation.
//
// Kept separate from the browser code so the two rules that cost the most to get wrong are testable
// without a browser:
//   - **compare the full composer, not a preview.** A 160-character preview made a labelled note look
//     like "something other than the exact reply", so a correct route refused to send. The comparison
//     must see the whole composer text.
//   - **reconcile before retrying a send.** This browser drops key dispatches, so a send is retried -
//     but only when the effect proves the send did *not* happen. If the composer is empty and the store
//     has no matching message, the outcome is ambiguous and there is no retry.
export function normalise(text) {
  return String(text || "").replace(/\s+/g, " ").trim();
}

export function normalizeDigits(value) {
  return String(value || "").replace(/[^0-9]/g, "");
}

// The profile binds a local account identity; the route must prove it is acting as that identity. A
// jid (`5511...@s.whatsapp.net`) and a bare number compare by digits.
export function accountMatches(expected, actual) {
  const want = normalizeDigits(expected), got = normalizeDigits(actual);
  if (want && got) return want === got;
  return String(expected) === String(actual);
}

// Compare the explicit page target and port of two ws endpoints. Loopback host spellings differ
// (`localhost` / `127.0.0.1` / `[::1]`); the page id and port are the binding.
export function endpointMatches(expected, actual) {
  const parse = (value) => {
    try {
      const url = new URL(value);
      const id = (url.pathname.split("/devtools/page/")[1] || "").split("/")[0];
      return { port: url.port || (url.protocol === "wss:" ? "443" : "80"), id };
    } catch { return null; }
  };
  const a = parse(expected), b = parse(actual);
  if (!a || !b) return false;
  return a.port === b.port && a.id !== "" && a.id === b.id;
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

// The raw reply script is reachable directly, not only through the profile-scoped Lua tool, so it must
// refuse a non-self send by itself unless unread clearing was explicitly accepted. Returns an error code
// when the send must not proceed, null when it may. A rehearsal (`send` false) always passes.
//   - toSelf: the resolved target is the operator's own notes-to-self chat
//   - chatId/selfId: the resolved ids, so the check does not depend on the caller's flag
//   - allowMarkRead: the explicit `--allow-mark-read` / env approval
//   - opening the chat is what clears the marker, so this must be decided *before* the chat is opened
//     (the tool checks `open` false).
export function sendGuard({ send, toSelf, chatId, selfId, allowMarkRead }) {
  if (!send) return null;
  if (toSelf) return null;
  if (selfId && chatId && String(chatId) === String(selfId)) return null;
  if (allowMarkRead) return null;
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
