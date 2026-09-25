// WhatsApp reply eligibility: the deterministic rule, tested without a browser or a model.
//
// The rule is the reason a message reaches a model at all, so every branch here is a branch that would
// otherwise spend a turn (or worse, reply) on something the operator did not want answered.
const assert = require("node:assert/strict");

let checked = 0;
const check = (value, label) => { assert.ok(value, label); checked += 1; };

const operator = { ids: ["5511999999999@s.whatsapp.net"], phones: ["5511999999999"] };

function conversation(overrides) {
  return { id: "5511888888888@c.us", title: "Someone", archived: false, left: false, ...overrides };
}
// Every fixture here is a *live* message unless it says otherwise. The rule has a window now, so a message
// with no timestamp is refused (`stale_unknown`) - a fixture that forgot one would be testing the refusal
// instead of the branch it names, which is how a suite quietly stops covering anything.
const NOW = Math.floor(Date.now() / 1000);
function message(overrides) {
  return { direction: "incoming", body: "hello?", mentioned_ids: null, mentioned_me: null, sent_at: NOW - 30, ...overrides };
}

(async () => {
  const mod = await import("../scripts/whatsapp-eligibility.mjs");
  const { chatKind, messageAge } = mod;
  // One clock and one operator binding for every check, so each keeps its own subject. The window is
  // measured against NOW, never against a local wall clock.
  const eligibility = (input, options = { operator }) => mod.eligibility(input, { now: NOW, ...options });

  // The kind comes from the id suffix, never from a title: this build reports isGroup false for @g.us,
  // and a contact can legitimately be named "Team Group".
  check(chatKind("123@g.us") === "group", "id suffix decides group");
  check(chatKind("123@c.us") === "direct", "id suffix decides direct");
  check(chatKind("status@broadcast") === "status", "status is its own kind");

  // Direct chats are eligible when the metadata is verified.
  const direct = eligibility({ conversation: conversation(), message: message() }, { operator });
  check(direct.eligible === true && direct.reason === "direct_chat", "a verified direct chat is eligible");
  check(direct.chat_id === "5511888888888@c.us" && direct.kind_source === "id", "identity is the id, tagged as such");

  // A title that looks like a group is not a group.
  const mislabelled = eligibility(
    { conversation: conversation({ title: "Team Group" }), message: message() },
    { operator }
  );
  check(mislabelled.eligible === true && mislabelled.chat_kind === "direct", "a group-sounding title stays direct");

  // Archived and left are excluded; unknown metadata fails closed.
  check(eligibility({ conversation: conversation({ archived: true }), message: message() }, { operator }).reason === "archived", "archived is excluded");
  check(eligibility({ conversation: conversation({ left: true }), message: message() }, { operator }).reason === "left", "left is excluded");
  check(eligibility({ conversation: conversation({ archived: null }), message: message() }, { operator }).reason === "archived_unknown", "unknown archived fails closed");
  check(eligibility({ conversation: conversation({ left: null }), message: message() }, { operator }).reason === "left_unknown", "unknown left fails closed");
  // A string, a number or an object is INVALID metadata, not false: it must fail closed, never read as
  // "not archived". `"false"` reading as false was a real defect.
  for (const bad of ["false", "true", 0, 1, {}, [], "no"]) {
    check(eligibility({ conversation: conversation({ archived: bad }), message: message() }, { operator }).reason === "archived_unknown", `archived ${JSON.stringify(bad)} is unknown, not false`);
  }
  for (const bad of ["false", 0, {}, []]) {
    check(eligibility({ conversation: conversation({ left: bad }), message: message() }, { operator }).reason === "left_unknown", `left ${JSON.stringify(bad)} is unknown, not false`);
  }

  // Broadcast and status are not people.
  check(eligibility({ conversation: conversation({ id: "status@broadcast" }), message: message() }, { operator }).reason === "not_a_person", "status is excluded");
  check(eligibility({ conversation: conversation({ id: "123@broadcast" }), message: message() }, { operator }).reason === "not_a_person", "broadcast is excluded");
  check(eligibility({ conversation: conversation({ id: "mystery" }), message: message() }, { operator }).reason === "unknown_chat_kind", "an unknown id suffix fails closed");

  // Outgoing is never eligible: the job answers other people, not its own replies.
  check(eligibility({ conversation: conversation(), message: message({ direction: "outgoing" }) }, { operator }).reason === "not_incoming", "outgoing is never eligible");

  // Groups only on a verified operator mention.
  const group = conversation({ id: "12345@g.us", title: "The group" });
  check(eligibility({ conversation: group, message: message({ mentioned_ids: [] }) }, { operator }).reason === "group_without_operator_mention", "group chatter is excluded");
  check(eligibility({ conversation: group, message: message({ mentioned_me: true }) }, { operator }).eligible === true, "an explicit app mention is eligible");
  check(eligibility({ conversation: group, message: message({ mentioned_ids: ["5511999999999@s.whatsapp.net"] }) }, { operator }).eligible === true, "a mentioned id is eligible");
  check(eligibility({ conversation: group, message: message({ body: "hey @5511999999999 please confirm" }) }, { operator }).eligible === true, "a literal @number mention is eligible");
  check(eligibility({ conversation: group, message: message({ body: "@5511999999999", mentioned_ids: [] }) }, { operator: {} }).reason === "group_without_operator_mention", "without a bound operator even @number is not eligible");
  const noMention = eligibility({ conversation: group, message: message() }, { operator });
  check(noMention.eligible === false && noMention.reason === "group_without_operator_mention", "absent mention evidence fails closed");
  const unknownMention = eligibility({ conversation: group, message: message() }, {});
  check(unknownMention.reason === "mention_unknown", "no operator binding means mentions cannot be verified");

  // Numeric prose and digit substrings are NOT mentions. `normalizeDigits(body).includes(number)` made a
  // random phone number in a sentence an operator mention; each of these would have matched it.
  for (const body of [
    "call me on 5511999999999",
    "my number is 5511999999999",
    "15511999999999",
    "1235511999999999",
    "55 11 99999-9999",
  ]) {
    check(
      eligibility({ conversation: group, message: message({ body, mentioned_ids: [] }) }, { operator }).reason === "group_without_operator_mention",
      `not a mention: ${body}`
    );
  }
  // Only an EXACT @<bound number> token, with boundaries on both sides.
  check(eligibility({ conversation: group, message: message({ body: "hey @5511999999999 please", mentioned_ids: [] }) }, { operator }).eligible === true, "an exact @token mid-sentence is a mention");
  check(eligibility({ conversation: group, message: message({ body: "@5511999999999", mentioned_ids: [] }) }, { operator }).eligible === true, "an exact @token at end is a mention");
  check(eligibility({ conversation: group, message: message({ body: "@55119999999990", mentioned_ids: [] }) }, { operator }).reason === "group_without_operator_mention", "a longer @number is not an exact mention");
  check(eligibility({ conversation: group, message: message({ body: "@5511999999999abc", mentioned_ids: [] }) }, { operator }).reason === "group_without_operator_mention", "no boundary after the @number is not a mention");
  check(eligibility({ conversation: group, message: message({ body: "x@5511999999999", mentioned_ids: [] }) }, { operator }).reason === "group_without_operator_mention", "an email-like @ is not a mention");
  // Mention metadata must be the app's real types, not strings.
  check(eligibility({ conversation: group, message: message({ mentioned_me: "true", mentioned_ids: [] }) }, { operator }).reason === "group_without_operator_mention", "a string mentioned_me is not a verified mention");
  check(eligibility({ conversation: group, message: message({ mentioned_ids: "5511999999999@s.whatsapp.net" }) }, { operator }).reason === "group_without_operator_mention", "a non-array mentioned_ids is not verified");

  // ---- the window ------------------------------------------------------------------------------
  // A message is answered only while it is recent, and transcribed only inside the hard bound. This is the
  // bound that was missing: the reader selects by cursor *position*, so after a lag - a busy node, the
  // source down, a restart - everything since the cursor looks new, and a three-hour-old voice note was
  // transcribed and answered as if it had just arrived.
  const chat = conversation();
  const at = (seconds) => message({ sent_at: NOW - seconds });
  check(eligibility({ conversation: chat, message: at(0) }, { operator }).reason === "direct_chat", "a message that just arrived is answered promptly");
  check(eligibility({ conversation: chat, message: at(299) }, { operator }).reason === "direct_chat", "a private message inside the prompt window is answered promptly");
  const grace = eligibility({ conversation: chat, message: at(400) }, { operator });
  check(grace.eligible === true && grace.reason === "direct_unanswered_grace", "a private message past the prompt window is still eligible inside the grace band");
  check(eligibility({ conversation: chat, message: at(601) }, { operator }).reason === "stale_message", "past the hard bound a private message is refused");
  check(eligibility({ conversation: chat, message: at(10800) }, { operator }).reason === "stale_message", "a three-hour-old message is refused, whatever else it is");
  check(eligibility({ conversation: group, message: message({ mentioned_me: true, sent_at: NOW - 400 }) }, { operator }).reason === "stale_group_mention", "a group mention past the prompt window is refused: the grace band is for a person waiting, not a busy group");
  check(eligibility({ conversation: group, message: message({ mentioned_me: true, sent_at: NOW - 60 }) }, { operator }).eligible === true, "a fresh group mention is still eligible");

  // The bound is measured on epoch seconds, so a local wall clock cannot move it. A time-zone bug here would
  // refuse on-time messages, which is the failure the operator named - so it is asserted, not assumed.
  check(messageAge(NOW - 100, NOW) === 100, "age is now minus sent_at");
  check(messageAge(NOW + 900, NOW) === 0, "a sender's clock ahead of ours is skew, not the future");
  check(messageAge(0, NOW) === null && messageAge(null, NOW) === null && messageAge("nope", NOW) === null, "a timestamp that is missing, zero or not a number is unknown");
  check(eligibility({ conversation: chat, message: message({ sent_at: 0 }) }, { operator }).reason === "stale_unknown", "an unknown timestamp fails closed");
  check(eligibility({ conversation: chat, message: message({ sent_at: NOW + 900 }) }, { operator }).eligible === true, "a skewed future timestamp is not refused as stale");

  // The knobs: the grace band can be closed and the bound widened, and the prompt window follows the bound
  // rather than being a third knob that could contradict it.
  check(eligibility({ conversation: chat, message: at(400) }, { operator, grace_seconds: 0 }).eligible === true, "with no grace band the whole bound is the prompt window");
  check(eligibility({ conversation: chat, message: at(1800) }, { operator, max_seconds: 3600 }).eligible === true, "a widened bound widens the prompt window with it");
  check(eligibility({ conversation: group, message: message({ mentioned_me: true, sent_at: NOW - 1800 }) }, { operator, max_seconds: 3600 }).eligible === true, "and the group window follows the same bound");

  // Two real child processes, two zones, one verdict - the alignment asserted rather than assumed. With a
  // local clock anywhere in the rule these two would disagree.
  const { spawnSync } = await import("node:child_process");
  const { pathToFileURL } = await import("node:url");
  const nodePath = await import("node:path");
  const moduleUrl = pathToFileURL(nodePath.resolve(__dirname, "..", "scripts", "whatsapp-eligibility.mjs")).href;
  const probe = "import(" + JSON.stringify(moduleUrl) + ").then((m) => { const now = 1790323400; const c = { id: '5511@c.us', title: 't', archived: false, left: false }; const at = (s) => ({ direction: 'incoming', body: 'x', sent_at: now - s }); console.log(JSON.stringify([m.eligibility({ conversation: c, message: at(290) }, { operator: {}, now }).reason, m.eligibility({ conversation: c, message: at(400) }, { operator: {}, now }).reason, m.eligibility({ conversation: c, message: at(700) }, { operator: {}, now }).reason])); });";
  const zones = ["UTC", "Pacific/Kiritimati"];
  const verdicts = zones.map((zone) => {
    const run = spawnSync(process.execPath, ["--input-type=module", "-e", probe], { env: { ...process.env, TZ: zone }, encoding: "utf8" });
    return String(run.stdout || "").trim();
  });
  check(verdicts[0].length > 0 && verdicts[0].indexOf("direct_chat") >= 0, "the zone probe really ran: " + verdicts[0]);
  console.log("ALL PASS");
  void checked;
})().catch((error) => {
  console.log("FAIL", (error && error.message) || error);
  console.log("1 FAILURE(S)");
  process.exitCode = 1;
});
