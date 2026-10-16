# WhatsApp injected app-action send — proof status and live procedure

The Copilot uses `scripts/whatsapp-store-send.mjs`, which invokes WhatsApp's own
`WAWebSendTextMsgChatAction.sendTextMsgToChat` action. It does not open/focus a chat, type, dispatch keys,
or mark a conversation read. A read-only live lookup and dry run confirmed the bound account/page, a
proven self identity, and that the app action exists. It also found a human draft on the self chat, so no
live send was attempted. The fake app-store/CDP suite covers ordinary direct and group dispatch, one-call
semantics, store verification and fail-closed refusal paths.

## Live send approval boundary

A live message remains an external effect. Do not validate against a third-party or group chat without
explicit approval of the recipient and exact content. The current self chat has a human draft; do not
clear, overwrite or restore it for this test. A later live proof requires the operator to resolve that
draft and explicitly authorize the exact test message. The route refuses unsupported/unproven target
metadata, identity/page mismatch, a draft, active composition or link-preview state before dispatch.

## Prerequisites

- The node and sentinel are running if proving the Copilot pipeline (`docs/JOBS.md`).
- Chrome holds the approved WhatsApp Web session. Bind the exact loopback DevTools page and account from
  a read-only lookup; the store route does not require the document-start event hook.
- The self chat id is **resolved from the app's store**, never typed from memory: the account has both a
  phone (`@c.us`) and a LID (`@lid`) identity and "message yourself" lives under one of them. Run a
  rehearsal first and read `self_id` from its JSON output.

## The exact profile

Install this as `<WASM_AGENT_HOME>/.wasm-agent/subagent-profiles/whatsapp-responder.json`. The host's
`paths.config()` is `<WASM_AGENT_HOME>/.wasm-agent` (default `%USERPROFILE%\.wasm-agent` on Windows) -
**not** `%LOCALAPPDATA%`; the *install* directory (`%LOCALAPPDATA%\wasm-agent`) is a different tree. It is
a **local approved** binding; none of it appears in a portable artifact.

```json
{
  "schema_version": 1,
  "id": "whatsapp-responder",
  "instructions": "Answer one WhatsApp conversation as the operator. Read it, decide, and send at most one short reply.",
  "allowed_tools": ["whatsapp_read", "whatsapp_decide", "whatsapp_send"],
  "resources": {
    "conversation": "<SELF_CHAT_ID>",
    "allowed_conversations": ["<SELF_CHAT_ID>"],
    "actions": ["read", "send"],
    "self_destination": "<SELF_CHAT_ID>",
    "account": "<OWN_ACCOUNT_ID>",
    "browser_endpoint": "ws://[::1]:9222/devtools/page/<EXPLICIT_TARGET_ID>",
    "send_path": "store",
    "allow_mark_read": false,
    "send_approved": true,
    "reply_script": "",
    "store_send_script": "<INSTALL>/scripts/whatsapp-store-send.mjs"
  },
  "limits": { "context_messages": 20, "body_bytes": 4096, "sends_per_run": 1 },
  "model": null,
  "reasoning": null
}
```

Bindings, and why each is required:

| field | value |
| --- | --- |
| `conversation` / `allowed_conversations` | the notes-to-self chat id, from the store |
| `actions` | `["read","send"]`; read does not imply send, so a draft-only binding is `["read"]` |
| `self_destination` | the notes-to-self chat id. It is a convenience binding, **not** an unread exemption: a self chat is still refused when its unread is nonzero or unproven |
| `account` | the operator's own account id. Passed as `--expect-account`; a phone/PN compares by digits, while a `@lid` or a label compares exactly (so `operator1` never equals `other1`) |
| `browser_endpoint` | the explicit loopback DevTools page from the read-only lookup. Passed as `--expect-browser-endpoint`; protocol, port and page id must match exactly, and only genuine loopback aliases are interchangeable |
| `send_path` | `store`; bind the installed `whatsapp-store-send.mjs` locally |
| `allow_mark_read` | `false`; the store route opens no chat and does not alter unread state |
| `send_approved` | `true` **only for the proof**; a decision never grants it |
| `store_send_script` | the deterministic app-action sender in the install |
| `limits.sends_per_run` | `1` |

## The commands

1. **Resolve the self chat id, read-only.** `--lookup-only` reads the app's store and returns the target,
   the account and `self_id` without acquiring the send lock, opening a chat, typing or sending:

   ```
   node <INSTALL>/scripts/whatsapp-reply.mjs --to-self --lookup-only
   # {"ok":true,"lookup_only":true,"chat":{"id":"<SELF_CHAT_ID>",...},"self_id":"<SELF_CHAT_ID>","account":"<OWN_ACCOUNT_ID>","is_me":true,...}
   ```

   Self is **proven by the app**, never inferred: the resolver asks `WAWebUserPrefsMeUser`
   (`isMeAccount`/`isSerializedWidMe` and the current PN/LID) and refuses
   (`self_chat_unresolved`/`self_chat_ambiguous`) when it cannot identify exactly one self chat. Message
   direction and display names are never evidence - an unanswered stranger has outgoing-only history too.

   Put `chat.id` in `conversation`, `allowed_conversations` and `self_destination`, and `account` in
   `account`. The lookup also returns the account (`account`) and the discovered endpoint
   (`browser_endpoint`) so the binding can be copied exactly. To read recent context without opening
   anything either, use `node <INSTALL>/scripts/whatsapp-read.mjs` (the store reader).

   The legacy UI send/rehearsal modes now fail closed with `ui_input_route_retired`; `whatsapp-reply.mjs`
   remains only as a read-only lookup shim. The store sender's no-body invocation below is read-only and
   does not touch the composer.

2. **Inspect the target, read-only.** Bind the conversation id from the trusted ledger/store, never a
   guessed title. This rehearsal connects only to the explicitly bound page and dispatches nothing:

   ```
   node <INSTALL>/scripts/whatsapp-store-send.mjs --chat <BOUND_CHAT_ID> --expect-account <OWN_ACCOUNT_ID> --expect-browser-endpoint <BOUND_PAGE>
   # dry_run=true; inspect kind, draft_present, active state and action_available
   ```

3. **The live send (coordinator only, after explicit approval).** The current self chat is not eligible
   while its draft is present. Do not work around `target_draft_present`. Once the operator has resolved
   the draft and approved the exact content, make one `--send` call against the bound target. Success
   requires a new store message with the exact recipient/body, `fromMe`, and server `ack >= 1`; timeout or
   missing proof is ambiguous and must not be retried.

4. **Record the ledger.** The Copilot's reader records decisions/effects separately; its note-home notices
   and transcript replies use the injected store sender with locally bound account, browser page and
   self-destination. They never fall back to `whatsapp-reply.mjs` or simulated input events.

This task performed only read-only live lookup/dry-run steps; it did not open a chat or send a message.

## What is proven, and what is not

- Proven here: the live page exposes the app action and bound account/self chat; live state reports a
  present draft, which the route refuses. Fake-store/CDP tests prove direct/group app-action calls, exact
  store reconciliation, supported-kind guards and no retry on ambiguity.
- Not proven: a live third-party/group send. The end-to-end scoped-tool path through `POST /subagents` is
  separate from the raw store-send proof.
- Never overwrite a human draft, open another chat, retry an ambiguous send, or send to an unbound target.

## The store send route (implementation and fixture-proven; no third-party live send)

`scripts/whatsapp-store-send.mjs` is the store route: it calls the app's own
`WAWebSendTextMsgChatAction.sendTextMsgToChat(chatModel, body, options)` and never opens the chat,
focuses, types, or marks anything read. It permits only Wid-method-proven direct/group chats; bot,
broadcast, suffix-only and unknown kinds fail closed.

Rules the route enforces:

- both identity bindings (`--expect-account`, `--expect-browser-endpoint`) are required for a send;
- the browser endpoint must be an explicitly bound loopback WebSocket page endpoint - no discovery and
  no fallback to a default port;
- a target draft or link-preview state refuses the send before the action runs (the action clears
  `urlText`/`urlNumber`), and unknown metadata fails closed;
- the app action is called exactly once; a throw or a timeout is an ambiguous post-dispatch outcome and
  is never retried;
- a send is `sent`/`verified` only when a new message in the store has the exact recipient, body and
  `fromMe`, and a server `ack >= 1`. A local optimistic insertion (ack 0) is not proof.

The page expressions and the guards are pure (`scripts/whatsapp-store-core.mjs`) and are tested against
adversarial fake app stores, plus the real CLI against a fake CDP server (`tests/whatsapp-store.js`). No
live browser is opened by the fixture.

### Verified app shape (read-only evidence, app 2.3000.1048024606)

The coordinator read these from the live app; the route and its fixture are built against them, not
against guessed booleans:

- `chat.id` is a Wid with `isUser()`/`isGroup()`/`isBot()` methods; `chat.isGroup` is **undefined**.
  A kind is authorized only when all methods return booleans and exactly one returns true; suffix fallback
  is display-only and cannot authorize a send.
- The per-chat draft is **`chat.draftMessage`**, an object with a `text` string and a `timestamp`.
  `chat.draft`/`draftText`/`composeContents` are undefined. The route uses `draftMessage` only to
  decide whether a draft is present, and **never reads the text out**.
- `chat.urlText`/`chat.urlNumber` are **undefined** on this build, so there is no link-preview state to
  clear here; a present, non-empty value is still refused before the action.
- `chat.unreadCount` is a number, `markedUnread` a boolean, `activeUnreadCount` a number;
  `archive`/`isReadOnly` are booleans; `active` is a boolean; `typing`/`recording`/`isComposingPoll` are
  booleans. The route refuses a read-only, archived or actively-composing target.

The live self chat has a draft; the route refuses it and never clears, overwrites or restores it. The app
action's return value is not delivery proof: only a new matching store message with a server ack confirms.

The direct/group guard is enabled against Wid methods and adversarial fixtures, but has not been live-proven by sending to a third party or group; the live third-party/group send remains unproven.
