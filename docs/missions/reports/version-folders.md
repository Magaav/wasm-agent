# version-folders: slice (b) - versions side by side, a pointer, and a rollback that is one rename

Branch: `change/version-folders` (based on origin/main `ebf6d2ec`). Requirements: Fable 24/11, the nine in
`docs/UPDATE-DESIGN.md` section 2.0 (`BUILD IT, these are REQUIREMENTS`). Plan and rows: `ready-sliceb-plan`
(mission dir). This file is updated as each step commits; a step that is not built says so.

## What this branch has, and what proves it

    commit     step                                   proof
    094fdbb7   S1+S2: the share root, the version id,  scripts/test-versions.sh, 29 checks, wired in
               the assembler (hard links), the pointer, scripts/test.sh; RED on the base (the library is
               installed.txt as a link, retention,      absent there, so the row cannot pass)
               the disk refusal

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

    R3/R5  a SIGKILL at every migration and install step boundary; after each: wa --version, a /health
           answer, and an update still completes. Needs S3 (the deploy path assembles a version) and S4
           (wa finishes a half-done migration at its next start).
    R8     the sentinel's order and the old-supervisor fallback. Needs S6.

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

## Not in this slice

(d) - side-by-side start, the listener handoff, fd passing, run-journal ownership (item 3(ii) and E3). Windows:
the in-place install stays there and the launcher is not built untested (requirement 9). Nothing here lands
before the cut; the diff goes to Fable.

