# VERDICT: `needs-change`

Independent review of `change/wa-session-childdispatch389b8886-2cfb-45bc-be85-64f4357931f9`.

* Reviewed tip: **`4b5a26ef9a00d76f26b8e81de23694e52b4d55b6`**, tree
  **`b7117642f1558d4f1f01deb57184c6e521854d58`** (`git rev-parse 4b5a26ef^{tree}`).
* Gated revision (receipt): **`be21c861`**, tree **`0bc8bb4d8791c62f7b91dacada8ad0ed4ba9767b`**.
  `git diff --stat be21c86..4b5a26e` = `docs/SUBSCRIPTION_CUTOVER_STATUS.md` only (+46/−16), so the
  *code* tree the gate passed is the code tree this branch ships. The merged candidate is
  `2010a9cd339b329a2edac2f0a2c8e50b87acacae` (`git merge-tree --write-tree da8dc89 4b5a26e`, exit 0)
  and is ungated - the merge lane's business, not counted against this branch.
* Base at review time `origin/main` = `da8dc8918a34c880768956ff775d883802dcb7a7`.
* Reviewed by `child:dispatch:6b8a0fe5-c65d-4125-9799-7700ef6ff15b`. I did not author this delivery,
  did not modify its branch, did not run `scripts/test.sh`, took no gate slot, did not merge and did
  not push `main`. Work was done on a `git archive` export of the tip in scratch, with its own
  `rust/target`, its own `WASM_AGENT_HOME` and its own stores.

**One blocking defect.** Both prior reviews' items are genuinely closed *except the login door*: it
exists, it is wired into `lua/core/init.lua`, it works with a Lua root - and it is **broken in the
shape a deployed node runs in**, which is the shape it exists for. `lua/core/init.lua:273` does
`dofile("scripts/openai-sub-login.lua")`; nothing under `scripts/` is in the binary's `EMBEDDED`
registry, so with `WASM_AGENT_LUA_ROOT` unset the command dies with
`embedded module missing: scripts/openai-sub-login.lua` and exit 1. The gate cannot see it
(`scripts/test.sh:158` exports a root), the producer's own door proof was taken in the root-set shape
(`~/.wasm-agent/wa-cutover-proof/run-absent-and-door.sh:10` exports `WASM_AGENT_LUA_ROOT`), and no
test anywhere exercises `wa subscription login`. The auth review's item 7 ("login drivable from a
script, not a route") is therefore only *half* fixed: the route exists for a checkout, not for an
installed node.

## Required item 1 - the Rust line-reader tests are now in a gate line, and it runs

| Fact | Evidence |
| --- | --- |
| The line exists | `scripts/test.sh:59` `cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host sse_line_tests` (added by `be21c86`, immediately after the `file_search::tests` filter) |
| It actually runs, 4 tests, no skip | my own run at the tip: `running 4 tests` / four `host::sse_line_tests::* ... ok` / `test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 77 filtered out` - `evidence/focused-suites-and-rust-tests.txt`, 10.3 s including a relink |
| It ran inside the real gate | `evidence/gate-receipt-and-log-excerpts.txt`: receipt `head be21c861`, `tree 0bc8bb4d…`, `passed true`, `skipped 2`, `gate_ms 847454.151`, `gate_lane {mode slot, request 166, waited_ms 686719}`; I recomputed `sha256sum wa-finish-gate.json.log` = `7b3e01b57fdb09a1d0bdf6f8d10021ae8591f5fcacc068703d31cb5aee13b8d3` = the receipt's `log_sha256`, and the log carries the four tests by name at lines 557-561 and `4 passed; 0 failed` at 562 |

**Prior wire-review finding (blocking): FIXED.** The suite's own numbers also moved from the
reviewed 132 to **135 checks** and the gate log says `subscription wire ok (135 checks)`; my own run
of the same suite at the tip says 135 in both shapes (root set and root unset), so this is a
confirmation, not a falsification. `docs/SUBSCRIPTION_WIRE_STATUS.md` §6 now carries the correction
in the file's own voice.

## Required item 2 - the embedded registry name is the wire's `dofile` name, proven with NO Lua root

`evidence/raw-no-lua-root-probe.txt` and `evidence/raw-no-lua-root-route-probe.txt`: binary built
from the tip (`cargo build --release --offline`, 2 m 57 s, exit 0), run with
`env -u WASM_AGENT_LUA_ROOT`, printing the host's own warning `lua root unset: using embedded
modules; edits under lua/ are NOT under test`:

```
lua root (getenv): nil
wire.CREDENTIAL_MODULE: lua/core/openai_sub_auth.lua
dofile(CREDENTIAL_MODULE) ok: true          credential.token is function: function
wire      source sha256 (LOADED_SOURCES): 480a2d6133f09257299ab97fd3c73b2fffb31b7415de282b1422b54253b79cfa
credential source sha256 (LOADED_SOURCES): 7949dc6f548f3ee03f4fe3da4386d86e991c9d03b33da3c3275685202d09daa9
negative control ok (must be false): false
negative control error: [string "bootstrap"]:1: embedded module missing: lua/core/definitely-not-registered.lua
```

`sha256sum lua/core/openai_sub_auth.lua lua/core/subscription_wire.lua` in the reviewed tree gives
exactly `7949dc6f…` and `480a2d61…`. So the bytes the binary ships for both modules are byte-identical
to the tree I reviewed, the wire's one name resolves to the embedded credential, and the pass is not
"dofile always answers" (negative control). **Answer: PROVEN, in the deployed shape, not the
tree-rooted one.** The route above the seam was exercised in that shape too: `openai_sub.lua` loads
from `EMBEDDED`, `transport()=native`, `configured()=false` with no credential, and `complete()`
raises the taxonomy rather than sending anything.

## Required item 3 - `reasoning`

**UNPROVEN, and now said so.** `be21c86` marks it explicitly in
`docs/SUBSCRIPTION_CUTOVER_STATUS.md` ("The `reasoning` field. UNPROVEN"), and
`docs/SUBSCRIPTION_WIRE_STATUS.md` no longer claims coverage it lacks. I did not run a live request,
so I neither reproduce nor contradict the producer's re-measurement (0 reasoning events, empty
`result.reasoning`, no `response.reasoning_*` in either fixture). The soft claim is gone; no soft
claim stands in its place. Not a blocker.

## Required item 4 - the seam attacked directly

* **`(token, failure)`, second value.** `M.credential()` (`subscription_wire.lua:155-168`) reads both
  and passes the credential lane's failure through unchanged; `M.complete` (`:908-910`) raises it with
  `error(..., 0)`. Measured with the store pointed at a path that does not exist:
  `credential() -> nil, subscription_credentials_absent: no ChatGPT-subscription credential at …;
  log in with: WA_SCRIPT=scripts/openai-sub-login.lua wa (device code), then retry` and
  `complete(gpt-6-luna, …) -> subscription_credentials_absent: …` with the code **first** and no
  `file:line:` prefix. `M.limits()` returns `{}` plus the same sentence as a second value (first value
  empty table: observed). Two callers still drop the second value on purpose and harmlessly -
  `openai_sub.lua:84` (`configured()` is a boolean) and `provider.lua:394` (`limits` is display data);
  neither can send a request. **PROVEN.**
* **Concurrency.** `M.token()` takes the fast path only when the stored credential is unexpired and
  otherwise takes the node-scoped lock, and `refresh_locked` **re-reads the store under the lock** and
  returns the other process's fresh token (`adopted`) instead of refreshing twice; a refused lease is
  `locked` (no POST), a refused refresh is `refresh_rejected:<status>` and never retried. The
  delivery's own suite prints `token POSTs=1, refreshed=1, adopted=1, rotation 77104c29d5f5 ->
  ef3936124add, second spend of the same token=refresh_rejected:400` and I reproduced that line
  (`evidence/auth-suite-tree-rooted.txt`, 43.45 s, `openai-sub auth ok (128 checks)`).
  **Confirmed at that depth, with a stated limit:** the counting fixture is the delivery's own
  (`scripts/lib/openai-sub-auth-mock.mjs`); I did not build an independent one, so what I verified
  independently is the *code path* and the reproduction of the counts, not the fixture's honesty.
* **Login expiry window.** `DEVICE_CODE_TIMEOUT_SECONDS = 900`, `DEFAULT_LOGIN_TIMEOUT_SECONDS = 300`,
  and `login_timeout_seconds()` clamps `WASM_AGENT_OPENAI_SUB_LOGIN_TIMEOUT` with
  `math.min(configured, 900)`; a *resumed* flow is additionally clamped to the pending flow's own
  remaining window. The status file's "never longer than the device flow's own 900 s window" is true
  of the env override and the default, and reachable-past-900 only through a Lua caller passing
  `opts.timeout_seconds` (no CLI flag does; `scripts/openai-sub-login.lua` parses no timeout option).
  I drove the door through the lane's own mock with a 3 s budget and it **completed**: `device
  authorized after 3 polls`, `logged in - account acct-fixture-0001, expires in 3599s`, store written,
  exit 0, no flow file left behind (`evidence/raw-login-device-window.txt`) - so "a fresh login
  stores a credential" is reproduced here, which the status file credits only to the credential lane.
  The `flow_expired` sentence I did **not** produce myself (that mock authorizes on the second poll);
  it is covered by the lane's suite assertions, whose log lines show the poll loop running to `0s
  left`. Minor, disclosed, not a blocker.
* **Can any path send a request with no credential?** The wire has exactly two request sites,
  `host.http_sse` at `:936` (after the seam check at `:908`) and `host.http` at `:997` (after the
  absent-credential early return at `:993`). Measured: with the store absent, `complete()` raises the
  taxonomy and `limits()` returns `{}` - no request is attempted. `provider.lua`'s gate is
  `subscription.configured()`. **PROVEN, in the embedded shape.**
* **Falsified claim, and it is the blocking one.** `docs/SUBSCRIPTION_CUTOVER_STATUS.md` and the
  `init.lua` comment present `wa subscription [status|login]` as the door "a user who installed a
  node" previously could not reach. On an installed node it is the *same* unreachable thing:
  `evidence/raw-login-door-both-shapes.txt` shows, same binary, same store path:
  with the root **unset** `wa subscription login --browser` → `lua error: [string "bootstrap"]:1:
  embedded module missing: scripts/openai-sub-login.lua`, exit 1; with the root **set**, the same
  command prints the authorize URL and exits 0; `status` works in both shapes (it loads an embedded
  `lua/` module). `grep -rn 'dofile("scripts/' lua/core/` = one hit, `init.lua:273`, and
  `grep -c '"scripts/' rust/wa-host/src/main.rs` = 0. `deploy.sh` ships the binary plus a handful of
  `scripts/*` and sets no root; `rust/wa-sentinel/src/instance.rs:107` makes
  `WASM_AGENT_LUA_ROOT` a *protected* key; nothing in production assigns it. The producer's own
  `run-absent-and-door.sh:10` exports `export WASM_AGENT_LUA_ROOT="$WT"` for the door proof while its
  sibling `pi-aside-run.sh:37` deliberately `unset`s it - so proofs 1-3 were run in the deployed
  shape and the door proof was not, and `docs/SUBSCRIPTION_CUTOVER_STATUS.md` says the no-root re-run
  "reproduced every assertion" without saying that proof 4 is outside it.

## Required item 5 - the focused suites: what they prove vs what the status files claim

| Suite (my run at the tip) | Result | What it actually proves |
| --- | --- | --- |
| `cargo test -p wa-host sse_line_tests` | 4/4, 0 skipped | the Rust reader hands the recorded stream over line for line, keeps a residual EOF line, stops at the failing line, ends where a truncated stream ended |
| `scripts/test-subscription-wire.lua` | `subscription wire ok (135 checks)` - **both** with and without a Lua root | everything above the socket on real recorded bytes, plus `wire.CREDENTIAL_MODULE == 'lua/core/openai_sub_auth.lua'`, that the module loads with a `token()`, and that an absent store yields the lane's code, not a bare nil |
| `scripts/test-openai-sub-auth.lua` | `openai-sub auth ok (128 checks)`, 43.45 s, plus `token POSTs=1, refreshed=1, adopted=1, rotation …, second spend=refresh_rejected:400` | the credential lane's store/refresh/lock/login taxonomy against a 127.0.0.1 mock, with the 6-process single-flight counting measured, not asserted (fixture is the delivery's) |
| `scripts/test-openai-sub-levels.lua` | `openai-sub levels ok (22 checks)` | the catalogue the repo owns answers the levels, with a disagreeing third-party store present |
| `node scripts/test-openai-sub.cjs` | `native subscription operations ok (15 checks)` + `PASS` | the bridge's messages/images/tools/stream/usage/limits shape |
| `scripts/check-subscription-wire-live.lua`, `scripts/check-subscription-wire-parity.lua` | **NOT RUN BY ME** | both need the network, one rewrites `tests/fixtures/subscription/*.txt`; both say they are not in the gate. Their status-file numbers are therefore unverified by this review |
| gate receipt | recomputed `log_sha256` = `7b3e01b5…`, `4 passed`, `subscription wire ok (135 checks)`, `openai-sub auth ok (128 checks)`, `smoke ok (2 skipped)` | the gate ran the delivered suites on `be21c86`'s tree; **no line in the gate log mentions `subscription login` or the new CLI arm** |

Numbers: **confirmed** 135 / 128 / 22 / 15 / 4-passed / `gate_ms 847454` / `waited 686.7 s` /
`skipped 2` / log sha256. **Falsified**: the reachability claim attached to the new login door (above).

## Prior findings, one by one

Wire review (`6de9fc08`):

1. **Rust line tests in no gate - FIXED**, see item 1.
2. **Gate coverage of the tip** - unchanged in kind and correctly described now: receipt covers
   `be21c86`/tree `0bc8bb4d`; `be21c86..4b5a26e` is the status file only; the merged candidate
   `2010a9cd` is ungated (merge lane).
3. **Cross-lane seam name (`M.credential()` asked for a file nobody shipped) - FIXED**, proven in the
   embedded shape (item 2). No shim, no second module, one name; the only surviving mention of the old
   name in code is the `openai_sub.lua:13` comment, which the status file discloses.
4. **`reasoning` untested - now explicitly UNPROVEN** (item 3).
5. Non-blocking notes (the `request_timeout` message, the `HOST.md` typo, the import header) are
   documentation-level and outside what I was asked to re-settle; I did not re-check them.

Auth review (`f0ebab33`):

1. **The status file the producer owed is absent - FIXED**: `docs/SUBSCRIPTION_CUTOVER_STATUS.md` is
   committed (`eca5eaf`), and it is honest about what it does not cover.
2. **Item 7 (login needs a chat/route, not a script) - PARTIALLY FIXED, and the fix does not work
   where it is needed.** `wa subscription` exists in `init.lua:242-273`; it works with a Lua root and
   fails with `embedded module missing: scripts/openai-sub-login.lua` without one. No test covers it
   (the auth suite only checks that `status` *names* the script). **This is the needs-change reason.**
3. Pi's credential (`source=import:pi`, `refreshes=2`) - unchanged by this delivery; I did not spend
   the live credential and did not re-verify it.
4. Atomic write verified by inspection only - unchanged; this delivery adds no crash test.
5. `status().mode` lags one write - unchanged, still a code-reading note.
6. "Nothing calls the module from the route" - **FIXED**: `openai_sub.lua` reaches the wire, and I
   drove the route offline in the embedded shape (`transport native`, `configured()=false`,
   `complete()` raises the taxonomy).
7. Gate on the final tree - as before, the receipt covers the gated tree and not the docs-only tip.

## What I could NOT verify

* Live network behaviour of any kind: no real request, no real login, no `check-subscription-wire-live`
  or `-parity` run. The status files' live transcripts are, for me, unreproduced claims.
* The delivery's own concurrency fixture's honesty (`scripts/lib/openai-sub-auth-mock.mjs`); I ran it
  and read the code, I did not write a second mock.
* A `flow_expired` device login produced by my own hand (the mock authorises on the second poll).
* The merged tree `2010a9cd` (no gate; merge lane's job) and `origin/main`'s four later tips.
* `docs/CONCURRENCY.md`, `docs/HOST.md`, `lua/core/provider.lua`'s remaining diffs were only read
  where the seam or the door touched them; this is not a whole-diff review.
* Anything about the operator's live credential store: every run of mine used a scratch
  `WASM_AGENT_HOME` and a scratch `WASM_AGENT_OPENAI_SUB_STORE`, and no token value was printed.
