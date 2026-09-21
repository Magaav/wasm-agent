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

Install this as `<config>/subagent-profiles/whatsapp-responder.json` (`<config>` is `paths.config()`,
e.g. `%LOCALAPPDATA%\wasm-agent` on Windows). It is a **local approved** binding; none of it appears in a
portable artifact.

```json
{
  "schema_version": 1,
  "id": "whatsapp-responder",
  "instructions": "Answer one WhatsApp conversation as the operator. Read it, decide, and send at most one short reply.",
  "allowed_tools": ["whatsapp_conversation", "whatsapp_decide", "whatsapp_send"],
  "resources": {
    "allowed_conversation": "<SELF_CHAT_ID>",
    "allowed_conversations": ["<SELF_CHAT_ID>"],
    "self_destination": "<SELF_CHAT_ID>",
    "account": "operator",
    "browser_endpoint": "ws://localhost:9222/devtools/page/<EXPLICIT_TARGET_ID>",
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
| `allowed_conversation` / `allowed_conversations` | the notes-to-self chat id, from the store |
| `self_destination` | the **same** id; this is what makes the UI route's unread consequence acceptable |
| `browser_endpoint` | the explicit loopback DevTools page, from `whatsapp-preflight.sh` |
| `send_path` | `ui` (the only proven route); `store` is refused without a real `store_send_script` |
| `allow_mark_read` | `false`; the self exemption applies, so it is not needed |
| `send_approved` | `true` **only for the proof**; a decision never grants it |
| `reply_script` | the deterministic reply tool in the install |
| `limits.sends_per_run` | `1` |

## The commands

1. **Resolve the self chat id (read-only, no send).** A rehearsal types the body, asserts the composer,
   and clears it:

   ```
   node <INSTALL>/scripts/whatsapp-reply.mjs --to-self --body "live proof rehearsal" 
   ```

   Read `chat.id` (and `self_id`) from the JSON output and put it in `allowed_conversation`,
   `allowed_conversations` and `self_destination`.

2. **Confirm the raw-script guard.** With the id bound, a non-self `--send` must be refused *before the
   chat is opened*:

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
   through `ctx.effects`.

## What is proven, and what is not

- Proven by this proof: resolve → open → type → send → store verification, on a real session, plus the
  refusal paths above.
- Not proven by this proof, and must not be claimed: a third-party reply (needs an approved store path or
  an accepted unread consequence), and the end-to-end scoped-tool path through `POST /subagents` until
  the runtime worker's registry and durable `ctx.effects` adapter land.
- Never do: overwrite a human draft (the tool refuses a non-empty composer), open another chat, retry an
  ambiguous send, or send to anyone the operator did not bind.
