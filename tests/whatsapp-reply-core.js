// The pure reply-route rules: full-composer comparison and reconcile-before-retry.
//
// These are the two rules that decide whether a send happens, so they are tested without a browser.
const assert = require("node:assert/strict");

let checked = 0;
const check = (value, label) => { assert.ok(value, label); checked += 1; };

(async () => {
  const { normalise, composerMatches, classifySendAttempt } = await import("../scripts/whatsapp-reply-core.mjs");

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

  console.log("ALL PASS");
  void checked;
})().catch((error) => {
  console.log("FAIL", (error && error.message) || error);
  console.log("1 FAILURE(S)");
  process.exitCode = 1;
});
