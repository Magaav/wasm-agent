# ChatGPT-subscription route: the cutover - status

Branch: `change/wa-session-childdispatch389b8886-2cfb-45bc-be85-64f4357931f9`
Built from: the transport tip `ea2f2011` (`subscription_wire.lua`, the catalogue, `host.http_sse`,
`WASM_AGENT_SUBSCRIPTION_TRANSPORT=native`) with the credential tip `a6e111d7`
(`openai_sub_auth.lua`) merged into it. Base for both was `ab827c88` (`origin/main`).

This file is written and committed **before** the seam fixes, on purpose: a cancelled run that
leaves a truthful status file still delivers, and the sibling delivery was marked needs-change
precisely because its status file was never committed. It is updated, not rewritten, as the work
lands; the last section says which state you are reading.

## State at this commit (`merge(credential+transport)`)

**What works.** The two halves are in one tree. The merge is committed as
`merge(credential+transport)` with two files resolved by keeping **both** intents - see "The merge"
below for the exact lines. Nothing in either lane's own change was edited to make them fit.

**What is proven.** Only that: the merge is committed, the tree is clean, and `bash -n scripts/test.sh`
parses. The two halves' own verification (the credential lane's 6-process single-flight proof, the
transport lane's offline wire replay) is theirs, was done on their branches, and is **not** re-proven
here.

**What is not true yet, at this commit.** The three seam defects below are still open. Do not read
further down this file as evidence for the pair working until the commit that closes them.

### The seam defects, as received

1. **The wire cannot find the credential.** `lua/core/subscription_wire.lua:126` does
   `pcall(dofile, 'lua/core/subscription_auth.lua')`; the credential lane shipped
   `lua/core/openai_sub_auth.lua`. Ruling (the coordinator's, not mine): adopt the credential lane's
   existing name, because that is the tested artifact; change the wire's `dofile`. The credential
   module is **not** renamed and **no** shim/second module is added.
2. **The wire reads only the first return value.** The seam returns `token, failure`; a missing or
   rejected credential therefore surfaces as a bare `nil` with the `code`/`message` taxonomy
   (`subscription_credentials_absent`, `refresh_rejected:<status>`, `locked`, `flow_expired`) dropped
   on the floor. The `code` has to reach the caller.
3. **The login has no consumer.** `scripts/openai-sub-login.lua` works from `WA_SCRIPT=`, but nothing
   in `lua/core` calls it, so no one who installed a node can start a login. The exposure must let a
   person start a flow and see the URL and the user code, and must say when a human is required
   rather than claim success.

## The merge: exactly which lines were chosen

Two files conflicted, both the same shape - two lanes each appending independent wiring to a shared
list. Kept both; nothing was dropped and nothing was reordered beyond grouping.

* **`rust/wa-host/src/main.rs`, the `EMBEDDED` list.** Kept the credential lane's entry *with its
  three-line comment* -

  ```
  // The subscription credential: our own store, refresh and login, which the transport lane
  // reaches through `M.token()`. It is here because this list is what a deployed node can load -
  // a module absent from it exists in the working tree and not in the shipped binary.
  ("lua/core/openai_sub_auth.lua", include_str!("../../../lua/core/openai_sub_auth.lua")),
  ```

  and then the transport lane's two entries, unchanged:
  `("lua/core/openai_sub_catalogue.lua", ...)` and `("lua/core/subscription_wire.lua", ...)`.
  *Why*: the comment is the reason the entry exists and I am not the lane that wrote it; all three
  modules must be embedded or a shipped binary cannot load them. The transport lane's
  `lua.register("http_sse", host::http_sse)` hunk did **not** conflict and is untouched.
* **`scripts/test.sh`.** Kept the transport lane's `test-subscription-wire.lua` block and the
  credential lane's `test-openai-sub-auth.lua` block in full, wire first, credential second.
  *Why*: they test different files and neither supersedes the other. The credential block's
  `SKIPPED` counter is the one already defined at line 6 of this file, so a machine without `node`
  skips visibly (`SKIPPED=$((SKIPPED + 1))`) instead of passing silently.

`git merge-tree --write-tree ea2f2011 a6e111d7` reported exactly these two conflicts before the
merge was performed; no other file conflicted.

## What works / what is proven / what is unproven

Filled in by the commits after this one. Read the **last** section for the state of this branch as
it stands.
