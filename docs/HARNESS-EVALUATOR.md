# Harness evaluator

`wa eval` freezes a task an operator actually gave a session, replays it against a candidate binary where
nothing real is reachable, and prints metrics. It **gathers benchmark evidence**; it does not gate a
release, does not decide and does not change the agent.

The engine and its material live under [`harness-evaluator/`](../harness-evaluator/README.md), which is the
reference for the verbs, the isolation, the privacy rule and what moved there. The Lua side is four
modules: `lua/core/harness_evaluator.lua` (store, capture, metrics, verdicts, report),
`lua/core/harness_evaluator_replay.lua` (the isolated replay), `lua/core/harness_evaluator_reviewer.lua`
(the landing reviewer) and `lua/core/harness_evaluator_cli.lua` (the operator's door, dispatched from
`lua/core/init.lua`).

Quick reference:

```
wa eval capture <session-id> --category code-fix --check human
wa eval run --all --bin ~/.local/bin/wa --timeout 600 --model
wa eval report
wa eval verdict <run-id> pass "checked by hand on the real task"
wa eval reviewer change/x --brief brief.md
wa eval reviewer mark change-x-001 accepted
wa eval reviewer miss change/x "it missed the bypass"
```

Two facts worth stating because they were measured rather than assumed:

* **A replay has no model unless you give it one.** `--model` passes only the model-route variables into
  the scratch home; without it the child boots with no provider and the run records that, so the numbers
  describe the harness (boot, prompt, tool loop, ledger) and not an answer.
* **Code mode is on in a replay.** It was forced off while the hook fired once per outermost tool call;
  since the nested-dispatch fix (`825ce08f`, `docs/HOOKS.md`) a call inside a script crosses the same hook
  boundary, so a script cannot perform an effect the sink never sees - and forcing it off measured the
  direct tool loop, not how the node is worked. The run record says `isolation.code_mode` for every run.

## The landing reviewer

`wa eval reviewer <branch>` starts a session that shares nothing with the caller - its own home, its own
ledger, no memory, no notes, no history - and has it review the branch before it lands: the brief, the
diff against the base, and every file the diff touches. Its instruction text is fixed byte for byte
(`M.INSTRUCTION`) and its model is pinned (`deepseek-v4.1-flash`, with no `--model` on the door), because
the text and the model are the two things whose change would invalidate every number in the store. The isolation is the replay's, reused:
a scratch root outside the node home, `env -i` with an allowlist, the sink that refuses effects and
connectors, the PATH guards, code mode on as in a replay. The review reads a discarded **export** of the
branch tip (`git archive`: no git directory, no alternates, no remote, so nothing in it points at the
operator's tree) and a diff the door wrote from the merge base of the base and the tip - a branch cut
before today's main is not made of other people's landed work.

The `bash` tool is not hooked (a review needs `git diff`), so what stands between a review and a remote git
is the guard on `PATH`: it refuses `push`/`fetch`/`pull`/`ls-remote`/`clone`, any argument that mentions
`alias` (an alias is expanded by the real git after the guard has looked), and every non-read form of
`remote`/`submodule` - while `git remote -v`, `git submodule status` and ordinary local verbs still run,
because a read is not an effect and an allowlist of "known" verbs refused local work (measured on the fifth
review of this feature).

That is a guard, not a sandbox, and the record says what the guard saw, not more: `bash` can name the real
binary by absolute path (`/usr/bin/git push`), the child's PATH is only the first `git`, and a config file
written by hand in the child's home is not examined. A review therefore stores the refusals its sink did see
(`record.effects`: what would have been done, blocked tool calls, refused commands) and claims nothing about
what it could not see.

It is **not a gate**. It prints the findings and the final `REVIEW <branch> <sha> findings=<n>` line, exits
0 whatever the findings are, and `scripts/landing-queue.mjs` never reads its store. The operator marks each
finding accepted or rejected (`wa eval reviewer mark`), records what the reviewer missed after the landing
(`wa eval reviewer miss`), and `wa eval report` prints per review - branch, sha, findings, tokens, time -
and the totals: findings, accepted rate, misses, cost.

One switch turns it off: `reviewer = off` in the node's config file (`<config>/env`, the one file the host
reads) or `WA_REVIEWER=off` in the environment; the door then says it is off and exits 0 - with or without
a branch named. Measured on this
node with no vault in the environment, a review cannot answer: the child boots, runs its own session and
the record says `no_review` with zero model calls - which is what a fast-path row proves, because the
answer path needs a model and a fast-path row has none.

## What changed for an operator (BEFORE / AFTER)

Every user-visible string this feature changed, so a reader never has to diff two commits to find one:

```
wa help (lua/core/init.lua)
- BEFORE  eval capture|list|run|report|verdict|reviewer  freeze real tasks, replay isolated, read metrics
- AFTER   eval capture|list|run|report|verdict|reviewer  freeze real tasks, replay isolated, review a branch, read metrics

wa eval help (lua/core/harness_evaluator_cli.lua)
- BEFORE  wa eval reviewer <run-id> [--findings N] [--accepted N] [--misses N] [--cost TEXT]
- AFTER   wa eval reviewer <branch> [--brief <file>] [--base <ref>] [--repo <dir>] [--bin <wa>]
                                  [--timeout SECONDS] [--keep-scratch] [--branch <name>]
          wa eval reviewer mark <review-id>[#N] accepted|rejected [--finding N]
          wa eval reviewer miss <branch> "<note>"
          wa eval reviewer list
          wa eval reviewer run <run-id> [--findings N] [--accepted N] [--misses N] [--cost TEXT]
```

The old spelling still exists as `wa eval reviewer run <run-id> ...` (same storage, same JSON answer):
the positional is the branch a review runs on now. A bare `wa eval reviewer <run-id>` is refused
("no such branch or commit in <repo>: <run-id>"), which is a behaviour change, and `--branch <name>`
reaches a branch whose name is one of the subcommand words.

Refusals, changed and new - `wa eval: <text>` on stdout, exit 2, except the two that describe a review
that RAN and did not review (no `REVIEW` line, or one about another commit), which exit 1:

```
- BEFORE  reviewer needs a run id
- AFTER   reviewer needs a branch, or `run`, `mark`, `miss` or `list` (wa eval help)
          reviewer run needs a replay run id
          unknown option <token> for `wa eval reviewer` (wa eval help)
          reviewer mark needs a review id and `accepted` or `rejected`
          reviewer miss needs the branch the miss was found on
          not inside a git repository, so there is no branch to review
          no such branch or commit in <repo>: <branch>
          no base to diff against (tried ...)
          the brief cannot be read: <path>
          the instruction, the brief and the input come to <n> bytes; one prompt argument holds about
            100000, so give a shorter brief
          the review session gave no REVIEW line (state <state>)
```

New output, none of it present before:

```
wa eval: the reviewer is off (<source> = <value>); nothing was run
wa eval: the reviewer is on; <source> = <value> is not one of off/0/false/no (or on/1/true/yes)
review <id>: <branch> @ <sha8> (base <ref>) <model> . rounds N . tools N . in N out N . Nms . <state>
the session's own final line: REVIEW ...   (when the review answered about another commit)
wa eval: the review answered about <branch> <sha>, not <branch> <sha> - its final line is its own
(no reviews: `wa eval reviewer <branch> --brief <file>` runs one)
<id>: accepted N, rejected N of N finding(s)
miss recorded for <branch>: <note>
wa eval: stderr tail: <text>
<review-id>  <sha8>  findings N  <state>  <branch>        (`wa eval reviewer list`, one row per review)
wa eval report  (appended section)
  reviews (data only - a review never blocks a landing):
  BRANCH  SHA  FINDINGS  ACCEPT  REJECT  IN  OUT  WALL  STATE
  totals: N review(s), findings N, accepted N, rejected N, unmarked N, accepted rate N%, misses N
  cost: N in / N out, N model call(s), N wall
```

Tests: `scripts/test-harness-evaluator.lua`, `scripts/test-harness-evaluator-replay.lua`,
`scripts/test-harness-evaluator-privacy.lua`, `scripts/test-harness-evaluator-reviewer.lua` (all four are
fast-path rows).
