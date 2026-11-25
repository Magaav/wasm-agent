# release-node-updates (G): a release-installed node must be updatable

Branch `change/release-node-updates`, base `origin/main` ebf6d2ec. Commits: `2111510e` (the bundle carries every
script a node execs from its install, and a gate that derives that list from the code), `4b7e4fae` (a tree-less
node answers `--commit` in one line with the command to type), `9c0a673e` (the follow says "no answer yet" and
keeps to its own bound), `b30753b2` (D7: the accepted tail of a verified master request is not a child),
`7e10d2b3` (a scratch installer run is isolated or it does not start). Every claim below cites the commit that
implements it; nothing is claimed that the diff does not show.

## The paragraph the release report must open with

A node installed from the published v0.1.1 bundle updates with a LOCAL `wa update` once v0.1.2 is published, or
by re-running the installer; its data is kept (node id, ledger, vault, binding - measured, section 2). It cannot
be updated FROM ANOTHER NODE until it runs v0.1.2, because the v0.1.1 bundle does not carry the script the
release door execs (`scripts/release-install.sh`) and `--commit` refuses a node with no tree (measured, section
1). Both halves are pinned: the bundle member list is derived from the code and enforced before a bundle is
packed (`2111510e`), and the door's own script is now in the bundle (same commit).

## 1. What a published v0.1.1 node does, measured (avell, 25/11)

Scratch pair the product's own way: a private registry, a coordinator home, and a peer home installed by
`scripts/linux/bootstrap.sh` from the PUBLIC index ("verified: v0.1.1 is signed ... every member matches",
commit 2104a4d8), its own ports/data/key, `wa-sentinel watch` + autostarted `wa serve`.

LOCAL `wa update` on that peer:

```
this node already runs the newest published bundle (v0.1.1); nothing to do.        RC=0
```

Source: lua/core/update.lua:588 (`M.run_release_updater`) runs the INSTALLED updater
(`<install>/scripts/install.sh --check --prefix <install>`) and answers "current" from its plan. It is the one
door on such a node that can reach a newer release, it is LOCAL, and it installs through `systemd-run --user`.

THE REMOTE DOORS, from a coordinator, verbatim:

```
wa update peer011 --commit ebf6d2ecffed2ee79b6484e57ff7576c3b23d1ee                       RC=1
peer011 no_runtime_tree: this node has no runtime-worktree.txt and does not run from a checkout, so
        there is no tree to move to a commit
next: this node is installed from a release: ask for it with mode="release" (wa update <node>
        --release), which fetches the published release and installs it as a neighbour process

wa update peer011 --release --commit ebf6d2ecffed2ee79b6484e57ff7576c3b23d1ee            RC=1
remote update of peer011: queued; commit ebf6d2ecffed
record e82bcc50-...  next: ask again with {action="status", id="e82bcc50-..."}
FAILED on peer011: operation op-... failed code=127 error=null; inspect retained stdout/stderr · 0s
  peer sentinel stderr: bash: <peer install>/scripts/release-install.sh: No such file or directory
  read-back: failed; ... code=127 ...; installed 2104a4d88a37... (installed.txt UNCHANGED)
```

`--binary --commit` routes to the same release door and dies on the same missing script. So on a v0.1.1 bundle
node the fleet step is closed, and the coordinator's refusal is the ONLY thing that can tell a person what to
do (`4b7e4fae`, section 4).

## 2. Re-running the installer over v0.1.1: it upgrades, and the data stays (measured)

A bundle BUILT FROM THIS TREE at ebf6d2ec, served as a signed LOCAL release (SHA256SUMS + SHA256SUMS.sig with
the committed TEST key, `file://` index, `WA_LINUX_RELEASE_ALLOW_LOCAL=1`) - the fixture shape
scripts/test-bootstrap-gate.sh uses - installed by main's `scripts/linux/bootstrap.sh` over the v0.1.1 install.

Before: `commit=2104a4d8... release=v0.1.1 via=linux-bootstrap`; node id ec46828e0eaa79d1; ledger fact
7cb358bb-2448-429a-9c2e-5dba42cee27d; vault entry `peer011-test-secret` = "across-an-installer-run";
binding.json 1398 bytes sha256 af89dac26ead4b6e.

```
bootstrap: install <peer>/install: update (installed 2104a4d88a37)
bootstrap: verified: v0.1.2-local is signed (release-signing-5465d9e84043b3d3) and names ...
bootstrap: candidate reports its own build: ebf6d2ecffed (tree dabc245d35dc, dirty false)
bootstrap: ancestry ok: this bundle contains the running commit 2104a4d88a37
bootstrap: installed v0.1.2-local into <peer>/install
bootstrap: node up on 127.0.0.1:19799 (UI) / 19800 (client bridge) - wasm-agent v0.1.2 · v0.1.2-local
```

After: `wa --version` = wasm-agent v0.1.2 · v0.1.2-local; `commit=ebf6d2ec..., release=v0.1.2-local,
via=linux-bootstrap`; node id UNCHANGED; the ledger fact still recalls; `wa vault reveal` still answers; the
binding is a binding again (same code 8e4b51d9c652, same operator, revision 2 - the file itself was rewritten
by the node's own attach after the restart, so byte equality is not the test and is not claimed);
`<install>/.prev` holds the replaced wa/wa-sentinel/installed.txt.

NOT DONE: the row the coordinator asked for - the v0.1.1 peer upgrading itself by LOCAL `wa update` from the
signed test channel - was not run. What is measured is the installer over a v0.1.1 install (above) and that
local `wa update` answers "current" today because v0.1.1 is the newest published release. The local door's
upgrade half is therefore UNMEASURED on this branch.

## 3. D2: the bundle carries every script a node execs from its install (`2111510e`)

scripts/lib/install-script-doors.mjs DERIVES the list from the code: every `'<install>/scripts/<file>'` literal
whose left-hand expression names the install (lua), every `resolve_script("<file>", ...)` the sentinel uses to
find a shipped script (rust), then the closure of every lib those members source and every sibling script they
actually RUN (a line with bash/sh/node/python3/exec - prose is not a door). Today that is 17 members:
install.sh, release-install.sh, rollback-node.sh, upgrade.sh, wave-entry.mjs and 12 libs. A door the code names
that the tree lacks is `door_absent_in_tree`; an exemption must be in scripts/lib/install-script-doors.allow
WITH A REASON (only scripts/deploy.sh: rust/wa-sentinel resolves it beside the binary and answers "no deploy.sh
found (looked at ...; set WA_SENTINEL_DEPLOY ...)", a refusal by name and not a 127, and a bundle node has no
tree to deploy); an exemption nothing needs is `stale_exemption`.

scripts/release-linux.sh stages the derived members and then re-checks the STAGED bundle against its own
files.sha256 before the manifest and the tarball, so a missing door is `bundle_incomplete` at pack time.
Measured: the bundle built from this branch prints

```
release-linux: doors     17 install-side script(s) staged: install.sh deploy-signal.sh ... wave-entry.mjs
install-script-doors: complete: 17 install-side member(s); every script the code execs from the install is in the bundle
```

and the published v0.1.1 bundle (and the pre-fix bundle built from this tree) is refused by `--check`, naming
all 16 members it lacks. On an installed node the doors are present: `row-fit` output above, "door present:
scripts/release-install.sh / rollback-node.sh / upgrade.sh / lib/node-binaries.sh".

ROWS: scripts/test-release-completeness.sh section 9 (45 checks, 0 failed), which drives a fixture tree (a door
the code names IS derived; a TREE-relative path is not; a door absent from the tree is refused by name), the
allow-list's three refusals, a staged bundle complete / missing a door / missing a member / missing
files.sha256 (unknown, never a pass), and the wiring (derive, check, then tar). On the base it fails at its
first row.

## 4. D1: `--commit` on a release node answers one line, with the command (`4b7e4fae`)

Same peer, same request, two coordinators:

```
BASE  omarchy no_runtime_tree: this node has no runtime-worktree.txt and does not run from a checkout, so
      there is no tree to move to a commit
      next: this node is installed from a release: ask for it with mode="release" (wa update <node>
      --release), which fetches the published release and installs it as a neighbour process

BRANCH  peer011 is installed from a release, not a checkout: move it with: wa update peer011 --release
        --commit ebf6d2ecffed2ee79b6484e57ff7576c3b23d1ee
```

Both ends say it, because the node that has the most to say is the one that cannot be changed any more: a
v0.1.1 bundle ships its own Lua. The coordinator (lua/core/remote_update.lua M.request) therefore rewrites THAT
ONE ERROR - `no_runtime_tree`, a commit named, no mode named - into the line, using the selector the operator
typed and their own commit; the peer's observation is kept in reply.observed. A node built from this branch
answers the same line itself (M.admit). `reply.one_line` is honoured by M.summary, reply.next still carries the
command for a tool, and M.next_line stops it being printed twice; with no commit in hand the line asks for one
(`--commit <40-hex>`) because the release door refuses `release_commit_required` without it.

WHICH DOOR: the fleet step picks it from the node's install kind - the ring's per-node mode (lua/core/land.lua
M.ring ~:4128, RING_MODES ~:4404) - and the judge of an update stays the node's own installed.txt.
docs/REMOTE-UPDATE.md says so now, with the command. NOT DONE: an automatic probe of each node's install kind
inside the fleet step. The ring still names the mode per node; making the step ask each node before it asks for
an install is a landing-critical change the brief did not ask for, so it is named here instead of guessed.

ROWS: scripts/test-update-treeless.lua 8 -> 26 checks, wired at scripts/test.sh:1029. On the base they fail
("the refusal says it is a one-line answer - nil").

## 5. D3: a deadline is "no answer yet", never "refused" - and the follow keeps to a bound (`9c0a673e`)

MEASURED, and the brief's own line reproduced verbatim by the new test on the base:

```
peer011: unknown \226\128\148 node_no_answer \194\183 0s
```

and RETURN - while the request ran on that node and settled a second later. The answer it gave up on is
lua/core/nodes.lua:1786-1800, the relay deadline (`not_known_yet=true, state="unknown"`), which is not the
node's word about anything. Two faults in one loop: the deadline was terminal, and the loop had NO bound (the
CLI passed neither o.polls nor o.seconds), so a quiet node held the terminal open for ever.

Now: an answer that is not an answer (`M.not_an_answer`) prints `<node>: no answer yet \226\128\148 <detail>`
and the follow keeps polling; a real refusal still ends it at once; and the follow keeps to
`M.REMOTE_FOLLOW_BOUND` (3600 s, because a deploy that builds can run that long) - on expiry it prints "<node>:
no answer yet after 1h00m - the request is still that node's; re-attach with: wa update <node> --follow" and
exits non-zero. `M.elapsed` (0s / 1m05s / 1h01m) is the one formatter.

ROWS: scripts/test-remote-follow.lua (new, 24 checks), wired at scripts/test.sh beside the tree-less row. On the
base it fails 8 rows and prints the dry run's line verbatim. Neighbours re-run green: test-remote-update.lua
150, test-update-release.lua 16, test-update-treeless.lua 26.

## 6. D7: the accepted tail of a verified master request is not a child (`b30753b2`)

D7 (fleet-dry-run ready-2): a coordinator's request to a TREE node was accepted and then refused by the peer's
own detached child - `FAILED on omarchy: update_coordinator_only`. lua/core/update.lua refused update.run for
`WASM_AGENT_PROVENANCE=child`, and rust/wa-capabilities/src/operations.rs:1020 stamps every detached operation
with the provenance of the process that started it; the accept runs the rest in exactly such a child
(`wa update --accept <id>`, M.spawn_accepted). The fleet step was therefore closed on BOTH kinds of node.

FIX: M.run refuses when the marker is child AND the caller is not an accepted tail (`options.signed_request`).
That flag has exactly two call sites, both in lua/core/remote_update.lua's own update doors (request_node, the
inline shape v0.1.1 always had, and run_accepted, the detached tail), and no command-line flag spells it.

WHY A WORKER SESSION CANNOT USE `--accept` TO GET AN INSTALL: the verb takes an ID and nothing else - no
commit, no mode, no reason. An id exists only if this node ADMITTED a request whose signature checked out
against its roster/binding (M.admit, master-only, audited), admission wrote the record with the target commit
in it, and M.run_accepted CLAIMS the id with mkdir before the work starts, so one id is one run. A worker that
runs the verb therefore runs, at most, a commit a verified master already had admitted on that node.

NOT the spawn-time escape: clearing the marker for the whole detached child would strip it from everything the
deploy runs underneath it (deploy.sh, upgrade.sh, their git and hooks), which is a wider hole than this door
needs. The child keeps the marker; only the tail's own door is let through, by the record the node wrote.

ROWS: scripts/test-update-child-guard.lua (new, 11 checks), wired in scripts/test.sh. (a) a child shell that
runs update.run is STILL refused with its own sentence; (b) the accepted tail is not refused as a child;
(c) coordinator/orchestrator paths are not refused; (d) `--accept` on an id this node never wrote answers
accept_record_missing, effect none, and prepares nothing; the flag has two call sites and no CLI flag spells
it. On the base it stops at (b): "the accepted tail (signed_request) is NOT refused as a child -
update_coordinator_only".

END-TO-END (no stub of update.run): the accepted tail ran a REAL release install on a scratch peer -
`wa update <peer> --release --commit 9c0a673ebf5c1caeb725962a090ac7698314606c` completed (record e7e4defa...,
kind=release, door=run, state queued, outcome installed, installed_commit named), installed.txt named the
commit, and the ledger fact, the vault entry and the binding survived. NOT DONE: the same row on a peer whose
own process carries the child marker (the dry run's shape) - the operation manager stamps the child with the
SPAWNER'S task provenance or an empty string, so on this machine's binaries that condition cannot be produced
by starting a node; the guard row above is what proves the decision instead. The tree-peer variant (a checkout
installed by deploy.sh) was not run either: the row above is a release install, and it is the one this mission
can build inside its time.

### What a same-user process can still do - APPROVED WORDING (Fable, 25/11, for the RC)

a same-user process can reach M.run{signed_request=true} (a Lua script through the node, or a forged accept
record), exactly as it could clear WASM_AGENT_PROVENANCE in v0.1.1, whose escape was the same cleared variable.
So this is PARITY with v0.1.1, not a new hole: the guard is a rail against a worker installing by accident, not
a wall against a hostile process. Making it a fact (the child re-verifies the signed envelope itself; a boolean
is refused) is queued as item 5 of _queue/installer-refuses-a-target-it-was-not-given.md, week 1.

## 7. A scratch install is isolated or it does not start (`7e10d2b3`)

scripts/lib/install-isolation.sh answers six questions about the environment a run WILL use: the state dir,
WA_INSTALL_DIR (unset means the operator's ~/.local/bin), the systemd unit dir and XDG_CONFIG_HOME, the
systemctl it would talk to, WASM_AGENT_DB, the port, and a vault URL. Everything must be under the scratch root;
unknown refuses. Three harnesses now call it - scripts/test-bootstrap-gate.sh,
scripts/test-release-install-exec.sh, scripts/test-linux-release-fetch.sh - and calling it found two real leaks:
the release-install row inherited the operator's WASM_AGENT_DB and WASM_AGENT_VAULT_URL next to an upgrade.sh
run, and the release-fetch row ran the real bootstrap core with whatever the caller had.

ROWS: scripts/test-installer-data-isolation.sh keeps its 159-row lint (landing 5606ecd3) and gains 17 checks:
a live-looking environment is REFUSED with each of the six named (the RED row the G condition asks for), a
scratch environment passes, and the three harnesses name the guard.

## 7b. The row, run GREEN by the orchestrator's row runner (63a41de4)

Fable rule 2 (25/11): installer rows are run by the orchestrator, not by a worker. The row lives in the repo as
scripts/test-release-door-update.sh (commit 90e0d6a7, plus two fixes the runner itself found: it must not
defeat the runner's warm CARGO_TARGET_DIR, and it must not ask scripts/lib/scratch-home.sh about the scratch
home the runner already gave it - that guard compares against $HOME, and inside the runner $HOME IS the row's
scratch home). The orchestrator ran it at commit 63a41de4 in a fresh checkout and its own scratch root, after
scratch-guard said ISOLATED:

```
row scripts/test-release-door-update.sh @ 63a41de4d2642e5b8990a185afe52425db6f282b in .../release-node-updates-20261125T010115Z (ports 34335/34336), timeout 3600 s
  ok   the bundle names its own commit: 63a41de4d264 (x86_64-unknown-linux-gnu)
  ok   the bundle carries the door the node execs: scripts/release-install.sh
  ok   the bundle carries the door the node execs: scripts/upgrade.sh
  ok   the bundle carries the door the node execs: scripts/lib/node-binaries.sh
  ok   the public installer installed the bundle on a scratch peer
  ok   and its install record names the commit the bundle reports
  ok   a second signed release is served from this directory
  ok   the coordinator has its own identity
  ok   the row's own rendezvous answers
  ok   the peer has its own identity
  ok   the peer's node answers on its own port (49557)
  ok   a ledger fact is written before the update: 4655328b-9a3c-4d00-94ec-418afa2a19db
    remote update of peer: queued; commit 63a41de4d264
    record 7f0aaa41-c7c7-4ee3-bb0d-684f25191c9e
    installed 63a41de4d264 on peer · 0s
  ok   the coordinator's follow ends INSTALLED on 63a41de4d264
  ok   and no door answered code 127 (the defect this row exists for)
  ok   the peer's own record says installed
  ok   and names the commit that was installed
  ok   installed.txt names the commit the door installed
  ok   the ledger fact survives the install
  ok   and the node is up after it
release door update ok (19 checks)
```

row-result.txt: `rc=0 row=scripts/test-release-door-update.sh commit=63a41de4d2642e5b8990a185afe52425db6f282b
leftovers=0 canary_before=green canary_after=green`. leftovers=0 and systemctl-calls.log is EMPTY: the row
touched no unit and left no process.

## 7c. The D7 row on the release commit: a coordinator updates a scratch TREE peer (51cb021e, GREEN)

Fable: "the D7 row (new coordinator -> new tree peer, real install, follow ends installed) must be green ON
that commit". scripts/test-tree-peer-remote-update.sh builds the binary from its own checkout (the row contract
gives a row no `wa` on PATH), sets WASM_AGENT_LUA_ROOT so both processes run THIS commit's Lua, and runs the
product's own two-process row through it - a real `wa serve` peer on its own ports, the real remote_update.serve,
whose accept starts a real detached child (`wa update --accept <id>`) through the node's own operation manager,
which runs the real update.run and fast-forwards the peer's TREE. The runner ran it at 51cb021e (which carries
b30753b2) and it passed, leftovers=0:

```
  ok   the row built the binary it tests from 51cb021ef123d8dd918a85606e93627ab32dbea7
  (the product's own row: 39 checks, printed verbatim in rows/20261125T011053Z/out.log)
      ok: and it is INSTALLED, not accepted forever
      ok: installed.txt names the commit that was asked for: b52c198febfb
      ok: the peer's own tree is on the requested commit
      ok: exactly ONE deploy request exists on the peer
    accept two process ok (39 checks): 6 s of relay hold, one deploy, the peer on b52c198f
  ok   the request settled INSTALLED (the follow ends installed)
  ok   and the peer's installed.txt moved to the commit that was asked for
  ok   one request, one deploy (the accept is claimed once)
  ok   and the peer never answered update_coordinator_only (the D7 refusal)
tree peer remote update ok (7 checks)
rc=0 ... leftovers=0 canary_before=green canary_after=skip
```

canary_after=skip on that first run is the runner's own field: it could not READ the canary afterwards, which is
not a claim that it stayed green. Fable asked for one rerun when no landing is active, so it was re-run at
dcbd80be AFTER the live node reported build=82f57859 (the RC installed):

```
rc=0 row=scripts/test-tree-peer-remote-update.sh commit=dcbd80bed448941ffb85481477c2c9dd76aa3fb4
leftovers=0 canary_before=skip canary_after=green
  (the product's own row: 39 checks)  accept two process ok (39 checks): 6 s of relay hold, one deploy, the peer on 6fe7d083
  ok   the request settled INSTALLED (the follow ends installed)
  ok   and the peer never answered update_coordinator_only (the D7 refusal)
tree peer remote update ok (7 checks)
```

canary_before was skip on the rerun (the node had just come back from its install and the runner could not read
the canary before the row). Across the two runs every direction has been seen green once - first before=green /
after=skip, then before=skip / after=green - and neither run saw a red. The discrimination for D7's decision is the unit
row of section 6 (red on the base with update_coordinator_only, green here); this row is the end-to-end proof
on the release commit.

## 7d. The release channel a row uses, said in its first output line (Fable 25/11)

The unauthenticated GitHub API allowance is 60 requests/hour per address and every row on this laptop shares
it, so a scratch row that does not test the public channel must use a local stub, and a row that does test the
public channel says so first. Both of this mission's rows comply and now say which they are:

```
release door update: channel LOCAL SIGNED STUB (file:// index + SHA256SUMS/.sig, committed TEST key,
  WA_LINUX_RELEASE_ALLOW_LOCAL=1) - the public channel is NOT tested and no GitHub API request is made
tree peer remote update: channel NONE (the binary is built from this checkout; no release channel is read,
  no GitHub API request is made)
```

audited before writing those lines: neither row names github.com or gh anywhere, scripts/release-linux.sh
--local's build path (scripts/lib/build-requirements.sh, scripts/codemode-build.mjs) makes no GitHub API
request, and the only github.com in scripts/linux/bootstrap.sh is the launcher comment at its head - the code
fetches the index, the sums and the assets from the URL the index names, which in these rows is file://.

### The command the text prints is the command a row runs

The refusal of section 4 prints `wa update peer011 --release --commit <sha>` (scripts/test-update-treeless.lua
asserts that string, 26 checks), and the row runs exactly that form:

```
$ grep -n 'update "$PEER_ID" --release --commit "$COMMIT"' scripts/test-release-door-update.sh
210:  timeout 600 "$PEER/install/wa" update "$PEER_ID" --release --commit "$COMMIT" 2>&1)
```

The row names the node by ID where the text writes `<node>`, and it prints that itself before it runs it
(`release door update: command: wa update <id> --release --commit <sha>   (node id; the peer registered as
"peer")`), because a scratch node's NAME can collide with another node on the same registry - measured 25/11,
two nodes both answering to the host name. So the form is the one the text gives; only the spelling of `<node>`
differs, and the row says which spelling it used.

## 8. The guard, pasted (every install row of this mission was run under it)

```
$ scratch/gwarun.sh --root .../scratch/gr-row -- /bin/sh -c '...'
scratch-guard: root /home/victor/Work/missions/release-node-updates/scratch/gr-row (2026-11-25T00:43:53Z)
  ok   HOME = .../gr-row/coord
  ok   WASM_AGENT_HOME = .../gr-row/coord
  ok   data dir = .../gr-row/coord/.wasm-agent
  ok   install dir (WA_INSTALL_DIR) = .../gr-row/install
  ok   unit dir = .../gr-row/units
  ok   WASM_AGENT_DB unset
  ok   WA_SENTINEL_SCRIPTS = .../gr-row/install/scripts
  ok   WA_SENTINEL_UNIT_SYSTEMCTL = .../gr-row/bin/systemctl-stub
  ok   WASM_AGENT_PORT = 17799
  ok   WASM_AGENT_CLIENT_PORT = 17800
scratch-guard: ISOLATED
```

The wrapper (scratch/gwarun.sh) drops every inherited WA_*/WASM_AGENT_* and WASM_AGENT_DB/XDG_CONFIG_HOME, sets
HOME, WASM_AGENT_HOME, WA_INSTALL_DIR, both ports, the unit dir, a REFUSING systemctl stub, WA_SENTINEL_SCRIPTS
and TMPDIR under the scratch root, runs the guard with exactly that environment, and starts the command only on
ISOLATED.

## 9. What the interrupted turn did to the live node, stated exactly

Before the stop, my scratch rows ran WITHOUT the guard and with XDG_CONFIG_HOME inherited. The orchestrator
stopped, by PID, my scratch upgrade.sh (pid 566544), its sentinel and its node. I cannot exclude that my
upgrade.sh rewrote the live unit file: ~/.config/systemd/user/wa-sentinel.service has mtime 21:28:44 local,
inside my run window. Its CONTENT is the live node's own (ExecStart /home/victor/.local/bin/wa-sentinel watch,
WA_INSTALL_DIR=/home/victor/.local/bin, WASM_AGENT_PORT=8799, no scratch path), ~/.local/bin/runtime-worktree.txt
reads /home/victor/wasm-agent/checkout, ~/.local/bin/installed.txt is unchanged (mtime 20:27, before my runs),
and the live node answers /health 200. Nothing of mine runs now: every scratch sentinel/node/rendezvous I
started was stopped by PID (registry 19890, peer011, peerfix, gr-row watcher and registry 17890).

## 9b. Cut condition 1 in progress: the v0.1.1 node's LOCAL door on a test channel (commit 1f8a34d4)

Fable: the two unrun rows are CUT conditions, they continue after this lands. This is the first of them.

Writing the row found the reason it had never been testable. scripts/install.sh resolves the index it reads
(WA_INSTALL_BASE / WA_INSTALL_REF, or the new WA_INSTALL_INDEX), fetches the CORE from that channel - and then
ran the core WITHOUT --index, so bootstrap.sh fell back to its own default, the PUBLIC index. A v0.1.1 node whose
updater had just read a local channel therefore compared itself against GitHub and answered
"this node already runs the newest published bundle (v0.1.1); nothing to do", measured in the row's first run.

FIX (1f8a34d4): the linux channel passes the index it read to the core, and WA_INSTALL_INDEX names one
explicitly. scripts/test-install.sh 56 -> 58 checks (both new rows red before it).

WHAT THE ROW'S FIRST RUN ALSO TAUGHT (its own bugs, fixed in the next commit): a file:// channel must be laid
out PER COMMIT - scripts/install.sh resolves the core at <base>/<the commit the index names>/scripts/linux/
bootstrap.sh, the shape raw.githubusercontent.com/<repo>/<sha>/ has - so the row now writes that directory and
links <base>/main to it. And its assertion that the update was accepted matched the word "installed" inside
"nothing was installed": it now asserts the node is NOT told it is current, that the answer names the release
the channel carries, and that the version and installed.txt actually move.

### The five runs, and what each one measured

1. install.sh ran the core WITHOUT --index: a v0.1.1 node answered "this node already runs the newest published
   bundle (v0.1.1); nothing to do" while the channel it had been pointed at named a newer release. Fixed
   forward in 1f8a34d4 (WA_INSTALL_INDEX, and the index the updater read is passed to the core).
2. A file:// channel must be laid out PER COMMIT - <base>/<the commit the index names>/scripts/linux/
   bootstrap.sh, the shape raw.githubusercontent.com/<repo>/<sha>/ has - or the core is unreachable.
3. A file:// channel needs BOTH opt-ins: WA_INSTALL_ALLOW_LOCAL for the files the updater fetches and
   WA_LINUX_RELEASE_ALLOW_LOCAL for the core's own index read. Each script makes a local URL opt in for
   itself; a self-hosted channel therefore needs both.
4. The v0.1.1 node's own updater cannot see a test channel at all (that copy predates the pass-through): the row
   now asserts exactly that, and in production such a node moves when the PUBLIC index names v0.1.2.
5. With the fixed updater the local door INSTALLED the release: the node came back as wasm-agent v0.1.2
   v6299490f, installed.txt named the commit, the node id and the ledger fact were intact. That run still
   failed on two of the ROW's own assertions - a version grep for the twelve-character commit when a bundle
   prints eight, and the core's systemd user-unit step, which fires AFTER the install and cannot work where
   there is no user manager ("systemd_user_unavailable ... or use --no-service"). Both fixed in a211269f.

GREEN at a211269f (row 20261125T022452Z): rc=0, leftovers=0, canary green before and after,
systemctl-calls.log empty, 18 checks:

```
  ok   the published v0.1.1 bundle is installed on the scratch peer
  ok   and it runs the published release: wasm-agent v0.1.1 · v2104a4d8
    v0.1.1 updater: this node already runs the newest published bundle (v0.1.1); nothing to do.
  ok   the v0.1.1 node's own updater answers from the PUBLIC index, whatever channel it is pointed at
  ok   the fixed updater ran (exit 0)
  ok   the node now runs the release from this commit: wasm-agent v0.1.2 · va211269f
  ok   installed.txt names the commit it moved to
  ok   the node id is unchanged: c2df86f9f65813d4abc1bd44f1c7b2c9
  ok   the ledger fact survives the update
local update v011 peer ok (18 checks): the published v0.1.1 node moved itself to a211269f77e2 with its data
```

So the FIRST half of cut condition 1 is closed: a v0.1.1 bundle node's own updater cannot be pointed at a test
channel (measured and asserted), and the local door - the updater lua/core/update.lua runs - moves such a node to
a this-commit release and keeps its data. The second half (the nextcloud install kind) is untouched.

## 10. Not done, and known failures

- CUT CONDITION, not a landing condition (Fable 25/11): the v0.1.1 peer upgrading itself by LOCAL
  `wa update` from the signed test channel. NOT RUN; the installer-over-v0.1.1 row is measured (section 2).
- CUT CONDITION, not a landing condition (Fable 25/11): the nextcloud kind (installed.txt
  via=remote-update.sh, no runtime-worktree.txt, v0.1.1). NOT reproduced and NOT measured; no door was proved
  from it and nextcloud was not touched.
- The TREE-peer end-to-end row (a checkout installed by deploy.sh, a real install to a second commit): NOT RUN.
  The release-door row is green under the runner (section 7b); the tree deploy door is a different path and is
  not proved by it.
- The follower's bound is 3600 s with no flag to change it: an operator who wants a shorter bind has to wait for
  a product change (named, not hidden).
- PRE-EXISTING, measured on the base worktree /tmp/base-ebf6d2ec at ebf6d2ec: scripts/test-linux-release-fetch.sh
  is red there (14 passed, 13 failed: "arch pick", "fresh install", "WA_NODE in env", "no PATH line in
  ~/.profile", ...), and the same 14/13 on this branch - my isolation change did not move it. It is wired in
  scripts/test.sh, so the full suite was already red before this branch.
- scripts/test-remote-update.lua (150 checks) fails unless it is run from the tree root (it reads
  lua/core/server.lua through the cwd); that is a harness property, not a branch failure, and it is not wired
  in scripts/test.sh.

## Texts to approve (number increasing)

1. `peer011 is installed from a release, not a checkout: move it with: wa update peer011 --release --commit
   ebf6d2ecffed2ee79b6484e57ff7576c3b23d1ee` - the one-line refusal (D1, `4b7e4fae`), coordinator and node.
2. `peer011 no_runtime_tree: this node has no runtime-worktree.txt and does not run from a checkout, so there is
   no tree to move to a commit` - kept as the fact in reply.observed.
3. `no answer yet` - the follow's label for an answer that is not an answer (D3, `9c0a673e`).
4. `peer011: no answer yet after 1h00m - the request is still that node's; re-attach with: wa update peer011
   --follow` - the bound's own sentence, printed on expiry; exit code 1.
5. `door_missing: scripts/release-install.sh - is not in the bundle; the code execs it from the install
   (lua/core/remote_update.lua:449), so a node installed from this bundle answers that door with code 127` -
   the packer's refusal (`2111510e`).
6. `install-script-doors: complete: 17 install-side member(s); every script the code execs from the install is
   in the bundle` - the packer's success line.
7. `install-script-doors: door_absent_in_tree: <file> is exec from the install (<site>) and this tree does not
   have the file` | `stale_exemption: <file> is exempt in <allow> and no code in this tree execs it; drop the
   line` | `exemption_without_reason: <file>` - the derivation's three refusals.
8. `not_isolated: <one of the six> ...` and `refused(isolation_unknown): this run did not name its scratch root
   and the home it will use, so nothing can show it is isolated` - the isolation guard (`7e10d2b3`).
9. `refused(real_node_home): ...` (unchanged, scripts/lib/scratch-home.sh) is now reached through the guard's
   data-dir check too.
10. The D7 comment block's sentence `Workers merge/report; only coordinator requests installation.` is
    UNCHANGED and still what a child shell sees.
