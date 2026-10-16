---
name: whatsapp-module-inspection
description: Read-only inspection of WhatsApp Web's internal module/function contracts. Use when implementing or debugging a store-based adapter, especially when the document-start hook missed a factory or an exported function only delegates to an async wrapper. Never treat source discovery as permission to send.
---

# Inspect the function, not private account data

1. Connect to the existing authorized WhatsApp page through CDP. Try both loopback
   stacks: an HTTP 404 at `127.0.0.1:9222` does not establish that `[::1]:9222` is down.
   Do not reload the user's page to recover a missed document-start hook.
2. Read `Object.keys(window.require('<module>') || {})`. This discovers exports;
   **do not invoke actions** while probing.
3. `window.require('__debug').modulesMap[name]` exposes module metadata even when
   `window.require` itself has no enumerable cache. Its factory may already have
   been cleared after execution. Do not claim that `factory: null` means the module
   is unavailable.
4. For a wrapper such as `function d(e,t,n){return m.apply(this,arguments)}`:
   - `Runtime.evaluate` the exported function with `returnByValue:false`.
   - `Runtime.getProperties` its object ID; locate internal `[[Scopes]]`.
   - Inspect only closure scopes, then the wrapper's named function delegate.
   - Obtain delegate source with `Runtime.callFunctionOn`, declaration
     `function(){return Function.prototype.toString.call(this)}`.
   - An async helper's closure can contain the generator function implementing the
     action. Inspect that **function's source**, not arbitrary values in its closure.
5. Restrict output to function source and module/property names. Never dump account
   objects, tokens, message collections, authentication storage, or complete scopes.
6. Record the actual contract and app build separately from behavioral evidence.
   Finding a send function does not prove delivery, receipt identity, unread safety,
   draft preservation, crash recovery, or authority. Prove those in isolated fixtures
   first; live sends require explicit approval and verified destination identity.

## Verified discovery, not a send procedure

On the inspected Chrome 153 session, `WAWebSendTextMsgChatAction` exported
`sendTextMsgToChat`, `createTextMsgData`, and `addAndSendTextMsg`. The inspected send
wrapper delegated through message-data creation, business terms handling,
ephemerality handling, and the app's send pipeline. Do not bypass these steps by
assuming a lower-level helper is equivalent.

`WAWebUserPrefsMeUser` exported `getMaybeMePnUser`, `getMaybeMeLidUser`, and
`isMeAccount`. Self-chat identity must come from those verified account identities,
**never** from a chat title or from the absence of incoming messages: an unanswered
third-party conversation can also contain only outgoing messages.

For ordinary replies, follow [the reply procedure](../whatsapp-reply/SKILL.md).
