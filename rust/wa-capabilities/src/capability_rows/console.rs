//! The console: the slash menu's commands, the line reader and the lines it holds, the transcript and
//! link helpers, the keybinding table, and the stream the UI reads. The handlers are in crate::host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("isatty", Device, crate::host::stream_is_terminal, "Whether standard input/output/error is a terminal"),
    plain!("terminal_size", Device, crate::host::terminal_size, "The console's own width and height"),
    plain!("terminal_write", Device, crate::host::terminal_write, "Write to the real console, serialized with the editor and the ticker"),
    plain!("ticker", Device, crate::host::ticker, "Start or stop the CLI status line, which keeps drawing while the interpreter is blocked"),
    plain!("input_start", Device, crate::host::input_start, "Start the one off-thread console line reader"),
    plain!("input_editor", Device, crate::host::input_editor, "Repaint the live editor's input row"),
    plain!("opening_start", Device, crate::host::opening_start, "Play the opening on the alternate screen: green rain, a supernova (a flash, a sphere of debris in depth, one ring in a tilted plane), the header star landing, the title translated from the alien alphabet"),
    plain!("opening_header", Device, crate::host::opening_header, "Hand the opening the welcome block the view painted, so its last frame is the real header"),
    plain!("panel", Device, crate::host::panel, "Open, replace or close the CLI's bottom panel and wait for the reader's choice"),
    plain!("transcript_write", Device, crate::host::transcript_write, "Append text to the CLI transcript's current block"),
    plain!("transcript_block", Device, crate::host::transcript_block, "Start a CLI transcript block (a collapsible topic, a plain block, or a code-mode block drawn expanded while it runs)"),
    plain!("transcript_live", Device, crate::host::transcript_live, "Write or clear the running tool call's live line inside its own transcript block"),
    plain!("transcript_head", Device, crate::host::transcript_head, "Rewrite the current transcript block's first line (a call's heading when its result lands)"),
    plain!("transcript_fold", Device, crate::host::transcript_fold, "Collapse the newest code-mode block to its one-row summary because a newer one has started"),
    plain!("transcript_rewrite", Device, crate::host::transcript_rewrite, "Replace a committed line of the current transcript block by offset from its end"),
    plain!("transcript_copy", Device, crate::host::transcript_copy, "Mark lines of the next transcript write as copyable: a copy icon on each, a click puts its content on the clipboard"),
    plain!("transcript_expand", Device, crate::host::transcript_expand, "Mark lines of the next transcript write as expandable (hover brightens, click shows the full text)"),
    plain!("transcript_card", Device, crate::host::transcript_card, "Mark the diff body of a card in the next transcript write: drawn open up to the card bound, the rest counted on one row, Ctrl+O or a click draws it all"),
    plain!("status_snapshot", Device, crate::host::status_snapshot, "Store the /status panel the CLI shows by itself while a run is in flight"),
    plain!("local_view", Device, crate::host::local_view, "Store a read-only command's balloon so the CLI draws it while a run is in flight"),
    plain!("transcript_hold", Device, crate::host::transcript_hold, "Keep CLI transcript writes undrawn until released, then draw once"),
    plain!("editor_status", Device, crate::host::editor_status, "Show or hide the CLI's status line row (shown while a run is in flight)"),
    plain!("editor_footer", Device, crate::host::editor_footer, "Set the hint row under the CLI's input box"),
    plain!("editor_wakes", Device, crate::host::editor_wakes, "Set the CLI's self-wake row, one line above the session status bar"),
    plain!("editor_notice", Device, crate::host::editor_notice, "Set the CLI's update notice row, between the input box and the session status bar"),
    plain!("input_commands", Device, crate::host::input_commands, "Set the commands the CLI's slash menu offers"),
    plain!("input_held", Device, crate::host::input_held, "List lines the CLI took but holds as still queued above its status line"),
    plain!("input_take", Device, crate::host::input_take, "Take lines the reader buffered while a run was in flight"),
    plain!("transcript_copy_first", Device, crate::host::transcript_copy_first, "Make the current transcript block's first line copyable (a code block's script)"),
    plain!("link_span", ReadOnly, crate::host::link_span, "The first bare URL in a line as start,stop (1-based byte offsets): the one detector the renderer underlines and a click copies"),
    plain!("keybindings", ReadOnly, crate::host::keybindings, "Every special key the editor and console handle, generated from the table they dispatch on: surface, group, key and what it does"),
    plain!("input_image", Device, crate::host::input_image, "The image pasted with Ctrl+V as [Image #n] in this session (mime + base64)"),
    plain!("input_stop", Device, crate::host::input_stop, "Stop the console line reader"),
    plain!("input_idle", Device, crate::host::input_idle, "Whether the CLI could restart now: empty draft, no panel, nothing queued, no selection"),
    plain!("binary_changed", ReadOnly, crate::host::binary_changed, "Whether this process's wa binary was replaced on disk since it started"),
    plain!("cli_reexec", RunsProcess, crate::host::cli_reexec, "Replace the interactive CLI process with the installed wa binary (restart into a session)"),
    plain!("stream", Device, crate::host::stream, "Push one server-sent event to the connected UI page"),
];
