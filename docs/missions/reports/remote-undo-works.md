# remote-undo-works: the chat gets the /undo its own tool description promised

Base `899fdd47`. Branch `change/remote-undo-works`.

| commit | what it does |
| --- | --- |
| `f3e4e3a4` | the door (`lua/core/undo_command.lua`), the peer transport moved out of `server.lua` (`lua/core/remote_files.lua`), `memory.last_change_turn`, the `/help` row + REPL arm, `scripts/test-undo-command.lua` (40 checks), `scripts/test-undo-pty.mjs` (17 checks), both wired into `scripts/fast.sh` |
| `0c341f34` | `scripts/test-undo-remote-pty.mjs` (15 checks, a REAL scratch peer on this machine), wired into `scripts/fast.sh` |

`lua/core/tools.lua` is BYTE-FOR-BYTE the base's: `git diff 899fdd47 -- lua/core/tools.lua` is empty, so no
model-read byte moved and the prompt cache is untouched. The promise is made true instead of deleted.

## 1. Re-measured, before any code (the brief's premises)

| premise | verdict |
| --- | --- |
| `lua/core/tools.lua:577` tells the model "the change is recorded here, so /undo restores that file there" | **confirmed**, same line on the base and here |
| `lua/core/changeset.lua` records the change (before/after in a content-addressed store) | **confirmed**: `M.record`/`M.store`, and a remote entry carries `node` (`changeset.lua:105-130, 361`) |
| undo exists as a server route, not in the chat | **confirmed**: `wa_diff` at `server.lua:2106` on the base calls `changeset.check` (`:2146`) and `changeset.undo` (`:2171`), plus `redo` (`:2176`) |
| the chat has no door | **confirmed**: `git show 899fdd47:lua/core/chat.lua \| rg undo` and the same on `commands.lua` are both EMPTY. A slash word with no arm is refused by the fallback ("unknown or incomplete command /undo - /help lists them"), never sent to the model |
| the peer transport is `changeset.set_file_host`, installed by `server.lua` | **confirmed**: `changeset.lua:117` and `server.lua:46` on the base |
| the remote-edit-first-class report claimed undo works | **confirmed**: `docs/missions/reports/remote-edit-first-class.md:125` ("the change is recorded here; /undo restores it on the peer") and its section 6 undoes a remote change through `wa_diff`. It was TRUE for the window and silent about the chat |

The brief's own line numbers for `server.lua` ("~2114-2171") are the base's comment and the `undo` call;
the function starts at `:2106`. Everything else in the brief held.

## 2. What a chat's /undo does now

`lua/core/undo_command.lua` (`f3e4e3a4`) is a DOOR: it finds the newest turn of THIS session that recorded
a file change (`memory.last_change_turn`, `memory.lua`), merges repeats the way the route does
(`changeset.normalize`), and calls the SAME `changeset.check` then `changeset.undo` that `wa_diff` calls.
No second restore was written. It then CHECKS the result: every recorded text is addressed by its own
sha256, so `file.before` is the version each file must hold; a file that holds something else is a named
failure (`restore_unverified`), never a success.

A file that lives on a peer is reached through `lua/core/remote_files.lua` (`f3e4e3a4`), which is the
`set_file_host` transport moved out of `server.lua` verbatim (the route installs the same module, with the
server's own nodes module handed over so a call is signed by that process's identity). The chat process
never loads the server, so it installs the same transport itself. `changeset.check` verifies the peer's
version by asking the peer for the file's digest (one small read), and the restore is a `write` capability
call to that node - the same fenced remote write the route performs.

`commands.lua` gained the row (`f3e4e3a4`), so `/help` lists it and `scripts/test-command-parity.cjs`
keeps the window and the CLI in step; `chat.lua` gained the arm, which prints through the same `ui.say`
every other command uses and never reaches the model.

## 3. The remote undo, measured with a REAL scratch peer (not a stand-in)

Two wasm-agent processes on this machine, each with its own `WASM_AGENT_HOME`, a private `wa rendezvous` on
loopback with `WASM_AGENT_NETWORK_ADMINS` set to those two nodes, both registered there, and every call
signed and relayed over loopback. Nothing of the operator's fleet was configured or reachable. A script in
the CALLER's home made one remote edit and then undid it twice - once through the route, once through the
new door - and the answers were:

```
read_version=4fdbc441ea7b...  edit_applied=true  file_after_edit=alpha\nBETA\ngamma\n  record_node=b
route_check={"can_undo":true,"reason":"undoable"}
route_undo={"ok":true}          file_after_route_undo=alpha\nbeta\ngamma\n
edit2_applied=true  file_after_edit2=alpha\nbeta\nGAMMA\n
door_ok=true  door_category=undone
door_lines=  undo: /tmp/.../demo.txt (on b) - version 4fdbc441ea7b
file_after_door=alpha\nbeta\ngamma\n
```

So: the route's undo of a REMOTE change does restore the peer's file (answer: yes, with the peer's own
digest checked before the write), and the door does the same thing through the same code.

`scripts/test-undo-remote-pty.mjs` (`0c341f34`) is that measurement as a permanent test: the chat in a real
pty, the peer as a second `wa serve`, the model reading a page there and editing a line, then `/undo`. Its
honest evidence that the RESTORE crossed the wire is the peer's own log of the call it dispatched - on one
machine the bytes cannot tell a local write from a remote one, and the test says so where it asserts it.

## 4. Tests (each fails on the base)

| test | checks | how it is driven | wired |
| --- | --- | --- | --- |
| `scripts/test-undo-command.lua` | 40 | the door + the peer stand-in `scripts/test-remote-edit.lua` uses (real `wa_peer_dispatch`, real `wa_diff`); its FIRST assertion is about the shipped `/help` rows, so on the base it fails on a value, not on a missing file | the fast path runs every `scripts/test-*.lua` not in `scripts/fast-path.exclude`; this one is not listed there (`f3e4e3a4`) |
| `scripts/test-undo-pty.mjs` | 17 | the real binary in a private tmux pty; a local SSE fixture writes a file (turn 1), changes one line (turn 2), then `/undo` must restore the bytes AND the version, must not reach the model (the fixture counts its requests), and a second `/undo` must refuse `version_moved` | `scripts/fast.sh`, row `undo-pty` (`f3e4e3a4`) |
| `scripts/test-undo-remote-pty.mjs` | 15 | a real scratch peer (above) | `scripts/fast.sh`, row `undo-remote-pty` (`0c341f34`) |

Each test creates its own scratch `WASM_AGENT_HOME` and REFUSES to run when it is the real
`~/.wasm-agent`; the pty ones also refuse a cwd inside the checkout and pick fresh ports (never
8799/8800/8890). No test reaches the live fleet: the local pty test sets no rendezvous and no relay, the
remote one configures only its own.

## 5. Texts to approve (every new operator-facing string, verbatim)

1. `/help` row (`lua/core/commands.lua`): `put back the last file change this session recorded: here, or on the node that holds the file`
2. one file restored: `  undo: <path> (this node) - version <12 hex>` / `  undo: <path> (on <node>) - version <12 hex>`
3. a created file restored: `  undo: <path> (<where>) - emptied: that turn created it, and undo restores text, it never deletes`
4. more than one file: `  undo: restored <N> files from the last recorded change`, then one `<4 spaces><path> (<where>) - version <12 hex>` row per file
5. refusal, first row: `  undo: refused (<category>) - <sentence>`; second row: `<4 spaces><the harness's own reason>` (`changed_since_turn:<path>` and so on). The categories and their sentences: `nothing_to_undo` - `this session has recorded no file change`; `version_moved` - `the file is not what that turn left there`; `node_unreachable` - `the node that holds the file could not be read`; `not_recorded` - `that change was not recorded well enough to put back`; `write_failed` - `the write that would put it back failed`; `restore_unverified` - `the file did not hold the previous text after the restore`; anything unclassified - `refused` with `the undo did not run`

## 6. What this does NOT do (named, not hidden)

- **`/redo` is not in the chat.** The route has it, but `changeset.redo`'s guard reads the file with
  `host.read_file(file.path)` for EVERY file, including one on a peer (`changeset.lua`, the loop before
  `M.apply_all` in `M.redo`): a remote redo would compare the LOCAL file of the same path, and a missing
  local file skips the check entirely. That is a pre-existing hole in a path no chat exposes; exposing
  `/redo` would have shipped it, so it is reported here instead of added. The brief allows this ("and
  /redo if the route has it").
- **One change per /undo.** It puts back the newest recorded change. A second `/undo` does not walk back to
  the turn before it: it refuses `version_moved`, because the file is no longer what that turn left. That is
  the route's own rule, and the tests pin the refusal rather than pretending a cursor exists.
- **A created file is emptied, not deleted** (the host has no `remove_file`); the answer says `emptied`.
- `changed_since_turn` is reported as `version_moved`: the NAME is the chat's, the harness's own reason
  travels on the second row unchanged, so the file that moved is still named.
