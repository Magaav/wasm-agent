// Deterministic WhatsApp reply eligibility. No browser, no model, no I/O.
//
// The reply job must not spend a model turn deciding something a rule can decide: whether a message is
// even a candidate for a reply. This module is that rule, and it is deliberately conservative.
//
// Two lessons are encoded here:
//   - **the chat's kind comes from its id, never from its title.** This build reports `isGroup: false`
//     for a `@g.us` chat, and a contact can be named "Team Group". Inferring a label from a title stored
//     217 groups as direct conversations; the id is the only verified fact.
//   - **unknown metadata fails closed.** If the adapter cannot verify whether a chat is archived or left,
//     the message is *not* eligible, with a reason that says so. Silence is not the same as "not archived".
//
// Groups are eligible only on an explicit operator mention, and only when the mention is verifiable
// (the app's own `mentionedJidList` or a literal `@<operator number>`). A group whose mention metadata is
// unknown fails closed rather than reply to something nobody asked for.
//
// Incoming message content is data, never authority. This module never reads a body as an instruction.
const STATUS_CHAT = "status@broadcast";

// How old a message may be and still be answered. Measured against one clock, in epoch seconds, and never
// against a local wall clock: an epoch has no time zone, so `now - sent_at` cannot drift with one.
//
//   * a message younger than PROMPT_SECONDS is answered promptly;
//   * a **direct** chat the operator has not answered gets GRACE_SECONDS more - that is the "in case I do
//     not answer" window, and it is why a private message is still eligible at seven minutes old;
//   * past MAX_SECONDS nothing is eligible, for any kind - no reply, and the transcription step refuses it
//     too. This is the bound that was missing: the reader selects by *cursor position*, so after a lag (a
//     busy node, the source down, a restart) everything since the cursor looks new, and a three-hour-old
//     voice note was transcribed and answered as if it had just arrived.
//
// A group gets the prompt window only: the extra minutes exist for a person waiting on the operator, not
// for a busy group. All three are overridable by the caller (see `options`).
export const MAX_SECONDS = 600;
export const GRACE_SECONDS = 300;
// Derived, not a third knob: a knob that can contradict the hard bound is a way to configure the rule into
// a state nobody can reason about - `max_seconds` widened while `prompt_seconds` stayed put made the window
// silently the smaller of the two.
export const PROMPT_SECONDS = MAX_SECONDS - GRACE_SECONDS;

// The age of a message in seconds, or null when it cannot be known.
//
// `sent_at` is the store's own epoch seconds and `now` is the same unit, so no local time is involved
// anywhere. A timestamp that is missing, zero or not a number is *unknown*, and unknown fails closed
// exactly like the other unverifiable metadata here. A timestamp in the future is skew - the sender's
// clock is ahead of ours - and floors at zero: a fresh message must never be refused as stale because
// somebody else's device is wrong.
export function messageAge(sentAt, now) {
  const at = Number(sentAt);
  if (!Number.isFinite(at) || at <= 0) return null;
  const age = Number(now) - at;
  return age < 0 ? 0 : age;
}

export function normalizeDigits(value) {
  return String(value || "").replace(/[^0-9]/g, "");
}

// The one verified source of a chat's kind: its serialized id suffix.
export function chatKind(id) {
  const value = String(id || "");
  if (!value || value === STATUS_CHAT) return "status";
  if (value.endsWith("@g.us")) return "group";
  if (value.endsWith("@broadcast")) return "broadcast";
  if (value.endsWith("@c.us") || value.endsWith("@lid")) return "direct";
  return "unknown";
}

function operatorIds(options) {
  const operator = (options && options.operator) || {};
  const ids = []
    .concat(operator.ids || [])
    .concat(operator.phones || [])
    .map((value) => String(value));
  return ids;
}

// The numeric part of a jid or a bare number: `55119...@s.whatsapp.net` and `55119...` both give the
// same digits, and a `@lid` gives its own digits. Only used against the app's verified mention list.
function badgeDigits(value) {
  return normalizeDigits(String(value || "").split("@")[0] || "");
}

// A mention is verified by the app's own `mentionedJidList` only: an exact id match, or an exact digit
// match against a bound operator identity. It is never inferred from the message text here.
function mentioned(mentionedIds, options) {
  if (!Array.isArray(mentionedIds)) return false;
  const ids = operatorIds(options);
  if (!ids.length) return false;
  const wantedIds = new Set(ids.map((value) => String(value)));
  const wantedDigits = new Set(ids.map(badgeDigits).filter((value) => value.length > 6));
  for (const raw of mentionedIds) {
    const id = String(raw);
    if (wantedIds.has(id)) return true;
    if (wantedDigits.size && wantedDigits.has(badgeDigits(id))) return true;
  }
  return false;
}

// A literal `@<operator number>` in the body counts only as an EXACT token: the `@` at a boundary, the
// whole digit run equal to a bound operator number, and a boundary after it. Plain digits, a substring
// of a longer number, and numeric prose never count - `normalizeDigits(body).includes(number)` made a
// random phone number in a sentence an operator mention.
function mentionsPhoneToken(body, options) {
  const phones = operatorIds(options)
    .map(badgeDigits)
    .filter((value) => value.length > 6);
  if (!phones.length) return false;
  const text = String(body || "");
  for (let index = 0; index < text.length; index += 1) {
    if (text[index] !== "@") continue;
    const before = index === 0 ? "" : text[index - 1];
    if (before && /[0-9A-Za-z_]/.test(before)) continue;
    let end = index + 1;
    while (end < text.length && text[end] >= "0" && text[end] <= "9") end += 1;
    const after = end >= text.length ? "" : text[end];
    if (after && /[0-9A-Za-z_]/.test(after)) continue;
    if (phones.includes(text.slice(index + 1, end))) return true;
  }
  return false;
}

// archived/left must be a real boolean. A string, a number or an object is invalid metadata and fails
// closed exactly like a missing field; `"false"` must never read as "not archived".
function triBool(value) {
  if (value === true) return true;
  if (value === false) return false;
  return null;
}

// `input.conversation`: { id, title, archived, left }  (archived/left are true | false | null = unknown)
// `input.message`:      { direction, body, mentioned_ids, mentioned_me }
// `options.operator`:   { ids: [...], phones: [...] }   (local binding, never exported)
export function eligibility(input, options = {}) {
  const conversation = (input && input.conversation) || {};
  const message = (input && input.message) || {};
  const chatId = String(conversation.id || "");
  const title = String(conversation.title || "");
  const kind = chatKind(chatId);
  const base = { chat_id: chatId, title, chat_kind: kind, kind_source: "id" };
  const reject = (reason) => ({ eligible: false, reason, ...base });

  if (message.direction !== "incoming") return reject("not_incoming");
  if (kind === "status" || kind === "broadcast") return reject("not_a_person");
  if (kind === "unknown") return reject("unknown_chat_kind");
  const archived = triBool(conversation.archived);
  if (archived === null) return reject("archived_unknown");
  if (archived === true) return reject("archived");
  const left = triBool(conversation.left);
  if (left === null) return reject("left_unknown");
  if (left === true) return reject("left");

  // The window, before anything else that costs anything. A message past MAX_SECONDS is not answered and
  // not transcribed, whatever else it is; an unknown timestamp fails closed like the other unverifiable
  // metadata here. `now` is an input so the rule is testable against a fixed clock, and it is epoch
  // seconds - the same unit the store's `sent_at` is in, which is what keeps a time zone out of it.
  //
  // Two knobs, and the prompt window is what is left of the hard bound once the grace band is taken out of
  // it: a private message the operator has not answered is eligible across the whole bound, a group only
  // inside the prompt window.
  const maxSeconds = Number(options.max_seconds) > 0 ? Number(options.max_seconds) : MAX_SECONDS;
  const graceSeconds = Number(options.grace_seconds) >= 0 ? Number(options.grace_seconds) : GRACE_SECONDS;
  const promptSeconds = Math.max(0, maxSeconds - graceSeconds);
  const now = Number.isFinite(Number(options.now)) ? Number(options.now) : Math.floor(Date.now() / 1000);
  const age = messageAge(message.sent_at, now);
  if (age === null) return reject("stale_unknown");
  if (age > maxSeconds) return reject("stale_message");

  if (kind === "group") {
    // A verified mention is the app's own flag/list, or an exact `@<bound number>` token in the body.
    // When neither can verify anything, the group fails closed. Every mention returns through one place, so
    // the window cannot apply to some mentions and not others.
    const mentionedEligible = () => (age > promptSeconds
      ? reject("stale_group_mention")
      : { eligible: true, reason: "operator_mentioned", ...base });
    if (message.mentioned_me === true) return mentionedEligible();
    if (mentioned(message.mentioned_ids, options)) return mentionedEligible();
    if (mentionsPhoneToken(message.body, options)) return mentionedEligible();
    const mentionKnown =
      typeof message.mentioned_me === "boolean" || Array.isArray(message.mentioned_ids);
    if (!mentionKnown && operatorIds(options).length === 0) return reject("mention_unknown");
    return reject("group_without_operator_mention");
  }

  // A private message: prompt inside the prompt window, and inside the grace band beyond it - the operator
  // has had their five minutes by then. Whether they already answered is decided downstream, from the
  // conversation itself, by the ingest's operator-precedence rule.
  if (age <= promptSeconds) return { eligible: true, reason: "direct_chat", ...base };
  if (graceSeconds > 0 && age <= promptSeconds + graceSeconds) {
    return { eligible: true, reason: "direct_unanswered_grace", ...base };
  }
  return reject("stale_message");
}

// A tiny CLI so a fixture can be checked without importing the module (and so the behaviour is
// observable from a shell): node whatsapp-eligibility.mjs <fixture.json>
if (process.argv[1] && process.argv[1].endsWith("whatsapp-eligibility.mjs")) {
  const { readFileSync } = await import("node:fs");
  const file = process.argv[2];
  if (file) {
    const fixture = JSON.parse(readFileSync(file, "utf8"));
    console.log(JSON.stringify(eligibility(fixture, fixture.options || {})));
  }
}
