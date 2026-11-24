# fleet-update-survives-a-slow-relay (G, class c) - first version

Mission dir: `/home/victor/Work/missions/fleet-update-survives-a-slow-relay`
Worktree: `wt`, branch `change/fleet-update-survives-a-slow-relay`, base `origin/main @ 53bb69b1`.
Commits, rebased onto `origin/main @ fe108a8c` (the 24/11 landing that restructured `wa update`; the
`--accept` entry point was re-resolved by hand in `lua/core/init.lua`, keeping BOTH sides): `ee59a4fd` (the seam + a deadline is not a refusal),
`89eb3325` (accept fast / detached / poll by id), `1f9f9e3c` (review a: the record is written before the
child), `1ad0b114` (review b: one id, one run), `34ed7000` + this one (report). The entry-guard fix is no
longer on this branch: it landed on `main` as `ce1feb5b` (`land-quick: merge change/fleet-update-entry`),
and the rebase dropped my `0c6afffc` as an already-applied patch.
Nothing was pushed. Nothing on a live node was written: every read below is `wa call work bash` read-only
(`tools.remote`), and no update was requested on `work`.

---

## 1. Reproduction, read-only, with the timings per hop (item 1)

`wa update work --tree --commit 53bb69b1` from avell failed 2 of 2 with
`{"error":"remote_refused","reason":"relay_request_timeout","node_status":504,"transport":"relay"}`.
Nothing was refused. The numbers below are the node's own artefacts (its audit records, the two
pre-update backup directories they left behind, and the mtimes inside them), plus timings taken with
`time` over read-only commands on that node the same day.

| # | hop | measured | how |
|---|-----|----------|-----|
| 0 | relay hold, per attempt | 45 s, less a 3 s answer margin -> **42 s deadline** | `rust/wa-rendezvous/src/rendezvous.rs`:32 `SEND_WAIT`, :47 `ANSWER_MARGIN_MS` |
| 1 | relay round trip, trivial bash, avell -> work | 2.9 s and 3.7 s (two calls) | wall clock around `tools.remote` |
| 2 | the node's own authorization (`nodes.author_of`) | < 1 ms | code read, `lua/core/remote_update.lua` M.serve |
| 3 | `M.facts()` watcher probe (`wa-sentinel preflight`) | 39 ms (x2 per accept) | `time wa-sentinel preflight` on work |
| 4 | `prepare_tree`: `git fetch origin` + fast-forward | 1.19 s (fetch, `--dry-run`) | `time git -C /work/wasm-agent fetch --dry-run origin` |
| 5 | **pre-update backup (VACUUM INTO of every store)** | **101 s and 103 s** | the two `*-pre-update` dirs: first file 13:46:20 -> `manifest.json` 13:47:40 (attempt 1), 13:47:36 -> 13:49:09 (attempt 2); 431 MB total (195 MB memory.db, 152 MB index.sqlite, 85 MB graph.db) |
| 6 | handing the deploy to the sentinel (`wa request deploy`) | ~1 s and ~4 s | record written right after the backup finished |
| 7 | **the node's whole accept** | **108 s and 117 s** | its audit records: requested_at 13:45:55Z / 13:47:18Z, answered 13:47:43Z / 13:49:15Z |

So the accept is 108-117 s against a 42 s relay deadline, and **101-103 s of it is the pre-update
backup**. Hops 2, 3 and 4 together are ~1-7 s; the relay itself is ~3 s per round trip.

The node's own answer, written 66 s *after* the relay had already told the master "refused":
`sentinel_unverifiable - the sentinel exited nil naming no request; stdout was empty; stderr was empty`
(both records). That is a separate defect (the host's exec answer carried no exit code and
`lua/core/update.lua` renders a missing code as success), named here and not fixed: it is
`update-reports-what-happened` item 1c's family.

### Where the 60 MiB of "refused" came from
`lua/core/nodes.lua` renders a **non-200 answer with an allow-listed code** through
`M.refusal("node", code, status, node)`. The relay's own 504 `relay_request_timeout` arrives that way, so
the relay's deadline was printed as `remote_refused ... layer "node"` - "the node refused" - and
`relay_request_timeout` was not even in `M.RELAY_DEADLINE_REASONS`, the list callers read a deadline by.

## 2. The fix (item 2) and the seam the pull design reuses

**`lua/core/accepted.lua` (new, commit `ee59a4fd`) - the reusable piece, and it is not about deploys.**
One request, two lifetimes:

* `accepted.accept{root, id, kind, detail}` - claims the id with an atomic `mkdir`, writes the record,
  starts nothing. A claim that cannot be made is a refusal (`accept_claim_unavailable`), never an
  assumed success.
* `accepted.detach{root, id, program, args, owner}` - starts the work as the node's **own managed
  operation** (`host.operation`, the long-job path this node has) and returns at once.
* `accepted.begin` = accept + detach, for a caller with nothing to say in between.
* `accepted.status{root, id, probe}` - `accepted / running / done / failed`, from durable evidence only
  (the record, the operation the host reports, and the caller's own `probe` of ITS outcome files), and
  `unknown` when it cannot tell. Unknown is never yes.
* `accepted.finish{root, id, state, detail}` - the detached process' own terminal write, the only writer
  of done/failed.

Idempotency is the id and the claim is the `mkdir`: **a retried request can never start a second
update**. The future pull design calls the same five functions with a different `program`/kind.

**`lua/core/remote_update.lua` (commit `89eb3325`)** - the deploy door now uses it:
the id is the master's own (`args.id`) so the master's pending record, the node's audit record and the
accept record are one name; the cheap decisive checks stay synchronous (every refusal a caller reads
today it still reads, and reads again by id); the expensive tail - backup, then the sentinel request -
runs as `wa update --accept <id>` (one child, `M.run_accepted`, the same `update.run()`); a host with no
operation manager runs it inline exactly as before and the answer says so (`inline=true`,
`inline_because`). `read_status` answers the phase while the tail runs instead of
`unknown_remote_update`, and the tail's `done` maps to the deploy's own word `queued`, never
`installed`. The other doors (rendezvous/binary/release/rollback) are untouched.

**`lua/core/nodes.lua` (commit `ee59a4fd`)** - a deadline is not a refusal: the deadline codes (an
allow-list, `relay_request_timeout` now among them) answer `{error:"not_known_yet", not_known_yet:true,
state:"unknown", retryable:true, id/rid, next:"read it back by id"}`; every other non-200 keeps the
refusal rendering it had. The `remote_error` branch keeps its code (rows read it) and gains
`not_known_yet=true` and a message that starts there.

**`lua/core/remote_update.lua` M.request (master half)** - names the id, remembers it *before* the call,
and a `not_known_yet` answer is returned as NOT KNOWN YET with the id and the read-back, never as a
refusal.

**`lua/core/land.lua`** - the deploy step keeps a deadline answer as the row state `not_known_yet` and
reads it back by id until the deploy deadline (`unknown` for a request whose id we know does not end the
row); `failure_for` then says `deploy_not_known` and names the read-back. The canaries step names a
relay deadline as NOT KNOWN YET (retried once, still red - unknown is never green) instead of reporting
the node as having refused.

**`lua/core/init.lua`** - `wa update --accept <id>`, the detached side's entry point (not a verb a human
types).

## 3. Rows: what is green, what proves what, and what is NOT done

Green now (each run with its own scratch home, `WA_MESH`/vault vars unset):

| row | checks | proves |
|-----|--------|--------|
| `scripts/test-remote-update.lua` | 139 | the accept is `state:accepted` + `detached:true` in one call; the child is `wa update --accept <this id>`; **the same id twice starts nothing new**; the tail writes the same record, the one `--if-no-pending` sentinel command and the forced `--force --reason` line as before; two log lines per request (accepted, admitted) instead of one |
| `scripts/test-land-canary-step.lua` | 49 | the canaries step unchanged for a node that answers |
| `scripts/test-land-rows.lua` | 137 | the deploy step's ringing/settle shape |
| `scripts/test-remote-refusals.lua` | 146 | every refusal shape still renders as before (a real `unknown_caller` is still `remote_refused`) |
| `scripts/test-remote-call-shape.lua` | 89 | the relay cap constants |
| `scripts/test-refusal-contract.lua` | 18049 | the new code `not_known_yet` renders message/input/fix; inventory regenerated |
| `scripts/test-main-module-entry.mjs` | 6 | see item 4 |

**NOT DONE, and it is item 3 of the brief: the 60 s stub-relay row.** A first version
(`scripts/test-accept-slow-relay.lua`, uncommitted and deleted) drove the real `nodes.remote_call`
against the real `remote_update.serve` through a relay stand-in that withholds the update answer 60 s
of the test's clock, then answers the relay's own 504. It hangs, and the two blockers are measured and
worth writing down:

1. loading `lua/core/nodes.lua` with `WASM_AGENT_RENDEZVOUS`/`WASM_AGENT_RELAY` answered **before**
   the load blocks in that load (nothing is printed and `host.http` is never reached);
2. installing the virtual clock (`host.sleep` advancing the test's clock) **before** loading
   `lua/core/update.lua` blocks in that load - a wait whose time is the stub never ends.

Loading first and stubbing afterwards fixes both, and the row then ran into its own fixture (a
shadowing `local remote`) - which is where the session's time ran out. Next session's first step: that
row with **two real processes** (the row starts a real relay process on a real port; the peer half is a
real `wa serve` with its own scratch home), because the current version stubs the wire.

## 4. work's failed install of 24/11 15:34:55Z: the cause, and a red/green row

Fable's addendum, answered from the node's own files (`wa call work bash`, read-only; no retry, no
cleaning).

**Cause.** `deploy.sh` pins the commit and builds in a pinned worktree. On `work` that path is
`/tmp/wa-deploy-pins/<sha>`, a **symlink** to `/home/agent/.wasm-agent/pins/<sha>` (`ls -ld`
measured). The host build was then run as

    node /tmp/wa-deploy-pins/5bb28d8a1f51.../scripts/codemode-build.mjs build <pin root>

and that script's entry guard compared `path.resolve(process.argv[1])` (which does **not** resolve
symlinks) with `fileURLToPath(import.meta.url)` (which Node has already canonicalized). Through the
symlinked path the two can never match: the module loaded, printed **nothing**, ran cargo **never** and
exited **0**. `deploy.sh`'s `|| fail` therefore saw success.

**Evidence on work:** `build-logs/wa-host.log` and `build-logs/wa-host.receipt.json` are both **0
bytes**, mtime 15:29:14Z (a deploy that ran cargo leaves `Compiling ...`/`Finished ...` in the first and
the receipt JSON in the second); `deploy.out` says `compiled 0 + 60 crate(s)` (0 from the host build, 60
from the sentinel build, which is a plain cargo run and goes through no guard); `wa-sentinel.log` is
5713 bytes at 15:34:54Z, and one second later the deploy died on `no built binary at
.../deploy-5bb28d8a1f51/release/wa` - a `wa` that was never built (only `wa-sentinel` is in that
directory). Reproduced read-only on work with the same node binary:

    node /tmp/wa-deploy-pins/<sha>/scripts/codemode-build.mjs assets-path <pin>         -> (nothing), exit 0
    node /home/agent/.wasm-agent/pins/<sha>/scripts/codemode-build.mjs assets-path <pin> -> the path, exit 0

**Does the fleet step's nodes hit it?** Yes: every tree deploy goes through `landing-queue.mjs pin`, so
every node whose `/tmp/wa-deploy-pins` is a symlink (work's was made 23/11 12:47) fails the same way,
and a `wa land` deploy to any of them lands red with that message.

**Fix (`0c6afffc`):** every entry guard asks `isMain(import.meta.url)` from one implementation,
`scripts/lib/main-module.mjs` (realpath on both sides). **21 script files** carried the same idiom
(`codemode-build`, `gate-check`, `build-receipt`, `cargo-executable`, `full-gate-proof`, `wave-guard`,
`producer-admission`, `lane-boundary`, `merge-lane`, `fast-result`, `reclaim-disk`,
`runtime-install-binding` and the `wave-*` entry points) and every one of them silently did nothing when
reached through a symlink.

**Row `scripts/test-main-module-entry.mjs`** (wired into `scripts/test.sh` next to `test-gate-check`): runs
`codemode-build.mjs` through a symlinked path and requires the same answer as the real path, and refuses
any script that compares an unresolved `argv[1]` with `import.meta.url` (so a copy of the old line is a
red row, not a silent install failure).

* **RED on the base**, verified in a separate worktree at `HEAD` (`git worktree add /tmp/wa-base-entry`,
removed afterwards; no `git stash`): `FAIL and it ANSWERS instead of doing nothing - {"status":0,
  "stdout":"","stderr":""}`.
* **GREEN here:** 6 checks.

## 5. Where the seam is (for the pull design and "long checks run on a peer")

`lua/core/accepted.lua` is the seam: `accept` (claim + record), `detach` (start the work as the node's
own managed operation), `status` (accepted/running/done/failed from durable evidence, plus the caller's
own `probe`), `finish` (the child's terminal write), and `begin` as the pair. It knows a kind, an
idempotency key and a command - nothing about deploys - so a pull (`program = <fetch+verify>`), a long
check on a peer, and today's `wa update --accept` all call it unchanged. What the *caller* needs on the
other side is one rule, implemented in `lua/core/nodes.lua`: a deadline is `not_known_yet` with the id,
and the answer names the read-back.

## 6. Texts to approve (new or changed operator/model-facing strings, verbatim)

1. `"NOT KNOWN YET: %s did not answer inside the deadline this call was given (%d s) and the answer was
   %s, which says nothing about whether it ran - it was NOT refused. Read the request back by its id on
   that node before asking again: a second request with the same id starts nothing new."`
2. `"NOT KNOWN YET - %s did not answer a relayed call within %d s ..."` (the existing relay deadline note,
   now prefixed)
3. `"NOT KNOWN YET: %s did not answer inside the deadline; whether it accepted the request is unknown, and
   it was NOT refused."` (the master half's summary)  + `"read it back: wa update <node> --status --id <id>"`
4. `"accepted: this node is preparing the deploy (the pre-update backup, then the request to its own
   Sentinel) detached from this call. This is not installed yet."`
5. `"this id was already accepted on this node: nothing new was started, and the answer is what that
   request is doing."`
6. `"accepted on that node: <phase> - <detail>"` and `"ask again with the same --id: accepted and running
   are not installed"`
7. refusal `not_known_yet`: message `"the deadline passed before that node answered, so whether it ran is
   not known ({origin})."`, fix `"read the request back by its id on that node (its own status action
   answers accepted/running/installed/failed) before asking again; a second request with the same id
   starts nothing new."`
8. land deploy step: `"node %s (%s): NOT KNOWN YET after %ss - the relay did not carry an answer inside the
   deadline, and the read-back named no phase. It was NOT refused: the node may still be working."` and
   `"read it back on that node: wa update <node> --status --id <id>; then `wa land --resume` continues at
   this step"`
9. canaries step: `"%s: NOT PROVEN - NOT KNOWN YET: the relay did not carry an answer inside the deadline
   (<reason>); the node was not proven, and nothing here says it refused"`
10. `"wa update --accept <id>: the id of the request this node accepted is required"`
11. `"wa update --accept <id>`'s summary line is the tail's own `: <detail>` (queued / failed text).

## 7. What is not verified, and the next slices

* **Not verified:** the accept-fast path against a real sentinel and a real relay (the detached child in
  production was never executed on work: no update was requested there, by order). The 60 s stub-relay
  row is not written (section 3). The node's `sentinel_unverifiable` (a missing exit code read as
  success) is diagnosed, not fixed.
* **Next slices, in this order:** (1) the 60 s stub-relay row with two real processes; (2) the missing
  exit code in `update.lua`'s `shell()` reading as success (`sentinel_unverifiable` with `code=nil`);
  (3) `wa land`'s deploy step on work once the entry-guard fix is installed there (the release's fleet
  step will then build instead of dying at 361 s).

---

## 8. Fable's review, 24/11 ~17:10Z: what changed, and the one item still open

### 8.1 Question 1 (not blocking): why did 23/11's build run cargo through the same symlink?

**It did not - yesterday's build failed the same way, three times, and was worked around by hand.** From
work's own `sentinel/deploy.out` (read-only):

| when (23/11) | what the log says |
|---|---|
| 1795437043 (retry 2) | the codemode cargo step hit its `1800000ms` spawnSync timeout on a cold build |
| 1795438155 (retry 3) | "pin dir now on an exec filesystem (`/tmp/wa-deploy-pins -> /home/agent/.wasm-agent/pins`)" |
| retry 3 block | `building ccbd3cdd... from pinned worktree /tmp/wa-deploy-pins/ccbd3cdd...` then `compiled 0 + 5 crate(s)` |
| retry 4 block | `building 7865a08e... from pinned worktree /tmp/wa-deploy-pins/7865a08e...` -> `compiled 0 + 5 crate(s)` -> **`no built binary at .../deploy-7865a08e3222/release/wa`** |
| next block | `compiled 0 + 0 crate(s)` -> `no built binary` again |
| 1795442006 (retry 7) | "shipping build run **directly by the agent** - v7865a08e, native_checked:true, receipt sha 9e86f6ef matches release/wa; deploy should reuse it" -> `compiled 0 + 0 crate(s)` -> installed |

So the guard misfired on every pinned build after the pin dir became a symlink (23/11 12:47), and the
`wa` that shipped that day was built by the agent running the shipping build **from a real path**, then
reused by deploy.sh. Today's failure is the same defect reaching a deploy that had no by-hand binary to
reuse. (Not an explanation gap; the row `scripts/test-main-module-entry.mjs` now proves the defect and
the fix - on `main` as `ce1feb5b`.)

### 8.2 Review a (order) - `1f9f9e3c`

The record is written BEFORE the child is started; the operation id is added to the same record after
the start; a write that fails starts nothing and answers `accept_record_not_written`. The child's
no-record branch settles the accept **failed** with `accept_record_missing` and returns that refusal -
it used to be pasted from `read_status` and read a `caller` that does not exist in that scope (Fable was
right: it would have raised on that path). Row: the child for an unknown id fails by name and settles
the accept failed.

### 8.3 Review b (once) - `1ad0b114`

Two layers, both needed: `accepted.claim_running` is an atomic `mkdir` claim beside the record (released
by the only terminal writer, `finish`), and `run_accepted` checks the id's own phase first with an
ALLOW-LIST - only an id nobody has claimed, or one whose work `detach()` has started (`running`), may
run; `queued`/`done`/`failed` are answered with the phase and start nothing. (The subtlety: `detach()`
leaves the record `running` because it has just started this very verb, so `running` must be allowed.)
Row: the verb twice starts nothing the second time, no second operation, **exactly one `request deploy`
for one id**, and the first call does not answer `already`.

Plus the assertion Fable asked for: **a refused role leaves no accept record** (the role check is the
first thing `serve()` does), in the same row. `scripts/test-remote-update.lua` is 146 checks.

### 8.4 Review c (the real row) - DONE: two real processes, green here, red on base

`scripts/test-accept-two-process.lua` (commit `7e4e47de`, wired into `scripts/test.sh` beside
`test-remote-pending`). It starts the fleet's own path on this machine and touches no live node:

* THIS process is the master - a real `wa`, the real `lua/core/nodes.lua` remote_call, the real signed
  body and relay loop, real `host.http`;
* a real `wa serve` peer, its own HOME and ports, running the real `remote_update.serve`, whose accept
  starts a real `wa update --accept <id>` child through the node's own operation manager;
* a real relay PROCESS on its own port that forwards the signed call and withholds the answer past the
  master's deadline, then answers the relay's own 504;
* the product's own discovery and authority - a scratch `wa rendezvous`, this node promoted to master in
  it, and a signed roster for the pair;
* a REAL two-commit git repository as the peer's tree (the accept really fast-forwards it) and a fixture
  `wa-sentinel` that answers the real preflight shape and performs the deploy it is handed.

What it asserts: the master reads NOT KNOWN YET (`refused` false, the id travels, and 6 s of real relay
hold elapsed), the id reads back, the phase goes accepted -> installed with `installed.txt` naming the
commit that was asked for, the peer's own tree is on that commit, exactly ONE deploy request exists, and
a retry with the same id is answered from the record with no second request. 39 checks.

* GREEN: `accept two process ok (39 checks): 6 s of relay hold, one deploy, the peer on <sha>`.
* RED on the base, verified in a worktree of `origin/main` with this row copied in:
  `FAIL a relayed deadline is reported as NOT KNOWN YET - got nil, want true`.

FIVE PRODUCT LINES THE ROW FORCED (Fable reads the diff; these are the ones to look at):

1. `lua/core/accepted.lua` `M.start_operation`: the HOST's operation `kind` is an allow-list
   (`command`, `build`, `test`, `deploy`); this module passed its own vocabulary and every start was
   refused with `operation_kind_unknown:remote-update`. The caller's word stays in the record and the host
   is told `command`.
2. `lua/core/accepted.lua` `M.detach`: `ok` now means the work is RUNNING. A refused start wrote a record
   with a `start_problem` and still returned `ok=true`, so the caller answered "accepted" for a request
   nothing would ever do.
3. `lua/core/remote_update.lua` `read_status`: a REFUSED deploy is reported failed, not `queued` forever
   (`outcome_of` answers `queued` for a record whose install it cannot see).
4. `lua/core/remote_update.lua` `run_accepted`: a claim that could not be MADE settles the accept failed
   with that reason instead of answering "already" (your review of a+b).
5. `lua/core/remote_update.lua` `accept_phase`: the phase detail is a sentence, never the table the
   accepting call stored (a summary line printed `table: 0x...`).

The row also settled the earlier blockers: the peer's data dir is `<WASM_AGENT_HOME>/.wasm-agent`, so
`wa node` and the serve must be given the SAME `WASM_AGENT_HOME` (two identities for one home was measured
first), the scratch repository needs a real `refs/remotes/origin/main` (a push alone leaves FETCH_HEAD),
and every module must be LOADED BEFORE any host stub (a stubbed clock or transport makes the load itself
block).
