# opening-no-flick: the banner and its notes are one frame (24/11)

Fable accepted the star target (the welcome line's `✻` when the status row is empty) and asked for one small
fix: the one-row flick.

## What the flick was, measured

On the installed binary, frame by frame in a pty at 80x24 / 120x40 / 200x60: the opening's LAST frame drew the
star at (11,1) / (27,1) / (48,1); the chat's FIRST paint drew it at (12,1) / (28,1) / (49,1); the settled
screen was (11,1) / (27,1) / (48,1) again. The row diff named the cause exactly: the first chat frame held the
BANNER only (10 rows at 80x24) and the next one held banner + the icons notice (11 rows) - the transcript is
bottom-anchored, so one more line under the block lifts it by one row, and the star moved with it.

`lua/core/cli_view.lua`'s `render_welcome` wrote the banner and then each line under it in SEPARATE
`self:write` calls: two writes are two frames.

## The fix

* `render_welcome` writes the banner and the lines that belong under it as ONE string - one write, one frame;
* those lines travel with the block now: `chat.lua` computes the icons notice and the reload source BEFORE
  `view:welcome(...)` and passes them as `notes = {...}`; `welcome_painted()` composes the same list in the same
  order, so the block the opening paints and the block the chat writes are the same rows by construction.

## The row (and that it fails on main)

`rust/wa-term/tests/collapse.rs`, wired into `scripts/test.sh` next to the opening pty row: at 80x24, 120x40 and
200x60 - the star's cell in the opening's LAST frame, in the chat's FIRST frame and on the settled screen must
be the SAME, and EVERY frame after the hand-over (one snapshot per read) must draw it in that cell. A settled
screen comparison cannot make that assertion; this one does.

On main (`WASM_AGENT_LUA_ROOT` at origin/main 71a6426e, the same binary) it fails as designed:

```
80x24: the chat's FIRST frame draws the star at (12, 1), the opening's last frame at (11, 1) - that is the flick
```

## Rows run on the branch

| row | result |
|---|---|
| `cargo test -p wa-term --test collapse` (new) | 1 passed |
| `cargo test -p wa-term --test collapse`, main's Lua | FAILED - the flick, named |
| `scripts/test-opening.lua` | 44 ok |
| `scripts/test-icons.lua` | 267 ok |
| `scripts/test-cli-view.lua` (touched code) | 566 ok |
| `scripts/test-chat-start-pty.mjs` | 16 ok |

Texts: none added or changed - the block's rows are the same lines in the same order, drawn once instead of
twice.
