# version-folders: slice (b) - versions side by side, a pointer, and a rollback that is one rename

Branch: `change/version-folders` (based on origin/main `ebf6d2ec`). Requirements: Fable 24/11, the nine in
`docs/UPDATE-DESIGN.md` section 2.0 (`BUILD IT, these are REQUIREMENTS`). Plan and rows: `ready-sliceb-plan`
(mission dir). This file is updated as each step commits; a step that is not built says so.

## What this branch has, and what proves it

    commit     step                                   proof
    094fdbb7   S1+S2: the share root, the version id,  scripts/test-versions.sh (S1+S2 rows), wired in
               the assembler (hard links), the pointer, scripts/test.sh; RED on the base (the library is
               installed.txt as a link, retention,      absent there, so the row cannot pass)
               the disk refusal
    5a093959   S4: a cut is finished by wa ITSELF at  lua/core/version_repair.lua + init.lua + 12 checks in
               the next start                     scripts/test-version-repair.lua + 5 more in
                                                  scripts/test-versions.sh through the real start path:
                                                  the absent link is back and the command answered
    ae4288fd   S6 + R8: the sentinel moves AFTER   scripts/lib/sentinel-move.sh,
               the node, and a failed start        scripts/test-sentinel-version-move.sh (5 checks, runner:
               leaves the previous supervising   rc=0 leftovers=0).
    78960a31   S3 + R3: the installer, and a cut   scripts/version-install.sh (9 steps, resumable),
               at EVERY step boundary             scripts/test-version-install.sh (10 checks: end to end,
                                                  rerun continues, no-room refused before staging, and a
                                                  SIGKILL after each of the 8 steps leaves a node whose wa
                                                  answers and which installs again to the end), plus
                                                  scripts/lib/scratch-env.sh and the G-condition lint
                                                  scripts/test-installer-data-isolation.sh (14 checks)

Rows that exist and pass (each named in its failure message):

    R1  one variable names versions/current in the share root, beside ui, never the data dir
    R2  a version is made once (assembling an existing id is refused: version_exists) and is read-only
    R4  installed.txt is a LINK to current's own record and follows a pointer move with no second write
    R6  an unchanged member shares an inode with the previous version; the pair's real disk stays under 5 MiB
        where two 4 MiB copies would be 8
    R7  retention keeps 3 and never current, the one before it, a version a live process runs from (its real
        /proc/<pid>/exe), or a pinned one; the legacy wa.prev copies are not touched
    R9  no room -> version_no_room free/need/margin BEFORE anything is staged, and no staging dir is left

Rows that do NOT exist yet and are the next commits (named, not implied):

    R5 first half IS green (5a093959): a cut leaves an absent link, and the next start puts it back through
           the real binary (WA_SHARE_ROOT + WA_INSTALL_DIR + this tree's Lua), never replacing a real
           directory and repairing nothing on a healthy install.
    R3     GREEN at the step boundaries (78960a31): a SIGKILL after each of the installer's 8 steps, then the
           install's own wa answers and the same install runs again to the end. The cut INSIDE a step (between
           "rename the real path aside" and "rename the link onto it") is not reachable from that hook; that
           window is covered by lua/core/version_repair.lua and scripts/test-version-repair.lua.
    R8     GREEN (ae4288fd) through the row runner: the sentinel refuses to move before the node is healthy
           (sentinel_move_before_node), a failed new start leaves the PREVIOUS version supervising through a
           drop-in naming its absolute path, and nothing supervising is named. 5 checks,
           rows/20261125T004434Z, rc=0 leftovers=0 canary green before and after.

## The measured ground this is built on (24/11, read-only)

- `~/.local/bin` holds wa (79,400,744 B), lua-core/ (214 files), scripts/, installed.txt, rollback/ (84 MB),
  lua-core.prev/, lua-core.stale.<ts>/. The share root `~/.local/share/wasm-agent` held exactly one thing:
  ui/. So `versions/` and `current` go beside ui, as requirement 1 says.
- The binary already resolves its Lua tree from its own REAL executable path and reads it ONCE:
  `rust/wa-host/src/main.rs:88` (`current_exe()?.parent()?.join("lua-core")`, or $WA_LUA_TREE) and
  `main.rs:130` (a `OnceLock` that verifies every file's sha256 and the capability digest). Requirement 2 is
  therefore true by construction the moment the path it resolves is never overwritten - which is what this
  branch builds. It is also why the version folder must contain `lua-core/` and `scripts/` as members.
- deploy swaps the Lua tree by directory renames (`scripts/deploy.sh:1624-1629`) and installs the program
  through `scripts/upgrade.sh`: the in-place path this slice replaces, not a bug in itself.
- TWO ANSWERS to "which Lua am I running", measured today: `wa --lua-tree` says
  `installed lua tree: commit 87a5e363 (214 files)` while `installed.txt` says `lua_tree=ebf6d2ec`. This is
  the class requirement 4 closes: one atomic thing says which version is current.
- The live `wa-sentinel.service` unit's ExecStart names a SCRATCH install path
  (`/home/victor/Work/missions/landing-is-installable-by-download/.wa-scratch/.../install/wa-sentinel watch`),
  not `~/.local/bin`: a test repointed the operator's unit and nothing moved it back. Requirement 8 has to
  survive the unit being wrong, so the sentinel's move is the caller's order and its fallback is explicit.

## The cut order, per path (requirement 5)

    versions/<id>   assembled in versions/.staging-<id>, sealed, then ONE rename into place
                    (versions/<id> is complete or absent; a cut leaves .staging-<id> to be swept)
    current         LINK_TMP -> rename(2) over current: readers see the old version or the new one, never none
    lua-core        rename the real dir aside (lua-core.stale.<ts>), then LINK_TMP -> rename over lua-core.
                    In the window between the two the path is absent: a process starting then falls back to
                    the binary's compiled-in Lua and says so once - a working node, not a broken one
    scripts         the same two steps as lua-core
    ui (share root) the same two steps
    installed.txt   becomes a link to current/installed.txt; the old real file is renamed aside

## What a version costs, measured on this branch's fixture

A 4 MiB member unchanged between two versions is ONE inode (a second copy would be 8 MiB for the pair): the
pair's real disk measured under 5 MiB in `scripts/test-versions.sh`. The report's "~127 MB per version"
(`docs/UPDATE-DESIGN.md` section 1b) is the apparent size of a complete version; with N=3 and hard links a
scripts-only sequence adds a few MB per version, not 127.

## A mistake made here, kept as a lesson

A debug line sourced `scripts/lib/versions.sh` with `WA_SHARE_ROOT=... . lib` - an assignment that applies to
the `.` builtin only - so the function ran against the REAL share root and wrote a fixture folder
`~/.local/share/wasm-agent/versions/aaaaaaaaaaaa`. It was found and removed in the same turn (the share root
is back to ui/ alone, verified by `ls`), and the test itself refuses a scratch inside the data dir. The
lesson: the library operates on the real root by design, so anything that CALLS it in a probe must export
`WA_SHARE_ROOT`; the row's own guard is what caught the same class in the test's first run.

## Where S4 lives, and a claim this report made that was WRONG

An earlier version of this file (commit 02391009) said the repair belongs in \`rust/wa-host\` because Lua cannot
create a link. That was wrong, and it was measured wrong within the hour: \`host.exec\` exists, so Lua can run
\`ln\`. What IS true is narrower - there is no \`host.symlink\` capability, so a link is made by a child process,
and the interpreter that needs the repair is the one whose tree may be absent (it then runs the binary's
compiled-in copy, which carries this module once the binary is rebuilt).

So S4 is Lua (\`lua/core/version_repair.lua\`, called from \`init.lua\` before the tree is needed and before
\`memory.setup()\`), and two host facts learned by the row failing are recorded in the module's comments:
\`host.file_exists\` does not exist in this host's surface (\`host.path_kind\` answers "missing" for both an absent
path and a dangling link, which is exactly the question), and \`host.exec\` answers a JSON envelope rather than
bare stdout (the row built a scratch path out of the envelope on its first run).

## Scratch isolation (Fable 25/11, binding): the G condition and the guard

Every installer run on this branch is isolated by construction, not by habit:

- \`scripts/lib/scratch-env.sh\` holds the clean prefix and a checker over every dimension Fable named - HOME,
  WASM_AGENT_HOME, the data dir, WA_INSTALL_DIR, the unit dir, WASM_AGENT_DB, XDG_CONFIG_HOME,
  WA_RUNTIME_WORKTREE, WA_SENTINEL_SCRIPTS, a stub systemctl (never the real one), the ports (never
  8799/8800/8801/8810) and the vault URLs.
- \`scripts/test-version-install.sh\` applies that prefix, installs its stub systemctl, and asks the checker
  BEFORE it runs anything; it also hashes the three operator files
  (~/.config/systemd/user/wa-sentinel.service, ~/.local/bin/runtime-worktree.txt, ~/.local/bin/installed.txt)
  before and after and stops the row on any difference.
- \`scripts/test-installer-data-isolation.sh\` (Fable's G condition, 14 checks) proves the checker REJECTS each
  live dimension on its own, that the installer row asks it before running, and that neutralising a harness
  which inherits HOME, XDG_CONFIG_HOME and a ledger path lands on ISOLATED with the three files unchanged.
- Every run below was made under \`env -i\` with the scratch prefix, after the orchestrator's own guard:

```
scratch-guard: root /tmp/wa-scratch-vf (2026-11-25T00:36:24Z)
  ok   HOME = /tmp/wa-scratch-vf/home
  ok   WASM_AGENT_HOME = /tmp/wa-scratch-vf/home
  ok   data dir = /tmp/wa-scratch-vf/home/.wasm-agent
  ok   install dir (WA_INSTALL_DIR) = /tmp/wa-scratch-vf/install
  ok   unit dir = /tmp/wa-scratch-vf/units
  ok   WASM_AGENT_DB unset
  ok   WA_SENTINEL_UNIT_SYSTEMCTL = /tmp/wa-scratch-vf/bin/systemctl-stub
  ok   WASM_AGENT_PORT = 19799
  ok   WASM_AGENT_CLIENT_PORT = 19800
scratch-guard: ISOLATED
```

## Not in this slice

(d) - side-by-side start, the listener handoff, fd passing, run-journal ownership (item 3(ii) and E3). Windows:
the in-place install stays there and the launcher is not built untested (requirement 9). Nothing here lands
before the cut; the diff goes to Fable.

