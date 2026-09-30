# ChatGPT-subscription route: the cutover - status

Branch: `change/wa-session-childdispatch389b8886-2cfb-45bc-be85-64f4357931f9`
Built from: the transport tip `ea2f2011` (`subscription_wire.lua`, the catalogue, `host.http_sse`,
`WASM_AGENT_SUBSCRIPTION_TRANSPORT=native`) with the credential tip `a6e111d7`
(`openai_sub_auth.lua`) merged into it. Base for both was `ab827c88` (`origin/main`).

This file is written and committed **before** the seam fixes, on purpose: a cancelled run that
leaves a truthful status file still delivers, and the sibling delivery was marked needs-change
precisely because its status file was never committed. It is updated, not rewritten, as the work
lands.

**Read "What works, what is proven, what is unproven" at the end for the state of this branch.**
The section immediately below is the state at the merge commit, kept as it was written.

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

## What works, what is proven, what is unproven

### The three seam defects, fixed (`9e015d6`)

1. **The name.** `M.credential()` now names `M.CREDENTIAL_MODULE = 'lua/core/openai_sub_auth.lua'`
   - the credential lane's tested artifact. The credential module was not renamed and no shim or
   second module was added. The same stale literal was fixed in the three files that call the seam
   by that name: `scripts/test-subscription-wire.lua` (which asserted the old name),
   `scripts/check-subscription-wire-parity.lua` and `scripts/check-subscription-wire-live.lua`
   (both of which would otherwise have silently fallen back to reading pi's `auth.json`).
2. **The second return value.** `M.credential()` returns `token, failure` - the credential lane's
   `code`/`message` passed through unchanged - and `M.complete` raises it with `error(..., 0)` so the
   code is first in the text. `M.limits()` returns it as a second value instead of swallowing it.
   Two cases the credential lane cannot report itself (its file unloadable, `token()` answering with
   neither value) get codes of this file's own, in the same shape.
3. **The login door.** `wa subscription [status | login ...]` in `lua/core/init.lua`. It is a route,
   not a second policy: it loads the credential lane's own `scripts/openai-sub-login.lua` and hands
   `args` through, so "already logged in", the one-time import out of Pi, the printed URL and code
   and the exit codes stay that lane's tested behaviour.

### Proof 1 - `configured()` is true on native with Pi unreachable (the gate at `agent.lua:1083`)

Pi's package directory (`.../npm/node_modules/@earendil-works`) and `~/.pi/agent/auth.json` were both
renamed aside first; `ls` on each reported "No such file or directory".

```
transport:             native
pi auth path:          C:\Users\Victor/.pi/agent/auth.json
pi auth readable:      false   (must be false)
our store:             C:\Users\Victor/.wasm-agent/openai-sub/credentials.json
configured():          true   (must be true)
provider.configured(): true
openai-sub credential: valid for account 14c747d9-6514-4792-97f7-bee01c49cbae, expires in 858839s, refreshes 2, refresh 5d9c89658161
proof 1 ok: configured() is true on native with no Pi on disk
```

### Proof 2 - a real request through the wire, credential through the credential module

Same run, Pi still aside. **The call is direct** - `lua/core/openai_sub.lua`'s own `complete`, not an
agent turn - because this node's provider refuses `gpt-6-*` as `model_not_servable` from its
servability store, so a turn through `provider.lua` cannot carry this model here. The credential was
taken through the seam itself (`wire.credential()`, both return values); no stub and no fixture token
was installed anywhere in the process.

```
transport:              native
pi auth readable:       false   (must be false)
configured():           true
credential from the seam: account=14c747d9-6514-4792-97f7-bee01c49cbae access_fingerprint=9c2278285978 expires_in_s=858839
events:                 pending_delta=8 commentary=1 unresolved_pending=0
  pending_delta  pending_id=a3d9933a-...:1 text="I"
  pending_delta  pending_id=a3d9933a-...:1 text="’m"
  ... (6 more deltas, same pending_id)
  pending_delta  pending_id=a3d9933a-...:1 text="."
  commentary     pending_id=a3d9933a-...:1 message_id=acff086a-2602-42d3-bc6b-a2d708c68237 phase=nil text="I’m checking the current UTC time."
result.commentary (the resolved commentary the route returns): [{"content":"I’m checking the current UTC time.","id":"acff086a-...","pending_id":"a3d9933a-...:1"}]
result.content (the answer, which must not contain it):         ""
tool_calls: 1
  call id=call_zGfK1kyuK0VWLEWTcAeG9SIK|fc_0165d136a958599b016abd19f317e887d28e1d62fc7791f26c name=get_time arguments={"zone":"UTC"}
  arguments parsed back: {"zone":"UTC"}
usage:            {"completion_tokens":33,"completion_tokens_details":{"reasoning_tokens":0},"prompt_tokens":93,"prompt_tokens_details":{"cached_tokens":0},"total_tokens":126}
finish_reason:    tool_calls  stream_complete=true  events=24  ttft_ms=1179.7148  request_id=resp_0165d136a958599b016abd19f1c74487d295e65b525dbc7d98  elapsed_ms=1829
store afterwards: present=true state=valid source=import:pi refreshes=2 access_fingerprint=9c2278285978
proof 2 ok: a real stream through the wire, credential from the credential module, commentary resolved, tool call with arguments, usage
```

Read it as: eight `pending_delta` events on one `pending_id` resolved to exactly one `commentary`
event (0 unresolved), the resolved commentary is what the route returns and it is **not** in
`result.content`, the tool call's arguments are parsed (`{"zone":"UTC"}` re-decoded from what the
wire published, not raw model text), and usage is the endpoint's numbers. The store afterwards still
reports the same `access_fingerprint` as the credential the seam served, `source=import:pi`,
`refreshes=2` - the credential is ours, imported once from Pi by the credential lane, and **nothing
read Pi's files to get it**: they were renamed aside for the whole run.

### Proof 3 - missing credential: the taxonomy reaches the surface, and 0 token POSTs

Our store absent (`WASM_AGENT_OPENAI_SUB_STORE` at a path that does not exist) and the auth host
replaced by the credential lane's counting stand-in (`scripts/lib/openai-sub-auth-mock.mjs`), which
appends one line per POST to `posts.jsonl`.

```
store:               /tmp/waproof/absent/credentials.json   readable=false (must be false)
pi auth:             C:\Users\Victor/.pi/agent/auth.json   readable=true
seam credential:     nil
seam failure.code:   subscription_credentials_absent
seam as a sentence:  subscription_credentials_absent: no ChatGPT-subscription credential at /tmp/waproof/absent/credentials.json and no credential to import from C:\Users\Victor/.pi/agent/auth.json; log in with: WA_SCRIPT=scripts/openai-sub-login.lua wa (device code), then retry
complete ok:         false
complete raised:     subscription_credentials_absent: no ChatGPT-subscription credential at ...
configured():        false (must be false: no credential, no turn)
proof 3 ok: the taxonomy reaches the surface, and no turn is attempted without a credential
token POSTs to the auth host: 0  (mock log lines: 1)
```

Note what is *stronger* here than the brief asked for: pi's `auth.json` was readable in this run
(it had already been restored), the store was not, and nothing consulted it - `readable=false` for
our store is the only thing that changed the answer. The single mock log line is `ready <port>`; the
counter recorded no request at all, so "0 token POSTs" is a measurement, not an assertion.

### Proof 4 - the login door, and how a person reaches it

```
$ wa subscription status
openai-sub credential: valid for account 14c747d9-6514-4792-97f7-bee01c49cbae, expires in 858817s, refreshes 2, refresh 5d9c89658161
    store:  C:\Users\Victor/.wasm-agent/openai-sub/credentials.json
    log in: wa subscription login             device code: prints the URL and the code,
                                              then waits for you to enter it
            wa subscription login --browser    sign in in a browser, come back with --code <url>

$ wa subscription login --browser        (with no Pi credential in reach)
openai-sub: open this URL, sign in, then paste the address you land on (it starts with http://localhost:1455/auth/callback):
https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&...&originator=wasm-agent
openai-sub: waiting for the browser step - re-run with --code <the address you landed on>
  exit 0

$ wa subscription login --device         (real endpoint, 12s human budget)
openai-sub: open https://auth.openai.com/codex/device and enter the code 6L1K-35D8K  (waiting up to 12s)
openai-sub: still waiting for the code 6L1K-35D8K (6 polls, 0s left)
openai-sub login failed: flow_expired
  the device login for code 6L1K-35D8K expired after 12s without authorization; the pending flow is kept at /tmp/waproof/door2/login-flow.json - re-run the login to resume, or open https://auth.openai.com/codex/device and enter 6L1K-35D8K
  exit 1

$ wa help
    subscription [status | login [--device|--browser|--code <url>]]  this node's ChatGPT
        subscription credential: print the verification URL and code, then wait for you
```

So the two ways a person reaches a login are `wa subscription login` (device code: prints the real
verification URL and a real user code, then waits) and `wa subscription login --browser` followed by
`wa subscription login --code <the address you landed on>`. Both print what a human has to do; the
12 s device run ends at `flow_expired`, says which code is still valid and how to resume, and exits
non-zero rather than claiming a credential it did not store. `WASM_AGENT_OPENAI_SUB_LOGIN_TIMEOUT`
set the 12 s budget for this run (the human is not available in an agent's window). With no such
override the same command waits 300 s by default (`DEFAULT_LOGIN_TIMEOUT_SECONDS`), and never longer
than the device flow's own 900 s window.

### Pi's files: restored, and unchanged

```
auth.json sha256 before: c60f57470aa1b63d13077bf11c1f7fd4f8cd19ee710ac8fc74259055f4014d74
auth.json sha256 after:  c60f57470aa1b63d13077bf11c1f7fd4f8cd19ee710ac8fc74259055f4014d74
package dir listing before: 9f8111c609785f392feebd73eb97e8712593b9fce13e1d2e3093dcfe0c742a74
package dir listing after:  9f8111c609785f392feebd73eb97e8712593b9fce13e1d2e3093dcfe0c742a74
auth.json UNCHANGED
package dir UNCHANGED
```

The rename is done inside a script whose `trap ... EXIT` restores both paths, so an interrupted run
puts Pi back rather than leaving the operator's installation moved.

### Follow-up: the transport half's review (VERDICT needs-change), folded in here

These three landed inside this delivery because it is already merging exactly these files.

**1. A test nobody runs is a comment.** The transport half added `mod sse_line_tests` to
`rust/wa-host/src/host.rs` (4 tests), reported them passing by hand, and **no `cargo test` line in
`scripts/test.sh` executed them**: `grep sse_line scripts/test.sh` was empty, every `-p wa-host`
invocation named a different module (`file_search::tests`, `ticker_tests`, `terminal_tests`,
`terminal_editor::tests`, `serve::`, `subagents::`, `deadline_note_tests`), and the gate log had no
`running 4 tests` for them. Corrected in two places:

* `scripts/test.sh` - the line added, immediately after the `file_search::tests` filter and before the
  `ticker_tests` comment, beside the other `-p wa-host` filters:

  ```
  cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host sse_line_tests
  ```

  with a comment above it saying why it belongs there (the line boundaries `host.http_sse` hands the
  wire are half of that route's contract, and the recorded fixtures under
  `tests/fixtures/subscription/` are what it reads).
* `docs/SUBSCRIPTION_WIRE_STATUS.md` §6 - that table listed the filter as if it were "in the gate's
  own terms" while three rows above it carried a `test.sh:<line>` annotation and this one could not.
  A correction is now in the file, in the file's own voice, saying what was true: four tests existed,
  four passed by hand, and no gate line ran one of them - a branch receipt cannot cover a suite.

Neither this file nor any status file here had claimed gate coverage of those four before; silence was
the problem, and the row that implied it is the one corrected.

**2. The `EMBEDDED` key and the wire's `dofile` name.** After the merge these are one string, and it
is worth stating exactly:

```
rust/wa-host/src/main.rs:65   ("lua/core/openai_sub_auth.lua", include_str!("../../../lua/core/openai_sub_auth.lua")),
lua/core/subscription_wire.lua:130   M.CREDENTIAL_MODULE = 'lua/core/openai_sub_auth.lua'
```

The reviewer's reading was of the two halves *before* the seam fix (the wire then asked for
`subscription_auth.lua`, which is the defect this delivery exists to close) - but the reason to care
survives the fix, so the entry's comment now says that the key is not free: the wire loads the
credential as `dofile(M.CREDENTIAL_MODULE)` and nothing else, so a credential registered under a name
the wire never asks for is embedded and unreachable. And the proof was re-run in the shape production
has - **`WASM_AGENT_LUA_ROOT` unset**, so `dofile` resolves every module from the binary's own
embedded registry and no file in this worktree can rescue a wrong name. The binary says so itself:

```
lua root unset: using embedded modules; edits under lua/ are NOT under test
transport:              native
configured():           true
credential module the wire names: lua/core/openai_sub_auth.lua   lua root: nil
```

Everything in the proof sections **above** reproduced in that shape, in the same order (proofs 1, 2
and 3), with Pi's package directory renamed aside and `auth.json` unreachable: `configured()` true, 8
`pending_delta` -> 1 `commentary`, `arguments={"zone":"UTC"}`, usage `{prompt 93, completion 33,
total 126}`, `stream_complete=true`, `token POSTs=0` on the absent-store path, and Pi's hashes
unchanged (`c60f5747…` / `9f8111c6…`). Those transcripts above are the root-set run; the no-root run
is the same assertions with the same values, and the only difference between the two runs is which
copy of the Lua answered - which is the point. A successful request with no Lua root *is* the
agreement proof: a stale embedded wire would `dofile` a name the embedded registry does not carry, and
there would be no request to report.

**3. The `reasoning` field: UNPROVEN, and now said out loud.** The wire implements three
`response.reasoning_*` events (`lua/core/subscription_wire.lua:671-685`) and returns
`result.reasoning`; no live run has ever shown the endpoint sending one. Re-measured here rather than
argued: `reasoning events: 0   result.reasoning=""` on the `low`-level run above, and the reviewer's
two prompts (`low` and `medium`) found none either - and neither recorded fixture contains a
`response.reasoning_*` event. So the honest statement is: **the reasoning event and `result.reasoning`
are implemented and never observed to fire; treat them as unproven.** The `reasoning_tokens:0` in the
usage block is a different thing (the endpoint's own token accounting), and it is present.

### The closing gate

Run twice, and the second run is the one that counts, because the first was refused and the tree
changed in between. The lane serializes these runs; both facts below are the lane's own words.

**Run 1 - refused, and correctly so.** With a bounded wait (`WA_GATE_LANE_WAIT_SECONDS=600`) the lane
granted no slot: `acquire #165 refused after 600s (terminal, not a retry). capacity 1 of 1 in use;
running #164 (finish integrate/frozen-batch-20260930, pid 38044, held 824s); queue depth 1; waited
600s`. The script reported `gate_verified: false` with that refusal as `gate_error` and
the gate did **not** run: `scripts/test.sh` was not executed without a slot, which is the one thing
the lane exists to prevent. It covers nothing and is recorded here so the record is not "one run,
passed".

(An earlier attempt, before this file's first gate section, used the *installed* copy of the closing
script under `~/.wasm-agent/skills/`, whose lane path resolves one directory too high; the lane could
not be consulted at all, so that run went ahead without a slot. It was cancelled rather than accepted,
and the worktree's own copy - `skills/parallel-evolution/scripts/finish.mjs`, whose lane path resolves
this tree's `scripts/gate-lane.mjs` - is what both runs above used.)

**Run 2 - passed, on `be21c86`.**

```
repository_ready true, all 8 checks ok (revision, source_tree, branch, clean, fresh_remote_refs,
  current, pushed, merge_proof)
gate_verified true, tested_head be21c8613a53c3adab32b73d0f290ad0aebcaf7e, equivalence git_tree,
  skipped 2, gate_ms 847454.151, gate_runs 1, gate_exit 0, gate_reused false
gate_lane: slot #166 granted after waiting 686.7s (mode slot, request 166)
verdict line: "smoke ok (2 skipped)"
```

The four Rust tests item 1 of the review is about are **inside that log**, which is the whole point of
adding the line:

```
running 4 tests
test host::sse_line_tests::a_residual_line_at_eof_is_still_a_line ... ok
test host::sse_line_tests::a_failing_callback_stops_the_read_at_that_line ... ok
test host::sse_line_tests::a_truncated_stream_ends_where_it_ended ... ok
test host::sse_line_tests::the_recorded_stream_is_handed_over_line_for_line ... ok
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 77 filtered out; finished in 0.00s
```

and so are the subscription suites:

```
openai-sub levels ok (22 checks)
subscription wire ok (135 checks)
openai-sub auth ok (128 checks)
openai-sub concurrency evidence: token POSTs=1, refreshed=1, adopted=1, rotation 50250ab6e946 -> 3626c3721573, second spend of the same token=refresh_rejected:400
```

The 2 skips are the suite's own: `termux launcher: 8 passed, 1 skipped (POSIX mode semantics
unavailable on Windows)` and Android build/runtime skipped on this non-Android host. Free space was
64 GiB available before run 2 and 63 GiB after it. `finish.mjs verify` at the same HEAD agrees: all
eight checks ok, `gate_verified true`, no gate error.

**What run 2 covers, exactly:** the tree `0bc8bb4d8791c62f7b91dacada8ad0ed4ba9767b` at `be21c86`. The
commit after it changes only this file (documentation), so the code tree the gate passed is the code
tree this branch ships - and a later commit that is *not* documentation-only is not covered by it.
(Run 2 supersedes the earlier `483ee40` gate recorded in this file's history: that tree did not yet
contain the `sse_line_tests` line, which is exactly the gap the review found.)

The harness behind proofs 1-3 and the login door is outside the repository, at
`C:/Users/Victor/.wasm-agent/wa-cutover-proof/` (`01-configured.lua`, `02-live.lua`,
`03-absent.lua`, `pi-aside-run.sh`, `run-absent-and-door.sh`), and is deliberately not committed: it
renames the operator's global npm directory, which is not something a fresh clone should do. Re-running
`bash pi-aside-run.sh` reproduces proofs 1, 2 and the Pi hash comparison end to end.

### What is unproven, and what was not done

* **The `reasoning` field.** UNPROVEN, and marked so in the review follow-up above: the wire
  implements three `response.reasoning_*` events and returns `result.reasoning`, and no live run -
  mine, or the reviewer's two prompts - has ever seen the endpoint send one. `reasoning_tokens` in
  the usage block is a different field, and that one is present.
* **Nothing about the gate is claimed beyond the line above.** The credential lane's *live* test
  (`scripts/test-openai-sub-auth-live.lua`) and the wire's *live* recording check
  (`scripts/check-subscription-wire-live.lua`) are not in the gate by design - they need the network
  and one of them rewrites the recorded fixtures - and were not run here.
* **The route through an agent turn.** Not exercised, and cannot be on this node as it stands: the
  provider refuses `gpt-6-*` (`model_not_servable`). Everything above is a direct call to
  `lua/core/openai_sub.lua`.
* **Reaching an authorized login.** The browser flow needs a human at a browser and the device flow
  needs a human to enter the code; neither was completed, so "a fresh login stores a usable
  credential" is the credential lane's proof, not re-proven here. What is proven here is that a
  person can *start* both and is told the human step is outstanding.
* **The default route.** Still `pi`; nothing here switches it. That is the coordinator's cutover and
  it is what `WASM_AGENT_SUBSCRIPTION_TRANSPORT=native` in the proof stands in for.
* **`lua/core/openai_sub.lua:13`** still describes the seam as `lua/core/subscription_auth.lua` in a
  comment. One line, no behaviour, and outside this delivery's scope - left for the coordinator, who
  owns that file next, rather than touched here.
* **No REPL `/login`.** The door is the `wa subscription` CLI arm. A blocking device login inside the
  REPL would block the REPL, and this delivery does not add a background login; the credential lane's
  own script is the same entry point a REPL command would have to call.
* **`scripts/check-subscription-wire-live.lua`'s fallback** now triggers only when the credential
  module cannot be loaded at all, so a live run against a tree that has the module but no credential
  fails with `subscription_credentials_absent` instead of falling back to reading pi's `auth.json`.
  That is the intended direction (pi's file is not a credential source for this route) and it was not
  re-run live, because it needs the network and rewrites the recorded fixtures.

## The installed-shape defect, found by the independent review (VERDICT needs-change)

Reproduced first-hand on this branch's own tip `4b5a26e` before any repair, with **no**
`WASM_AGENT_LUA_ROOT` - the shape `deploy.sh` ships and `wa-sentinel/src/instance.rs` protects:

```
$ wa subscription status                  (no Lua root)
openai-sub credential: absent (subscription_credentials_absent) at ...
    store:  ...
    log in: wa subscription login             device code: prints the URL and the code,
status exit=0

$ wa subscription login --browser         (no Lua root)
lua error: [string "bootstrap"]:1: embedded module missing: scripts/openai-sub-login.lua
browser exit=1
```

**The cause, exactly.** `lua/core/init.lua:273` did `dofile("scripts/openai-sub-login.lua")`, and the
`EMBEDDED` registry in `rust/wa-host/src/main.rs` has **zero** entries under `scripts/` (57 under
`lua/`). With a Lua root set, the file is on disk and the door works; with no root - an installed node -
`scripts/` is not in the registry at all, so the arm that exists to start a login is the one arm that
cannot run in the shape it exists for. `wa subscription status` worked only because every one of its
calls is already in `lua/` and therefore embedded, which is why the two subcommands disagreed.

**Why my own door proof missed it.** `~/.wasm-agent/wa-cutover-proof/run-absent-and-door.sh` exported
`WASM_AGENT_LUA_ROOT`, while its sibling `pi-aside-run.sh` deliberately unsets it - so the door was
proven in the checkout shape and the live request was proven in the installed shape, and neither run
covered both. That was a proof-design error, not a build accident, and the mechanical check below is
what makes the next one of these visible without a reviewer.

**The repair, in three parts.** (1) The login CLI moves into `lua/core/openai_sub_login.lua`, which is
in `EMBEDDED`; `scripts/openai-sub-login.lua` stays as a checkout wrapper, because the credential
module's own `LOGIN_COMMAND` and its tests name that path and that file is used as delivered. `status`
and `login` must behave identically in both shapes. (2) A gate-visible check that fails, by name, when
a literal `dofile("...")` target reachable from an embedded `lua/` file is not in `EMBEDDED` -
falsified by adding such a `dofile`, shown failing by name, removed. (3) A gate-visible test of the
login door with **no** Lua root, plus an equality check of `status` output between the two shapes.

Evidence for all three follows in the commits after this one. This section is committed first, so a
lost lane still leaves the finding and the plan rather than only the defect.

Agent: wasm-agent node=wasm_the_first role=child session=child:dispatch:389b8886-2cfb-45bc-be85-64f4357931f9
