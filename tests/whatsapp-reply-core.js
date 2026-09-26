// The pure reply-route rules: full-composer comparison and reconcile-before-retry.
//
// These are the two rules that decide whether a send happens, so they are tested without a browser.
const assert = require("node:assert/strict");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

let checked = 0;
const check = (value, label) => { assert.ok(value, label); checked += 1; };

(async () => {
  const { normalise, composerMatches, classifySendAttempt, sendGuard, accountMatches, endpointMatches, identityGuard, lookupExpression } = await import("../scripts/whatsapp-reply-core.mjs");

  const retired = spawnSync(process.execPath, [path.resolve(__dirname, "../scripts/whatsapp-reply.mjs"), "--to-self", "--body", "must not type", "--send"], { encoding: "utf8" });
  assert.equal(retired.status, 5, "the legacy UI sender is retired before browser discovery or input");
  assert.equal(JSON.parse(retired.stdout.trim()).error, "ui_input_route_retired");
  checked += 2;

  check(normalise("  a\n b\tc ") === "a b c", "normalise collapses whitespace");
  check(composerMatches("a b c", "a\n b   c") === true, "matching ignores whitespace shape");
  check(composerMatches("a b", "a b c") === false, "different bodies do not match");

  // The regression this exists for: a labelled note is longer than the 160-character preview the old
  // comparison used, so compare the *whole* composer, not a slice.
  const longBody = "x".repeat(300);
  check(composerMatches(`note\n\n${longBody}`, `note\n\n${longBody}`) === true, "a long labelled body compares equal in full");
  check(composerMatches(`note\n\n${longBody}`.slice(0, 160), `note\n\n${longBody}`) === false, "a truncated preview would not compare equal");

  // Reconcile before retry. Only an intact composer proves the send did not happen.
  check(classifySendAttempt({ verified: true, composerText: "", expectedText: "hi" }) === "sent", "a store match is sent");
  check(classifySendAttempt({ verified: false, composerText: "hi", expectedText: "hi" }) === "retry", "an intact composer means safe to retry");
  check(classifySendAttempt({ verified: false, composerText: "", expectedText: "hi" }) === "ambiguous", "an empty composer with no store match is ambiguous");
  check(classifySendAttempt({ verified: false, composerText: "something else", expectedText: "hi" }) === "stop", "an unexpected composer stops the loop");

  // The guard is about *opening*, not sending: a rehearsal opens too. `isMe` is not a bypass, and a self
  // chat may open without approval only when unread is a proven zero.
  check(sendGuard({ isMe: true, unread: 0 }) === null, "a self chat with proven zero unread opens");
  check(sendGuard({ isMe: true, unread: 3 }) === "unread_would_be_broken", "a self chat with unread is refused without approval");
  check(sendGuard({ isMe: true, unread: null }) === "unread_would_be_broken", "a self chat with unknown unread is refused");
  check(sendGuard({ isMe: false, unread: 0 }) === "unread_would_be_broken", "a nonself chat needs approval even at zero unread");
  check(sendGuard({ isMe: false, unread: 0, allowMarkRead: true }) === null, "explicit approval opens a nonself chat");
  check(sendGuard({ isMe: true, unread: 3, allowMarkRead: true }) === null, "explicit approval opens a self chat with unread");

  // The locally bound account/endpoint must be proven by the route. Only real phone/PN shapes compare by
  // digits; a label or a LID compares exactly, and only loopback aliases are interchangeable.
  check(accountMatches("5511999999999", "5511999999999@s.whatsapp.net") === true, "an account matches its jid form");
  check(accountMatches("5511999999999", "5511999999998") === false, "a different number does not match");
  check(accountMatches("operator1", "other1") === false, "a labelled identity is not reduced to its digits");
  check(accountMatches("123@c.us", "123@lid") === false, "a PN and a LID with the same digits never match");
  check(accountMatches("123@lid", "123@lid") === true, "an opaque identity matches exactly");
  check(endpointMatches("ws://[::1]:9222/devtools/page/ABC", "ws://127.0.0.1:9222/devtools/page/ABC") === true, "loopback aliases are equivalent");
  check(endpointMatches("ws://[::1]:9222/devtools/page/ABC", "ws://[::1]:9222/devtools/page/OTHER") === false, "a different page id does not match");
  check(endpointMatches("ws://[::1]:9223/devtools/page/ABC", "ws://[::1]:9222/devtools/page/ABC") === false, "a different port does not match");
  check(endpointMatches("ws://[::1]:9222/devtools/page/ABC", "ws://10.0.0.1:9222/devtools/page/ABC") === false, "a non-loopback host never matches a loopback binding");
  check(endpointMatches("ws://[::1]:9222/devtools/page/ABC", "wss://[::1]:9222/devtools/page/ABC") === false, "a different protocol does not match");
  check(identityGuard({ expectedAccount: "5511", actualAccount: "5511" }) === null, "a proven identity passes");
  check(identityGuard({ expectedAccount: "5511", actualAccount: "" }) === "account_unproven", "an unproven account is refused");
  check(identityGuard({ expectedAccount: "5511", actualAccount: "5512" }) === "account_mismatch", "a mismatched account is refused");
  check(identityGuard({ expectedEndpoint: "ws://[::1]:9222/devtools/page/A", actualEndpoint: "ws://[::1]:9222/devtools/page/B" }) === "endpoint_mismatch", "a mismatched endpoint is refused");
  check(identityGuard({ expectedEndpoint: "ws://[::1]:9222/devtools/page/A", actualEndpoint: "" }) === "endpoint_unproven", "an unproven endpoint is refused");
  check(identityGuard({}) === null, "an unbound identity is not checked");

  // The self resolver is evaluated against an adversarial fake store: an unanswered stranger (outgoing
  // only) appears BEFORE the real self chat, and only `WAWebUserPrefsMeUser.isMeAccount` proves self.
  const evaluateLookup = (chats, meModule, toSelf, chat = "") => {
    const window = {
      require: (name) => {
        if (name === "WAWebChatCollection") return { ChatCollection: { getModelsArray: () => chats } };
        if (name === "WAWebMsgCollection") return { MsgCollection: { getModelsArray: () => [] } };
        if (name === "WAWebUserPrefsMeUser") { if (!meModule) throw new Error("no me module"); return meModule; }
        throw new Error("unexpected require " + name);
      },
    };
    return JSON.parse(new Function("window", "return " + lookupExpression(chat, toSelf))(window));
  };
  const stranger = { id: "5511888888888@c.us", formattedTitle: "Me (looks like me)" };
  const selfChat = { id: "5511999999999@c.us", formattedTitle: "Notes" };
  const isMeAccount = (id) => String(id) === selfChat.id;
  const meModule = { isMeAccount, isSerializedWidMe: () => false, getMaybeMePnUser: () => ({ _serialized: selfChat.id }), getMaybeMeLidUser: () => null };
  const resolved = evaluateLookup([stranger, selfChat], meModule, true);
  check(resolved.self_id === selfChat.id, "an unanswered stranger is never selected as self");
  check(resolved.account === selfChat.id, "the account is resolved from the app's own identity");
  const addressed = evaluateLookup([stranger, selfChat], meModule, false, selfChat.id);
  check(addressed.is_me === true, "a --chat lookup proves the account through the app");
  const noProof = evaluateLookup([stranger, selfChat], null, true);
  check(noProof.error === "self_chat_unresolved", "without the app's proof, self is refused, never guessed");
  const ambiguous = evaluateLookup([{ id: "a@c.us" }, { id: "b@c.us" }], { isMeAccount: () => true, getMaybeMePnUser: () => null, getMaybeMeLidUser: () => null }, true);
  check(ambiguous.error === "self_chat_ambiguous", "multiple self chats are refused, not picked");
  // Metadata is tri-state: an absent unread is null (unknown), a numeric one is preserved, and an
  // archive-like non-boolean is not coerced to false.
  const withUnread = evaluateLookup([{ id: selfChat.id, unreadCount: 4, archive: "true" }], meModule, false, selfChat.id);
  check(withUnread.unread === 4, "a numeric unread count is preserved");
  check(withUnread.archived === null, "a non-boolean archive field stays unknown");
  const withoutUnread = evaluateLookup([{ id: selfChat.id }], meModule, false, selfChat.id);
  check(withoutUnread.unread === null, "an absent unread count stays unknown, never 0");
  check(withoutUnread.archived === null, "an absent archive stays unknown");

  console.log("ALL PASS");
  void checked;
})().catch((error) => {
  console.log("FAIL", (error && error.message) || error);
  console.log("1 FAILURE(S)");
  process.exitCode = 1;
});
