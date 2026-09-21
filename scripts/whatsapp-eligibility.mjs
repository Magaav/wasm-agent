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

function mentioned(body, mentionedIds, options) {
  const ids = operatorIds(options);
  if (!ids.length) return false;
  const digits = new Set(ids.map(normalizeDigits).filter((value) => value.length > 6));
  for (const id of mentionedIds || []) {
    if (ids.includes(String(id))) return true;
    if (digits.has(normalizeDigits(id))) return true;
  }
  const bodyDigits = normalizeDigits(body);
  for (const value of digits) {
    if (bodyDigits.includes(value)) return true;
  }
  return false;
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
  if (conversation.archived === null || conversation.archived === undefined) {
    return reject("archived_unknown");
  }
  if (conversation.archived === true) return reject("archived");
  if (conversation.left === null || conversation.left === undefined) {
    return reject("left_unknown");
  }
  if (conversation.left === true) return reject("left");

  if (kind === "group") {
    // A verified mention is either the app's own flag/list, or a literal @number in the body matched
    // against a bound operator identity. When neither can verify anything, the group fails closed.
    if (message.mentioned_me === true) return { eligible: true, reason: "operator_mentioned", ...base };
    if (mentioned(message.body, message.mentioned_ids, options)) {
      return { eligible: true, reason: "operator_mentioned", ...base };
    }
    const mentionKnown =
      (message.mentioned_me !== null && message.mentioned_me !== undefined) ||
      Array.isArray(message.mentioned_ids);
    if (!mentionKnown && operatorIds(options).length === 0) return reject("mention_unknown");
    return reject("group_without_operator_mention");
  }

  return { eligible: true, reason: "direct_chat", ...base };
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
