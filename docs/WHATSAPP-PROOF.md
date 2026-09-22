# WhatsApp self-chat live proof — setup (not performed here)

The final live proof sends one reply to the operator's **own notes-to-self** chat. It is the smallest
real send that exercises the whole route (resolve, open, type, send, verify in the store) without
touching a third party or clearing someone else's unread marker. The coordinator performs the send; this
page is the exact setup it needs.

## Why self-chat is the safe live proof

The only route this build proves is the UI route: it opens the chat, and opening a chat is what clears
its unread marker. For **notes-to-self** there is nothing to clear, so the route is acceptable without
accepting a third party's marker being cleared. `lua/core/whatsapp.lua` encodes that exemption
(`conversation == resources.self_destination`), and `scripts/whatsapp-reply.mjs` refuses a non-self
`--send` before it opens anything unless `--allow-mark-read` (or `WA_WHATSAPP_ALLOW_MARK_READ=1`) is
passed. A third-party live proof is out of scope here: it needs an approved store send path
(`resources.store_send_script`) or an explicit decision to accept the unread consequence.

## Prerequisites

- The node and sentinel are running, and the job pipeline is enabled (`docs/JOBS.md`).
- Chrome holds the operator's WhatsApp Web session, and the document-start hook is bound:
  `bash scripts/whatsapp-preflight.sh` must print `whatsapp preflight ok ... hook=...`. A red line names
  the broken link; do not proceed past it.
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
    "send_path": "ui",
    "allow_mark_read": false,
    "send_approved": true,
    "reply_script": "<INSTALL>/scripts/whatsapp-reply.mjs",
    "store_send_script": ""
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
| `browser_endpoint` | the explicit loopback DevTools page from `whatsapp-preflight.sh`. On the verified machine the store and hook are on **IPv6 `[::1]:9222`**; IPv4 `127.0.0.1:9222` answers 404 (not a browser). Passed as `--expect-browser-endpoint`; protocol, port and page id must match exactly, and only genuine loopback aliases are interchangeable |
| `send_path` | `ui` (the only proven route); `store` is refused without a real `store_send_script` |
| `allow_mark_read` | `false`; opening any chat without a proven zero unread (the operator's own notes included) requires `true` |
| `send_approved` | `true` **only for the proof**; a decision never grants it |
| `reply_script` | the deterministic reply tool in the install |
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

   A **rehearsal** (`--to-self --body "..."` without `--send`) is *not* read-only: it opens the chat,
   types the body, asserts the composer and clears its own text (opening clears the self chat's marker,
   which is empty anyway). Use it only when you intend to interact with the page.

2. **Confirm the raw-script guard.** Opening the chat clears its unread marker, so a non-self target is
   refused before it is opened, and a self target is refused unless its unread is a proven zero. Passing
   `--allow-mark-read` explicitly accepts the marker being cleared; the script independently proves the
   account through the app rather than a string comparison against a guessed id:

   ```
   node <INSTALL>/scripts/whatsapp-reply.mjs --chat <OTHER_CHAT_ID> --body "should not send" --send
   # {"error":"unread_would_be_broken", ...}  exit 8, and no chat was opened
   ```

3. **The live send (coordinator).** One message to the operator's own notes:

   ```
   node <INSTALL>/scripts/whatsapp-reply.mjs --to-self --body "wasm-agent live proof <timestamp>" --send
   ```

   Success is the store, not the keystroke:

   ```json
   {"ok":true,"sent":true,"verified":true,"chat":{"id":"<SELF_CHAT_ID>"},
    "message":{"id":"3EB0...","ack":3},"body":"wasm-agent live proof ...","unread_before":0}
   ```

4. **Record the ledger.** The reply job, when it runs, summarises to the same notes chat with
   `whatsapp-reply.mjs --to-self` and first calls `whatsapp_decide`, which writes a durable effect
   through `ctx.effects` (reserve/confirm; a decision must not clobber a send reservation).

This task performed none of the live steps above: no browser was opened and no message was sent.

## What is proven, and what is not

- Proven by this proof: resolve → open → type → send → store verification, on a real session, plus the
  refusal paths above.
- Not proven by this proof, and must not be claimed: a third-party reply (needs an approved store path or
  an accepted unread consequence), and the end-to-end scoped-tool path through `POST /subagents` until
  the runtime worker's registry and durable `ctx.effects` adapter land.
- Never do: overwrite a human draft (the tool refuses a non-empty composer), open another chat, retry an
  ambiguous send, or send to anyone the operator did not bind.
