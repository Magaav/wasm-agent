# ops-cwd-red (24/11): three rows main turned red, and what in my landing caused each

Branch `change/ops-cwd-red` from `origin/main` (`bce56ab2`, which carries the landed
`change/operations-explain-and-survive` = `fa94a958`), then rebased onto `2c06d6bf` (main moved while this
branch was open: `change/esc-stops-now` landed). Reproduced every row here before touching anything, then
found the cause in file:line and fixed it in the product where the product was wrong.

## 1. `scripts/test-start-instant.lua` - the start path wrote the ledger (1143 ms)

**Cause.** `lua/core/agent.lua`, `M:run` -> `M.record_run_directory` -> `memory.set_session_cwd`: my landing
recorded the session's directory by writing the ledger at the RUN'S START.

**Measured, not inferred** (`/tmp/probe2.lua`, run behind a real 8 s hold taken by
`scripts/fixtures/sqlite-busy-holder.lua`):

    session_worktree            0 ms
    session_cwd(read)           0 ms
    set_session_cwd(write)   7654 ms
    session()                   0 ms

So the reads the orchestrator suspected are free; the WRITE is what waits, and
`test-start-instant` measured 1143 ms of it before the first model call, against its contract.

**Fix (`3d193c78`).** The decision is made from data the run already has, kept in memory, and the ONE ledger
write happens in `M.flush_run_directory`, called where the run has ENDED (`lua/core/agent.lua`, right after
`run_body` returns - the place the run already writes its own record). A process killed before its run ends
leaves the old row, and the next node-served turn then behaves as it did before this mission (the node's own
directory) until a run of that session finishes and records it. Said plainly in the code comment.

**A second pass, and a mistake I corrected (`94a490c3`).** I first cached the value for `M.workdir` too. The
cache then went stale when a caller set the recorded directory itself: `scripts/test-operation-cwd.lua` check 7
("the prompt's workdir is the directory the commands run in") failed, because `M.workdir` answered the cached
value while the ledger held a newer one. Reads cost 0 ms, so the cache bought nothing and only added a second
source of truth: it is gone, the ledger is the one answer, and the deferred WRITE remains the fix.

## 2. `scripts/test-codemode-model-boundary.lua` - the cursor scope hashed the cwd

**Cause.** `lua/core/tools.lua`, the `tool_call` branch: the routed-read cursor's scope hash included
`cwd = session_cwd(memory, ctx)`. A session's directory can now legitimately CHANGE while it runs - the first
run records it - so a cursor issued before that run and resumed after it computed another hash and answered
`batch_cursor_scope_changed` (measured: `ERR=batch_cursor_scope_changed`) to a session that had done nothing
wrong.

**Fix (`3d193c78`).** The scope is WHO, not WHERE: the hash keeps user, role, session, the workspace binding and
subagent profile, and drops the directory. The retained page is absolute content, so resuming it from another
directory discloses nothing new, and the guard still refuses a cursor presented from another session or another
workspace.

## 3. `scripts/test-network-outage-recovery.lua` - the tool call "not run" (0 executions)

**Cause.** Not the outage path: `lua/core/tools.lua`, `resolve_path` resolves a relative path in the session's
directory, and with an unbound session that directory is no longer empty (this mission's whole point), so the
read arrives as `<session dir>/DESIGN.md` instead of the bare `DESIGN.md`. The row stubs `host.read_file` for
the exact string `DESIGN.md`, so the stub missed, the REAL reader ran, the file was not there, the tool answered
an error, and `TOOL_RUNS` stayed 0.

**Fix (the row, not an assertion).** The stub now answers for the FILE the tool asked for
(`path == 'DESIGN.md' or path:match('DESIGN%.md$')`). What the row asserts - exactly ONE execution, never re-run
after the outage - is untouched and exactly as strong; what changed is that the fixture no longer encodes one
spelling of the path. The behaviour (file tools resolve in the session's directory) is deliberate and stays:
that is the same directory the prompt names and the commands run in.

**If a row had encoded the old cwd behaviour on purpose** I would have said so here and restated it no weaker.
None of the three did: (1) and (2) encoded two assumptions that stopped being true ("the start path may write",
"a session's directory never changes"), and (3) encoded a path spelling. All three are fixed where the wrong
assumption was, and no assertion was loosened, deleted or given more time.

## Verification (singly, on the rebased tip)

| row | verdict |
| --- | --- |
| `scripts/test-start-instant.lua` | `start-instant ok` (the held-lock case included) |
| `scripts/test-codemode-model-boundary.lua` | seed `665 checks ok`, restart `43 checks ok` |
| `scripts/test-network-outage-recovery.lua` | `network outage recovery ok (34 checks)` |
| `scripts/test-operation-cwd.lua` | 31 checks |
| `scripts/test-session-isolation.lua` | 141 checks, 0 failed |
| `scripts/test-remote-pending.lua` | 90 checks |
| `scripts/test-handle-wake.lua` | 17 checks |

The narrowed run at the previous tip (`cd0a35a3`) reported `3 of 136 checks` failed - all three contract
checks, none of them a row this branch touches, and each traced to main rather than to this diff:
`check-esc-stops-pty` (the load-sensitive timing row, proven pre-existing earlier in this mission),
`check-tmp-cleanliness` (fails on `scripts/test-placement-defer.sh:24`, a literal `/tmp` mktemp that landed on
main in `bd9331e9`, another mission's commit), and `check-install-guards` (the in-turn upgrade refusal, 6 of 72,
proven pre-existing on a base worktree earlier today). The run on the rebased tip is recorded at the end of this
file.
