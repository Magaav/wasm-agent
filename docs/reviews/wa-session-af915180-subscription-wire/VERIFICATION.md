# Independent verification: `change/wa-session-childdispatchaf915180-…` @ `ea2f2011`

Reviewer: independent (session `child:dispatch:c5606d25-1e49-452e-862c-9576c39081c7`), own worktree,
branch `change/wa-session-childdispatchc5606d25-…`. The delivery's branch was **not** modified.

Subject: head `ea2f2011adae10e1c427c0eb75b5535fee94a302` ("5 ahead of `origin/main` = `ab827c88`"),
predecessor tip `320c0fcd9e4940a02733dcd5d1d15d0c13c6dbbe` (contained). Producer's status file
`docs/SUBSCRIPTION_WIRE_STATUS.md` is treated as claims throughout.

This file is written incrementally; each section names the test that produced it.

## Facts about the branches (no gate needed, no queue)

`git merge-tree --write-tree` (real exit codes captured, not `head`'s):

| merge | exit | result |
| --- | --- | --- |
| `origin/main` × `ea2f2011` (this delivery) | 0 | clean, tree `34575647569ab7e5210f5c33adadfbbf4d746c84` |
| `origin/main` × `a6e111d` (auth tip, `…8ad3ecc6…`) | 0 | clean, tree `b0ba92b603124baf40e5bc80b80fdf632368f804` |
| `ea2f2011` × `a6e111d` (**the two together**) | **1** | **CONFLICT**: `rust/wa-host/src/main.rs`, `scripts/test.sh` |

So each branch merges `main` cleanly; the pair does not merge with each other. Exactly the two files
the brief predicted, and no third. Nothing was resolved.

Auth-side tips (`git branch -a -v`): `…8ad3ecc6…` = `a6e111d`, `…95d6189a…` = `24fb23c`, and
`24fb23c` is an ancestor of `a6e111d` (`git log --oneline origin/main..a6e111d` lists
`a6e111d, 24fb23c, 50fd09b, 17916fe`).

`scripts/test.sh` on `ea2f2011` adds **one** suite to the gate:
`WA_SCRIPT=scripts/test-subscription-wire.lua "$BIN" --db "$DB.sub-wire" | grep "subscription wire ok"`
(wall-time measured below). `scripts/check-subscription-wire-live.lua` and
`scripts/check-subscription-wire-parity.lua` are *not* wired into `test.sh` (they need the network);
`check-subscription-wire-live.lua`'s own header says so and `grep` confirms no `test.sh` reference.

## `host.http_sse` — is the transport real or a shim? (code path, read at `ea2f2011`)

**Real, line-by-line, while the socket is open.** Path, `rust/wa-host/src/host.rs`:

* `http_sse` (`host.rs:1778`) validates the callback (`:1784`), refuses non-POST (`:1788`), checks
  `run_cancel_requested()` *before* the request (`:1792`), sends, and refuses a non-200 as a bounded
  body rather than an empty stream (`:1811-1817`).
* `:1818` `let reader = std::io::BufReader::new(response.into_body().into_reader());`
  `:1819` `read_sse_lines(reader, |line| call_lua_string(l, 5, line))` — the body is wrapped in a
  streaming reader and handed straight to the line loop. There is **no** `read_to_string` on the
  streaming path (the only `read_to_string` is the non-200 error body at `:1812`). So the response is
  consumed as it arrives, not buffered first.
* `read_sse_lines` (`:1846-1868`): `for line in reader.lines()` → `run_cancel_requested()` **per line**
  (`:1853`, returns `termination:"cancelled"`) → read error → `termination:"read_failed"` →
  `on_line(&line)`; a callback `Err` returns immediately with `termination:"line_callback_failed"`
  and the lines already delivered (`:1863-1865`), i.e. the read **ends at that line**, not at EOF.
* `call_lua_string` (`:1877-1898`) anchors the callee in the caller's frame, runs it under
  `lua_pcallk`, restores the stack on both paths, and turns a Lua error into `Err(redacted, ≤512)`
  instead of unwinding through the C boundary.
* The deadline is not in Rust: `subscription_wire.lua:894` raises `subscription_timeout` from inside
  this callback on every line, so the same per-line mechanism ends the read. Only `run_cancel_requested`
  is checked in Rust; the producer's status prose ("checks cancellation and the deadline per line")
  is true of the pair, and the deadline half lives in Lua — stated here because the wording in the
  status file reads as if both were in `host.rs`.
