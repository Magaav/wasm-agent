# The long-call row (`⟳ bash · 3m10s …`)

One line directly above the session status bar — the **session-status-content** row — says what a tool
call that is taking a while is actually doing. It exists because of a measured failure: on 08/11 the
agent ran `cargo test` in its `bash` tool for twenty minutes, and `wa chat` showed only `Running bash`
with no output and no movement. A healthy build and a wedged process looked the same, and the reader
had no way to tell which one they were looking at.

```text
⟳ bash · 3m10s ▕████░░░░░░░░░░▏ 143/412 building serde_json
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

A call **under two seconds** gets no row at all: the status line already says `Running bash`, and a
line that appears and vanishes inside two seconds is flicker, not information.

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

* `rust/wa-term/src/tool_progress.rs` — the native editor's row, drawn by the host's ticker, which is
  awake while Lua is blocked;
* `lua/core/tool_progress.lua` — the CLI's own layout and its transcript line;
* `ui/app.js` — the window, which reads `/health` (`operations[]`) and `/operation` itself.

A file whose `at` is older than 10 seconds is a node that died mid-call: it shows **nothing** rather
than a frozen line. The row is finished by the operation's own record (settled, cancelled, promoted,
overdue), never by a timer.

## Precedence on the row

The row has three claimants and one line. In order:

1. a **build loader** (`⟳ building wasm-agent …`) — a node rebuild replaces everything, because it is
   what the terminal is doing right now;
2. the **standing update notice** (`Update available (<sha>): run wa update or /update`);
3. **this** — a long tool call.

A fact about the node outranks a fact about one call, which is why this is the lowest claimant
(`lua/core/cli_view.lua`'s `session_content`, `rust/wa-term/src/terminal_editor.rs`'s
`session_content`, `ui/app.js`'s `paintSessionContent`). Empty is no row at all: the element/row is
removed, so there is never a blank gap above the status bar.

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
| `rust/wa-tool-progress/src/lib.rs` | the decision: dialects, tail, clocks, stall rule, row text, redaction |
| `rust/wa-term/src/tool_progress.rs` | the renderer: colour, clipping, the live file, `Editor::tool_progress` |
| `rust/wa-capabilities/src/tool_progress.rs` | the feeder: reads the operation's output tail and publishes the facts |
| `rust/wa-capabilities/src/operations.rs` | `progress_tick` in `foreground` and `control("await")` — the two wait loops |
| `rust/wa-term/src/build_status.rs` | the row it shares, and the bar and colours it reuses |
| `lua/core/tool_progress.lua` | the CLI's twin of the decision (same wording, same thresholds) |
| `lua/core/cli_view.lua` | `session_content`/`session_line`: the third claimant and its colour |
| `ui/app.js`, `ui/style.css` | the window's footer line |
| `scripts/test-tool-progress.lua`, `tests/tool-progress.js` | the Lua and window halves, with the row's exact wording |

The three renderers are three implementations of **one** rule; the tests assert the same strings in
all of them (the glyphs, `no output for 3m`, the 14-cell bar, the two clocks), so a change to one is a
failure in the others rather than two sentences for one call.
