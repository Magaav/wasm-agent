# wa 1.0 — the roadmap

Written 15/11/2026 after a night of real-task replays (rounds 1–6) with the operator. If this work stops
half-way, resume from here: every open item names its branch, its evidence and its next step.

## What "wa 1.0" means — the bar

1.0 is tagged when **one replay round** of the four real tasks (below) meets every row, with the fast suite
and the two-engine seam check green.

| # | Criterion | State (15/11) |
|---|---|---|
| 1 | **0 harness-caused failures** in a full replay round; 0 regressions in suite + seam | met in round 5; round 6 regression fixed (fix26) |
| 2 | **WhatsApp at the floor**: send to a JID = 1 call, read by name = 1–2 calls | met (1 / 2) |
| 3 | **"send to Laura <3" works**: phone-saved names indexed beside push names; most recent of equal names picked | fix27 (address book) landing |
| 4 | **Email reads in ≤ 6 calls**, no wedge, no secret touched, no shape probing | needs vars + return shapes |
| 5 | **Raw code channel** default-on after an A/B (calls, output tokens, failures equal or better) | branch `change/rawcode` |
| 6 | **Session vars**: identities, caches, plans, drafts survive across scripts in a session | branch `change/vars` |
| 7 | **Credentials unreachable** from agent tools (guard now; vault-delivered secrets next) | guard on `change/guard`; vault plan below |
| 8 | **One dispatcher**: one pathway for every rule in both codemode engines | done (fix27, `settle_call`) |

### The replay set (the measuring stick)
Run on node `work`, one turn each, read-only except a send to the operator's own chat:
1. `can you check my email if anything important?`
2. `yo, check last message sent to laura`
3. `find Laah's chat and show me the last 5 messages`
4. `send 'teste harness round N' to my own WhatsApp chat 5519994939204@s.whatsapp.net`

`docker exec wasm-agent bash -lc "cd /work && timeout 600 wa chat --once \"<prompt>\""`, then read every
call of the session and classify each failed call or wasted step: **harness** (fix it), **model guess**
(the error must say how to fix the call), **world** (legit 404/500). Calls per task by round:

| Task | R1 | R2 | R3 | R4 | R5 | R6 |
|---|---|---|---|---|---|---|
| Email | 13 | 20+ | 7 | 22 | 17 | 17 (mail regression, fixed) |
| Laura | 3 | 2 | 5 | 2 | 2 | 6 |
| Laah | 2 | 2 | 2 | 2 | 2 | 2 |
| Self-send | 2 | 2 | 2 | 1 | 1 | 1 |

## Done (main, in order)
- **land32–37 (14/11):** sends route to the account node; direct calls run as one-line scripts; minimal
  envelope (codemode + session_worktree); script errors as one sentence with the script line; queued sends
  cancellable; status on every answer (200/202/400/403/404/500, `lua/core/status.lua`); Gather → Reflect →
  Act → Stop guidance; harness block scope (`const text` legal); `tools.<helper>`; argument synonyms;
  send answers 200 + message_id; sent messages indexed; update notice drawn by one renderer; build cap
  that cannot stall (fix18).
- **fix19–fix26 (15/11):** email unwedged (MCP rejection/any error reply no longer poisons; uncertain reads
  expire 120 s); scripts get MCP data, not envelopes; non-zero exit = result; chat names in WhatsApp reads;
  script result = header + exactly what the script returned (no wrapper key — `value`/`returned` were
  misread as tool shapes); raw multi-line text; evidence = sha256 + bytes; compact word search (17 KB →
  3.7 KB); hash-free connector names; connector index shows `name({required, optional?})`; TimeoutError
  explained; mail wrapper repairs (cursor drops filters, account_id from message_id — requests only, never
  answers: rewriting tools/list broke the schema-bound approval, fix26); `email_component_absent` instead of
  an endless 202.

## In flight (branches on the drop box `oc-in`)
| Branch | What | Next step |
|---|---|---|
| `change/fix27` | one dispatcher (`settle_call`) + address book (app-state MACs in 16 blobs per collection; kv "again" retried) + wa-whatsapp repin `components-1811167d2c31` | land; then on openclaw check `address-book rows held: N>0` and `mcp_whatsapp_contacts({q:"Laura <3"})` → `112682812330026@lid` |
| `change/guard` | `lua/core/secret_guard.lua`: read/write/edit/ls/grep/bash/shell refuse `~/.wasm-agent/secrets`, `keys`, `node.key`, sandbox vault (403 `secret_path_denied`) | suite, land after fix27 |
| `change/shapes` | return shapes in the connector index: `name({args}) → {shape}` (declared outputSchema > learned first answer, keys/types only > static for wa tools) | worker report, review index text, land |
| `change/vars` | session `vars` on the session store + `vars:` index line in every observation + one guidance sentence | worker report, review guidance text, land |
| `change/rawcode` | raw code channel behind `WASM_AGENT_RAW_CODE=1`: ```` ```js run ```` block → the same codemode call; stop sequence after the fence | worker report; A/B on the replay set; default-on only if equal or better |

Merge order: fix27 → guard → vars → shapes → rawcode (each its own landing; vars/shapes/rawcode are based
on fix27 and touch different files).

## Decisions and why (do not re-litigate without new evidence)
- **One pathway**: a duplicated path with the same input/output/purpose becomes one (relay/SSH security
  fallbacks excepted). Every rule lives in one place (`settle_call`, `status.lua`, `parse_view`).
- **The harness's word is final**: an effect that answered 200 + id is done; the model must not verify.
- **No wrapper keys around what a script returned**: any key name gets read as the tool's own shape.
- **Answers are never rewritten in front of a schema-bound approval** (tools/list); only requests are repaired.
- **No `final_answer()`**: a turn ends with a message without a run block, so the answer always follows the
  last observation; the stop sequence prevents writing past the code (no fake observations).
- **Vars explicit, not a live interpreter**: fresh sandbox per script; persistence only through `vars`
  (visible as names + sizes), so no hidden stale state.
- **Mechanisms over prompt rules**; model-facing text changes are shown to the operator before landing.

## Open items (with evidence)
- **Vault-delivered secrets (row 7, the real fix):** today connectors read credentials from files in
  `~/.wasm-agent/secrets`, readable by the agent's own processes (same OS user). Plan: the wa-vault hands a
  connector its credential at start (process env only, never a file the agent can open); retire the files.
- **Four helper scripts `/tmp/imap*.py` on work** (written by the model in round 6; read the secret file at
  run time, contain no password). Operator decision pending: delete / keep as evidence / move.
- **wa-email service is enabled on no node**: wa's own email index is unused; the IMAP connector is the
  working path. Enabling it on one node is a config step (operator to choose the node).
- **mail-mcp (third-party binary) quirks** still visible to the model: `limit` 1..50 undeclared (cannot be
  declared without breaking the schema-bound approval), `get_message` nests under `message`.
- **Machine loop (operator: "not yet")**: freeze the replay set with `wa eval` and make it a landing check,
  so every change reports calls/steps/failure classes per task automatically.
- **Native vs component**: on a validation refusal the native engine includes the rejected text, the
  component does not (kept, flagged in `settle_call`).
- **Ideas queued after 1.0**: sizes in the summary line (`search 200 (31 KB)`); persistent working notes
  shown each turn for long runs (`vars.plan`).

## How to resume the pipeline (desktop WSL distro `wa`, user `wa`)
- Worktree per change: `git -C /home/wa/wasm-agent worktree add -b change/<x> /home/wa/wt-<x> oc-in/<base>`.
- Test one script: `HOME=$(mktemp -d) WASM_AGENT_LUA_ROOT=$PWD WA_SCRIPT=scripts/<t>.lua <wa-bin> --db <tmp>/m.db`.
- Full suite: `WA_BIN=<bin> bash scripts/fast.sh --jobs 3` (0 failed, 0 skipped); seam:
  `WA_BIN=<bin> CARGO_TARGET_DIR=$PWD/rust/target bash scripts/test-codemode-component.sh` (20 comparisons).
- Land: `/home/wa/q/land<N>.sh change/<x>` (merge onto origin/main, build, suite, seam, cargo tests, push
  `land<N>/final`), fast-forward main on openclaw, signed release (freeze → sign via wa-vault → publish),
  deploy work → mail + nextcloud → openclaw, stop at the first failure.
- A component source change needs a repin: `publish-components.sh` (measure), repin only the changed
  component, bundle with `--from` (last verified bundle + the new wasm), push `artifacts/components-<lock12>`,
  publish its release on openclaw before deploying.
- Keep the build root bounded: landings remove old `wt-land*` trees; the build cap evicts oldest outputs.
