// The adapter's derived metadata: `left`, tested without a browser.
//
// This is the branch that decides whether a message can reach a model at all. Every chat in the live
// store used to be refused `left_unknown`, so nothing was ever emitted - the test below pins the
// derivation that replaced it, including the cases that must still fail closed.
const assert = require("node:assert/strict");

let checked = 0;
const check = (value, label) => { assert.ok(value, label); checked += 1; };

(async () => {
  const { deriveLeft, sameWid } = await import("../scripts/whatsapp-read-core.mjs");

  // An explicit flag always wins, whatever else the build says.
  check(deriveLeft({ kind: "group", left: true }) === true, "an explicit left=true is kept");
  check(deriveLeft({ kind: "group", left: false, can_send: false }) === false,
    "an explicit left=false is not overridden by another signal");
  check(deriveLeft({ kind: "direct", left: false }) === false, "an explicit flag wins for a direct chat too");

  // A direct chat has no membership to leave, so it is never unknown - that was the whole bug.
  check(deriveLeft({ kind: "direct" }) === false, "a direct chat is never left, and never unknown");
  check(deriveLeft({ kind: "direct", can_send: null, me_in_participants: null }) === false,
    "a direct chat does not depend on group signals");

  // A group: membership first, then the app's own canSend.
  check(deriveLeft({ kind: "group", me_in_participants: true }) === false, "in the participant list means not left");
  check(deriveLeft({ kind: "group", me_in_participants: false }) === true, "absent from the participant list means left");
  check(deriveLeft({ kind: "group", me_in_participants: true, can_send: false }) === false,
    "membership outranks canSend");
  check(deriveLeft({ kind: "group", can_send: false }) === true, "canSend=false means the account cannot post there");
  check(deriveLeft({ kind: "group", can_send: true }) === false, "canSend=true means the account can post there");

  // Unknown stays unknown: the eligibility rule must keep failing closed on these.
  check(deriveLeft({ kind: "group" }) === null, "a group with no signal at all is unknown");
  check(deriveLeft({ kind: "group", me_in_participants: null, can_send: null }) === null, "nulls are unknown, not false");
  check(deriveLeft({ kind: "broadcast" }) === null, "a broadcast chat is unknown");
  check(deriveLeft({ kind: "unknown" }) === null, "an unrecognised id kind is unknown");
  check(deriveLeft({}) === null, "a conversation with no kind is unknown");
  check(deriveLeft(null) === null, "no conversation is unknown");
  check(deriveLeft("group") === null, "a non-object is unknown");

  // Wid comparison: a phone compares by digits, anything opaque compares exactly.
  check(sameWid("5511999999999@c.us", "5511999999999@s.whatsapp.net") === true, "a PN compares by digits");
  check(sameWid("5511999999999@c.us", "55 11 99999-9999@c.us") === true, "formatting does not change a PN");
  check(sameWid("5511999999999@c.us", "5511888888888@c.us") === false, "different numbers are different");
  check(sameWid("72103978127547@lid", "72103978127547@lid") === true, "a LID compares exactly");
  check(sameWid("72103978127547@lid", "72103978127548@lid") === false, "LIDs are not compared by digits");
  check(sameWid("operator1", "other1") === false, "a label never equals another label by digits");
  check(sameWid("", "5511999999999@c.us") === false, "an empty id matches nothing");

  console.log(`whatsapp read core ok (${checked} checks)`);
  console.log("ALL PASS");
  void checked;
})().catch((error) => {
  console.log("FAIL", (error && error.message) || error);
  console.log("1 FAILURE(S)");
  process.exitCode = 1;
});
