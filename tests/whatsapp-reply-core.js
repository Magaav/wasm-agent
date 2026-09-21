// The pure reply-route rules: full-composer comparison and reconcile-before-retry.
//
// These are the two rules that decide whether a send happens, so they are tested without a browser.
const assert = require("node:assert/strict");

let checked = 0;
const check = (value, label) => { assert.ok(value, label); checked += 1; };

(async () => {
  const { normalise, composerMatches, classifySendAttempt, sendGuard, accountMatches, endpointMatches, identityGuard } = await import("../scripts/whatsapp-reply-core.mjs");

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

  // The raw script refuses a non-self send before it opens anything, unless unread clearing was accepted.
  check(sendGuard({ send: false, chatId: "x@c.us", selfId: "me@c.us" }) === null, "a rehearsal is never blocked");
  check(sendGuard({ send: true, toSelf: true, chatId: "me@c.us", selfId: "me@c.us" }) === null, "a notes-to-self send is allowed");
  check(sendGuard({ send: true, chatId: "me@c.us", selfId: "me@c.us" }) === null, "a resolved self id is allowed even without the flag");
  check(sendGuard({ send: true, chatId: "x@c.us", selfId: "me@c.us", allowMarkRead: true }) === null, "explicit unread acceptance allows a third-party send");
  check(sendGuard({ send: true, chatId: "x@c.us", selfId: "me@c.us" }) === "unread_would_be_broken", "a third-party send is refused by default");

  // The locally bound account/endpoint must be proven by the route; loopback spellings are equivalent.
  check(accountMatches("5511999999999", "5511999999999@s.whatsapp.net") === true, "an account matches its jid form");
  check(accountMatches("5511999999999", "5511999999998") === false, "a different number does not match");
  check(endpointMatches("ws://[::1]:9222/devtools/page/ABC", "ws://127.0.0.1:9222/devtools/page/ABC") === true, "loopback spellings are equivalent");
  check(endpointMatches("ws://[::1]:9222/devtools/page/ABC", "ws://[::1]:9222/devtools/page/OTHER") === false, "a different page id does not match");
  check(endpointMatches("ws://[::1]:9223/devtools/page/ABC", "ws://[::1]:9222/devtools/page/ABC") === false, "a different port does not match");
  check(identityGuard({ expectedAccount: "5511", actualAccount: "5511" }) === null, "a proven identity passes");
  check(identityGuard({ expectedAccount: "5511", actualAccount: "" }) === "account_unproven", "an unproven account is refused");
  check(identityGuard({ expectedAccount: "5511", actualAccount: "5512" }) === "account_mismatch", "a mismatched account is refused");
  check(identityGuard({ expectedEndpoint: "ws://[::1]:9222/devtools/page/A", actualEndpoint: "ws://[::1]:9222/devtools/page/B" }) === "endpoint_mismatch", "a mismatched endpoint is refused");
  check(identityGuard({ expectedEndpoint: "ws://[::1]:9222/devtools/page/A", actualEndpoint: "" }) === "endpoint_unproven", "an unproven endpoint is refused");
  check(identityGuard({}) === null, "an unbound identity is not checked");

  console.log("ALL PASS");
  void checked;
})().catch((error) => {
  console.log("FAIL", (error && error.message) || error);
  console.log("1 FAILURE(S)");
  process.exitCode = 1;
});
