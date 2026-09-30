# VERDICT-2: `needs-change` (one narrow item; the previous blocker is fixed and proven)

Independent re-review of the repaired branch
`change/wa-session-childdispatch389b8886-2cfb-45bc-be85-64f4357931f9`.

* Reviewed tip: **`a19c64bf807c36fb6067183dfc0ae339d7fb8553`**, tree
  **`e3a599233eee7821b58780369164c684e6e6c037`** (`git rev-parse a19c64bf^{tree}`).
* Base `origin/main` = `da8dc8918a34c880768956ff775d883802dcb7a7`; `git merge-tree --write-tree` of
  the two is **exit 0**, merged tree `57442c81629729e4549ac4ed6d852d94a24169c5` (ungated - merge
  lane's).
* New commits since the tree I reviewed (`4b5a26e`): **`6b97afb`** (docs: the defect written down
  before it was fixed), **`5158666`** (the fix), **`a19c64b`** (docs: two-shape proof and the check's
  failure). `git diff --name-status 4b5a26e..a19c64bf` = `docs/SUBSCRIPTION_CUTOVER_STATUS.md`,
  `lua/core/init.lua`, `lua/core/openai_sub_login.lua` (new), `rust/wa-host/src/main.rs`,
  `scripts/check-embedded-lua-closure.mjs` (new), `scripts/openai-sub-login.lua`,
  `scripts/test-subscription-login-door.sh` (new), `scripts/test.sh`.
* **What is in the tree:** neither earlier review document is - `git ls-tree` under `docs/reviews/`
  holds only `wa-session-e6bfc741-placement-review.md`. `f0ebab33`'s and `6de9fc08`'s verdicts are
  **not** folded into this branch; the branch answers them in its own files instead.
* Reviewed by `child:dispatch:6b8a0fe5-c65d-4125-9799-7700ef6ff15b`. I did not author this delivery,
  did not edit it, ran no `scripts/test.sh`, took no gate slot (slot #181 is held), did not merge and
  did not push `main`. Everything ran on a `git archive` export of the tip with its own
  `rust/target`, `WASM_AGENT_HOME`, stores and Pi-auth path.

**Verdict in one line.** The defect I falsified last round is genuinely fixed, in both shapes, and
proven on the shipped bytes; the blind spot is closed by a check that does fail by name; the
gate-visible no-root test exists. The one thing still open is the door's **browser** flow: the
sentence the door itself prints tells the reader to re-run with `--code <the address you landed on>`,
and that spelling starts a *device* login, discards the pasted address, and destroys the pending
browser flow. `--browser --code <url>` works; the documented standalone spelling does not.

## 1. The blocker, in both shapes - FIXED

`evidence-2/raw-door-both-shapes.txt` (binary built from the tip, `cargo build --release --offline`,
3 m 17 s, exit 0):

```
A) WASM_AGENT_LUA_ROOT UNSET (the installed shape - "an installed node runs without a root by design")
$ wa subscription status        -> "openai-sub credential: absent (subscription_credentials_absent) ..."
                                   + "log in: wa subscription login ..."          exit=0
$ wa subscription login --browser
  openai-sub: open this URL, sign in, then paste the address you land on (it starts with
  http://localhost:1455/auth/callback):
  https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&...&state=ee6e2451f2b9407caed4567581e4df4e&...&originator=wasm-agent
  openai-sub: waiting for the browser step - re-run with --code <the address you landed on>
                                                                                    exit=0
B) WASM_AGENT_LUA_ROOT SET - the same two commands, same shape of answer, exit 0 both.
```

The same two commands are also compared mechanically by the delivery's new test
(`scripts/test-subscription-login-door.sh`, run by me: `subscription login door ok (9 checks, no Lua
root and Lua root, no network, no credential)`, exit 0 - `evidence-2/raw-closure-check-and-door-test.txt`).

**Byte-for-byte, in the no-root shape** (`evidence-2/raw-registry-identity-noroot.txt`): with
`env -u WASM_AGENT_LUA_ROOT`, `dofile('lua/core/openai_sub_login.lua')` loads and
`LOADED_SOURCES` gives

| module | registry sha256 | `sha256sum` on disk |
| --- | --- | --- |
| `lua/core/openai_sub_login.lua` (the door) | `07cc7db6f7b5429c17dc7746204f3fe8ecd69ac8fbb156cb1f1fbc25f11b32d9` | same |
| `lua/core/subscription_wire.lua` | `480a2d6133f09257299ab97fd3c73b2fffb31b7415de282b1422b54253b79cfa` | same |
| `lua/core/openai_sub_auth.lua` | `7949dc6f548f3ee03f4fe3da4386d86e991c9d03b33da3c3275685202d09daa9` | same |
| `lua/core/openai_sub_catalogue.lua` | `3ddb0859b6997b5c79ac78082fe4c4088407932d0faa3e0ea3deef003b311be5` | same |

so the module the CLI loads is the module the binary ships, and `wire.CREDENTIAL_MODULE` still
resolves to the embedded credential (item 4's seam check, unchanged).

## 2. The blind spot - closed mechanically, and I falsified the check

The check exists: `scripts/check-embedded-lua-closure.mjs`. Run at the tip
(`evidence-2/raw-closure-check-and-door-test.txt`):

```
embedded registry: 55 entries, all 55 include_str! accounted for (52 .lua)
traversed: 52 embedded file(s), 215 literal dofile target(s), 0 non-literal (not checkable statically)
embedded lua closure ok: every literal dofile target reachable from the registry is in the registry
exit=0
```

**My falsification** (`evidence-2/falsify-closure-check.sh`, `evidence-2/raw-closure-falsification.txt`;
run against a throwaway copy of `main.rs` + `lua/`, never the reviewed tree):

* **M1 - a real dofile of a non-embedded path added to `lua/core/init.lua`:**
  `MISSING lua/core/this_module_is_not_embedded.lua  (required by lua/core/init.lua:295: not in EMBEDDED)`,
  exit **1**; remove it, exit **0**. The check fails by name for the defect class it was written for.
* **M2 - the same name only inside a line comment:** exit 0 (their comment-stripping fix holds).
* **M5 - the non-literal target wrong on purpose** (`M.CREDENTIAL_MODULE = 'lua/core/subscription_auth.lua'`,
  the never-shipped name that began all of this): the check **passes, exit 0**, silently.

## 3. A gate-visible no-root test - present, and it is the one that would have caught this

`scripts/test.sh:1608` `node scripts/check-embedded-lua-closure.mjs`, and
`scripts/test.sh:1614` `env -u WASM_AGENT_LUA_ROOT bash scripts/test-subscription-login-door.sh "$BIN" "$DB.sub-login" | grep "subscription login door ok"`.
The `env -u` is the point: the rest of the script exports a Lua root at line 158, and this line
strips it for the run. By hand I get 9 checks, exit 0, and it exercises `status` in both shapes,
`login --browser` in both shapes (authorize URL + the outstanding-human sentence, normalised for the
fresh PKCE state), and an unknown subcommand's exit 2 in both.

## 4. Nothing I verified before regressed

| spot check | result |
| --- | --- |
| `scripts/test.sh:59` `cargo test ... -p wa-host sse_line_tests` still there, still runs | `running 4 tests` / `4 passed; 0 failed; 0 ignored; 77 filtered out` - unchanged |
| the wire's `dofile` name still matches the registry | `wire.CREDENTIAL_MODULE: lua/core/openai_sub_auth.lua`, `dofile` resolves it from EMBEDDED, sha identical to disk |
| suite counts | `subscription wire ok (135 checks)`; `openai-sub auth ok (128 checks)` + `token POSTs=1, refreshed=1, adopted=1, rotation 52bad29d8d47 -> 3ba936f0c515, second spend of the same token=refresh_rejected:400` (43 s) |
| the `WA_SCRIPT=` spelling still works in both shapes | wrapper run with no root and with a root prints the same URL, exit 0 |

All in `evidence-2/raw-item4-spotchecks.txt` / `evidence-2/raw-registry-identity-noroot.txt`.

## 5. The repair attacked - and the one defect that is still open

* **The open one: the door's browser instructions start the wrong flow.**
  `evidence-2/raw-browser-two-step.txt`, no Lua root, against the reviewer's stub. Step 1
  `wa subscription login --browser` prints the authorize URL, exit 0, and stores a pending browser
  flow (`{"flow":"browser","state":"18c533adc5104c08a074d71ec59a4683",...}`) - and its last line tells
  the reader: `re-run with --code <the address you landed on>`. Step 2, doing exactly that with the
  *correct* state pasted back:
  `openai-sub: open http://127.0.0.1:30998/codex/device and enter the code STUB-CODE-1 (waiting up to 2s)`
  - a **device** login. The pasted address is dropped, and the device flow's own `write_flow`
  **overwrites** the pending browser flow: step 2b `--browser --code <the same address>` then answers
  `flow_expired: there is no pending browser login to complete`. The code path is
  `lua/core/openai_sub_login.lua`'s `auth.login(options.mode or "device", { code = options.code })`
  (`--code` sets `options.code` but not `options.mode`), and it is a **faithful copy of the
  pre-existing `scripts/openai-sub-login.lua`** - so the behaviour is inherited, not invented here.
  What is new is that this delivery *presents* the spelling: the module's own header lists
  `wa subscription login --code <the address you landed on>`, `init.lua`'s status text says
  "come back with --code <url>", and `docs/SUBSCRIPTION_CUTOVER_STATUS.md` (Proof 4) says a person
  reaches the login "`wa subscription login --code <the address you landed on>`" - which my run
  falsifies. Nothing covers it: the new door test exercises `--browser` but never `--code`.
  *Fix is one of two one-liners plus a test check*: infer browser mode when `--code` is given, or
  correct the three texts (and the `wa help` line) to `--browser --code <url>`.
* **Can the door report success without storing a credential? No, on the paths I could drive.**
  `--code` with no pending flow, unreadable store, unreachable auth host: every one answers
  `openai-sub login failed: <taxonomy code>` and exit 1, and no store file is created
  (`evidence-2/raw-door-code-spelling.txt`: after three failing invocations the store directory does
  not exist). `run()` returns a number on every branch, so `os.exit(run(args))` cannot fall through to
  0; `--browser` returns 0 only with the "waiting for the browser step" sentence, never "logged in".
* **What a checkout user gets:** unchanged in kind - `WA_SCRIPT=scripts/openai-sub-login.lua` still
  works, now in both shapes, because it is a wrapper over the embedded module; the wrapper's own
  header says the behaviour moved. The one asymmetry: with no Lua root, edits to the *wrapper* no
  longer change behaviour (the module is the embedded copy). That is the intended trade and is stated.
* **`status` in both shapes:** answers, exit 0, and the door test compares the two byte-for-byte
  (same store dir, so nothing else differs).

## Non-blocking observations

* **The check has false-positive modes**, demonstrated on a throwaway copy
  (`evidence-2/raw-closure-falsification.txt`): a single-line long-bracket **string** containing
  `dofile("lua/core/string_only_target.lua")` fails the gate (M3, exit 1), a multi-line `[[ ]]`
  string fails (M7), and a multi-line **levelled comment** `--[==[ ... ]==]` fails (M6) - all text
  that is not a call. The check errs safe (noise, not a missed defect), and the delivery's own
  comment says it strips "long `[[ ]]` blocks", which is true only of `--[[ ]]` at level 0.
* **`0 non-literal (not checkable statically)` is not true.** `lua/core/subscription_wire.lua:156`
  is `pcall(dofile, M.CREDENTIAL_MODULE)` - a non-literal target, and the one the whole delivery is
  about - and the check does not count it because its patterns require `dofile(`. Four more sites
  (`openai_sub_auth.lua:276`, `tools.lua:346`, `completions.lua:56`, `subagents.lua:145`) pass a
  **literal** path through `pcall(dofile, "…")` and are likewise not checked. I checked all five
  targets by hand: `lua/core/memory.lua`, `whatsapp.lua`, `subagents.lua` are all in the registry, so
  there is no live instance - this is a reporting/coverage gap, and the specific seam regression is
  still covered by the wire suite's `CREDENTIAL_MODULE` assertion.
* The poll-loop anomaly I flagged last round (polls reaching `0s left` and continuing) reappeared in
  my unreachable-host runs; I did not chase it again and it is still **not** a verdict driver.

## Added after the verdict commit: the primary door path, end to end, with no Lua root

`evidence-2/raw-door-device-noroot.txt` - `wa subscription login --device`, `env -u
WASM_AGENT_LUA_ROOT`, against the delivery's own mock (`scripts/lib/openai-sub-auth-mock.mjs`):

```
openai-sub: open http://127.0.0.1:29550/codex/device and enter the code FIXTURE-CODE  (waiting up to 20s)
openai-sub: device authorized after 3 polls; exchanging the authorization code
openai-sub: logged in - account acct-fixture-0001, store ...\dev\credentials.json      exit=0
$ wa subscription status   ->  openai-sub credential: valid for account acct-fixture-0001,
                               expires in 3599s, refreshes 0, refresh 7082e0654e93
$ wa subscription login    ->  the same describe() + "(logging in again replaces this credential: ...)" exit=0
```

So in the installed shape the door completes a real device login, writes the store, reports it
valid, and takes the already-logged-in branch without starting a flow - the primary path, not just
`--browser`. (The credential comes from the delivery's own mock, so this proves the door's plumbing
end to end, not the provider's - same limit as the suite's 128 checks.)

## What I could NOT verify

* **No independent fixture, again.** The door proof above uses the delivery's own stub for the
  device-auth endpoints (I did not build a second one); the `--code` finding uses my stub only as a
  *witness* that a device request was made, which does not depend on its honesty.
* No live network at all: no real login completion, no `check-subscription-wire-live`/`-parity`, no
  `scripts/test.sh`, no gate receipt for this tip (slot #181 held by another lane).
* The device-login *expiry* path was not re-run this round; the merge candidate `57442c81` is ungated.
* I could not determine whether `--code`-without-`--browser` is deliberate policy: nothing in the
  tree says so, and the three texts that describe it read as instructions to use it.
