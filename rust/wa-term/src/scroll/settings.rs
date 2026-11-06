//! What the fullscreen console is told to do, and where it is told it.
//!
//! The node's config is one file - `<config>/env`, `KEY=VALUE` per line, loaded into the process
//! environment at startup (`load_env_file` in `rust/wa-host/src/main.rs`) - and the console settler
//! already reads its knobs through the environment (`WASM_AGENT_CLI_EDITOR`, `WASM_AGENT_CLI_FRAME`).
//! So this is where the new ones live, next to them, and a `~/.wasm-agent/env` line is all an
//! operator writes:
//!
//! ```text
//! WA_TUI_FULLSCREEN=on          # fullscreen transcript on the alternate screen (default on)
//! WA_TUI=inline                 # the fallback, also chosen by --inline, a pipe or a dumb terminal
//! WA_TUI_SCROLLBAR=auto         # auto | always | hidden
//! WA_TUI_WHEEL_LINES=auto       # auto | a number of rows per wheel event
//! WA_TUI_KEYS=ctrl+u=line-up,alt+v=half-page-down,pageup=none
//! ```
//!
//! `from_env` takes the getter as an argument, so the whole surface is testable without touching
//! the process environment - the same reason `cli_view` takes `getenv`.
//!
//! A key is `<name>=<action>`: the name is what the terminal sends (`pageup`, `ctrl+home`, `alt+v`,
//! `shift+down`, ...), the action is one of `page-up`, `page-down`, `half-page-up`,
//! `half-page-down`, `line-up`, `line-down`, `top`, `bottom`, `toggle-tools`, `toggle-thinking`, or
//! `none` to unbind the key. Overrides are applied on top of the defaults, so a reader changes one
//! key and keeps the rest. Anything that does not parse is kept in `warnings` and shown by the
//! caller - a knob that was ignored is not a knob that was applied.

/// Where the chat is drawn: the whole alternate screen, or the region above the input row.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode { Fullscreen, Inline }

/// The column of the fullscreen chat the scroll position is drawn in.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Scrollbar { Auto, Always, Hidden }

/// How far one wheel event scrolls.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Wheel { Auto, Lines(usize) }

/// What a key does to the chat. Only the chat: the input editor keeps its own keys.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Action {
    PageUp, PageDown, HalfPageUp, HalfPageDown, LineUp, LineDown, Top, Bottom, ToggleTools, ToggleThinking,
}

impl Action {
    /// The name an operator writes on the right of `=` in `WA_TUI_KEYS`.
    pub fn name(self) -> &'static str {
        match self {
            Action::PageUp => "page-up", Action::PageDown => "page-down",
            Action::HalfPageUp => "half-page-up", Action::HalfPageDown => "half-page-down",
            Action::LineUp => "line-up", Action::LineDown => "line-down",
            Action::Top => "top", Action::Bottom => "bottom",
            Action::ToggleTools => "toggle-tools", Action::ToggleThinking => "toggle-thinking",
        }
    }

    pub fn parse(name: &str) -> Option<Action> {
        let name = name.trim().to_ascii_lowercase();
        [Action::PageUp, Action::PageDown, Action::HalfPageUp, Action::HalfPageDown, Action::LineUp, Action::LineDown,
         Action::Top, Action::Bottom, Action::ToggleTools, Action::ToggleThinking]
            .into_iter().find(|action| action.name() == name)
    }
}

/// The key names a binding may carry: exactly the ones `keys::Decoder` can produce a name for.
pub const KEYS: &[&str] = &[
    "pageup", "pagedown", "home", "end", "ctrl+home", "ctrl+end", "up", "down", "shift+up", "shift+down",
    "ctrl+u", "ctrl+d", "ctrl+y", "alt+v", "ctrl+o", "ctrl+t", "f5", "f6",
];

/// One wheel event when `WA_TUI_WHEEL_LINES=auto`: the inline console's own step, so the wheel moves
/// the same distance in both modes.
pub const WHEEL_AUTO_ROWS: usize = 3;

#[derive(Clone, Debug)]
pub struct Settings {
    /// Whether the fullscreen transcript is wanted at all (`WA_TUI_FULLSCREEN`).
    pub fullscreen: bool,
    pub scrollbar: Scrollbar,
    pub wheel: Wheel,
    /// `(key, action)` in the order they were set; the defaults first, then the overrides.
    pub bindings: Vec<(String, Action)>,
    /// Operator settings this build could not read, in the operator's words.
    pub warnings: Vec<String>,
}

impl Default for Settings {
    /// PageUp/PageDown page, Ctrl+Home/Ctrl+End are the ends, Ctrl+O/Ctrl+T fold. Half-page and line
    /// scrolling exist and are unbound: they are the keys a reader adds, not ones this program picks
    /// for them over the input editor's own chords.
    fn default() -> Self {
        Settings {
            fullscreen: true,
            scrollbar: Scrollbar::Auto,
            wheel: Wheel::Auto,
            bindings: vec![
                ("pageup".into(), Action::PageUp), ("pagedown".into(), Action::PageDown),
                ("ctrl+home".into(), Action::Top), ("ctrl+end".into(), Action::Bottom),
                ("ctrl+o".into(), Action::ToggleTools), ("ctrl+t".into(), Action::ToggleThinking),
            ],
            warnings: Vec::new(),
        }
    }
}

impl Settings {
    /// The settings a node's environment asks for; anything unreadable stays at its default and is
    /// named in `warnings`.
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Settings {
        let mut settings = Settings::default();
        if let Some(value) = get("WA_TUI_FULLSCREEN") {
            match on_off(&value) { Some(on) => settings.fullscreen = on, None => settings.warn("WA_TUI_FULLSCREEN", &value) }
        }
        if let Some(value) = get("WA_TUI_SCROLLBAR") {
            match Scrollbar::parse(&value) { Some(bar) => settings.scrollbar = bar, None => settings.warn("WA_TUI_SCROLLBAR", &value) }
        }
        if let Some(value) = get("WA_TUI_WHEEL_LINES") {
            match Wheel::parse(&value) { Some(wheel) => settings.wheel = wheel, None => settings.warn("WA_TUI_WHEEL_LINES", &value) }
        }
        if let Some(value) = get("WA_TUI_KEYS") { settings.apply_keys(&value); }
        settings
    }

    /// Rows one wheel event scrolls at a viewport of `height`.
    pub fn wheel_rows(&self, height: usize) -> usize {
        match self.wheel { Wheel::Auto => WHEEL_AUTO_ROWS, Wheel::Lines(rows) => rows }.min(height.max(1)).max(1)
    }

    /// The action bound to a key name, if any. A key an operator unbound has none, and its bytes go
    /// back to the input editor.
    pub fn action(&self, key: &str) -> Option<Action> {
        self.bindings.iter().find(|(name, _)| name == key).map(|(_, action)| *action)
    }

    /// Apply a whole `WA_TUI_KEYS` value: `key=action,key=action`.
    pub fn apply_keys(&mut self, value: &str) {
        for entry in value.split(',').map(str::trim).filter(|entry| !entry.is_empty()) {
            let Some((key, action)) = entry.split_once('=') else { self.warn("WA_TUI_KEYS", entry); continue };
            let (key, action) = (key.trim().to_ascii_lowercase(), action.trim().to_ascii_lowercase());
            if !KEYS.contains(&key.as_str()) { self.warn("WA_TUI_KEYS", entry); continue; }
            if action == "none" || action == "unbind" { self.bindings.retain(|(name, _)| name != &key); continue; }
            match Action::parse(&action) {
                Some(action) => self.set(key, action),
                None => self.warn("WA_TUI_KEYS", entry),
            }
        }
    }

    /// Bind `key` to `action`, replacing what it was bound to.
    pub fn set(&mut self, key: impl Into<String>, action: Action) {
        let key = key.into().to_ascii_lowercase();
        match self.bindings.iter_mut().find(|(name, _)| name == &key) {
            Some(slot) => slot.1 = action,
            None => self.bindings.push((key, action)),
        }
    }

    fn warn(&mut self, name: &str, value: &str) {
        // The value may be an operator's typo, never anything secret: nothing here is a credential.
        self.warnings.push(format!("{name}: ignoring {value:?}"));
    }

    /// Where the chat is drawn. `--inline` wins over everything (an explicit flag is the reader
    /// asking for the fallback right now); `WA_TUI` next; then a terminal is needed at all; then the
    /// node's own `fullscreen` setting.
    pub fn mode(&self, args: &[String], get: impl Fn(&str) -> Option<String>, tty: bool) -> Mode {
        if args.iter().any(|arg| arg == "--inline") { return Mode::Inline; }
        match get("WA_TUI").map(|value| value.trim().to_ascii_lowercase()).as_deref() {
            Some("inline") => return Mode::Inline,
            Some("fullscreen") if tty => return Mode::Fullscreen,
            Some("fullscreen") => return Mode::Inline,
            _ => {}
        }
        if !tty || !self.fullscreen { Mode::Inline } else { Mode::Fullscreen }
    }
}

impl Scrollbar {
    pub fn parse(value: &str) -> Option<Scrollbar> {
        match value.trim().to_ascii_lowercase().as_str() {
            "auto" => Some(Scrollbar::Auto), "always" => Some(Scrollbar::Always), "hidden" => Some(Scrollbar::Hidden),
            _ => None,
        }
    }
}

impl Wheel {
    pub fn parse(value: &str) -> Option<Wheel> {
        let value = value.trim().to_ascii_lowercase();
        if value == "auto" { return Some(Wheel::Auto); }
        value.parse::<usize>().ok().filter(|n| *n > 0).map(Wheel::Lines)
    }
}

fn on_off(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "on" | "true" | "yes" => Some(true),
        "0" | "off" | "false" | "no" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let owned: Vec<(String, String)> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |name: &str| owned.iter().find(|(key, _)| key == name).map(|(_, value)| value.clone())
    }

    #[test]
    fn the_defaults_page_go_fold_and_leave_half_page_and_line_unbound() {
        let settings = Settings::from_env(env(&[]));
        assert_eq!(settings.action("pageup"), Some(Action::PageUp));
        assert_eq!(settings.action("pagedown"), Some(Action::PageDown));
        assert_eq!(settings.action("ctrl+home"), Some(Action::Top));
        assert_eq!(settings.action("ctrl+end"), Some(Action::Bottom));
        assert_eq!(settings.action("ctrl+o"), Some(Action::ToggleTools));
        assert_eq!(settings.action("ctrl+t"), Some(Action::ToggleThinking));
        for name in ["alt+v", "ctrl+u", "ctrl+d", "shift+up", "f5"] {
            assert_eq!(settings.action(name), None, "{name} is unbound until an operator binds it");
        }
        assert!(settings.warnings.is_empty());
        assert_eq!(settings.wheel_rows(24), WHEEL_AUTO_ROWS, "the inline console's own step");
    }

    #[test]
    fn the_node_config_setting_is_read_from_the_environment_and_bad_values_are_named() {
        let settings = Settings::from_env(env(&[
            ("WA_TUI_FULLSCREEN", "off"), ("WA_TUI_SCROLLBAR", "always"),
            ("WA_TUI_WHEEL_LINES", "5"), ("WA_TUI_KEYS", "ctrl+u=line-up,alt+v=half-page-down,pageup=none"),
        ]));
        assert!(!settings.fullscreen);
        assert_eq!(settings.scrollbar, Scrollbar::Always);
        assert_eq!(settings.wheel, Wheel::Lines(5));
        assert_eq!(settings.wheel_rows(24), 5);
        assert_eq!(settings.action("ctrl+u"), Some(Action::LineUp));
        assert_eq!(settings.action("alt+v"), Some(Action::HalfPageDown));
        assert_eq!(settings.action("pageup"), None, "none unbinds");
        assert_eq!(settings.action("pagedown"), Some(Action::PageDown), "and the rest keep their defaults");
        let bad = Settings::from_env(env(&[("WA_TUI_SCROLLBAR", "sometimes"), ("WA_TUI_KEYS", "ctrl+q=nope")]));
        assert_eq!(bad.scrollbar, Scrollbar::Auto);
        assert_eq!(bad.warnings.len(), 2, "{:?}", bad.warnings);
        assert!(bad.warnings[0].contains("WA_TUI_SCROLLBAR"), "the warning names the knob: {:?}", bad.warnings);
        assert!(bad.warnings[1].contains("ctrl+q=nope"), "and the entry: {:?}", bad.warnings);
        // A wheel count is clamped to the viewport, so a huge number cannot scroll past the ends.
        let huge = Settings { wheel: Wheel::Lines(1000), ..Settings::default() };
        assert_eq!(huge.wheel_rows(10), 10);
    }

    #[test]
    fn the_fallback_is_chosen_by_the_flag_the_variable_the_pipe_and_the_setting() {
        let on = Settings::default();
        let off = Settings { fullscreen: false, ..Settings::default() };
        let args = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(on.mode(&[], env(&[]), true), Mode::Fullscreen);
        assert_eq!(on.mode(&args(&["--inline"]), env(&[("WA_TUI", "fullscreen")]), true), Mode::Inline, "--inline wins");
        assert_eq!(on.mode(&[], env(&[("WA_TUI", "inline")]), true), Mode::Inline);
        assert_eq!(off.mode(&[], env(&[("WA_TUI", "fullscreen")]), true), Mode::Fullscreen, "the variable overrules the node");
        assert_eq!(on.mode(&[], env(&[]), false), Mode::Inline, "a pipe is not a screen");
        assert_eq!(on.mode(&[], env(&[("WA_TUI", "fullscreen")]), false), Mode::Inline, "and cannot be made one");
        assert_eq!(off.mode(&[], env(&[]), true), Mode::Inline, "the node turned it off");
        assert_eq!(on.mode(&args(&["run"]), env(&[("WA_TUI", "nonsense")]), true), Mode::Fullscreen, "an unreadable WA_TUI is no opinion");
    }
}
