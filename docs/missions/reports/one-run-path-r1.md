# one-run-path, review r1 (Fable's audit of main 0b9d574c)

Branch `change/one-run-path-r1`, base **`a8cd5348`** (origin/main when the work started; the audit named
`0b9d574c`, which main has since moved past - every premise was re-measured on `a8cd5348`). Committed
locally; nothing pushed, nothing deployed.

## What each item became

| item | commit | what changed | how it is judged |
|---|---|---|---|
| 1. the net drops valid calls | `623adecb` | `agent.lua`: nothing is scanned when the step carried a tool call; without one the markup scan reads `raw_code.prose_only` (fenced blocks removed whole, inline spans blanked); `raw_code.text_action` fires only for a **run-tagged** block, so an answer ending in an untagged sample fence is an answer | `scripts/test-leak-net.lua` rewritten to drive the LOOP with a provider stub: valid call + quoted markup runs (no notice); a fence/backtick quote answers; bare markup earns one continue then the named failure; a run-tagged block earns one; a plain js fence is an answer (27 checks) |
| 2. an `only` thread is refused, not moved | `89a23c67` | `prompt_cache.enforce`: a thread whose record names a removed mode gets its TOOL half re-frozen to the list this build resolved (system bytes stay frozen); the note says the frozen instructions are replaced by the run tool | `scripts/test-one-run-path.lua` resumes the **real base records** (`fixtures/one-run-path/prefix-only.json`, `prefix-first.json`, written by `97251587`) through the loop with a stub that calls `run`: the call dispatches, exactly one note names the mode, earlier rows byte-identical (138 checks) |
| 3. the note repeats | `89a23c67` | `cas_row` remembers the bytes it wrote (without it the `noted` marker could never advance after a move), and `notes` rewrites `raw_mode` to native when the note carried the move | in the same test: a later unrelated change owes no `native` reason and its note never contains the sentence |
| 4. rollout hazards | `328cd561` | `scripts/fleet-install.sh` REFUSES (`refused_switch_still_set`, rollback, the line to delete); the service start logs ONE `[serve] REFUSING TO ACT` line and `/health` gains `execution_path` (`one_path:false` + value + **source**, reading the process env AND `<home>/.wasm-agent/env`), so a node that would refuse every job is loud before the first one; `raw_code.switch_refusal` names the env file when the value is there; README rewritten (the variable, the fenced block and the two-transport section are gone) | 4 Rust unit tests on the pure rule (`serve::execution_path_tests`), 4/4 pass; `cargo check -p wa-capabilities` compiles the start line; the installer probe run with the variable set prints `switch_still_set <value> | <the refusal>` and with it unset prints `ok`; the env-file naming was run and names the path (`It is in <home>/.wasm-agent/env: edit that file ...`) |
| 5. the door's repair | `328cd561` | `conform.decide` returns NO transport when nothing acted (0/0 was tool_call); `model_profile.file_name` encodes `/` so `vendor/model` can be measured (and stays inside the models dir); `wa conform` prints the `cp` line that installs the profile, and the door's message says the profile has to be installed; unreadable provider settings are refused by name (`provider_settings_unreadable`) | `scripts/test-conform-profile.lua` RESTORED (21 checks): all-fail decides nothing, a slash-named model round-trips, only a measured tool-call profile opens the door, the harness offers one door |
| 6. leftovers | `328cd561` | `fixtures/prompt-golden/`, `scripts/generate-prompt-goldens.lua`, `scripts/lib/prompt-golden-cases.lua` deleted (they pinned six modes that no longer exist, and the generator still set the switch); `opts.stop` deleted; the conform harness offers the one door; the lost "code mode off keeps ordinary tools" row is RESTORED in `scripts/test-envelope.lua` | the envelope row passes (100 checks); `test-prompt-golden.lua` keeps its arm-B rows and no longer reads the deleted fixtures (20 checks) |

## Measured, and not

- Rows re-run by name, with the runner's own env: `test-leak-net` 27, `test-one-run-path` 138,
  `test-envelope` 100, `test-conform-profile` 21, `test-prompt-golden` 20, `test-thinking-block` 99 - all green.
- Rust: `cargo test -p wa-capabilities execution_path_tests` - 4 passed (needs `WA_CODEMODE_ALLOW_EMPTY=1`
  for the tree build, which is why the first attempt failed to compile).
- **Not measured:** a live `GET /health` (it needs a serve loop; the rule is judged as a pure function and
  the field is wired into the body beside `codemode`); a live `wa conform` run (it spends a paid model);
  a real `wa chat` turn (this branch stays off the live route, rule 13); the full fast path and the gate
  on this tree (the discrimination run is recorded below when it lands).
- Kept as it was: `WASM_AGENT_CODEMODE=off` still leaves a node with no code door (named in the earlier
  report as an open hole, unchanged here).

## The gate, as far as this machine could judge it

- **Narrowed fast path on this tree: `fast path ok (80 checks, 0 skipped, 633s)`** - the five rows this
  round touched (`test-leak-net`, `test-one-run-path`, `test-envelope`, `test-conform-profile`,
  `test-prompt-golden`), the always-on core rows, and every contract check (`prompt-docs`, `instructions`,
  `direct-workflow`, `discrimination`, `landing-queue`, `fast-binary`, ...).
- **`scripts/test-discriminates.sh a8cd5348`: 0 blocking, and 0 judged** - it names all five rows
  `unrevertable` because "this branch changes rust/, and the Lua rows would run against this tree's binary,
  not the base's". That is a refusal to pass, not a pass.
- **Discrimination measured by hand instead**, with the same binary and the BASE's Lua tree
  (`WASM_AGENT_LUA_ROOT=/tmp/base-only`): `test-leak-net` fails there at "B: and the answer is the answer"
  (the base answers a quoted shape with the harness notice), `test-one-run-path` fails on
  `switch_refusal` (it does not exist there), and `test-conform-profile` fails at "an all-fail profile
  decides NOTHING (0 >= 0 is not tool_call)" - the audit's own item 5b. Two rows pass on both trees by
  design: `test-envelope`'s restored row (it pins behaviour that still exists) and `test-prompt-golden`'s
  arm-B rows (a scope change, not a new rule).
