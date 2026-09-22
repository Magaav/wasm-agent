// The adapter metadata this pipeline *derives* rather than reads, kept pure so it can be tested
// without a browser.
//
// Why it exists: the app's chat model exposes no isLeft/left/hasLeft/isExited. Verified live on app
// 2.3000.1048024606, a direct chat and a group both carry __x_archive / __x_isReadOnly / __x_canSend
// and nothing about membership, so `left: firstBool(chat, [...])` was null for every one of the 677
// chats in the store. The eligibility rule fails closed on an unknown `left`, so it refused all of
// them (`left_unknown`) and the ingest emitted zero events: no real message could ever wake the reply
// job. A tri-state that cannot be true is not caution, it is a pipeline that never runs.
//
// So `left` is derived from the signals this build does expose, and stays null - unknown, and the rule
// still fails closed - only when none of them is available:
//   - an explicit membership flag, if a build exposes one;
//   - a group: the app's participant list (is the account in it?), else its own `canSend`;
//   - a direct chat: there is no membership to leave, so false, never unknown;
//   - anything else (broadcast, an unrecognised id): null.
const PHONE_DOMAINS = ["c.us", "s.whatsapp.net"];

function domainOf(value) {
  const at = value.indexOf("@");
  return at < 0 ? "" : value.slice(at + 1).toLowerCase();
}

function digitsOf(value) {
  return value.replace(/[^0-9]/g, "");
}

// A phone/PN identity compares by digits; anything else - a LID, a label - is opaque and compares
// exactly, or `operator1` would equal `other1` and a PN would equal a LID with the same digits.
export function sameWid(a, b) {
  const left = String(a || "");
  const right = String(b || "");
  if (!left || !right) return false;
  if (left === right) return true;
  if (!PHONE_DOMAINS.includes(domainOf(left)) || !PHONE_DOMAINS.includes(domainOf(right))) return false;
  const x = digitsOf(left);
  const y = digitsOf(right);
  return Boolean(x) && x === y;
}

// `conversation` is one entry of the reader's payload: { kind, left, can_send, me_in_participants }.
// Returns true (the account cannot post here), false (it can) or null (this build cannot say).
export function deriveLeft(conversation) {
  if (!conversation || typeof conversation !== "object") return null;
  if (typeof conversation.left === "boolean") return conversation.left;
  const kind = conversation.kind;
  if (kind === "direct") return false;
  if (kind !== "group") return null;
  if (conversation.me_in_participants === true) return false;
  if (conversation.me_in_participants === false) return true;
  if (conversation.can_send === false) return true;
  if (conversation.can_send === true) return false;
  return null;
}
