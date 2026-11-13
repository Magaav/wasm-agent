# A code-mode block in the CLI transcript

Operator, 13/11 ~07:30: *"i like your code mode suggestion ... once a new codemode starts running we
collapse that expanded and stream the new expanded"*.

Before this, a code-mode call read badly in three ways. The heading repeated the script's first line
in its parentheses (`⏺ Codemode(const files = await tools.ls(...))`) and the body printed the same code
again; the result row showed the evidence envelope
(`{"evidence":{"bytes":2473,"path":"/home/agent/.wasm-agent/mcp/requests/..."}}`) where the script's
value belonged; and nothing said which tools ran, whether they worked, or how long they took.

```
⏺ Code · bash ×3                                                     1.2s
  const files = await tools.ls({path: 'lua/core'});
  const hits = files.filter(f => f.endsWith('.lua'));
  await tools.read({path: 'lua/core/chat.lua'});
  … +4 lines
  ✓ bash · ls lua/core · 0.2s
  ✓ read · lua/core/chat.lua · 0.1s
  ✗ web_read · example.com · web_http_429
  ⎿ {"count":2,"first":"chat.lua"}
  evidence: 2473 B · sha 5f2a1c9d (/console has the path)
```

## The rules

1. **The heading names the tools, never the code**: `⏺ Code · <name>` (`bash ×N` when a script called
   one tool N times, names joined with `, `), with the call's total time right-aligned on the row. The
   step mark carries the verdict's colour (green, red, accent while a call is pending).
2. **The script is shown once**: the first six rows, dim with syntax colours, then `… +N lines`. The
   whole script is in `/console`.
3. **One row per inner call**: `✓ bash · ls lua/core · 0.2s`, `✗ web_read · example.com ·
   web_http_429` (the error code, never the word "failed"), `⏳ mcp_whatsapp_send · to=me · pending
   op-77`. A fan-out of the same tool - `Promise.all`, `.map` - is ONE row with live counts:
   `bash ×10 ⏳4 ✓5 ✗1`.
4. **The result is the script's value**, pretty and cut to three rows (`… +N lines (/console shows
   all)`). An evidence envelope is replaced in the value by `…evidence` and named once under it, by
   size and digest; its path is in `/console`, which prints the result the model received.
5. **Live follow.** The code-mode block that is running is expanded and streams: each call's row is
   written when the call starts and rewritten in place when it settles (`host.transcript_rewrite`),
   then the value lands under it. When a new code-mode block starts, the previous one collapses to ONE
   row - `⏺ Code · bash ×3 ✓ · 1.2s → "a,b,c"`, or `⏺ Code · web_read ✗ web_http_429 · 0.4s` for a
   failure, which keeps its ✗ and its code. The newest block is at the bottom, so the screen does not
   jump. The last block stays expanded until the next one.
6. **Ctrl+O pins** a block expanded: the newer blocks no longer collapse it. Ctrl+O again lets it go,
   and the next block collapses it like any other.

## Where it lives

| piece | file |
| --- | --- |
| the rows, the summary, the evidence hiding | `lua/core/codemode_block.lua` (pure; a snapshot test renders it at 80x24 and 120x40) |
| which block is open, the fold, the pin, the in-place rewrite | `rust/wa-term/src/transcript.rs` (`code_block`, `fold_code`, `pin_toggle`, `rewrite`) |
| the view: when to fold, what to write, the live events | `lua/core/cli_view.lua` (`codemode_start`, `codemode_sync`, `codemode_settle`) |
| the live events themselves | `lua/core/codemode.lua` (`codemode_call` per nested call, through `ctx.emit`) |
| the host functions | `rust/wa-capabilities/src/host.rs` (`transcript_block(topic, code)`, `transcript_fold`, `transcript_rewrite`), registered in `capabilities.rs` |

## The model boundary is untouched

The block is presentation only. `codemode_call` events go to a view that asked for them
(`ctx.emit`); a run, a peer or a subagent has none, and nothing on the result path reads them.
`scripts/test-codemode-blocks.lua` runs one script twice - once with a listener, once without - and
compares the exact JSON the model receives, so "UI only" is a measured claim rather than a promise.

## Tests

- `scripts/test-codemode-blocks.lua`: the snapshot at 80x24 and 120x40 for one call ok, one call
  failed, a `Promise.all` of ten mixed, a pending call, two consecutive blocks (first collapsed,
  second expanded), a pinned block surviving a newer one, and a long script collapsed - plus the
  model-facing byte comparison above. `WA_CODEMODE_SNAPSHOT_UPDATE=1` rewrites
  `fixtures/codemode-blocks.txt`.
- `scripts/test-cli-view.lua`: the view's own contract - the block is opened as a code-mode block, a
  call's row appears as ⏳ and is rewritten in place to ✓, a failure keeps its code, the value is the
  result row, the evidence is hidden, the previous block is folded with the summary this side built,
  and the plain (captured) layout writes the block once with no live mark.
- `rust/wa-term/src/transcript.rs`: a code block is open while it runs and one row after, a pinned
  block survives the next one (and collapses once unpinned), and `rewrite` flips a row without adding
  one.
