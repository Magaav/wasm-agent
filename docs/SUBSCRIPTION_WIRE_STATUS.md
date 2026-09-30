# ChatGPT-subscription wire and catalogue - status

Branch: `change/wa-session-childdispatchaf915180-d6da-4eb4-a505-b41a7a36a52f`
Base: `320c0fcd` (the predecessor lane's single commit, fast-forwarded onto this session's branch;
nothing was restarted or rewritten). This file is the report the predecessor's cancelled run did not
leave: what exists, what is **proven**, and what is **not**.

The half this lane owns is the **wire** and the **catalogue**. The credential half is a sibling
lane's; the seam is one call, `lua/core/subscription_auth.lua`'s `token()`.

## What is proven, and how

### 1. A real request completes end to end, with Pi absent - PROVEN, twice

Command (harness at `/tmp/wa-native-proof/run.sh`, kept out of the repo because it renames the
user's global npm directory):

```sh
bash /tmp/wa-native-proof/run.sh <this-worktree>
```

Run twice, both exit 0. The first run is quoted below; the second run - the one whose full text is
committed at `tests/fixtures/subscription/live-check-output.txt` - repeated it with Pi's credential
file unreachable as well (see item 3), at `ttft_ms=1138.4481` / `1086.865`.

```
=== pi renamed aside for this run: .../npm/node_modules/@earendil-works -> ....PI-ASIDE-FOR-PROOF ===
pi-absent-check: ls: cannot access '.../npm/node_modules/@earendil-works': No such file or directory
pass 1: finish_reason=tool_calls ttft_ms=1968.815 events=11 usage={"completion_tokens":18,
  "completion_tokens_details":{"reasoning_tokens":0},"prompt_tokens":80,
  "prompt_tokens_details":{"cached_tokens":0},"total_tokens":98} (2248ms)
pass 1 tool call: id=call_QEby4ixqP67KlkIX5zOgXeuM|fc_0cb608d1f7fb858d016abd0568313087d292c7a6b01eec6b23
  name=get_time arguments={"zone":"UTC"}
pass 2: finish_reason=tool_calls ttft_ms=1393.6988 events=24 answer="" commentary=1 usage={...} (2057ms)
pass 2 streamed events: commentary=1 decision=2 pending_delta=8
subscription wire live check ok
=== live check exit: 0 ===
=== pi restored: .../npm/node_modules/@earendil-works ===
```

What each piece is evidence of:

* **Deltas arrive.** 8 `pending_delta` events with per-token text (`I`, `'m`, ` checking`, ...),
  resolved by one `commentary` event - the provisional-then-resolved phase contract, on real bytes.
* **A tool call.** `decision` announced (`complete=false`) then completed (`complete=true`), and the
  final call carries the `call_id|fc_item_id` id shape a replay needs, with parsed arguments.
* **Usage.** From the terminal event: prompt/cached/completion/reasoning token breakdown.
* **Independence.** `@earendil-works` (Pi 0.87.1, `pi-coding-agent`) was renamed aside for the
  duration and the same run succeeded; `WASM_AGENT_PI_MODELS_STORE` pointed at a nonexistent file.
  It was restored immediately after and its presence was checked again.

### 2. The fixture still matches the live endpoint - PROVEN

The run re-recorded both fixtures into a scratch tree. Against the committed fixtures, normalised for
the per-response identifiers the fixture README says are deliberately *not* redacted
(`resp_`/`msg_`/`fc_`/`call_`/`obfuscation`/`created_at`):

```
codex-responses-sse.txt      IDENTICAL (33 lines)
codex-responses-sse-text.txt IDENTICAL (72 lines)
```

Same event sequence, same fields, same shapes. The recorded bytes are not stale.

### 3. Credentials came from the seam, not from Pi - PROVEN, with a caveat

The scratch Lua root carried the sibling lane's credential module, fetched read-only
(`git show origin/change/wa-session-childdispatch95d6189a-...:lua/core/openai_sub_auth.lua`) and
placed at the seam path `lua/core/subscription_auth.lua` **inside the scratch tree only**. Nothing
was merged from that branch and no copy of it is committed here.

The evidence is a falsification, not an inference. The live check only falls back to reading Pi's
`auth.json` when the seam is missing, and it says so in a printed line. That line is absent from the
output. Stronger, and run second: the harness also sets
`PI_CODING_AGENT_DIR=<scratch>/NO-PI-AGENT-DIR`, which does not exist (`pi-agent-dir-absent-check: ls:
cannot access ...`), so Pi's credential file was **unreachable as well as Pi's package**. The run
still completed both requests end to end. There is therefore no path by which the token could have
come from Pi: it came from `lua/core/subscription_auth.lua`, over the seam, from the sibling store at
`~/.wasm-agent/openai-sub/credentials.json` (`access_fingerprint` `3f3ee3`, `obtained_at`
`1790766271171`).

**Caveat, stated plainly: the module file name differs between the two lanes (see below), so this
proves the seam *contract* works - name, shape, `token()` -> `{access, account_id}` - not that the
two branches as pushed are wired. That last step is the coordinator's.**

## What is NOT verified

* **The gate was never run.** The gate lane is a serial resource with capacity 1; at every check
  during this session the sibling lane held it (slot #141 `finish change/wa-session-childdispatch95d6189a-...`,
  held 1001s) with two queued behind it, one of which is a finish gate for the predecessor's branch
  (#145, waiting 815s). Two gates must not run at once, so this lane did not acquire a slot. What
  *was* run is written below; treat the gate as outstanding.
* **Parity against the Pi-backed route was not re-measured in this session.** The predecessor's
  claim (same content, `finish_reason`, `final_phase` and token counts) is repeated here only as a
  claim from `320c0fcd`, not as this lane's observation. The script that measures it is
  `scripts/check-subscription-wire-parity.lua`.
* **Cancellation against a real long-running stream** is not exercised live; it is covered offline
  against the recorded streams (the read stops at the next line).
* **`M.limits()`** (the `wham/usage` windows) was not called live in this session.

## The seam defect between the two lanes - the coordinator's cutover item

The brief names the seam `lua/core/subscription_auth.lua`. The sibling lane pushed
**`lua/core/openai_sub_auth.lua`**. `lua/core/subscription_wire.lua:126` requires
`dofile('lua/core/subscription_auth.lua')`, so **as both branches stand, the wire cannot find the
credential.** This is not a bug in either half; it is the one name the two halves must agree on. It
is deliberately *not* fixed here by copying, renaming or shimming the sibling's file - that would be
this lane duplicating a module it does not own.

Second, smaller mismatch: the sibling's documented seam returns **two** values,
`local token, failure = M.token()`, with a failure taxonomy (`subscription_credentials_absent`,
`refresh_rejected:<status>`, ...). The wire reads only the first value, so an absent or rejected
credential surfaces as `subscription_credential_missing: token() returned no access token` instead of
the sibling's `code` and operator-facing `message`.

## What this tree contains

* `lua/core/subscription_wire.lua` - the endpoint, the fixed headers, the Responses body, SSE
  framing, the event mapping and the result contract, in one file.
* `lua/core/openai_sub_catalogue.lua` - ids, windows, image support, per-id thinking levels, with
  `import_from_pi` as the documented one-shot refresh and nothing under `lua/` reading `~/.pi` at
  request time. `thinking_level_map` still returns **nil, not `{}`**, when it cannot answer.
* `host.http_sse` in `rust/wa-host/src/host.rs` - the transport: a `text/event-stream` line reader
  that hands each line to a Lua callback, checks cancellation and the deadline per line, and ends the
  read on a Lua error. Chosen over `host.http_stream` (`host.rs:1736`) because that one reads exactly
  one dialect (OpenAI-compatible `choices[0].delta`) and maps it to UI events itself, which would
  flatten this route's phase semantics; here the capability is the socket and the protocol stays the
  caller's. No Node and no Pi in the runtime path.
* `WASM_AGENT_SUBSCRIPTION_TRANSPORT=native` routes through it; the default is still Pi's adapter and
  `openai_sub_bridge.lua` is untouched, so cutover and rollback are one environment variable.

**Named risk.** This is a private protocol that can change under us, and owning it means owning its
breakage: hence the endpoint and headers as constants at the top of one file, the event mapping
directly below them, and a recorded fixture so a future break is diagnosable against real bytes.

## What this lane did NOT do

Did not merge the sibling's branch or any credential module; did not delete `openai_sub_bridge.lua`;
did not switch the default route; did not touch the sibling's credential module; did not push `main`,
merge or deploy; did not run two gates at once; did not acquire a gate slot at all.

Agent: wasm-agent node=wasm_the_first role=child session=child:dispatch:af915180-d6da-4eb4-a505-b41a7a36a52f
