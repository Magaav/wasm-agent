// The store send route: identity/endpoint binding, the conservative self-only rule, the pre-effect
// state guard, one-dispatch reconciliation, and the page expressions against adversarial fake app
// stores. A fake CDP server then runs the real CLI end to end. No real browser, no real HOME.
const assert = require("node:assert/strict");
const http = require("node:http");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

let checked = 0;
const check = (value, label) => { assert.ok(value, label); checked += 1; };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---- a minimal fake CDP WebSocket server ------------------------------------
function encodeFrame(text) {
  const payload = Buffer.from(text, "utf8");
  const length = payload.length;
  let header;
  if (length < 126) header = Buffer.from([0x81, length]);
  else if (length < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 126; header.writeUInt16BE(length, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 127; header.writeBigUInt64BE(BigInt(length), 2); }
  return Buffer.concat([header, payload]);
}

function frameParser(onText) {
  let buffer = Buffer.alloc(0);
  return (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < 2) return;
      const opcode = buffer[0] & 0x0f;
      const masked = (buffer[1] & 0x80) !== 0;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      const maskLength = masked ? 4 : 0;
      if (buffer.length < offset + maskLength + length) return;
      const mask = masked ? buffer.slice(offset, offset + 4) : null;
      offset += maskLength;
      const payload = Buffer.from(buffer.slice(offset, offset + length));
      if (mask) for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4];
      buffer = buffer.slice(offset + length);
      if (opcode === 0x8) { onText(null); return; }
      if (opcode === 0x1) onText(payload.toString("utf8"));
    }
  };
}

// `handler(message)` returns the CDP result payload for a Runtime.evaluate, or `null` to never answer.
function startFakeCdp(handler) {
  const server = http.createServer((req, res) => { res.writeHead(404); res.end(); });
  server.on("upgrade", (req, socket) => {
    const accept = crypto.createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
    const parse = frameParser((text) => {
      if (text === null) { socket.end(); return; }
      let message = null;
      try { message = JSON.parse(text); } catch { return; }
      if (message.method !== "Runtime.evaluate") return;
      const payload = handler(message.params.expression);
      if (payload === null) return; // deliberately silent: the caller times out
      socket.write(encodeFrame(JSON.stringify({ id: message.id, result: { result: { value: JSON.stringify(payload) } } })));
    });
    socket.on("data", parse);
    socket.on("error", () => {});
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port })));
}

function runCli(args, timeoutMs = 20000) {
  const cli = path.join(__dirname, "..", "scripts", "whatsapp-store-send.mjs");
  // An isolated lock path: the fixture must never write the operator's real lock directory.
  const lockDir = fs.mkdtempSync(path.join(os.tmpdir(), "wa-store-lock-"));
  const env = { ...process.env, WA_WHATSAPP_SEND_LOCK: path.join(lockDir, "whatsapp-send.lock") };
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [cli, ...args], { encoding: "utf8", windowsHide: true, env });
    let stdout = "", stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => child.kill(), timeoutMs);
    child.on("close", (code) => {
      clearTimeout(timer);
      let payload = null;
      for (const line of stdout.trim().split(/\r?\n/).reverse()) {
        try { payload = JSON.parse(line); break; } catch { /* keep looking */ }
      }
      resolve({ code, stdout, stderr, payload });
    });
  });
}

(async () => {
  const core = await import("../scripts/whatsapp-store-core.mjs");

  // ---- typed accounts --------------------------------------------------------
  check(core.accountMatches("5511999999999", "5511999999999@s.whatsapp.net") === true, "a bare PN matches its jid form");
  check(core.accountMatches("5511999999999@s.whatsapp.net", "5511999999999@c.us") === true, "two PN spellings compare by digits");
  check(core.accountMatches("5511999999999", "5511999999998") === false, "a different number does not match");
  // A LID is not a PN, even when the digits are identical.
  check(core.accountMatches("5511999999999", "5511999999999@lid") === false, "a LID never matches a PN");
  check(core.accountMatches("5511999999999@lid", "5511999999999@lid") === true, "two identical LIDs match");
  // A label that contains the same digits is not an account.
  check(core.accountMatches("5511999999999", "+55 11 99999-9999") === false, "a formatted label does not match a PN by digits");
  check(core.accountMatches("Notes to self", "Notes to self") === true, "an exact non-account string still matches itself");
  check(core.parseAccount("+55 11 99999-9999").kind === "unknown", "a formatted label parses as unknown");
  check(core.parseAccount("5511999999999@lid").kind === "lid", "a lid parses as lid");

  // ---- endpoint binding ------------------------------------------------------
  check(core.endpointMatches("ws://[::1]:9222/devtools/page/ABC", "ws://127.0.0.1:9222/devtools/page/ABC") === true, "loopback spellings are equivalent");
  check(core.endpointMatches("ws://127.0.0.1:9222/devtools/page/ABC", "ws://127.0.0.1:9223/devtools/page/ABC") === false, "a different port does not match");
  check(core.endpointMatches("ws://127.0.0.1:9222/devtools/page/ABC", "ws://127.0.0.1:9222/devtools/page/OTHER") === false, "a different page id does not match");
  check(core.endpointMatches("ws://127.0.0.1:9222/devtools/page/ABC", "wss://127.0.0.1:9222/devtools/page/ABC") === false, "a different protocol does not match");
  check(core.endpointMatches("ws://10.0.0.1:9222/devtools/page/ABC", "ws://10.0.0.1:9222/devtools/page/ABC") === false, "a non-loopback endpoint is never a valid binding");
  check(core.parseEndpoint("ws://localhost:9222/devtools/page/ABC").host === "127.0.0.1", "localhost normalizes to loopback");
  check(core.isLoopbackEndpoint("ws://127.0.0.1:9222/devtools/page/ABC") === true, "a loopback endpoint is accepted");
  check(core.isLoopbackEndpoint("ws://192.168.1.5:9222/devtools/page/ABC") === false, "a non-loopback endpoint is refused");

  // ---- guards ----------------------------------------------------------------
  check(core.storeIdentityGuard({ send: true, expectedAccount: "5511", expectedEndpoint: "ws://127.0.0.1:9222/devtools/page/A", actualAccount: "5511", actualEndpoint: "ws://127.0.0.1:9222/devtools/page/A" }) === null, "both bindings proven passes");
  check(core.storeIdentityGuard({ send: true, expectedAccount: "", expectedEndpoint: "ws://127.0.0.1:9222/devtools/page/A" }) === "account_unbound", "a send without an account binding is refused");
  check(core.storeIdentityGuard({ send: true, expectedAccount: "5511", expectedEndpoint: "" }) === "endpoint_unbound", "a send without an endpoint binding is refused");
  check(core.storeIdentityGuard({ send: true, expectedAccount: "5511", expectedEndpoint: "ws://127.0.0.1:9222/devtools/page/A", actualAccount: "", actualEndpoint: "ws://127.0.0.1:9222/devtools/page/A" }) === "account_unproven", "an unproven account is refused");
  check(core.storeIdentityGuard({ send: true, expectedAccount: "5511", expectedEndpoint: "ws://127.0.0.1:9222/devtools/page/A", actualAccount: "5512", actualEndpoint: "ws://127.0.0.1:9222/devtools/page/A" }) === "account_mismatch", "a mismatched account is refused");
  check(core.storeIdentityGuard({ send: true, expectedAccount: "5511", expectedEndpoint: "ws://127.0.0.1:9222/devtools/page/A", actualAccount: "5511", actualEndpoint: "ws://127.0.0.1:9222/devtools/page/B" }) === "endpoint_mismatch", "a mismatched endpoint is refused");
  check(core.storeIdentityGuard({ send: false, expectedAccount: "5511" }) === null, "a rehearsal does not require both bindings");

  check(core.routeGuard({ send: true, isMe: true }) === null, "the verified self chat is the allowed route");
  check(core.routeGuard({ send: true, isMe: false }) === "ordinary_chat_unverified", "a non-self send is refused as unverified");
  check(core.routeGuard({ send: true, isMe: undefined }) === "ordinary_chat_unverified", "an unproven self is refused");
  check(core.routeGuard({ send: false, isMe: false }) === null, "a rehearsal is never blocked");

  const clean = { id: "a@c.us", isReadOnly: false, archived: false, typing: false, recording: false, isComposing: false, draftPresent: false, urlText: null, urlNumber: null };
  check(core.stateGuard({ send: true, target: clean }) === null, "a clean target state passes");
  check(core.stateGuard({ send: true, target: { ...clean, draftPresent: true } }) === "target_draft_present", "a present draft is refused");
  check(core.stateGuard({ send: true, target: { ...clean, draftPresent: null } }) === "draft_unknown", "an unexpected draft shape fails closed");
  check(core.stateGuard({ send: true, target: { ...clean, urlText: "http://x" } }) === "link_preview_present", "a target link preview is refused");
  check(core.stateGuard({ send: true, target: { ...clean, urlNumber: "123" } }) === "link_preview_present", "a target url number is refused");
  check(core.stateGuard({ send: true, target: { ...clean, isReadOnly: true } }) === "target_read_only", "a read-only target is refused");
  check(core.stateGuard({ send: true, target: { ...clean, archived: true } }) === "target_archived", "an archived target is refused");
  check(core.stateGuard({ send: true, target: { ...clean, typing: true } }) === "target_composing", "a target being typed into is refused");
  check(core.stateGuard({ send: false, target: { draftPresent: null } }) === null, "a rehearsal is never blocked by unknown metadata");

  check(core.classifyStoreAttempt({ send: true, dispatched: true, verified: true, ack: 1 }) === "sent", "an exact message with a server ack is sent");
  check(core.classifyStoreAttempt({ send: true, dispatched: true, verified: true, ack: 0 }) === "ambiguous", "a local optimistic insertion (ack 0) is ambiguous");
  check(core.classifyStoreAttempt({ send: true, dispatched: true, verified: false, ack: 0 }) === "ambiguous", "a dispatched action with no store proof is ambiguous");
  check(core.classifyStoreAttempt({ send: true, dispatched: true, verified: false, ack: 0, timedOut: true }) === "ambiguous", "a timeout is ambiguous, never a refusal");
  check(core.classifyStoreAttempt({ send: true, dispatched: true, verified: true, ack: 1, timedOut: true }) === "sent", "a store proof is sent even when the action call timed out");
  check(core.classifyStoreAttempt({ send: true, dispatched: false, verified: false, ack: 0 }) === "refused", "a pre-dispatch refusal is a refusal");
  check(core.classifyStoreAttempt({ send: false }) === "dry_run", "a rehearsal is a dry run");

  check(core.normalizeBody("  hi  ").effective === "hi" && core.normalizeBody("  hi  ").normalized === true, "the body is trimmed like the action trims it");
  check(core.normalizeBody("   ").empty === true, "a whitespace-only body is empty");

  // ---- page expressions against a fake app store ------------------------------
  const fakeStore = (chats, messages, meModule) => ({
    require: (name) => {
      if (name === "WAWebChatCollection") return { ChatCollection: { getModelsArray: () => chats } };
      if (name === "WAWebMsgCollection") return { MsgCollection: { getModelsArray: () => messages } };
      if (name === "WAWebUserPrefsMeUser") { if (!meModule) throw new Error("no me module"); return meModule; }
      if (name === "WAWebSendTextMsgChatAction") return { sendTextMsgToChat: () => { throw new Error("not expected here"); } };
      throw new Error("unexpected require " + name);
    },
  });

  const SELF_ID = "5511999999999@c.us";
  const STRANGER_ID = "5511888888888@c.us";
  const wid = (serialized, flags) => ({ _serialized: serialized, toString: () => serialized, isUser: () => flags.isUser, isGroup: () => flags.isGroup, isBot: () => flags.isBot });
  // The verified chat shape (app 2.3000.1048024606): `id` is a Wid with isUser/isGroup/isBot methods,
  // `chat.isGroup` is undefined, the draft is `draftMessage`, and urlText/urlNumber are undefined.
  const selfChat = { id: wid(SELF_ID, { isUser: true, isGroup: false, isBot: false }), formattedTitle: "Notes", unreadCount: 2,
    archive: false, isReadOnly: false, draftMessage: undefined, urlText: undefined, urlNumber: undefined,
    active: true, markedUnread: false, activeUnreadCount: 0, isComposingPoll: false, recording: false, typing: false };
  const stranger = { id: wid(STRANGER_ID, { isUser: true, isGroup: false, isBot: false }), formattedTitle: "Me (looks like me)", unreadCount: 0,
    archive: false, isReadOnly: false, draftMessage: undefined, urlText: undefined, urlNumber: undefined,
    active: false, markedUnread: false, activeUnreadCount: 0, isComposingPoll: false, recording: false, typing: false };
  const me = { isMeAccount: (id) => String(id) === SELF_ID, getMaybeMePnUser: () => ({ _serialized: SELF_ID }), getMaybeMeLidUser: () => null };
  const lookup = (chats, meModule, chatId) => JSON.parse(new Function("window", "return " + core.lookupExpression(chatId))(fakeStore(chats, [], meModule)));
  const selfLookup = lookup([stranger, selfChat], me, SELF_ID);
  check(selfLookup.ok === true && selfLookup.is_me === true, "the self chat is proven by the app's own identity");
  check(selfLookup.account === SELF_ID, "the account comes from UserPrefsMeUser, not a title");
  check(selfLookup.chat.kind === "direct", "the kind comes from the Wid methods, not an isGroup boolean");
  check(selfLookup.draft_present === false && selfLookup.url_text === null && selfLookup.url_number === null, "an absent draft and absent link-preview fields are reported as absent");
  const draftLookup = lookup([{ ...selfChat, draftMessage: { text: "a human draft", timestamp: 1 } }], me, SELF_ID);
  check(draftLookup.draft_present === true && !JSON.stringify(draftLookup).includes("a human draft"), "a present draft is reported without its text");
  const groupChat = { ...selfChat, id: wid("123@g.us", { isUser: false, isGroup: true, isBot: false }) };
  check(lookup([groupChat], me, "123@g.us").chat.kind === "group", "a group Wid is reported as a group");
  const strangerLookup = lookup([stranger, selfChat], me, STRANGER_ID);
  check(strangerLookup.is_me === false, "an unanswered stranger is never self");
  const unknownMe = lookup([selfChat], null, SELF_ID);
  check(unknownMe.is_me === false && unknownMe.account_known === false, "without the app's proof, self is refused, never guessed");

  const prior = { id: { remote: SELF_ID, fromMe: true, id: "OLD" }, body: "hello", ack: 3 };
  const fresh = { id: { remote: SELF_ID, fromMe: true, id: "NEW" }, body: "hello", ack: 1, t: 5 };
  const foreignMessage = { id: { remote: STRANGER_ID, fromMe: true, id: "FOREIGN" }, body: "hello", ack: 3 };
  const incoming = { id: { remote: SELF_ID, fromMe: false, id: "IN" }, body: "hello", ack: 1 };
  const verify = (messages, chatId, body, exclude) => JSON.parse(new Function("window", "return " + core.verifyExpression(chatId, body, exclude))(fakeStore([], messages, me)));
  check(verify([prior, fresh], SELF_ID, "hello", "OLD").verified === true, "a new matching message is verified");
  check(verify([prior, fresh], SELF_ID, "hello", "OLD").message.id === "NEW", "the exclude id keeps an earlier identical body out");
  check(verify([prior], SELF_ID, "hello", "OLD").verified === false, "an earlier identical body is not this send");
  check(verify([fresh, foreignMessage], SELF_ID, "hello", "").message.id === "NEW", "a foreign recipient is not accepted");
  check(verify([incoming, fresh], SELF_ID, "hello", "").verified === true, "an incoming message is not mistaken for the send");
  check(verify([{ id: { remote: SELF_ID, fromMe: true, id: "A" }, body: "hello ", ack: 1 }], SELF_ID, "hello", "").verified === false, "a body with extra whitespace does not match");
  check(verify([{ id: { remote: SELF_ID, fromMe: true, id: "A" }, body: "hello", ack: 0 }], SELF_ID, "hello", "").message.ack === 0, "an ack of 0 is visible, not treated as proof");

  let actionCalls = 0;
  const actionWindow = {
    require: (name) => {
      if (name === "WAWebChatCollection") return { ChatCollection: { getModelsArray: () => [selfChat] } };
      if (name === "WAWebSendTextMsgChatAction") return { sendTextMsgToChat: () => { actionCalls += 1; return Promise.resolve({ id: "M1" }); } };
      throw new Error("unexpected require " + name);
    },
  };
  const actionResult = JSON.parse(await new Function("window", "return " + core.actionExpression(SELF_ID, "hello"))(actionWindow));
  check(actionCalls === 1 && actionResult.dispatched === true, "the app action is called exactly once");
  const missing = JSON.parse(await new Function("window", "return " + core.actionExpression("nope@c.us", "hello"))(actionWindow));
  check(missing.error === "chat_not_found" && missing.dispatched === undefined, "a missing chat is a pre-dispatch refusal");

  // ---- the real CLI against a fake CDP server ---------------------------------
  const loopback = (port, page = "ABC") => `ws://127.0.0.1:${port}/devtools/page/${page}`;
  const cleanLookup = { ok: true, chat: { id: SELF_ID, name: "Notes", kind: "direct" }, is_me: true, account: SELF_ID,
    account_known: true, unread: 0, marked_unread: false, archived: false, is_read_only: false, draft_present: false,
    url_text: null, url_number: null, active: true, active_chat_id: SELF_ID, typing: false, recording: false,
    is_composing: false, action_available: true, chats: 2 };

  const scenario = (state) => {
    let actionCalls = 0;
    const fake = startFakeCdp((expression) => {
      if (expression.includes("await action.sendTextMsgToChat")) { actionCalls += 1; return state.action === undefined ? { dispatched: true, result: null } : state.action; }
      if (expression.includes("fromMe")) return state.verify === undefined ? { verified: true, message: { id: "NEW", recipient: SELF_ID, body: "hello", from_me: true, ack: 1, t: 1 } } : state.verify;
      return state.lookup === undefined ? cleanLookup : state.lookup;
    });
    return fake.then((f) => ({ ...f, calls: () => actionCalls }));
  };

  // Dry run: inspect only, never dispatch.
  const dry = await scenario({});
  let result = await runCli(["--chat", SELF_ID, "--expect-browser-endpoint", loopback(dry.port), "--body", "hello"]);
  check(result.code === 0 && result.payload && result.payload.dry_run === true && result.payload.action_available === true, "a dry run inspects and reports");
  check(dry.calls() === 0, "a dry run never dispatches the action");
  dry.server.close();

  // A bound endpoint is required, and only a loopback one.
  result = await runCli(["--chat", SELF_ID, "--body", "hello"]);
  check(result.code === 3 && result.payload.error === "endpoint_required", "a missing endpoint is refused before connecting");
  result = await runCli(["--chat", SELF_ID, "--expect-browser-endpoint", "ws://10.0.0.1:9222/devtools/page/ABC", "--body", "hello"]);
  check(result.code === 3 && result.payload.error === "endpoint_not_loopback", "a non-loopback endpoint is refused before connecting");

  // A verified send: one dispatch, exact proof, success.
  const sent = await scenario({});
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(sent.port), "--body", "hello", "--send"]);
  check(result.code === 0 && result.payload.sent === true && result.payload.verified === true && result.payload.dispatch === "store_action", "a verified send reports ok/sent/verified");
  check(result.payload.chat.id === SELF_ID && result.payload.body === "hello" && result.payload.message.id === "NEW" && result.payload.message.ack === 1, "the send reports the exact recipient, body and message");
  check(sent.calls() === 1, "a verified send dispatches the action exactly once");
  sent.server.close();

  // ack 0: a local optimistic insertion is not proof, and is not retried.
  const ack0 = await scenario({ verify: { verified: true, message: { id: "NEW", recipient: SELF_ID, body: "hello", from_me: true, ack: 0, t: 1 } } });
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(ack0.port), "--body", "hello", "--send"]);
  check(result.code === 8 && result.payload.error === "ambiguous_send" && result.payload.dispatch === "store_action", "an ack of 0 is ambiguous, not sent");
  check(ack0.calls() === 1, "an ack of 0 is never retried");
  ack0.server.close();

  // No store proof: ambiguous, one dispatch.
  const noProof = await scenario({ verify: { verified: false, message: null } });
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(noProof.port), "--body", "hello", "--send"]);
  check(result.code === 8 && result.payload.error === "ambiguous_send", "a dispatched action with no store proof is ambiguous");
  check(noProof.calls() === 1, "an unverified dispatch is never retried");
  noProof.server.close();

  // Timeout: the action evaluate never answers. Ambiguous, never retried.
  const timedOut = await scenario({ action: null, verify: { verified: false, message: null } });
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(timedOut.port), "--body", "hello", "--send", "--timeout-ms", "400"]);
  check(result.code === 8 && result.payload.dispatch === "store_action_timeout", "a timed-out action is an ambiguous post-dispatch outcome");
  check(timedOut.calls() === 1, "a timed-out action is never retried");
  timedOut.server.close();

  // The pre-effect guards refuse before any dispatch.
  const draft = await scenario({ lookup: { ...cleanLookup, draft_present: true } });
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(draft.port), "--body", "hello", "--send"]);
  check(result.code === 5 && result.payload.error === "target_draft_present" && draft.calls() === 0, "a target draft refuses before dispatch");
  draft.server.close();

  const preview = await scenario({ lookup: { ...cleanLookup, url_text: "http://example" } });
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(preview.port), "--body", "hello", "--send"]);
  check(result.code === 5 && result.payload.error === "link_preview_present" && preview.calls() === 0, "a link preview refuses before dispatch");
  preview.server.close();

  const unknown = await scenario({ lookup: { ...cleanLookup, draft_present: null } });
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(unknown.port), "--body", "hello", "--send"]);
  check(result.code === 5 && result.payload.error === "draft_unknown" && unknown.calls() === 0, "unknown metadata fails closed before dispatch");
  unknown.server.close();

  const mismatch = await scenario({});
  result = await runCli(["--chat", SELF_ID, "--expect-account", "5511000000000", "--expect-browser-endpoint", loopback(mismatch.port), "--body", "hello", "--send"]);
  check(result.code === 5 && result.payload.error === "account_mismatch" && mismatch.calls() === 0, "a mismatched bound account refuses before dispatch");
  mismatch.server.close();

  const nonSelf = await scenario({ lookup: { ...cleanLookup, is_me: false } });
  result = await runCli(["--chat", STRANGER_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(nonSelf.port), "--body", "hello", "--send"]);
  check(result.code === 5 && result.payload.error === "ordinary_chat_unverified" && nonSelf.calls() === 0, "a non-self send is refused as unverified");
  check(/self chat/.test(String(result.payload.limitation || "")), "the self-only limitation is reported, not hidden");
  nonSelf.server.close();

  const missingChat = await scenario({ lookup: { error: "chat_not_found" } });
  result = await runCli(["--chat", "nope@c.us", "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(missingChat.port), "--body", "hello", "--send"]);
  check(result.code === 5 && result.payload.error === "chat_not_found" && missingChat.calls() === 0, "a missing chat is a pre-dispatch refusal");
  missingChat.server.close();

  // The action refusing before doing anything is a refusal, not an ambiguous send.
  const preDispatch = await scenario({ action: { error: "store_action_missing" } });
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(preDispatch.port), "--body", "hello", "--send"]);
  check(result.code === 5 && result.payload.error === "store_action_missing", "a pre-dispatch action refusal is not ambiguous");
  preDispatch.server.close();

  // A body file is read, and whitespace is normalized to what the action will send.
  const bodyFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "wa-store-body-")), "body.txt");
  fs.writeFileSync(bodyFile, "  hello from file  \n");
  const fileSend = await scenario({});
  result = await runCli(["--chat", SELF_ID, "--expect-account", SELF_ID, "--expect-browser-endpoint", loopback(fileSend.port), "--body-file", bodyFile, "--send"]);
  check(result.code === 0 && result.payload.body === "hello from file", "the body file is trimmed to what the action sends");
  fileSend.server.close();

  console.log("ALL PASS");
  console.log("whatsapp store ok (" + checked + " checks, 0 skips; pure rules plus a fake-CDP CLI)");
  void checked;
})().catch((error) => {
  console.log("FAIL", (error && error.stack) || error);
  console.log("1 FAILURE(S)");
  process.exit(1);
});
