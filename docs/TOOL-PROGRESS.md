# The long-call line (`⟳ bash · 3m10s …`)

One row **inside the tool call's own block in the transcript**, under its `⏺ Bash(…)` heading, says
what a call that is taking a while is actually doing. It exists because of a measured failure: on 08/11
the agent ran `cargo test` in its `bash` tool for twenty minutes, and `wa chat` showed only `Running
bash` with no output and no movement. A healthy build and a wedged process looked the same, and the
reader had no way to tell which one they were looking at.

**Not on the session-status-content row.** That row - the one line directly above the session status
bar - is the update notice's, its rebuild loader's and its result's, and nothing else's (Victor,
2026-11-10: "this bash description should be printed in the bash toolcall not at the footer. that
place belongs to update message and update launcher seeker, not info about tools, which should be in
the terminal content"). It was there once, and that was the bug this page records the fix for: a
running call had no block of its own while it ran, so its progress was pinned to the only row left.
⟳ bash · 41s · Downloading numpy-1.26.0-cp311.whl (15.8 MB)
⟳ bash · 4m20s · no output for 3m
```

## What it says, and when

| part | rule |
| --- | --- |
| `⟳ <tool>` | the name the reader knows the call by (`bash`, `operation`); sent with the launch, drawn only |
| `· <elapsed>` | how long this call has run: `45s`, `2m05s`, `1h02m` |
| the detail | the newest line a known progress dialect recognizes, else the last non-empty line |
| `▕███░░▏ n/m` | when the dialect carries numbers: a bar (the build loader's, 14 cells) and the count |
| `· no output for 3m` | nothing written for **3 minutes**; dim. Not a verdict — a quiet compiler is healthy — but it is the one fact a still picture cannot carry |

A call **under two seconds** gets no line at all: the block's heading and the status line already say
`Running bash`, and a line that appears and vanishes inside two seconds is flicker, not information.

Dialects recognized, in `rust/wa-tool-progress/src/lib.rs` (`Detail::from_lines`):

* **cargo** — `Building [=====>    ] 143/412: serde_json, syn` (bar + count + first crate) and
  `Compiling serde_json v1.0` / `Finished … in 4m12s` (text);
* **npm / pnpm** — `Progress: resolved 143, reused 120, downloaded 23, added 0` → `resolved 143
  packages`, `reify:<pkg>: timing …` → `reify:<pkg>`;
* **pip** — `  45%|████▌   | 45.0/100.0 [00:03<00:04]` (bar) and `Downloading …` / `Collecting …`
  (text);
* **git** — `Receiving objects:  45% (450/1000), …`, `Resolving deltas: …`, `Counting objects: …`,
  `Compressing objects: …` (bar), `Cloning into 'x'...` (text);
* **anything else** — the last non-empty line, which is what a reader watching a terminal would see.

## Where the output comes from

A foreground `bash` blocks the node-thread inside the host's own `host.exec`, so **Lua cannot poll and
cannot paint** while the call runs. The operation supervisor's wait loop is awake every 100 ms and
already owns the operation's output files, so it reads the tail there — at most **four times a second**
(`wa_capabilities::tool_progress::INTERVAL_MS`), with a grow-only byte cursor — and publishes the facts
to:

```text
$WASM_AGENT_DATA/tool-progress.json      # else $WASM_AGENT_HOME/.wasm-agent, else ~/.wasm-agent
{state: running|done, tool, started_at, at, last_output_at,
 detail: {kind: bar, label, done, total, percent} | {kind: text, text}}
```

Every surface reads that one file, so they cannot disagree:

* `rust/wa-term/src/tool_progress.rs` — the sentence the call's own row draws, rendered by the host's
  ticker, which is awake while Lua is blocked;
* `lua/core/tool_progress.lua` — the CLI's own layout and its transcript line;
* `ui/app.js` — the window, which reads `/health` (`operations[]`) and `/operation` itself.

A file whose `at` is older than 10 seconds is a node that died mid-call: it shows **nothing** rather
than a frozen line. The row is finished by the operation's own record (settled, cancelled, promoted,
overdue), never by a timer.

## Where the line is drawn

In the block the call opened when it **started**, as the row under its heading:

```text
⏺ Bash(test-remote-call-shape)
  ⟳ bash · 43s · remote call shape ok
```

* the CLI prints the heading when the call starts (`lua/core/cli_view.lua`'s `METHODS:tool_live`,
  `host.transcript_live`), which is what gives the progress line a block to live in;
* the host's ticker rewrites **that one row in place** while Lua is blocked in `host.exec`
  (`rust/wa-term/src/transcript.rs`'s `Transcript::live`, fed by `wa-capabilities`'
  `refresh_tool_progress` from the same facts);
* the result lands under the same heading, and the first real write takes the live row away, so a
  finished call never leaves a stale clock behind; the heading itself is rewritten in place with its
  outcome dot (`host.transcript_head`);
* the window does the same in the call's own topic (`wa-tool`'s `setProgress`, fed by the /health +
  /operation poll).

The row it is **not** on has two claimants and one line: a **build loader** (`⟳ building wasm-agent …`),
which replaces everything because it is what the terminal is doing right now, and the **standing update
notice** (`Update available (<sha>): run wa update or /update`). Empty is no row at all: the element/row
is removed, so there is never a blank gap above the status bar. `session_content` in
`lua/core/cli_view.lua`, `rust/wa-term/src/terminal_editor.rs` and `ui/app.js` refuse a tool's line by
construction - the caller is not there any more - and `scripts/test-cli-view.lua` asserts it.

## What it never does

* **It never changes a tool result.** Nothing here is on the result path; the row is text.
* **It never carries a secret.** The tail is the bytes `wa-operation` already wrote *after* its
  redactor, so the node's own configured values never reach it; the row then passes the same text
  through the existing shape redaction (`lua/core/redact.lua`'s `text`, `ui/app.js`'s `toolScrub`) and,
  in Rust, `wa_tool_progress::redact` (exact value, defence in depth).
* **It is never more than one row.** Control characters and ANSI sequences are stripped where the text
  is built, and the caller clips to its width (`clip_cells` in Rust, `clip` in Lua, CSS ellipsis in the
  window).
* **It never becomes a file-write storm.** Four writes a second, a cursor, and no read of the process.

## Where the code is

| file | what |
| --- | --- |
| `rust/wa-tool-progress/src/lib.rs` | the decision: dialects, tail, clocks, stall rule, line text, redaction |
| `rust/wa-term/src/tool_progress.rs` | the renderer: colour, clipping, the live file, the sentence the block draws |
| `rust/wa-term/src/transcript.rs` | `Transcript::live`/`head`: the row inside the call's own block, replaced in place |
| `rust/wa-capabilities/src/tool_progress.rs` | the feeder: reads the operation's output tail and publishes the facts |
| `rust/wa-capabilities/src/operations.rs` | `progress_tick` in `foreground` and `control("await")` — the two wait loops |
| `rust/wa-capabilities/src/host.rs` | `refresh_tool_progress`: the ticker's one row, and `host.transcript_live`/`transcript_head` |
| `rust/wa-term/src/build_status.rs` | the update row, and the bar and colours it reuses |
| `lua/core/tool_progress.lua` | the CLI's twin of the decision (same wording, same thresholds) |
| `lua/core/cli_view.lua` | `tool_live`/`tool_head`: the call's block, opened when it starts |
| `ui/app.js`, `ui/components.js`, `ui/style.css` | the window: `toolCallSentence` into `wa-tool`'s own `setProgress` |
| `scripts/test-tool-progress.lua`, `scripts/test-cli-view.lua`, `tests/tool-progress.js` | the Lua and window halves, with the line's exact wording |

The three renderers are three implementations of **one** rule; the tests assert the same strings in
all of them (the glyphs, `no output for 3m`, the 14-cell bar, the two clocks), so a change to one is a
failure in the others rather than two sentences for one call.
