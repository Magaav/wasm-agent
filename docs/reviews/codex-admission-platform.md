# Independent review: external admission provenance and update fixture

Verdict: **narrowed**. The requested behavior passes focused independent checks on
the exact delivery below. This is a source review and scratch-fixture result;
**the full smoke test is pending, not passed**, and this report is not admission,
gate evidence, integration, or deployment authorization.

## Exact binding and independence

| Field | Value |
| --- | --- |
| Producer branch | `change/codex-admission-platform` |
| Producer tip | `3290d32727fcfc77e0646039f6322b0821a408c2` |
| Producer tree | `961c9d358806326de70c5c4899c3aa836d8168f3` |
| Producer session | `term_2806604b-b664-48da-8aed-68b78b482bdd` |
| Independent reviewer | `codex` |
| Reviewer session handle | `term_3baca61f-5cd3-4e24-92d2-0a4eb0eb6f50` |
| Reviewer Codex thread ID | `01a0f296-0194-7cf3-ba24-f89d764b1a0b` (session environment) |
| Reviewer branch | `change/review-codex-admission-platform` |
| Reviewer worktree | `C:/Users/Victor/orca/workspaces/wasm-agent/codex-admission-review` |
| Reviewer base | `origin/main` = `ab827c88a6ac091318b5adb8be34e83e858c4e9a` |
| Dispatch | `task_a0c23eeed637` / `ctx_d3a135c294e6` |
| Review date | 2026-09-30 |

The reviewer did not produce the delivery. I read `AGENTS.md`,
`skills/parallel-evolution/SKILL.md`, `skills/git-orchestrator/SKILL.md`, and the
lane reservations in `docs/CONCURRENCY.md`. The reviewer branch starts at main
and adds only this artifact; it does not carry or edit producer code. Tests used
an archive of the exact producer tip, not the review branch's older scripts.

## Findings

1. **Requested provenance behavior passes.** The generic anchor
   `/^Agent:[ \t]*[^\s]+[ \t]+([^\r\n]+)$/m` accepts authentic `Agent: codex`,
   `Agent: pi`, and `Agent: claude` trailers without relabeling the harness.
   Independent fixtures also omitted the optional `node=` field, used the real
   reviewer terminal handle for Codex, and used colon-containing session IDs for
   Pi and Claude. Missing reviews, mismatched reviewer identity, different
   reviewed trees, producer-as-reviewer, missing review commits, and unpublished
   review commits refuse. The regex does not consume a session from the next line.
2. **Requested verdict behavior passes.** Only exact `passed` and `narrowed`
   values pass the new blocking condition. `refused`, absent, empty, `approved`,
   `Passed`, and boolean verdicts refuse with `review_verdict_not_accepted`.
   Narrowed reviews retain a caveat. Existing unresolved `summary_exceeds_code`
   findings and self-admission still refuse in the committed scratch suite.
3. **Update fixture passes on Windows.** The unchanged update heredoc now gives
   `verdict` the actual platform-specific sentinel path and checks that path's
   start command. The Windows assertion checks its registered task hint; a
   Linux fixture no longer assumes that Windows task name. Independent pure
   Linux/macOS platform seams produced `/i/wa-sentinel start` without `schtasks`.
   These seams are not execution on Linux/macOS hosts.
4. **`boundary_gap:unresolved` — session parsing remains a trust boundary.**
   `anchorSession` still searches for the substring `session=` anywhere in the
   captured payload and otherwise uses its first token. Independent published
   scratch reviews with `Agent: codex nosession=external` and
   `Agent: codex legacy-reviewer` were admitted for reviewers `external` and
   `legacy-reviewer`, respectively. The substring search and fallback are
   unchanged from the producer's parent; this delivery generalizes the harness
   matcher without hardening those semantics. A normal bare `Agent: codex`, no
   Agent trailer, or a session on the next line refused. Thus the evidence
   supports the stated normal trailer convention, not strict token validation
   or authenticated authorship. No parser repair was made in this review.
5. **`unverifiable_claim:unresolved` — broader verification remains pending.**
   No build, full gate, gate acquisition, gate receipt, live-node check,
   two-node test, or deployment was run. Native Windows capabilities came from
   the installed executable; Lua modules came from the exact archived source.
   The verdict/tree fields are trusted delivery-record data, not parsed or
   authenticated from report prose. Ref publication is observed through fetched
   Git refs, not a fresh remote read within `evaluate`.

No new blocking finding was established for the requested behavior. Carry
findings 4 and 5 as named caveats if this review is recorded with verdict
`narrowed`; do not turn these focused results into a full-gate claim.

## Commands and results

The retained private scratch directory is
`C:/Users/Victor/AppData/Local/Temp/wa-codex-admission-review-7618b220a76a43d9a692f509133d40a8`.
In the commands below, `$reviewScratch` is that exact native Windows path.
Node was `v24.19.0`; Git was `2.55.0.windows.3`.

Source materialization, exit 0:

```powershell
git archive --format=zip --output="$reviewScratch/delivery.zip" 3290d32727fcfc77e0646039f6322b0821a408c2 scripts lua docs/integration/backlog-20260930.json
Expand-Archive -LiteralPath "$reviewScratch/delivery.zip" -DestinationPath "$reviewScratch/source"
```

| Exact focused command | Result | Skips / limits |
| --- | --- | --- |
| `node "$reviewScratch/source/scripts/test-delivery-admission.mjs" --record "$reviewScratch/admission-suite.json"` | Exit 0; `delivery admission ok (54 checks)` | No skipped checks or skip branches in this suite; local bare origin and scratch store only. |
| `node "$reviewScratch/independent-probes.mjs"` | Exit 0; `independent probes ok (36 checks; exact admission source unchanged ...)` | All 36 expected decisions checked; published scratch commits, ordinary remote-tracking refs, no `--tip-ref` seam. |
| `& 'C:/Users/Victor/AppData/Local/wasm-agent/wa.exe' --db "$reviewScratch/update.db"` with `WA_SCRIPT="$reviewScratch/update.lua"` | Exit 0; `update decision ok` | Entire unchanged heredoc; private real files and watcher PID probe, deliberately non-executable private sentinel fixture. |
| Same executable with `--db "$reviewScratch/platform.db"` and `WA_SCRIPT="$reviewScratch/platform-probes.lua"` | Exit 0; `platform probes ok (3 pure platform cases; actual host windows; source hashes verified)` | Real Windows host plus pure Linux/macOS seams; no watcher start or scheduled-task execution. |
| `git merge-tree --write-tree origin/main 3290d32727fcfc77e0646039f6322b0821a408c2` | Exit 0; `961c9d358806326de70c5c4899c3aa836d8168f3` | Against the base named above; source compatibility only. |

The Lua invocations used this environment and the installed binary, with native
absolute paths. The update invocation's working directory was the archived
`source` directory:

```powershell
$env:WASM_AGENT_HOME="$reviewScratch/home"
$env:TEMP="$reviewScratch/tmp"
$env:TMP="$reviewScratch/tmp"
$env:WASM_AGENT_LUA_ROOT="$reviewScratch/source"
$env:WA_INSTALL_DIR="$reviewScratch/private-install"
$env:WASM_AGENT_RENDEZVOUS=''
$env:WASM_AGENT_RELAY=''
$env:WASM_AGENT_MANAGED='0'
$env:WASM_AGENT_LLM_BASE_URL='http://127.0.0.1:1'
$env:WASM_AGENT_LLM_API_KEY='fixture-only'
```

`update.lua` was extracted byte-for-byte from the region starting with
`cat > "$DB.update.lua" <<'LUA'` and ending at its matching `LUA` delimiter;
the ending newline was preserved. I did not execute `scripts/test.sh`.
The independent platform probe verified `LOADED_SOURCES` against the archived
files' SHA-256 values, including update/platform modules.

### Independent falsification attempts

- For each external harness, change only the reviewer, remove the review, replace
  the tree with a different real Git tree, and set the verdict to `refused`:
  all four mutations refuse; changing only the verdict to `narrowed` admits with
  a caveat. Authentic `Agent: <harness> session=...` reviews admit.
- Remove the new verdict condition from a private copy: the identical refused
  review wrongly admits. The exact original module refuses it again.
- Restore the old wasm-agent-only anchor in another private copy: authentic
  Codex provenance wrongly refuses. The delivery's generic anchor admits it.
- The delivery's committed suite removes tree binding in a private copy and
  wrongly admits the wrong-tree delivery, then confirms the original module
  remains byte-identical and refuses it again.
- Attack missing, multiline, legacy, tab-separated, and malformed provenance:
  normal missing/multiline cases refuse, compatible tab/legacy cases admit,
  and the `nosession=` attempt exposes finding 4 rather than being reported as
  a successful refusal.

All admission mutations stayed in private fixtures. The independent probes
asserted byte identity of the original archived admission module afterward.
Expected refusals and deliberately weakened-copy admissions are successful
falsification checks, not test failures.

### Retained evidence hashes (SHA-256)

| Evidence | SHA-256 |
| --- | --- |
| Exact admission source | `18011aa3559c1ab40955170a30154d005d6a7a6ba9ad941c9da9fd0ba13f4954` |
| Extracted update heredoc | `6d5cfbfb9963013243979668cc56a545f44ea6b0cd64a09b7edefc3d050fee9a` |
| Independent probe script | `cb8c2484e701cb09245c04039acc1361b85b21983756652efdfeee3a9313095d` |
| Admission suite log | `0a0c35b1bb74e9c977ee0cc60b2c6e96ac1129f3e94ea8d152c83e6a3459e949` |
| Windows update log | `0e9775a85640333644c4be1406240590de17f7e97e74fc3142e89a48cbeb6a03` |
| Platform probe log | `4ea9880e2a052106242a3d4779110e44916e213bccbfadb5ddbe81a2fe87493b` |
| Loaded update module | `ccd914ae4a79e47e16c7e8745302cd6bea7e90eda21acc9215b2c0360b9137c8` |
| Loaded platform module | `77adcec4d674879ff8fc8cdce5caff4028b6ae811d698aaa188e1b91ecd1a07d` |
| Installed Windows executable | `dc70c7bde00366675628fd6cee4ee9c59e7e207e2c8e56977688976048029280` |

The installed record identified commit `ab827c8`, branch `main`, and the same
executable hash. It is not a new build of the producer tip.

## Observed integration evidence and handoff limits

The delivery's `docs/integration/backlog-20260930.json` is a snapshot at
`2026-09-30T13:45:49.108Z`, naming main `ab827c88...`, 12 rows (11 remote
non-main heads plus local-only sentinel WIP), 4 batches, 28 pair probes, and
11 installed-drift observations. Its scope explicitly says `not an admission`.
It records a complete responsiveness batch and unresolved warm/retention and
auth/SSE overlaps. I read this as historical integration evidence; I did not
independently refresh its cloud, installed-skill, or pair-probe observations.

Only this report is committed and pushed on the independent review branch,
with `Agent: codex session=term_3baca61f-5cd3-4e24-92d2-0a4eb0eb6f50`.
The closing `git merge-tree --write-tree origin/main HEAD` result and pushed
review tip are reported through the dispatch lifecycle. No producer branch,
other checkout, main, gate state, live runtime, or unfinished work was changed.
The Codex parent relays this exact artifact to wasm-agent coordinator `df71ee84`,
the sole publisher; this reviewer does not publish an admission record.
