# Mission change/session-home — every session owns one folder, allocated lazily

Base: fresh origin/main after harness-fixes and vault-one land. One implementation per behaviour.
Each item: a failing-then-passing test, quoted in REPORT.md. Build/test on this node only. Never push.

## Why (measured)

Session output is scattered today: worktrees hanging off a human checkout (two worktrees on `main`
blocked a deploy 18/11), wave registration lost when the repo moved (avell 18/11), `/tmp` files,
`/work/.scratch/*` copies, separate build dirs (73 dirs / 196 GB filled the desktop 13/11).

## Required behaviour

1. **One folder per session, created empty at start:** `~/.wasm-agent/sessions/<session-id>/` with
   `tmp/` (the session's TMPDIR), `files/` (downloads, reports, evidence). Creating it costs nothing;
   a session that only answers questions ends with an empty folder that is removed at once.
2. **Lazy, not by kind.** No session "type" chosen up front. A resource appears the first time a tool
   needs it:
   - first write to a repo → `worktree/<repo>` from the node's bare mirror
     (`~/.wasm-agent/repos/<repo>.git`, fetched from origin), branch `change/<name>` on fresh
     `origin/main`; never from a human checkout; never a second worktree on `main`.
   - first patch to a non-git target (a live install, a client's config) → `journal/`: the original
     bytes are copied there before the write, so every patch has an undo; the journal is kept until the
     operator accepts or reverts.
3. **Shared build cache outside the folder.** One per node (`~/.wasm-agent/build/<repo>`), never per
   session; the session folder is source + tmp + files + journal only.
4. **Remote work = the folder lives where the work runs.** A session on node A working on node B's
   project dispatches a child session on B (B's folder, B's mirror, B's build cache) and supervises
   it; quick remote reads stay plain remote calls. Mid-way case (remote calls that write on B): B
   creates `sessions/<parent-id>/` on first write and its reaper owns it; the parent's end, or a lost
   heartbeat past retention, releases it.
5. **Safe cleanup — one function, because of the 11/11 home wipe.** Deletion only through
   `session_home.release(id)`: realpath must be strictly inside `~/.wasm-agent/sessions/`, never the
   root itself, never `$HOME`; refuses while the branch has commits not on origin (or writes a bundle
   to `files/` first and says so); refuses an unresolved journal. Retention: released when the branch
   lands, or after N days idle (configurable), with a per-session size line in `/status`.
6. **Credentials by reference (builds on vault-one).** git and gh in the session use a credential
   helper that asks the vault (`{{vault:github/<repo>}}`); no token file in the folder.
7. **Replace, don't add.** The wave registration requirement for allocation and `session_worktree`'s
   manual actions shrink to what this model needs; remove what becomes dead.

## Done when

Proofs: a question-only session leaves nothing on disk; a coding session gets a worktree from the mirror
on its first edit and a fresh-main branch; two concurrent coding sessions never share a branch; a remote
child on another node owns its folder there; a patch to a non-git file is undone from the journal;
release refuses unpushed commits, refuses a path outside the root (symlink and `..` cases), and frees
the folder after landing; no token file appears in any session folder.
