# VERDICT-3: `accept with named residue` - the printed sentence and the behaviour agree

Independent review of the repaired branch
`change/wa-session-childdispatch389b8886-2cfb-45bc-be85-64f4357931f9`.

* Reviewed tip: **`c86891c5d2e1608b9cff0dd8ff4e543adfd15f25`**, tree
  **`987f4faff2e81c05d1de5e80d549b308556615cd`** (`git rev-parse c86891c5^{tree}`).
* Base `origin/main` = **`9d3061734442e542b562871a2774f652ecfd3cc3`**; merge-base with the tip
  `ab827c88a6ac091318b5adb8be34e83e858c4e9a`. The merge itself is the landing's business, not mine.
* This review is narrow by instruction: it settles **one** open item and spot-checks that nothing
  previously proved regressed. `VERDICT.md` (tip `4b5a26ef`) and `VERDICT-2.md` (tip `a19c64bf`) are
  the earlier two and are not re-opened.
* Reviewed by `child:dispatch:a575416c-d4d2-4e3e-b407-7f218fb12cc4` in its own worktree. I did not
  author or edit this delivery (`git status --porcelain` on the reviewed tree shows only my own new
  `docs/reviews/...` directory), ran **no** `scripts/test.sh`, took **no** gate slot, did not merge and
  did not push `main`.
* The delta is exactly what was claimed - one commit, three files, additive:

```
$ git diff --name-status a19c64bf c86891c5
M	docs/SUBSCRIPTION_CUTOVER_STATUS.md
M	lua/core/openai_sub_login.lua
M	scripts/test-subscription-login-door.sh

$ git diff --numstat a19c64bf c86891c5
65	0	docs/SUBSCRIPTION_CUTOVER_STATUS.md
11	0	lua/core/openai_sub_login.lua
48	1	scripts/test-subscription-login-door.sh
```

(Note for anyone reproducing the build: the cargo workspace root is `rust/`, not the repository
root. `cargo build --release --offline` at the root exits 101, `could not find Cargo.toml`. Run from
`rust/`.)

**Verdict in one line.** The door's printed sentence - `re-run with --code <the address you landed
on>` - now completes the *browser* flow when run verbatim in the installed shape: exit 0, store
`"source":"login:browser"`, no device-code line, and the sentence was left untouched rather than
reworded around. The delivery's test runs that sentence itself and counts 17 checks, exit 0, and I
falsified the two new assertions on throwaway copies: removing the one fix line makes checks 5 and 8
fail by name, and rewording the sentence makes check 2 fail by name. The residue is the one this lane
has carried all along: every completion here is against the lane's own node stand-in for the auth
host, so the provider's own contract is still unproven, and no gate has ever run these 17 checks.

## 1. The printed sentence and the behaviour now agree - SETTLED

Binary built from the reviewed tree in the review worktree
(`cargo build --release --offline`, from `rust/`, exit 0, `Finished \`release\` profile [optimized]
target(s) in 3m 09s`, `target/release/wa.exe` 23 272 960 bytes). Every door invocation below ran with
**`WASM_AGENT_LUA_ROOT` unset** (the installed shape this delivery exists for); the auth host was the
delivery's own `scripts/lib/openai-sub-auth-mock.mjs` on `127.0.0.1:58100`
(`WASM_AGENT_OPENAI_SUB_AUTH_BASE`), because a browser flow cannot complete without something
answering the token endpoint. Raw: `evidence-3/raw-printed-sentence.txt`.

```
$ wa subscription login --browser                      # WASM_AGENT_LUA_ROOT unset
openai-sub: open this URL, sign in, then paste the address you land on (it starts with
http://localhost:1455/auth/callback):
http://127.0.0.1:58100/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann
  &...&code_challenge=lU-oMRYn1UwJWDUBIKrT02FenOPBUr6lTMcKPWmIbh0&code_challenge_method=S256
  &state=5a14f4fa79fa4800ad0086fe2591e43f&...&originator=wasm-agent
openai-sub: waiting for the browser step - re-run with --code <the address you landed on>
exit=0
flow file while pending: {"flow":"browser","pending":true,"state":"5a14f4fa79fa4800ad0086fe2591e43f",...}
```

**The sentence, verbatim: `re-run with --code <the address you landed on>`** - unchanged from the
sentence `VERDICT-2` flagged. Run exactly that, with the address I "landed on" pasted back:

```
$ wa subscription login --code "http://localhost:1455/auth/callback?code=PASTED-CODE&state=5a14f4fa79fa4800ad0086fe2591e43f"
openai-sub: logged in - account acct-fixture-0001
openai-sub: logged in - account acct-fixture-0001, store .../sentence/credentials.json
exit=0

credentials.json source: "source":"login:browser"
device-code line printed anywhere above: 0
$ wa subscription status
openai-sub credential: valid for account acct-fixture-0001, expires in 3599s, refreshes 0, refresh 850843a410ed
exit=0
```

So: **the browser flow completes** with the documented standalone spelling. The fix is the smaller
option I offered last round - `M.options` now reads `--code` as a browser-flow argument
(`if options.code and not options.mode then options.mode = "browser" end`,
`lua/core/openai_sub_login.lua:44`), and the sentence is left as it was. `--browser --code <url>`
still reaches the same mode, and `--device --code <x>` is unaffected (`--device` sets the mode first,
so the new line cannot fire). `lua/core/openai_sub_auth.lua` is untouched by this commit.

## 2. The test pins it - 17 checks, exit 0, and it fails by name on drift

Run the way the gate runs it (`scripts/test.sh:1614`), with the same `env -u WASM_AGENT_LUA_ROOT` and
a scratch `WASM_AGENT_HOME` (which is what `test.sh:38` exports anyway) so the live node's home is
neither read nor written. Raw: `evidence-3/raw-door-test.txt`.

```
$ env -u WASM_AGENT_LUA_ROOT WASM_AGENT_HOME=<scratch> bash scripts/test-subscription-login-door.sh \
      rust/target/release/wa.exe <scratch>/db.sub-login
subscription login door ok (17 checks, no Lua root and Lua root, no network beyond the local
stand-in for the auth host, no credential)
TEST_EXIT=0
```

**17 checks, exit 0** - up from 9, matching the delivery's own claim, and the section is *not* the
skipped branch (`node` is on PATH here; the `SKIPPED` line did not print).

**Would the new checks fail if the sentence and the behaviour drifted apart again? Yes - both
directions, measured** (`evidence-3/falsify-sentence-drift.sh`,
`evidence-3/raw-falsify-sentence-drift.txt`). The mutations are made on `git archive` exports of the
reviewed tree into a throwaway root; the checkout was never edited.

* **M1 - the behaviour drifts (the fix line deleted from the copy, sentence untouched):**
  `login --browser` still prints the exact instruction (check 2 passes, 1 match) and the pending flow
  still reads `browser` (check 3 passes) - and then the printed sentence, run verbatim, prints
  `open http://127.0.0.1:.../codex/device and enter the code FIXTURE-CODE`, `device authorized after 3
  polls`, and leaves **`"source":"login:device"`**. So check 5 (`the BROWSER flow completed`) and
  check 8 (`no device-code line`: 2 found) fail by name. Note check 4 (`exits 0`) still passes - the
  device login succeeds - which is precisely why checks 5 and 8 exist rather than exit status alone.
* **M2 - the sentence drifts (the copy prints `--browser --code`, behaviour untouched):** check 2
  finds **0** matches of the sentence and fails, even though the behaviour is correct.

That is the shape a pin should have: it fails for the defect, not for the environment. The one
difference from the test's own invocation is that M1/M2 drive the mutated module through
`WASM_AGENT_LUA_ROOT` (the test's new section is `shape noroot`); the door code is otherwise identical
and the assertions exercised are the test's own.

## 3. Nothing previously proved regressed (spot-checks, not re-derivations)

| spot check | result |
| --- | --- |
| door in **both** shapes, raw (`evidence-3/raw-door-both-shapes.txt`) | `subscription status` exit 0 in both, and **byte-identical** in both (same store dir); `login --browser` exit 0 in both, same authorize URL and same outstanding-human sentence after normalising only the fresh `state`/`code_challenge` |
| the door test's own two-shape checks | inside the 17, exit 0 (section 2) |
| embedded registry identity, **no Lua root** (`evidence-3/raw-registry-identity-noroot.txt`) | `LOADED_SOURCES` == `sha256sum` on disk, for every module below |
| `wire.CREDENTIAL_MODULE` | still `lua/core/openai_sub_auth.lua`, resolves from EMBEDDED, digest matches disk |
| the `WA_SCRIPT=` spelling, both shapes | `WA_SCRIPT=scripts/openai-sub-login.lua ... --browser` exit 0 in both, same URL (no-root run also prints `lua root unset: using embedded modules`) |
| the closure check the gate runs (`scripts/test.sh:1608`), run directly | `embedded registry: 55 entries, all 55 include_str! accounted for (52 .lua)` / `... closure ok`, exit 0 (`evidence-3/raw-closure-check.txt`) |

The digests, which are the point of the last row of `VERDICT-2`'s table:

| module | registry sha256 (no root) | `sha256sum` on disk |
| --- | --- | --- |
| `lua/core/subscription_wire.lua` | `480a2d6133f09257299ab97fd3c73b2fffb31b7415de282b1422b54253b79cfa` | same (unchanged from `VERDICT-2`) |
| `lua/core/openai_sub_auth.lua` | `7949dc6f548f3ee03f4fe3da4386d86e991c9d03b33da3c3275685202d09daa9` | same (unchanged) |
| `lua/core/openai_sub_catalogue.lua` | `3ddb0859b6997b5c79ac78082fe4c4088407932d0faa3e0ea3deef003b311be5` | same (unchanged) |
| `lua/core/openai_sub_login.lua` (the door) | `cd60453da346fbd96cf8a87b5ad9f8f57329121143c645c8d169f88a1b02649b` | same |

**On the door's digest:** `07cc7db6...` cannot still hold - the fix *is* a change to that file - so I
re-checked the invariant rather than the old value: the module the CLI loads in the installed shape is
byte-for-byte the module the binary ships, and it is the module that carries the fix (the exported
`HEAD` copy showed the line at 44 before I mutated it). The three modules the commit did not touch
still carry exactly the digests `VERDICT-2` recorded.

## Non-blocking observations

* **The already-logged-in path is the one behaviour that changed besides the sentence.** With a
  credential already stored, `wa subscription login --code <url>` used to print the credential and
  exit 0 (`if existing.present and not options.mode`); a bare `--code` now sets the mode, so it
  instead tries to complete a browser flow and answers `flow_expired` (exit 1) when none is pending.
  I judge that correct - the user asked to complete a flow - but it is a change no check pins, and it
  is the kind of thing worth a line in the status file next time the door is touched.
* **The test's new section can orphan its node stand-in.** `cleanup()` only removes `$WORK`; the
  `kill $MOCK_PID` sits at the end of the happy path, so a failing check inside that section exits
  through the trap with the mock still running. A `kill` in `cleanup()` would close it.
* **The sentence is pinned literally.** Rewording it to the other working spelling (`--browser
  --code`) fails check 2 even though that spelling works (M2). That is the intended trade for a
  sentence that must not drift from its behaviour; it is worth knowing before anyone "improves" the
  wording.

## What I could NOT verify

* **No live provider.** The browser completion above runs against the delivery's own node stand-in,
  which accepts any authorization code. It proves the door's mode selection, its store write and its
  exit code; it does not prove the provider's `authorization_code` contract. Same limit as the lane's
  own suites.
* **No `scripts/test.sh` and no gate slot** (by instruction, and a landing may hold the gate): no
  gate receipt exists for tree `987f4faf`, so these 17 checks have only ever run by hand, as the
  delivery itself says.
* **No real browser step.** I pasted the callback address by hand; nothing here exercises a browser,
  the redirect listener, or PKCE as the provider would perform it.
* **The device-login path was not re-run deliberately** (it was proved last round). It did run
  incidentally in the M1 falsification - a full device login through the mock, exit 0 - which is not
  evidence about the tip.
* **The merge into the moved `main` is not checked here** (merge-base `ab827c88`); that is the
  landing's, and a landing merges.
