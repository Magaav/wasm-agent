//! The one table of the console's keys: every special key it handles, what the key does, where it
//! applies, and the exact bytes the terminal sends for it.
//!
//! Why a table. The keys used to be decided in five places - `terminal_editor::Editor::feed_key`'s
//! match on control bytes and escape sequences, its `menu_key`, `transcript::NavDecoder`,
//! `terminal_editor::Panel::feed` and the host's pointer routing in
//! `wa-capabilities/src/host.rs` - and nothing anywhere listed them. A reader asking "what does
//! Ctrl+X do" had three options: read four files, press it, or ask a model; and a list written by
//! hand beside four dispatchers is a list that is wrong the first time one of them changes. So the
//! keys live here, once, and the dispatchers *read this table*:
//!
//! - [`draft_byte`] / [`draft_seq`] / [`draft_prefix`] - the draft's text area
//!   (`terminal_editor::Editor::feed`),
//! - [`menu_seq`] / [`menu_byte`] - the slash menu (`terminal_editor::Editor::menu_key`),
//! - [`nav_seq`] / [`nav_byte`] - the transcript's blocks (`transcript::NavDecoder`),
//! - [`panel_seq`] / [`panel_byte`] / [`panel_digit`] / [`panel_letter`] - a panel page
//!   (`terminal_editor::Panel::feed`),
//! - [`gestures`] - the pointer (`wa-capabilities/src/host.rs`, `handle_mouse`), in the table's own
//!   precedence order, so a press a link claims is a link copy because the table says so,
//! - [`console_byte`] - the keys the reader thread takes before the draft (Ctrl+O, Ctrl+C on a
//!   transcript selection, Esc),
//! - [`rows_for`] - the same rows, rendered: `/keybindings` prints exactly this, so the list a
//!   reader is shown cannot disagree with the bytes the console obeys.
//!
//! The fullscreen console's keys are the sixth source and stay where they belong
//! (`scroll::settings`): they are an operator's setting (`WA_TUI_KEYS`), not a constant, so the
//! rows here are *generated from the live settings* rather than copied.
//!
//! A row carries the surface it applies in, its group inside that surface, the key as a reader says
//! it (`Ctrl+X`), the trigger the dispatcher matches, the act the dispatcher performs, and one line
//! of what it does. `every_act_has_a_row` and `every_row_is_dispatched` below are the two
//! directions of one promise: an act with no row is a key nobody can look up, and a row with no
//! dispatch is a list that lies.

use crate::scroll::settings::{Action as ScrollAction, Settings};

/// Where a key applies: the surface the reader is in when it does something.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub enum Surface { Draft, Menu, Transcript, Fullscreen, Panel, Mouse, Console }

impl Surface {
    /// Every surface, in the order `/keybindings` lists them: the text area first (it is where a
    /// reader types), then the things a key opens, then the pointer and the reader thread.
    pub const ALL: &'static [Surface] = &[
        Surface::Draft, Surface::Menu, Surface::Transcript, Surface::Fullscreen, Surface::Panel,
        Surface::Mouse, Surface::Console,
    ];

    /// The id a rendered row carries (`"draft"`), for a caller that groups them.
    pub fn id(self) -> &'static str {
        match self {
            Surface::Draft => "draft", Surface::Menu => "menu",
            Surface::Transcript => "transcript", Surface::Fullscreen => "fullscreen",
            Surface::Panel => "panel", Surface::Mouse => "mouse", Surface::Console => "console",
        }
    }

    /// The heading `/keybindings` prints above the surface's groups.
    pub fn title(self) -> &'static str {
        match self {
            Surface::Draft => "Text area (the draft)",
            Surface::Menu => "Slash menu (a / at the start of the draft)",
            Surface::Transcript => "Transcript (Ctrl+Up from the draft)",
            Surface::Fullscreen => "Fullscreen console (WA_TUI_KEYS)",
            Surface::Panel => "Panels (a page over the box)",
            Surface::Mouse => "Mouse",
            Surface::Console => "Taken before the draft (the reader thread)",
        }
    }

    pub fn parse(id: &str) -> Option<Surface> {
        Surface::ALL.iter().copied().find(|surface| surface.id() == id.trim().to_ascii_lowercase())
    }
}

/// What a key does to the draft. One variant per behaviour the editor has; `Editor::perform`
/// matches on it exhaustively, so a variant with no behaviour does not compile and a behaviour the
/// table does not name cannot be reached by a key.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DraftAct {
    /// Send the draft (`!cmd` runs the line here as a bash command).
    Submit,
    /// Send the draft NOW: the same line as Submit, with the reader saying that this one may end
    /// the wait a run is in (Ctrl+Enter, and Ctrl+G for a terminal whose Ctrl+Enter arrives as a
    /// plain Enter). Between runs it is Submit; see docs/HOST.md, "A line typed during a run".
    SubmitNow,
    /// A new line in the draft, without sending it.
    Newline,
    /// Close the slash menu, leave bash mode; the console decides what a bare Esc means.
    Escape,
    /// The selection to the clipboard, else interrupt the run, else the quitting notice.
    Interrupt,
    /// The selection to the clipboard (OSC 52).
    Copy,
    /// Delete the selection, else the character after the cursor.
    DeleteForward,
    /// Delete the selection, else the character before the cursor.
    Backspace,
    /// Delete after the cursor; on an empty draft, leave the session.
    DeleteForwardOrLeave,
    /// The selection, or else to the end of the line.
    KillLine,
    /// The selection, or else back to the start of the line.
    KillToStart,
    /// The selection, or else the word before the cursor.
    KillWord,
    SelectAll,
    Undo, Redo,
    /// The system clipboard read once: its text at the cursor, or an image as `[Image #n]`.
    Paste,
    PasteStart, PasteEnd,
    Left, Right, Up, Down,
    LineStart, LineEnd, DocStart, DocEnd,
    ExtendLeft, ExtendRight, ExtendUp, ExtendDown, ExtendLineStart, ExtendLineEnd,
    HistoryPrev, HistoryNext,
    PageUp, PageDown, Bottom, Nav,
    /// The first `!` of an empty draft: the line is a shell command.
    BashMode,
    /// Any other printable character: it goes into the draft at the cursor.
    Type,
}

impl DraftAct {
    pub const ALL: &'static [DraftAct] = &[
        DraftAct::Submit, DraftAct::SubmitNow, DraftAct::Newline, DraftAct::Escape,
        DraftAct::Interrupt, DraftAct::Copy,
        DraftAct::DeleteForward, DraftAct::Backspace, DraftAct::DeleteForwardOrLeave,
        DraftAct::KillLine, DraftAct::KillToStart, DraftAct::KillWord, DraftAct::SelectAll,
        DraftAct::Undo, DraftAct::Redo, DraftAct::Paste, DraftAct::PasteStart,
        DraftAct::PasteEnd, DraftAct::Left, DraftAct::Right, DraftAct::Up, DraftAct::Down,
        DraftAct::LineStart, DraftAct::LineEnd, DraftAct::DocStart, DraftAct::DocEnd,
        DraftAct::ExtendLeft, DraftAct::ExtendRight, DraftAct::ExtendUp, DraftAct::ExtendDown,
        DraftAct::ExtendLineStart, DraftAct::ExtendLineEnd, DraftAct::HistoryPrev,
        DraftAct::HistoryNext, DraftAct::PageUp, DraftAct::PageDown, DraftAct::Bottom,
        DraftAct::Nav, DraftAct::BashMode, DraftAct::Type,
    ];
}

/// What a key does to the slash menu.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MenuAct { MovePrev, MoveNext, Complete, Run }

impl MenuAct {
    pub const ALL: &'static [MenuAct] = &[MenuAct::MovePrev, MenuAct::MoveNext, MenuAct::Complete, MenuAct::Run];
}

/// What a key does to a block in the transcript (what Ctrl+Up reaches).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum NavAct { Prev, Next, Expand, Fold, PageUp, PageDown, Bottom, Pin, Back }

impl NavAct {
    pub const ALL: &'static [NavAct] = &[
        NavAct::Prev, NavAct::Next, NavAct::Expand, NavAct::Fold, NavAct::PageUp, NavAct::PageDown,
        NavAct::Bottom, NavAct::Pin, NavAct::Back,
    ];
}

/// What a key does to a panel page.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PanelAct { Prev, Next, Back, Choose, Cancel, ChooseDigit, ChooseLetter, Backspace, ClearField }

impl PanelAct {
    pub const ALL: &'static [PanelAct] = &[
        PanelAct::Prev, PanelAct::Next, PanelAct::Back, PanelAct::Choose, PanelAct::Cancel,
        PanelAct::ChooseDigit, PanelAct::ChooseLetter, PanelAct::Backspace, PanelAct::ClearField,
    ];
}

/// What the pointer does. The host resolves a pointer event into one of these and performs it; the
/// table lists them in the order it tries them (a link claims a press before a selection does).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Gesture {
    /// A press in the scrollbar's column: jump there and grab the thumb (a drag moves it).
    BarJump,
    /// A press in the draft's rows: the cursor goes there (a drag from there selects).
    DraftPress,
    /// A press on a folded result: open it, or fold it again.
    ExpandToggle,
    /// A press on a URL: copy it.
    LinkCopy,
    /// A press on a block's copy icon: copy that block's text.
    BlockCopy,
    /// A press in the transcript: start selecting there.
    TranscriptSelection,
    /// A drag: select from where the press landed to the pointer.
    SelectDrag,
    /// The wheel: scroll the transcript.
    Wheel,
    /// A pointer that is only moving: say what it is over.
    Hover,
}

impl Gesture {
    pub const ALL: &'static [Gesture] = &[
        Gesture::BarJump, Gesture::DraftPress, Gesture::ExpandToggle, Gesture::LinkCopy,
        Gesture::BlockCopy, Gesture::TranscriptSelection, Gesture::SelectDrag, Gesture::Wheel,
        Gesture::Hover,
    ];
}

/// The pointer event a gesture belongs to: the table lists a gesture once per event kind, which is
/// what lets the host ask "which gestures does a press mean, and in which order".
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pose { Press, Drag, Release, Wheel, Motion }

impl Pose {
    pub const ALL: &'static [Pose] = &[Pose::Press, Pose::Drag, Pose::Release, Pose::Wheel, Pose::Motion];
}

/// The keys the reader thread takes before the draft gets them.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HostAct {
    /// Pin the focused block (a code-mode block stays open under the next one).
    Pin,
    /// Copy the text selected in the transcript.
    CopySelection,
    /// Esc with nothing after it: leave the page, the blocks or the menu, or interrupt the run.
    Escape,
}

impl HostAct {
    pub const ALL: &'static [HostAct] = &[HostAct::Pin, HostAct::CopySelection, HostAct::Escape];
}

/// Every act of every surface, as one value: what a row carries.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Act { Draft(DraftAct), Menu(MenuAct), Nav(NavAct), Panel(PanelAct), Mouse(Pose, Gesture), Host(HostAct) }

/// What the dispatcher matches a row on.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Trigger {
    /// One byte: a control key, Enter, or a printable key that has its own meaning (`!`).
    Byte(u8),
    /// An escape sequence, exactly as the terminal sends it.
    Seq(&'static [u8]),
    /// The digits 1-9, which a panel page offers as one-key choices.
    Digits,
    /// A letter the page itself named (`keys` in the spec): `[e]` edits, `[r]` rejects.
    Letters,
    /// A pointer gesture, on the event kind it belongs to.
    Gesture(Pose, Gesture),
    /// Any other printable character: the fall-through every text field needs.
    Typed,
}

/// One row of the table: a key, where it applies, what it does, and how it is matched.
#[derive(Clone, Copy)]
pub struct Binding {
    pub surface: Surface,
    /// The group `/keybindings` lists it under, inside its surface.
    pub group: &'static str,
    /// The key as a reader says it.
    pub key: &'static str,
    pub trigger: Trigger,
    pub act: Act,
    /// One line: what the key does.
    pub does: &'static str,
}

const fn d(group: &'static str, key: &'static str, trigger: Trigger, act: DraftAct, does: &'static str) -> Binding {
    Binding { surface: Surface::Draft, group, key, trigger, act: Act::Draft(act), does }
}
const fn m(group: &'static str, key: &'static str, trigger: Trigger, act: MenuAct, does: &'static str) -> Binding {
    Binding { surface: Surface::Menu, group, key, trigger, act: Act::Menu(act), does }
}
const fn t(group: &'static str, key: &'static str, trigger: Trigger, act: NavAct, does: &'static str) -> Binding {
    Binding { surface: Surface::Transcript, group, key, trigger, act: Act::Nav(act), does }
}
const fn p(group: &'static str, key: &'static str, trigger: Trigger, act: PanelAct, does: &'static str) -> Binding {
    Binding { surface: Surface::Panel, group, key, trigger, act: Act::Panel(act), does }
}
const fn g(key: &'static str, pose: Pose, gesture: Gesture, does: &'static str) -> Binding {
    Binding { surface: Surface::Mouse, group: "Pointer", key, trigger: Trigger::Gesture(pose, gesture), act: Act::Mouse(pose, gesture), does }
}
const fn c(group: &'static str, key: &'static str, byte: u8, act: HostAct, does: &'static str) -> Binding {
    Binding { surface: Surface::Console, group, key, trigger: Trigger::Byte(byte), act: Act::Host(act), does }
}

/// The table. Written out rather than generated: this file is the document a reader opens to learn
/// what a key does, so it has to read like one.
pub const BINDINGS: &[Binding] = &[
    // ---- the draft: sending a line ---------------------------------------------------------
    d("Sending", "Enter", Trigger::Byte(b'\r'), DraftAct::Submit,
      "send the draft; a `!cmd` line is run here as a bash command"),
    d("Sending", "Ctrl+Enter", Trigger::Seq(b"\x1b[13;5u"), DraftAct::SubmitNow,
      "send the draft NOW: during a run this one ends the wait the run is in and is answered at once (Enter alone is queued and never interrupts)"),
    d("Sending", "Ctrl+Enter", Trigger::Seq(b"\x1b[27;5;13~"), DraftAct::SubmitNow,
      "the same, as an xterm's modifyOtherKeys reports it"),
    d("Sending", "Ctrl+G", Trigger::Byte(7), DraftAct::SubmitNow,
      "the same send-now, for a terminal whose Ctrl+Enter arrives as a plain Enter"),
    d("Sending", "Ctrl+J, Shift+Enter", Trigger::Byte(b'\n'), DraftAct::Newline,
      "a new line in the draft, without sending it"),
    d("Sending", "Shift+Enter", Trigger::Seq(b"\x1b\r"), DraftAct::Newline,
      "the same new line, as a terminal that sends it as ESC CR reports it (Orca, kitty)"),
    d("Sending", "Shift+Enter", Trigger::Seq(b"\x1b\n"), DraftAct::Newline,
      "and the same, as the older form sends it"),
    d("Sending", "Shift+Enter", Trigger::Seq(b"\x1b[13;2u"), DraftAct::Newline,
      "and the same, as the kitty keyboard protocol reports it"),
    d("Sending", "Shift+Enter", Trigger::Seq(b"\x1b[27;2;13~"), DraftAct::Newline,
      "and the same, as an xterm reports it"),
    d("Sending", "Shift+Enter", Trigger::Seq(b"\x1b[13;2~"), DraftAct::Newline,
      "and the same, as a third terminal reports it"),
    d("Sending", "Esc", Trigger::Byte(0x1b), DraftAct::Escape,
      "close the slash menu, leave bash mode; with nothing to close the console decides (see Esc under Taken before the draft)"),
    d("Sending", "Esc Esc", Trigger::Seq(b"\x1b\x1b"), DraftAct::Escape,
      "one Esc, for a terminal that sends the key twice"),
    d("Sending", "!", Trigger::Byte(b'!'), DraftAct::BashMode,
      "on an empty draft: the line is run here as a bash command, its output kept as context"),

    // ---- the draft: running a turn ---------------------------------------------------------
    d("Running a turn", "Ctrl+C", Trigger::Byte(3), DraftAct::Interrupt,
      "copy the selection; otherwise interrupt the run, or say how to quit - a second press on an empty draft leaves"),
    d("Running a turn", "Ctrl+Insert", Trigger::Seq(b"\x1b[2;5~"), DraftAct::Copy,
      "copy the selection to the system clipboard (OSC 52, so it works over ssh)"),

    // ---- the draft: editing ----------------------------------------------------------------
    d("Editing", "Backspace", Trigger::Byte(8), DraftAct::Backspace,
      "delete the selection, or the character before the cursor (it leaves bash mode on an empty draft)"),
    d("Editing", "Backspace", Trigger::Byte(127), DraftAct::Backspace, "the same, as the terminal's DEL byte"),
    d("Editing", "Delete", Trigger::Seq(b"\x1b[3~"), DraftAct::DeleteForward,
      "delete the selection, or the character after the cursor"),
    d("Editing", "Ctrl+D", Trigger::Byte(4), DraftAct::DeleteForwardOrLeave,
      "delete after the cursor; on an empty draft, leave the session"),
    d("Editing", "Ctrl+K", Trigger::Byte(11), DraftAct::KillLine,
      "kill the selection, or else the rest of the line"),
    d("Editing", "Ctrl+U", Trigger::Byte(21), DraftAct::KillToStart,
      "kill the selection, or else everything before the cursor on the line"),
    d("Editing", "Ctrl+W", Trigger::Byte(23), DraftAct::KillWord,
      "kill the selection, or else the word before the cursor"),
    d("Editing", "a character", Trigger::Typed, DraftAct::Type,
      "any other key: the character goes into the draft at the cursor, replacing the selection"),

    // ---- the draft: the selection ----------------------------------------------------------
    d("Selection", "Ctrl+A", Trigger::Byte(1), DraftAct::SelectAll,
      "select the whole draft (Ctrl+C or Ctrl+Insert then copies it)"),
    d("Selection", "Shift+Left", Trigger::Seq(b"\x1b[1;2D"), DraftAct::ExtendLeft,
      "extend the selection one character left"),
    d("Selection", "Shift+Right", Trigger::Seq(b"\x1b[1;2C"), DraftAct::ExtendRight,
      "extend the selection one character right"),
    d("Selection", "Shift+Up", Trigger::Seq(b"\x1b[1;2A"), DraftAct::ExtendUp,
      "extend the selection a line up, or to the start of the line"),
    d("Selection", "Shift+Down", Trigger::Seq(b"\x1b[1;2B"), DraftAct::ExtendDown,
      "extend the selection a line down, or to the end of the line"),
    d("Selection", "Shift+Home", Trigger::Seq(b"\x1b[1;2H"), DraftAct::ExtendLineStart,
      "extend the selection to the start of the line"),
    d("Selection", "Shift+End", Trigger::Seq(b"\x1b[1;2F"), DraftAct::ExtendLineEnd,
      "extend the selection to the end of the line"),

    // ---- the draft: moving -----------------------------------------------------------------
    d("Moving", "Left", Trigger::Seq(b"\x1b[D"), DraftAct::Left,
      "one character left (a selection ends at its near edge)"),
    d("Moving", "Right", Trigger::Seq(b"\x1b[C"), DraftAct::Right,
      "one character right (a selection ends at its far edge)"),
    d("Moving", "Up", Trigger::Seq(b"\x1b[A"), DraftAct::Up,
      "the line above in the draft; at its top, the previous line from the history"),
    d("Moving", "Down", Trigger::Seq(b"\x1b[B"), DraftAct::Down,
      "the line below in the draft; at its bottom, the next line from the history"),
    d("Moving", "Home", Trigger::Seq(b"\x1b[H"), DraftAct::LineStart,
      "the start of the line the cursor is on (not of the whole draft)"),
    d("Moving", "Home", Trigger::Seq(b"\x1b[1~"), DraftAct::LineStart, "the same, as xterm sends it"),
    d("Moving", "End", Trigger::Seq(b"\x1b[F"), DraftAct::LineEnd, "the end of the line the cursor is on"),
    d("Moving", "End", Trigger::Seq(b"\x1b[4~"), DraftAct::LineEnd, "the same, as xterm sends it"),
    d("Moving", "Ctrl+Home", Trigger::Seq(b"\x1b[1;5H"), DraftAct::DocStart, "the start of the whole draft"),
    d("Moving", "Ctrl+End", Trigger::Seq(b"\x1b[1;5F"), DraftAct::DocEnd, "the end of the whole draft"),
    d("Moving", "Ctrl+E", Trigger::Byte(5), DraftAct::LineEnd, "the end of the line (the readline spelling)"),

    // ---- the draft: history ----------------------------------------------------------------
    d("History", "Ctrl+P", Trigger::Byte(16), DraftAct::HistoryPrev, "the previous line from this session's history"),
    d("History", "Ctrl+N", Trigger::Byte(14), DraftAct::HistoryNext, "the next line from the history"),

    // ---- the draft: undo and redo ----------------------------------------------------------
    d("Undo and redo", "Ctrl+Z", Trigger::Byte(26), DraftAct::Undo, "undo the last change to the draft"),
    d("Undo and redo", "Ctrl+Z", Trigger::Seq(b"\x1b[122;5u"), DraftAct::Undo,
      "the same, as the kitty keyboard protocol reports it"),
    d("Undo and redo", "Ctrl+Y", Trigger::Byte(25), DraftAct::Redo, "redo the change Ctrl+Z took back"),
    d("Undo and redo", "Ctrl+Y", Trigger::Seq(b"\x1b[121;5u"), DraftAct::Redo,
      "the same, as the kitty keyboard protocol reports it"),
    d("Undo and redo", "Ctrl+X", Trigger::Byte(24), DraftAct::Redo,
      "redo as well - by design (operator 18/11); Ctrl+Y does the same, and a test asserts it"),
    d("Undo and redo", "Ctrl+X", Trigger::Seq(b"\x1b[120;5u"), DraftAct::Redo,
      "the same, as the kitty keyboard protocol reports it (foot sends Ctrl+V this way)"),
    d("Undo and redo", "Ctrl+Shift+Z", Trigger::Seq(b"\x1b[122;6u"), DraftAct::Redo,
      "redo, the other spelling of it"),
    d("Undo and redo", "Ctrl+Shift+Z", Trigger::Seq(b"\x1b[90;6u"), DraftAct::Redo,
      "the same, as a terminal that reports the shifted letter reports it"),

    // ---- the draft: paste and images -------------------------------------------------------
    d("Paste and images", "Ctrl+V", Trigger::Byte(22), DraftAct::Paste,
      "paste text or an image from the system clipboard: the text at the cursor, an image as `[Image #n]` sent with this message"),
    d("Paste and images", "Ctrl+V", Trigger::Seq(b"\x1b[118;5u"), DraftAct::Paste,
      "the same, as the kitty keyboard protocol reports it"),
    d("Paste and images", "a paste", Trigger::Seq(b"\x1b[200~"), DraftAct::PasteStart,
      "a bracketed paste: its newlines stay lines and the paste is one undo step"),
    d("Paste and images", "a paste", Trigger::Seq(b"\x1b[201~"), DraftAct::PasteEnd,
      "the paste ended; a path dropped there is attached as an image"),

    // ---- the draft: the transcript ---------------------------------------------------------
    d("The transcript", "Ctrl+Up", Trigger::Seq(b"\x1b[1;5A"), DraftAct::Nav,
      "leave the draft for the transcript's blocks (Up/Down walk them, Esc returns)"),
    d("The transcript", "PageUp", Trigger::Seq(b"\x1b[5~"), DraftAct::PageUp,
      "the transcript a page back (the draft keeps the keys)"),
    d("The transcript", "PageDown", Trigger::Seq(b"\x1b[6~"), DraftAct::PageDown,
      "the transcript a page forward"),
    d("The transcript", "Ctrl+PageDown", Trigger::Seq(b"\x1b[6;5~"), DraftAct::Bottom,
      "back to the live bottom of the transcript"),

    // ---- the slash menu --------------------------------------------------------------------
    m("The menu", "Up", Trigger::Seq(b"\x1b[A"), MenuAct::MovePrev, "the command above in the list"),
    m("The menu", "Down", Trigger::Seq(b"\x1b[B"), MenuAct::MoveNext, "the command below in the list"),
    m("The menu", "Tab", Trigger::Byte(b'\t'), MenuAct::Complete,
      "complete the selected command; one that takes arguments leaves the cursor after a space"),
    m("The menu", "Enter", Trigger::Byte(b'\r'), MenuAct::Run,
      "run the selected command (one that takes arguments is completed first so they can be typed)"),

    // ---- the transcript's blocks -----------------------------------------------------------
    t("The blocks", "Up", Trigger::Seq(b"\x1b[A"), NavAct::Prev, "the block above"),
    t("The blocks", "Down", Trigger::Seq(b"\x1b[B"), NavAct::Next,
      "the block below; at the last one, back to the live transcript"),
    t("The blocks", "Right", Trigger::Seq(b"\x1b[C"), NavAct::Expand, "open the focused block"),
    t("The blocks", "Left", Trigger::Seq(b"\x1b[D"), NavAct::Fold, "fold the focused block"),
    t("The blocks", "Ctrl+O", Trigger::Byte(0x0f), NavAct::Pin,
      "pin the focused block open, so the next one does not collapse it; again lets it go"),
    t("The blocks", "PageUp", Trigger::Seq(b"\x1b[5~"), NavAct::PageUp, "a page back"),
    t("The blocks", "PageDown", Trigger::Seq(b"\x1b[6~"), NavAct::PageDown, "a page forward"),
    t("The blocks", "Ctrl+PageDown", Trigger::Seq(b"\x1b[6;5~"), NavAct::Bottom, "back to the live bottom"),
    t("The blocks", "Enter, Ctrl+C", Trigger::Byte(b'\r'), NavAct::Back, "back to the draft"),
    t("The blocks", "Enter, Ctrl+C", Trigger::Byte(3), NavAct::Back, "the same, for the interrupt key"),
    t("The blocks", "Esc", Trigger::Byte(0x1b), NavAct::Back, "back to the draft, the transcript where you left it"),

    // ---- a panel page ----------------------------------------------------------------------
    p("Choosing", "Up", Trigger::Seq(b"\x1b[A"), PanelAct::Prev, "the option above"),
    p("Choosing", "Up", Trigger::Seq(b"\x1bOA"), PanelAct::Prev, "the same, in the terminal's application mode"),
    p("Choosing", "Down", Trigger::Seq(b"\x1b[B"), PanelAct::Next, "the option below"),
    p("Choosing", "Down", Trigger::Seq(b"\x1bOB"), PanelAct::Next, "the same, in the terminal's application mode"),
    p("Choosing", "1-9", Trigger::Digits, PanelAct::ChooseDigit, "choose that numbered option"),
    p("Choosing", "a letter the page names", Trigger::Letters, PanelAct::ChooseLetter,
      "the shortcut the page offers ([e] edits, [r] rejects); a page names its own"),
    p("Choosing", "Enter", Trigger::Byte(b'\r'), PanelAct::Choose,
      "type the field's text into the page, choose the selected option, or close a page that only shows something"),
    p("Choosing", "Enter", Trigger::Byte(b'\n'), PanelAct::Choose, "the same, as the line-feed form"),
    p("Leaving", "Esc", Trigger::Seq(b"\x1b\x1b"), PanelAct::Cancel,
      "cancel the page and go back (the terminal's lone Esc, and Esc twice, take the same act)"),
    p("Leaving", "Left", Trigger::Seq(b"\x1b[D"), PanelAct::Back,
      "back, as Esc does - unless the field has text to edit"),
    p("Leaving", "Left", Trigger::Seq(b"\x1bOD"), PanelAct::Back, "the same, in the terminal's application mode"),
    p("Typing", "Backspace", Trigger::Byte(8), PanelAct::Backspace, "delete the last character of the field"),
    p("Typing", "Backspace", Trigger::Byte(127), PanelAct::Backspace, "the same, as the terminal's DEL byte"),
    p("Typing", "Ctrl+U", Trigger::Byte(21), PanelAct::ClearField, "clear the field"),

    // ---- the pointer -----------------------------------------------------------------------
    g("Press", Pose::Press, Gesture::BarJump,
      "press the scrollbar's column: jump the view to that row and grab the thumb"),
    g("Press", Pose::Press, Gesture::DraftPress,
      "press in the draft: the cursor goes there, and a drag from there selects"),
    g("Press", Pose::Press, Gesture::ExpandToggle,
      "press a folded result: open it, or fold it again"),
    g("Press", Pose::Press, Gesture::LinkCopy, "press a link: copy that URL to the clipboard"),
    g("Press", Pose::Press, Gesture::BlockCopy,
      "press a block's copy icon (⧉): copy that block's text"),
    g("Press", Pose::Press, Gesture::TranscriptSelection, "press the transcript: start a selection there"),
    g("Dragging", Pose::Drag, Gesture::SelectDrag,
      "drag: select from where the press landed to the pointer (the draft, or the transcript)"),
    g("Dragging", Pose::Drag, Gesture::BarJump, "drag the thumb: scroll to where it is dragged"),
    g("Dragging", Pose::Release, Gesture::BarJump, "release the thumb: the view stays where it was dragged"),
    g("Dragging", Pose::Release, Gesture::SelectDrag,
      "release: the selection stays, and Ctrl+C copies it"),
    g("Scrolling", Pose::Wheel, Gesture::Wheel, "the wheel: one row of the chat per event, so one notch is a few lines (your terminal's scrollback multiplier: seven with the 7.0 in foot.ini); over an input box with more lines than it shows: the draft"),
    g("Hovering", Pose::Motion, Gesture::Hover,
      "move the pointer: a row that answers a click brightens, and the bar's thumb thickens"),

    // ---- taken before the draft ------------------------------------------------------------
    c("The run", "Ctrl+O", 0x0f, HostAct::Pin,
      "pin the focused block open (the draft has no Ctrl+O; the transcript's own Pin is the same act)"),
    c("A selection", "Ctrl+C", 3, HostAct::CopySelection,
      "copy the text selected in the transcript, instead of interrupting the run"),
    c("Leaving", "Esc", 0x1b, HostAct::Escape,
      "close the page over the box, leave the transcript's blocks, close the slash menu, or interrupt the run"),
];

fn rows_of(surface: Surface) -> impl Iterator<Item = &'static Binding> {
    BINDINGS.iter().filter(move |binding| binding.surface == surface)
}

/// The act one byte performs in the draft, read from the table.
pub fn draft_byte(byte: u8) -> Option<DraftAct> {
    rows_of(Surface::Draft).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Byte(own), Act::Draft(act)) if own == byte => Some(act),
        _ => None,
    })
}

/// The act one escape sequence performs in the draft, read from the table.
pub fn draft_seq(sequence: &[u8]) -> Option<DraftAct> {
    rows_of(Surface::Draft).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Seq(own), Act::Draft(act)) if own == sequence => Some(act),
        _ => None,
    })
}

/// Whether a sequence still arriving could become one of the draft's keys. False means no row can
/// ever match it: the draft's decoder then swallows it whole instead of typing its bytes.
pub fn draft_prefix(sequence: &[u8]) -> bool {
    // An application-mode sequence nobody binds (ESC O ...): its remaining bytes must be swallowed,
    // never typed - the same rule an unknown CSI gets below.
    if sequence == b"\x1bO" { return true; }
    rows_of(Surface::Draft).any(|binding| match binding.trigger {
        Trigger::Seq(own) => own.len() > sequence.len() && own.starts_with(sequence),
        _ => false,
    })
}

/// The act an escape sequence performs in the slash menu.
pub fn menu_seq(sequence: &[u8]) -> Option<MenuAct> {
    rows_of(Surface::Menu).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Seq(own), Act::Menu(act)) if own == sequence => Some(act),
        _ => None,
    })
}

/// The act one byte performs in the slash menu.
pub fn menu_byte(byte: u8) -> Option<MenuAct> {
    rows_of(Surface::Menu).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Byte(own), Act::Menu(act)) if own == byte => Some(act),
        _ => None,
    })
}

/// The act one escape sequence performs on the transcript's blocks. The arrows are matched on their
/// final letter whatever modifier the terminal added: Shift+Up reaches the same block as Up, which is
/// what this decoder did before the table and what a reader pressing it means.
pub fn nav_seq(sequence: &[u8]) -> Option<NavAct> {
    if sequence.len() < 3 { return None; }
    let last = *sequence.last()?;
    let params = &sequence[2..sequence.len() - 1];
    let arrow = matches!(last, b'A' | b'B' | b'C' | b'D');
    rows_of(Surface::Transcript).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Seq(own), Act::Nav(act)) if own.len() >= 3 && *own.last()? == last => {
            if arrow { Some(act) }
            else if &own[2..own.len() - 1] == params { Some(act) }
            else { None }
        }
        _ => None,
    })
}

/// The act one byte performs on the transcript's blocks.
pub fn nav_byte(byte: u8) -> Option<NavAct> {
    rows_of(Surface::Transcript).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Byte(own), Act::Nav(act)) if own == byte => Some(act),
        _ => None,
    })
}

/// The act an escape sequence performs on a panel page.
pub fn panel_seq(sequence: &[u8]) -> Option<PanelAct> {
    rows_of(Surface::Panel).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Seq(own), Act::Panel(act)) if own == sequence => Some(act),
        _ => None,
    })
}

/// The act one byte performs on a panel page.
pub fn panel_byte(byte: u8) -> Option<PanelAct> {
    rows_of(Surface::Panel).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Byte(own), Act::Panel(act)) if own == byte => Some(act),
        _ => None,
    })
}

/// The act the digits 1-9 perform on a panel page, when the page offers that many options.
pub fn panel_digit(byte: u8) -> Option<PanelAct> {
    if !(b'1'..=b'9').contains(&byte) { return None; }
    rows_of(Surface::Panel).find_map(|binding| match binding.act {
        Act::Panel(act @ PanelAct::ChooseDigit) => Some(act),
        _ => None,
    })
}

/// The act a letter the page named performs on a panel page.
pub fn panel_letter() -> Option<PanelAct> {
    rows_of(Surface::Panel).find_map(|binding| match binding.act {
        Act::Panel(act @ PanelAct::ChooseLetter) => Some(act),
        _ => None,
    })
}

/// The act one byte performs before the draft gets it (Ctrl+O, Ctrl+C on a selection, Esc).
pub fn console_byte(byte: u8) -> Option<HostAct> {
    rows_of(Surface::Console).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Byte(own), Act::Host(act)) if own == byte => Some(act),
        _ => None,
    })
}

/// The byte Esc arrives as, so the console can ask the table before it decides what a lone Esc means.
pub fn console_escape() -> Option<u8> {
    rows_of(Surface::Console).find_map(|binding| match (binding.trigger, binding.act) {
        (Trigger::Byte(own), Act::Host(HostAct::Escape)) => Some(own),
        _ => None,
    })
}

/// The pointer gestures one event means, in the order the host must try them.
pub fn gestures(pose: Pose) -> Vec<Gesture> {
    rows_of(Surface::Mouse).filter_map(|binding| match binding.act {
        Act::Mouse(own, gesture) if own == pose => Some(gesture),
        _ => None,
    }).collect()
}

// ---- the rows, rendered --------------------------------------------------------------------

/// One row as `/keybindings` prints it: the surface, its group, the key, and what it does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub surface: Surface,
    pub group: &'static str,
    pub key: String,
    pub does: String,
}

/// The fullscreen console's rows, generated from the settings it actually obeys - an operator who
/// unbound PageUp reads that here, rather than a list of the defaults this build shipped with.
fn fullscreen_rows(settings: &Settings) -> Vec<Row> {
    let mut rows: Vec<Row> = Vec::new();
    for (key, action) in &settings.bindings {
        rows.push(Row { surface: Surface::Fullscreen, group: "Scroll", key: pretty_key(key), does: action.describe().to_string() });
    }
    for action in ScrollAction::ALL {
        if settings.bindings.iter().any(|(_, bound)| bound == action) { continue; }
        rows.push(Row {
            surface: Surface::Fullscreen, group: "Not bound on this node", key: String::new(),
            does: format!("{} (WA_TUI_KEYS=<key>={})", action.describe(), action.name()),
        });
    }
    rows
}

/// `ctrl+home` as a reader says it: `Ctrl+Home`.
pub fn pretty_key(name: &str) -> String {
    let word = |part: &str| match part {
        "pageup" => "PageUp".to_string(), "pagedown" => "PageDown".to_string(),
        "up" => "Up".to_string(), "down" => "Down".to_string(),
        "left" => "Left".to_string(), "right" => "Right".to_string(),
        "home" => "Home".to_string(), "end" => "End".to_string(),
        "ctrl" => "Ctrl".to_string(), "alt" => "Alt".to_string(), "shift" => "Shift".to_string(),
        other => {
            let mut chars = other.chars();
            match chars.next() { Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(), None => String::new() }
        }
    };
    name.split('+').map(word).collect::<Vec<_>>().join("+")
}

/// Every row, in surface order: the table's own rows plus the fullscreen console's live ones.
pub fn rows_for(settings: &Settings) -> Vec<Row> {
    let mut rows: Vec<Row> = Vec::new();
    for surface in Surface::ALL {
        if *surface == Surface::Fullscreen {
            rows.extend(fullscreen_rows(settings));
            continue;
        }
        for binding in rows_of(*surface) {
            rows.push(Row { surface: *surface, group: binding.group, key: binding.key.to_string(), does: binding.does.to_string() });
        }
    }
    rows
}

/// The rows as this node's console would obey them: `WA_TUI_KEYS` included.
pub fn rows() -> Vec<Row> { rows_for(&Settings::from_env(|name| std::env::var(name).ok())) }

/// The rows as JSON, the shape the `host.keybindings` capability answers: one object per row.
pub fn json() -> String {
    let rows: Vec<serde_json::Value> = rows().into_iter().map(|row| serde_json::json!({
        "surface": row.surface.id(),
        "title": row.surface.title(),
        "group": row.group,
        "key": row.key,
        "does": row.does,
    })).collect();
    serde_json::Value::Array(rows).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn triggers(surface: Surface) -> Vec<(Pose, Gesture)> {
        BINDINGS.iter().filter_map(|binding| match binding.act {
            Act::Mouse(pose, gesture) if binding.surface == surface => Some((pose, gesture)),
            _ => None,
        }).collect()
    }

    /// Direction one: an act with no row is a key no reader can look up.
    #[test]
    fn every_act_has_a_row() {
        let draft: Vec<Act> = BINDINGS.iter().map(|b| b.act).collect();
        for act in DraftAct::ALL {
            assert!(draft.contains(&Act::Draft(*act)), "the draft's {act:?} has no row in /keybindings");
        }
        for act in MenuAct::ALL { assert!(draft.contains(&Act::Menu(*act)), "the menu's {act:?} has no row"); }
        for act in NavAct::ALL { assert!(draft.contains(&Act::Nav(*act)), "the transcript's {act:?} has no row"); }
        for act in PanelAct::ALL { assert!(draft.contains(&Act::Panel(*act)), "the panel's {act:?} has no row"); }
        for act in HostAct::ALL { assert!(draft.contains(&Act::Host(*act)), "the console's {act:?} has no row"); }
        for gesture in Gesture::ALL {
            assert!(triggers(Surface::Mouse).iter().any(|(_, own)| own == gesture), "the pointer's {gesture:?} has no row");
        }
    }

    /// Direction two: a row with no dispatch is a list that lies. Every row is looked up by the
    /// surface's own dispatcher, through the same function that dispatcher calls.
    #[test]
    fn every_row_is_dispatched() {
        for binding in BINDINGS {
            let (key, does) = (binding.key, binding.does);
            match (binding.surface, binding.trigger, binding.act) {
                (Surface::Draft, Trigger::Byte(byte), Act::Draft(act)) =>
                    assert_eq!(draft_byte(byte), Some(act), "the draft's {key} ({byte}) is listed but not dispatched"),
                (Surface::Draft, Trigger::Seq(seq), Act::Draft(act)) =>
                    assert_eq!(draft_seq(seq), Some(act), "the draft's {key} ({seq:?}) is listed but not dispatched"),
                (Surface::Draft, Trigger::Typed, Act::Draft(DraftAct::Type)) => {}
                (Surface::Menu, Trigger::Byte(byte), Act::Menu(act)) =>
                    assert_eq!(menu_byte(byte), Some(act), "the menu's {key} is listed but not dispatched"),
                (Surface::Menu, Trigger::Seq(seq), Act::Menu(act)) =>
                    assert_eq!(menu_seq(seq), Some(act), "the menu's {key} is listed but not dispatched"),
                (Surface::Transcript, Trigger::Byte(byte), Act::Nav(act)) =>
                    assert_eq!(nav_byte(byte), Some(act), "the transcript's {key} is listed but not dispatched"),
                (Surface::Transcript, Trigger::Seq(seq), Act::Nav(act)) =>
                    assert_eq!(nav_seq(seq), Some(act), "the transcript's {key} is listed but not dispatched"),
                (Surface::Panel, Trigger::Byte(byte), Act::Panel(act)) =>
                    assert_eq!(panel_byte(byte), Some(act), "the panel's {key} is listed but not dispatched"),
                (Surface::Panel, Trigger::Seq(seq), Act::Panel(act)) =>
                    assert_eq!(panel_seq(seq), Some(act), "the panel's {key} ({seq:?}) is listed but not dispatched"),
                (Surface::Panel, Trigger::Digits, Act::Panel(act)) =>
                    assert_eq!(panel_digit(b'3'), Some(act), "the panel's digits are listed but not dispatched"),
                (Surface::Panel, Trigger::Letters, Act::Panel(act)) =>
                    assert_eq!(panel_letter(), Some(act), "the panel's own letters are listed but not dispatched"),
                (Surface::Console, Trigger::Byte(byte), Act::Host(act)) =>
                    assert_eq!(console_byte(byte), Some(act), "the console's {key} is listed but not dispatched"),
                (Surface::Mouse, Trigger::Gesture(pose, gesture), Act::Mouse(_, _)) =>
                    assert!(gestures(pose).contains(&gesture), "the pointer's {key} is listed but not dispatched"),
                (surface, trigger, act) => panic!("{surface:?} row {key:?} ({does:?}) has a trigger no dispatcher reads: {trigger:?} {act:?}"),
            }
        }
    }

    /// A key with two meanings in one surface is a table that cannot be obeyed: the second row would
    /// never be reached.
    #[test]
    fn no_key_has_two_acts_in_the_same_surface() {
        for surface in Surface::ALL {
            let mut seen: Vec<Trigger> = Vec::new();
            for binding in BINDINGS.iter().filter(|b| b.surface == *surface) {
                if matches!(binding.trigger, Trigger::Typed | Trigger::Digits | Trigger::Letters | Trigger::Gesture(..)) { continue; }
                assert!(!seen.contains(&binding.trigger), "{surface:?} has two rows for {:?} ({})", binding.trigger, binding.key);
                seen.push(binding.trigger);
            }
        }
    }

    /// What the draft obeys and what the list shows are the same rows, in the same order: the render
    /// is the table, not a copy of it.
    #[test]
    fn the_list_is_the_table() {
        let settings = Settings::default();
        let rows = rows_for(&settings);
        let drawn: Vec<(String, String)> = rows.iter().filter(|row| row.surface != Surface::Fullscreen)
            .map(|row| (row.key.clone(), row.does.clone())).collect();
        let table: Vec<(String, String)> = BINDINGS.iter().map(|b| (b.key.to_string(), b.does.to_string())).collect();
        assert_eq!(drawn, table, "the rendered rows are the table's rows");
        let unbound = ScrollAction::ALL.iter().filter(|action| !settings.bindings.iter().any(|(_, bound)| bound == *action)).count();
        assert_eq!(rows.len(), BINDINGS.len() + settings.bindings.len() + unbound, "the fullscreen rows are the live settings");
        for row in &rows {
            assert!(!row.does.trim().is_empty(), "{:?} {} has no sentence", row.surface, row.key);
        }
    }

    /// The fullscreen half is generated from the settings the console obeys, so an operator who
    /// unbound a key does not read it listed as a binding.
    #[test]
    fn the_fullscreen_rows_follow_the_operators_keys() {
        let settings = Settings::from_env(|name| match name {
            "WA_TUI_KEYS" => Some("pageup=none,ctrl+u=line-up".to_string()),
            _ => None,
        });
        let rows = rows_for(&settings);
        let fullscreen: Vec<&Row> = rows.iter().filter(|row| row.surface == Surface::Fullscreen).collect();
        assert!(!fullscreen.iter().any(|row| row.key == "PageUp"), "an unbound PageUp is listed as a fullscreen binding again: {fullscreen:?}");
        assert!(fullscreen.iter().any(|row| row.key == "Ctrl+U" && row.does == "scroll one row up"), "{fullscreen:?}");
        let unbound: Vec<&Row> = rows.iter().filter(|row| row.group == "Not bound on this node").collect();
        assert!(unbound.iter().any(|row| row.does.starts_with("scroll a page up") && row.does.contains("WA_TUI_KEYS=<key>=page-up")),
            "the keys an operator can still bind are listed, with the knob: {unbound:?}");
    }

    /// A key name a reader writes is a key name the list shows the way they say it.
    #[test]
    fn key_names_are_displayed_the_way_a_reader_says_them() {
        assert_eq!(pretty_key("ctrl+home"), "Ctrl+Home");
        assert_eq!(pretty_key("pageup"), "PageUp");
        assert_eq!(pretty_key("alt+v"), "Alt+V");
        assert_eq!(pretty_key("shift+up"), "Shift+Up");
        assert_eq!(pretty_key("f5"), "F5");
    }

    /// The capability's answer carries every row, surface and sentence: the CLI, the window and the
    /// JSON a tool reads all print the same list.
    #[test]
    fn the_json_carries_every_row() {
        let value: serde_json::Value = serde_json::from_str(&json()).expect("valid JSON");
        let drawn = value.as_array().expect("an array of rows");
        assert_eq!(drawn.len(), rows().len());
        for row in drawn {
            assert!(row.get("surface").and_then(|v| v.as_str()).is_some(), "{row}");
            assert!(row.get("title").and_then(|v| v.as_str()).is_some(), "{row}");
            assert!(row.get("does").and_then(|v| v.as_str()).is_some_and(|does| !does.is_empty()), "{row}");
        }
        for surface in Surface::ALL {
            assert!(rows().iter().any(|row| row.surface == *surface), "{surface:?} has no row at all");
            assert!(Surface::parse(surface.id()) == Some(*surface), "{surface:?} does not parse back from its id");
        }
    }

    /// The prefix rule the draft's decoder depends on: a sequence still arriving is waited for, and
    /// the application-mode escape nobody binds is swallowed rather than typed.
    #[test]
    fn a_sequence_still_arriving_is_a_prefix_and_nothing_else_is() {
        for binding in BINDINGS.iter().filter(|b| b.surface == Surface::Draft) {
            if let Trigger::Seq(seq) = binding.trigger {
                for cut in 1..seq.len() {
                    assert!(draft_prefix(&seq[..cut]), "{:?} is not recognised as still arriving", &seq[..cut]);
                }
                assert!(draft_seq(seq).is_some(), "{seq:?} is a row and a lookup");
            }
        }
        assert!(draft_prefix(b"\x1bO"), "the application-mode escape is swallowed, not typed");
        assert!(!draft_prefix(b"\x1bz"), "ESC z is Alt+z, not the start of a sequence");
        assert!(draft_seq(b"\x1b[A").is_some(), "Up is the draft's own key");
    }
}
