# rel-native round 3 - native as the DEFAULT (review r2: FIX)

Branch `change/rel-native`, base `rel/codeact-agnostic` = `826f172b`, golden base `a27490af`.
Worktree `/home/victor/Work/missions/rel-native/wt`. One commit per review item:

| item | commit | what it does |
|---|---|---|
| 1 | `7f2cb3f4` | a native node gets ONE source of native guidance |
| 2 | `b7d99bd7` | in native mode the guidance is ALWAYS guidance_for("tool_call") |
| 3 | `78620697` | the full envelope declares the run tool alone on a native node |
| 4 | `d2c8b64b` | goldens of the FULL built prompt + declared tools, recorded on a27490af; a default node asserted arm B |
| 5 | `bfc383df` | the <bash>/<run> pair scan is native only |
| 6 | `84824f03` | mode cached per process; RAW_CODE=bash keeps its old meaning; a thread keeps its frozen mode |

## Premises re-measured (brief facts that were wrong or imprecise)

* "a27490af is the base every explicit mode is byte-identical to" - TRUE for the prompt bytes except one named
  line: on a27490af the `conform: no profile for <model> ...` notice was APPENDED TO THE PROMPT
  (`a27490af:lua/core/agent.lua:1186-1190`, `block=block..'\n'..transport_notice`). This branch moved it to the
  operator log in `568ed30c` (before round 3, review MUST 4). So "byte-identical to a27490af" holds only after
  dropping that one line; the golden helper drops it BY EXACT PATTERN and the test asserts the built prompt
  carries none of it (`notice_lines_removed == 0`).
* "the 8 tests that went green only because the default flipped" - measured, not taken from the brief: I ran
  every test naming the raw channel twice, once with WASM_AGENT_RAW_CODE unset and once pinned to only. Only
  THREE differ (`test-ab-arms`, `test-leak-net`, `test-mode-parity`), and each of the three sets its own
  surface deliberately. The five others the brief listed (remote-call-shape, skill-discovery,
  orchestration-mode, raw-native, model-facing-texts) read the same verdict in both runs because earlier
  commits of this branch had already pinned them (`71d1c149`, `1aa43da1`, `11622231`).
* "envelope.lua:34" - line 34 is a header comment; the full-envelope decision is `M.schemas` (line 79 in this
  branch) and the progressive surface `M.bootstrap`. Both now read one function, `M.native_surface`
  (`78620697`).
* "agent.lua ~1189-1197 / :1196" - exact: the codemode block was appended at 1186-1189 and the transport
  sentence at 1196-1198. Fixed in `7f2cb3f4` and `b7d99bd7`.
* "raw_code.lua:586-603" - exact in this branch: `M.MARKUP_MARKERS` at 570, the pair table at 586-591,
  `M.markup_in_text` at 592. Fixed in `bfc383df`.
* base's own A/B arm contaminates any base comparison: `a27490af:lua/core/ab_arms.lua:25-32` answers "fence"
  whenever `WASM_AGENT_RAW_CODE` is UNSET, and that arm filters the declared list with an empty allow-list. That
  is why a27490af built an EMPTY subagent list in my first measurement; `1468bc53` (already in this branch) made
  the arm read its own `WA_AB_ARM`. I therefore cite base results for EXPLICIT modes only.

## Item 1 - one source of native guidance (`7f2cb3f4`)

* `codemode_policy.prompt(catalog,{native=true})`: the first line is `raw_code.guidance_for("tool_call")`
  (run-tool sentence + batching), and the codemode sentences are not sent with it. The connector and peer
  INDEXES stay: they are facts a script needs, not a second guidance.
* `agent.build_context` no longer appends the native guidance a second time; every other mode appends exactly
  as before. Measured on the built prompt: "Work in code" appears ONCE and the codemode sentence ZERO times,
  for a native master in BOTH envelopes and for a child.
* Test: `scripts/test-native-guidance.lua`, wired in `scripts/test.sh` ("native guidance ok").

## Item 2 - the mode decides the transport (`b7d99bd7`)

* In native mode `build_context` sets the transport to tool_call with source "native" and never calls
  `transport_for`, so a stored profile whose rates favour the block (the test stores exactly that profile:
  `uses_run_tool = 0, acts_in_answer = 1`) cannot bring the fence sentence back. The same profile in on mode
  still decides block - the control proves the profile is read where it is honoured.
* Test: the "item 2" block of `scripts/test-native-guidance.lua`.

## Item 3 - the full envelope on a native node (`78620697`)

* `envelope.lua`: one helper `M.native_surface` = run + the control-plane tools the progressive envelope
  keeps (+ the orchestration pair when that mode is on). `M.bootstrap` (progressive) and `M.schemas` (full)
  both read it, so the two envelopes cannot drift.
* `agent.subagent_tool_list`: a child whose profile allows run AND for whom code mode is really enabled
  declares the same one door. A child without code mode (explore) keeps every tool it was given - asserted,
  so this can never take a child's only way to act.
* Explicit only/first/codemode/off/on/stop keep a27490af's surface: golden-pinned below.

## Item 4 - goldens from the REAL build (`d2c8b64b`)

* `scripts/lib/prompt-golden.lua` (normalizer: scratch home -> <HOME>, node cwd -> <CWD>, the one conform notice
  line removed), `scripts/lib/prompt-golden-cases.lua` (cases), `scripts/generate-prompt-goldens.lua` (the
  recorder), `fixtures/prompt-golden/*.json` (13 files).
* The goldens were RECORDED BY RUNNING THE GENERATOR ON a27490af - a separate worktree
  (`git worktree add base-a27490af a27490af`), the same binary, its own scratch home. The test compares
  `agent:build_context()`'s own system prompt and `bot.tool_list`, never a block rebuilt from parts.
* `scripts/test-prompt-golden.lua` (wired in `scripts/test.sh`, "prompt golden ok", 73 checks): every explicit
  mode in both envelopes against its golden, and a DEFAULT node (no switch) - progressive AND full, master AND
  child - asserted arm B: run alone, the run-tool guidance, the batching sentence, no codemode guidance. Where
  the provider row does not say tool_call the arm-B rows print a named "did not apply" instead of passing.
* The 8-tests premise: see "Premises" - measured as three.

## Item 5 - the pair scan is native only (`bfc383df`)

* `raw_code.MARKUP_PAIRS` is now EMPTY and `M.NATIVE_MARKUP_PAIRS` holds <bash>/<run>/<invoke ...>; the scan takes
  the mode (`markup_in_text(text, mode)`). Both callers pass it: the leak net (with the thread's mode) and
  `finish_contract.markup` (with the caller's policy, else the switch).
* <invoke ...>...</invoke> was ALREADY caught in every mode by a27490af's bare </invoke> marker, so the pair
  adds only the opener-must-close rule there; the test pins the measured behaviour rather than a guess.
* Test `scripts/test-markup-pairs.lua` (wired in `scripts/test.sh`, "markup pairs ok", 39 checks). Its first
  version printed 8: a table with a nil hole made `ipairs` stop at once, so the mode loops never ran - found by
  reading the count, fixed by listing the modes without a nil entry.

## Item 6 - the small rules (`84824f03`)

* `raw_code.mode()` caches the DEFAULT for the process (`MODE_CACHE`, `M.reset_mode_cache()`); a provider
  switch drops it by name (`provider.set_provider`, `lua/core/provider.lua:290`).
* `WASM_AGENT_RAW_CODE=bash` returns nil unless `WA_AB_ARM` names the bash arm - a27490af's meaning for an
  unknown value, kept; the A/B arm is the only thing that ever meant arm D.
* A thread keeps the mode its prefix was frozen in: `prompt_cache` records `raw_mode` with the record,
  `build_context` reads it back (`policy.raw_mode`, `self.mode_source = frozen|switch`), and every mode reader
  goes through `raw_code.mode_of(policy)`. The record is written once and never rewritten.
* Test `scripts/test-raw-mode-small.lua` (wired in `scripts/test.sh`, "raw mode small rules ok", 16 checks).

## Texts to approve (verbatim, model- or operator-facing)

1. (item 1, model-facing, MOVED not new) "Work in code: call the run tool with `code` - it runs as one script in
   which every tool is `tools.<name>(args)`, and its result comes back to you. Use `raw` to carry a file body or a
   patch exactly. A message with no tool call is your answer." followed by the batching sentence
   (`raw_code.guidance_for("tool_call")`, unchanged text, now the ONLY guidance a native node gets).
2. (item 6, model-facing, unchanged text, narrower reach) the markup notice on a native node:
   "[Harness notice] This message had no action: ... Act by calling the run tool with the script in its
   `code` argument."

No other model-facing string was added or changed by this round.

## How it was verified

* The tree's own binary: `cargo build --release --offline` through `scripts/lib/build-target.sh` with the prepared
  code-mode assets (`pi-1.2.0-quickjs-3.6.2`), 2m21s, exit 0.
* Focused rows, each in its own scratch home under `GATE_ROOT` (the guard refuses the live home) with a clean
  environment: native guidance 43, prompt golden 73, markup pairs 39, raw mode small rules 16, mode parity 15,
  default mode 13, conform profile 18, thinking block 101, prompt cache 195, envelope 98, ab arms 8, leak net 7,
  raw native 23.
* Fast path under `flock /home/victor/Work/missions/.suite.lock`, log
  `/home/victor/Work/missions/rel-native/scratch/fast-84824f03.log`.

## Pre-existing failures (reproduced on a27490af, not caused here)

Each was run TWICE, once with `WASM_AGENT_LUA_ROOT` pointing at a27490af and once at this tree, same binary,
own scratch home, clean environment; every one fails identically on both:

* `scripts/test-raw-code.lua` (:45 "switch on: the guidance sentence is in the system prompt") - a fast-path row
  (not in `scripts/fast-path.exclude`) and not named by `scripts/test.sh`.
* `scripts/test-raw-first.lua` (:46 "1: the optional sentence, not the first guidance") - a fast-path row, not
  named by `scripts/test.sh`.
* `scripts/test-context-usage.lua` (:23) - a fast-path row, not named by `scripts/test.sh`.
* `scripts/test-prompt-layers.lua` (:5 "read is native main-loop bootstrap") - EXCLUDED from the fast path
  (`scripts/fast-path.exclude`), not named by `scripts/test.sh`.
* `scripts/test-codemode-native.lua` (:24 "opt-in adds one tool, direct tools retained") - EXCLUDED from the
  fast path, not named by `scripts/test.sh`.

## Not done / unknown

* The full gate (`scripts/test.sh`, ~50 min) was NOT run end to end; the fast path was.
* Base comparisons that need "no switch" were made only for explicit modes, for the reason in "Premises".
* `WASM_AGENT_RAW_CODE=bash` now means "off" without `WA_AB_ARM=bash`; an operator habit of using bash alone
  changes meaning, deliberately, and is named in item 6.
