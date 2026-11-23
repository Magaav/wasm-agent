# mission-resume-keeps-provider - a resumed or amended worker really runs, and "resumed" is never said for a turn that did not start

Branch `change/mission-resume-keeps-provider`, base `f05b3150`. Code, test and docs, committed locally only.

## What was measured first (rule 9: every premise re-measured)

| premise in the brief | what I measured 23/11 | verdict |
| --- | --- | --- |
| a factory mission's `amend` resume dies at its first line and the log still says "resumed" | `deploy-prunes-pins/amend.log` holds `54f93ecf353b53a4 2026-11-23T04:38:54Z resumed f9f9ee7c-... - pid=478528`, and `deploy-prunes-pins/err.log` holds `/home/victor/Work/missions/deploy-prunes-pins/amend-run.sh: line 5: /home/victor/Work/missions/deploy-prunes-pins/env: No such file or directory`; the written runner's line 5 was `. "$M/env"`; the mission has `serve.env` and no `env` (11 of `~/Work/missions/*/serve.env` exist, zero `env` files) | **true** |
| `wa mission resume` spawns its runner with a scrubbed environment and the CLI answers "No provider is configured" | the runner is spawned by `spawn_detached` -> `host.exec` (`lua/core/mission.lua:327`), and it sourced `. "$M/env"` only - which holds `NAME BRANCH BASE BASE_SHA NODE WT TOOLCHAIN TARGET WA` and no provider settings. The scrub is precise, not blanket (re-measured in `rust/wa-operation/src/lib.rs`): only the names matching `_API_KEY`/`_TOKEN`/`_SECRET`/`_PASSWORD`/`_PRIVATE_KEY` and a few exact names are withheld from a tool child, so `WASM_AGENT_LLM_API_KEY` is gone and the provider cannot be resolved. On a factory mission the resume was not reached at all: the verb required `dir/env` and answered `not_staged`. Reproduced both ways in the new fixture | **true**, and worse than stated: the verb refused a factory mission before spawning anything |
| amend calls a running factory worker "not in flight" | **re-measured, not reproducible as stated.** `wa steer f9f9ee7c-... --status --json` on this node answers `{"target":{..."state":"active"...}}` for that worker while it runs, and the new fixture shows amend steering a factory worker whose first model request is held (`queued for run`, no runner written). What *is* reproducible from the same log is the state machine: at 04:38Z the worker's turn had ended and the worker-gate was resuming that session (`out.log` line 13632, `round 1 of 3: resuming session f9f9ee7c-...`), so the node's run row was not `active` while another process was about to serve the same session | **premise partially wrong** - see the fix below |
| there is no `wa mission amend` verb | `lua/core/init.lua` dispatch had launch/start/resume/status/stop/preflight only | **true** |

A fourth thing was found while measuring the third: `M.run_verdict` (`lua/core/mission.lua`) read `body.active` out of `wa steer <id> --status --json`, and that answer has **never** carried an `active` key (it is `{target:{state=...},receipts=...}`). So every session the node knew about came back `unknown`, and `unknown` refuses every launch and resume that names a session.

## What changed, and the commit that does it

| item | change | commit |
| --- | --- | --- |
| 2 - the provider settings, whichever way the mission was started | the resumed runner sources `M/env` **and** `M/serve.env` (each when readable, under `set -a` so the child sees them); `WA` falls back to PATH when the file carries none; the toolchain exports are guarded so a factory mission (no `TOOLCHAIN`) does not trip `set -u`. `amend` refuses **by name** (`no_provider_env`, `undelivered` in `amend.log`) when a mission has neither file, before anything is written as resumed | `daa0d455` |
| 3 - "resumed" only when the turn runs | after the spawn, `amend` waits for the turn: the node's run lease `active` with an update after the spawn, or the turn's own `</turn>` in `out.log` (NOT the CLI's `Thinking` line, which is printed when the request *starts* - measured). `resume_failed` with the runner's own words and a non-zero exit when it exits first; `resume_unconfirmed` when it is still there with no turn; `resume_failed` is retryable without appending twice, `resume_unconfirmed` retries only once its pid is gone | `daa0d455`, `0e2b965f` |
| 3b - the same rule for a delivered note | the steering path requires the receipt id in the node's answer **and** asks the node again for that receipt (`queued`/`read`); otherwise `steer_unconfirmed` and a non-zero exit | `daa0d455` |
| the "not in flight" detection | a resume now needs the node's own `settled`/`failed` word, or no run row at all; `unknown` refuses by name, so a run nobody can vouch for is never resumed beside | `daa0d455` |
| `M.run_verdict` (found while measuring) | reads the run row's state (`target.state`), keeps `body.active` for a stub that speaks the older shape, and treats an absent `target` as "the node records no run for this session" | `0e2b965f` |
| 4 - `wa mission resume` keeps the provider settings; `wa mission amend` as a thin door | `M.RESUME_RUNNER` sources `env` **and** `serve.env`; `M.resume` accepts either file as "staged", refuses `run_unknown` by name, and reports `resume_failed` (quoting the CLI) instead of `resume_unconfirmed` when its runner exits first. `M.amend` finds `scripts/mission.sh` (missions root, then `WASM_AGENT_LUA_ROOT`/`WA_LAND_REPO`/checkout, or `--script`), runs `amend` with `MISSIONS_DIR` and `WA_BIN=<the running binary>` and returns its words and its exit code; the verb is wired in `lua/core/init.lua` | `daa0d455`, `0e2b965f` |
| 5 - the test | `scripts/test-mission-amend-resume.mjs`, 29 checks, wired into the fast path (`scripts/fast.sh`, row `mission-amend-resume`, right after `mission-amend`) | `cae1fd11` |
| 6 - the factory's driver notes | appended to `~/Work/missions/FACTORY.md` (outside this repository, so it cannot be cited by commit): the two rules that said "no scripts/mission.sh amend at all" now say the command is fixed, what it proves, and what to do when it answers `resume_failed` | not in git - see "Texts to approve" 24 |

The knowledge document is `docs/MISSIONS.md` step 4b (the two shapes of a mission's environment, the rule that a resume needs a turn, the receipt read-back, the `wa mission` doors, the new fixture) plus the `amend.log` state names in the mission-directory table.

## The fixture: what is real, and what it cannot prove

`scripts/test-mission-amend-resume.mjs` lays a mission out exactly as the factory's launcher does: `brief.md`,
`prompt.md` (brief first, so there is no title marker), `serve.env` carrying the whole environment the worker runs
with, and a `run.sh` that sources `serve.env` and runs `wa chat --once`, its rc landing in `done`. The worker is a
real `wa chat` against the fixture's own node store; the amendment is delivered by the real
`scripts/mission.sh amend` and by the real `wa mission amend`; the provider is an SSE fixture (a fixture may not
call a model).

The caller's own environment points at `http://127.0.0.1:1` where nothing listens, and only `serve.env` names the
fixture's port: a turn that read the caller's environment instead of `serve.env` cannot reach the fixture, so it
cannot be mistaken for a turn that ran. Measured consequence: the "provider answers nothing" mission prints
`Thinking · 0.0s · run 1` and then `! run_failed: provider_unreachable`, which is exactly why `Thinking` is not the
evidence.

What it does not do: it does not call `~/Work/missions/launch.sh` or `start.sh` (they need systemd and the
operator's missions root) - it reproduces their shape; it does not prove `fleet`/`deploy` behaviour (rule 13: no
live peer was touched at any point); and the `unknown`-run refusal is implemented but not fixtured, because no
knob in a fixture makes the real node record a run as `unknown` deterministically (that state comes from the
node's own presence recovery).

## Tests run

- `WA_BIN=~/.local/bin/wa node scripts/test-mission-amend-resume.mjs` -> 29 checks passed (`cae1fd11`).
- On the base, in a separate worktree of `f05b3150` (`git worktree add --detach /tmp/base-mrp f05b3150`, the test
  copied in): FAILED after 5 checks - the base does not read the node's receipt back, and the checks after it
  (the factory resume, `resume_failed`, `no_provider_env`, `wa mission resume`, `wa mission amend`) are the ones
  this branch adds. **The test fails on today's main.**
- Unchanged by this branch, re-run on this tree with these changes: `node scripts/test-mission-amend.mjs` (43
  checks), `bash scripts/test-mission-verb.sh` (49 checks), `bash scripts/test-mission.sh` (282 checks) - all
  green. The full fast path was not run by this session (rule 15: one heavy suite at a time, and the land gate
  runs it).

## Texts to approve (every new or changed operator- or model-facing string, verbatim)

1. `mission: <stamp> is in <brief>, but the node does not say that run is settled: it says '<state>' for session <sid>, so nothing was resumed (a turn beside a run nobody can vouch for is a second writer)`
2. `mission: read it (wa steer <sid> --status), then run this command again once the node says settled - the text is already in the brief and is not appended twice`
3. `mission: <stamp> is in <brief>, but this mission has neither <M>/env nor <M>/serve.env: a resumed turn would start with no provider settings, and a turn that cannot run is not a resume, so nothing was resumed`
4. `mission: give it its environment (scripts/mission.sh stage writes env; the factory's own start.sh writes serve.env), then run this command again - the text is already in the brief and is not appended twice`
5. `mission: amendment <stamp> appended to <brief>; the run for session <sid> was <state> (<done says ...>), so it is RESUMED with the amendment as the message of its next turn (pid <pid>), and that turn is running now`
6. `mission: resume_failed: <stamp> is appended to <brief>, but the runner (pid <pid>) exited before the turn started (<done>), so session <sid> never ran the amendment`
7. `mission: it said: <the runner's own last lines>`
8. `mission: nothing is appended twice - fix what that line names and run this command again, and it resumes the same session with the same text`
9. `mission: the resume runner (pid <pid>) is still there, but no turn has started after <n>s, so nothing is claimed as resumed: read <M>/out.log and wa steer <sid> --status, then run this command again once that runner is gone`
10. `mission: <stamp> is in <brief>, but the node's answer to the note carried no receipt id, so it is not called delivered: <answer>`
11. `mission: read it (wa steer <sid> --status), then run this command again - the text is not appended twice`
12. `mission: amendment <stamp> queued for run <run> (session <sid>, receipt <receipt>, the node says <queued|read>): the worker sees it at its next context boundary, once`
13. `mission: <stamp> is in <brief> and the node accepted the note (receipt <receipt>), but it does not list that receipt (it answers '<state>'), so it is not called delivered`
14. `mission: <stamp> (sha <sha>) is already in <brief> and the resume it started never ran a turn (<detail>): resuming it again now, without appending it twice`
15. `mission: <stamp> (sha <sha>) is in <brief> and its resume runner (pid <pid>) is still there without a turn, so nothing was started: a second resume beside it is a second writer`
16. `mission: read <M>/out.log and wa steer <sid> --status, then run this command again once that pid is gone - the text is not appended twice`
17. `mission: <stamp> (sha <sha>) is in <brief> and no turn started for its resume (<detail>); that runner is gone now, so it is resumed again without appending it twice`
18. runner stderr: `mission: neither <M>/env nor <M>/serve.env exists, so a resumed turn would start with no provider settings` / `mission: no wa to resume with: neither env nor PATH names one`
19. `amend.log` state words: `resume_failed`, `resume_unconfirmed`, `steer_unconfirmed` (`undelivered`, `queued`, `resumed` unchanged)
20. `wa mission resume` errors: `run_unknown` (`why` = `the node does not say that run is settled (<node reason>)`, `next_action` = `wa steer <sid> --status`), `resume_failed` (detail `the runner exited before any turn started (done: <done>); out.log: <last> | err.log: <last>`), and `not_staged` detail `not staged: neither <M>/env nor <M>/serve.env is there`
21. `wa mission amend` results: `amend_script_missing` (`detail` = `no mission.sh among: <candidates>`, `next_action` = `install it from the runtime tree: ln -s <runtime tree>/scripts/mission.sh <root>/mission.sh`), `file_required` (`usage: wa mission amend <name> <file> | wa mission amend <name> --text <words>`), `no_mission`, `amend_failed` (`why` = the script's last line), and the success object `{name, exit, script, file, effect, output, errors}`
22. usage line: `       wa mission amend <name> <file> | --text <words>   a change into a worker that is already running`
23. `wa help` line: `    mission amend <name> <file> | --text <words>   a change into a running worker (scripts/mission.sh amend)`
24. `~/Work/missions/FACTORY.md` (outside this repository): the two paragraphs that say "NO scripts/mission.sh amend at all" / "use scripts/mission.sh amend ONLY on a worker with a run in flight" are replaced by: the command is fixed for both a run in flight (the note is steered, and it needs the node's receipt) and a settled worker (it is resumed, and "resumed" is only said once the turn is running); `wa mission amend <mission> <file|--text>` is the same code; a `resume_failed` line means the turn did not start, the message is still in the brief, and the cause is in the `it said:` line.

## How Victor tests it

```
WA_BIN=~/.local/bin/wa node scripts/test-mission-amend-resume.mjs     # 29 checks, about 40 s
```

On a real mission, with the installed `wa` and no release needed:

```
wa mission amend <mission> --text "also keep the 0.1.0 wording"
```

A worker that is running sees `[amendment <UTC> from the planner] ...` at its next context boundary and its
report names that UTC stamp; a worker between turns is resumed, and the command prints `RESUMED ... and that turn is
running now` only when a turn actually started - a resume that dies prints `resume_failed` and the runner's own
words, and exits non-zero. `amend.log` in the mission directory carries the same state.

## Still open

- The `unknown`-run refusal is not fixtured (see above); it is code plus the rule, not a test.
- `M.resume`'s hiccup gate is unchanged: a clean `rc=0` turn still needs `--force` to be resumed, which is the
documented behaviour and what the fixture uses.
- `scripts/mission.sh` still writes `amend-run.sh` with `setsid nohup` from the calling shell rather than through
  `tools.operation`: unchanged by this mission, and it is a shell that exits on its own.
