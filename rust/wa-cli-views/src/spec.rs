//! What a local view is: a stack of panels one read-only command shows, and the rules for accepting
//! one from the side that captured it.
//!
//! The shape is not invented here. It is the shape `lua/core/nodes_cli.lua` already draws with
//! `host.panel` (`{title, lines, options = {{label, hint}}, selected}`, `selected` 1-based) plus two
//! fields that the host panel cannot express and a moving stack needs:
//!
//! - `options[i].view` - the panel this option opens (`views[j]`, 0-based; `views[0]` is the root),
//! - `options[i].pop`  - the "Back" option: go back one level,
//! - `captured_at`     - seconds since the epoch (`host.now`), so the panel can say how old it is.
//!
//! The specs are captured by the interpreter and drawn by the client (`wa_term`'s panel), which is
//! why every bound here is a bound on what one Lua call may hand the reader thread: this crate is
//! the only thing standing between a buggy view and a CLI that freezes mid-run.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fmt;

/// A whole view set is one Lua call's worth of JSON. `/nodes` for a hundred nodes is a few KiB.
pub const MAX_SPEC_BYTES: usize = 256 * 1024;
/// Panels in one set (the root plus one page per entry).
pub const MAX_VIEWS: usize = 64;
/// Options in one panel; `wa_term`'s panel shows `PANEL_OPTIONS` at a time and scrolls.
pub const MAX_OPTIONS: usize = 64;
/// Lines in one panel before the age line.
pub const MAX_LINES: usize = 200;
/// Characters in one line. `wa_term` truncates to the terminal width; this only stops a paste.
pub const MAX_LINE_CHARS: usize = 400;
/// Characters in an option's label or a panel's title.
pub const MAX_LABEL_CHARS: usize = 200;
pub const MAX_TITLE_CHARS: usize = 120;
/// Characters in the command name (`/nodes`).
pub const MAX_COMMAND_CHARS: usize = 32;

/// A spec that was not accepted, with the reason. `detail` is a *count* or an index, never the text
/// that was refused: a refused spec is a bug in a view, and a bug report does not need the reader's
/// node names in it (AGENTS.md: logs carry no message text).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub detail: String,
}

impl Refusal {
    pub fn new(code: &'static str, detail: impl Into<String>) -> Refusal {
        Refusal {
            code,
            detail: detail.into(),
        }
    }

    /// The answer `host.local_view` pushes back to Lua: `{"ok":false,...}`.
    pub fn answer(&self) -> Value {
        json!({"ok": false, "error": self.code, "detail": self.detail})
    }
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.detail)
    }
}

/// One choice in a panel.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct ViewOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
    /// The panel this option opens, as an index into [`ViewSet::views`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view: Option<usize>,
    /// Go back one level ("Back"). Not allowed in the root: from the root, back is close.
    #[serde(default, skip_serializing_if = "is_false")]
    pub pop: bool,
    /// A line for the interpreter to run **after this turn** ("disable this connector"). The client
    /// cannot do it - it has no registry, no provider and no business changing state - so choosing
    /// this option closes the balloon and queues the line exactly where a typed one goes. That is what
    /// keeps a mid-run action honest: the panel says it is queued, and it runs at the next turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run: Option<String>,
}

fn is_false(value: &bool) -> bool {
    !*value
}

/// One panel.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct View {
    pub title: String,
    #[serde(default)]
    pub lines: Vec<String>,
    #[serde(default)]
    pub options: Vec<ViewOption>,
    /// 1-based, as `host.panel` and `wa_term`'s panel both read it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<usize>,
}

impl View {
    /// The panel spec `wa_term::terminal_editor::Panel::from_spec` and `host.panel` both take, with
    /// `age` appended as its last line when there is one.
    pub fn panel_spec(&self, age: Option<String>) -> Value {
        let mut lines = self.lines.clone();
        if let Some(age) = age {
            lines.push(age);
        }
        let options: Vec<Value> = self
            .options
            .iter()
            .map(|option| json!({"label": option.label, "hint": option.hint.clone().unwrap_or_default()}))
            .collect();
        let selected = self.selected.unwrap_or(1).max(1);
        json!({"title": self.title, "lines": lines, "options": options, "selected": selected})
    }

    fn options_len(&self) -> usize {
        self.options.len()
    }

    fn refusal(&self, index: usize) -> Option<Refusal> {
        if self.title.chars().count() > MAX_TITLE_CHARS {
            return Some(Refusal::new(
                "title_too_long",
                format!("views[{index}]: {} characters", self.title.chars().count()),
            ));
        }
        if self.lines.len() > MAX_LINES {
            return Some(Refusal::new(
                "too_many_lines",
                format!("views[{index}]: {} lines", self.lines.len()),
            ));
        }
        for (line, text) in self.lines.iter().enumerate() {
            if text.chars().count() > MAX_LINE_CHARS {
                return Some(Refusal::new(
                    "line_too_long",
                    format!(
                        "views[{index}].lines[{line}]: {} characters",
                        text.chars().count()
                    ),
                ));
            }
        }
        if self.options.len() > MAX_OPTIONS {
            return Some(Refusal::new(
                "too_many_options",
                format!("views[{index}]: {} options", self.options.len()),
            ));
        }
        if let Some(selected) = self.selected {
            if selected == 0 || selected > self.options_len().max(1) {
                return Some(Refusal::new(
                    "selected_out_of_range",
                    format!(
                        "views[{index}]: selected {selected} of {}",
                        self.options_len()
                    ),
                ));
            }
        }
        for (option, entry) in self.options.iter().enumerate() {
            if entry.label.chars().count() > MAX_LABEL_CHARS {
                return Some(Refusal::new(
                    "label_too_long",
                    format!(
                        "views[{index}].options[{option}]: {} characters",
                        entry.label.chars().count()
                    ),
                ));
            }
            if entry.view.is_some() && entry.pop {
                return Some(Refusal::new(
                    "option_opens_and_pops",
                    format!("views[{index}].options[{option}]"),
                ));
            }
            if let Some(run) = entry.run.as_deref() {
                // A queued line has to be a command the interpreter owns, never model input: a reader
                // pressing Enter on "reconnect" must not put a sentence into the conversation.
                if !run.starts_with('/') || run.chars().count() > MAX_LINE_CHARS || run.contains('\n') {
                    return Some(Refusal::new(
                        "option_run_not_a_command",
                        format!("views[{index}].options[{option}]"),
                    ));
                }
                if entry.view.is_some() || entry.pop {
                    return Some(Refusal::new(
                        "option_runs_and_navigates",
                        format!("views[{index}].options[{option}]"),
                    ));
                }
            }
        }
        None
    }
}

/// A command's whole view stack, captured at one moment.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct ViewSet {
    /// The command this set answers, spelled as the reader types it (`/nodes`). The name it is filed
    /// under has to be the name it claims, so a snapshot can never answer a command it was not
    /// captured for.
    pub command: String,
    /// Seconds since the epoch, the node's own clock (`host.now`).
    #[serde(default)]
    pub captured_at: i64,
    /// The panels: `views[0]` is the root, and `options[i].view` indexes into this array.
    #[serde(default)]
    pub views: Vec<View>,
}

impl ViewSet {
    /// Reads and checks a set. The `command` argument is the name the caller is filing it under.
    ///
    /// Every bound is checked here rather than at draw time: the draw happens on the console reader
    /// thread, which cannot report a problem to anybody, and a spec accepted now is a spec that can
    /// be drawn later without a single failure path.
    pub fn parse(text: &str, command: &str) -> Result<ViewSet, Refusal> {
        if text.len() > MAX_SPEC_BYTES {
            return Err(Refusal::new(
                "spec_too_large",
                format!("{} bytes", text.len()),
            ));
        }
        let set: ViewSet = serde_json::from_str(text)
            .map_err(|error| Refusal::new("spec_unreadable", error.to_string()))?;
        set.check(command)?;
        Ok(set)
    }

    fn check(&self, command: &str) -> Result<(), Refusal> {
        let declared = self.command.trim();
        if declared.is_empty() {
            return Err(Refusal::new(
                "command_required",
                "the spec names no command",
            ));
        }
        if declared != command {
            return Err(Refusal::new(
                "command_mismatch",
                format!("filed as {command:?}"),
            ));
        }
        if !declared.starts_with('/')
            || declared.chars().count() > MAX_COMMAND_CHARS
            || declared.contains(char::is_whitespace)
        {
            return Err(Refusal::new(
                "command_unreadable",
                format!("{} characters", declared.chars().count()),
            ));
        }
        if self.views.is_empty() {
            return Err(Refusal::new("views_missing", "no panels"));
        }
        if self.views.len() > MAX_VIEWS {
            return Err(Refusal::new(
                "too_many_views",
                format!("{} panels", self.views.len()),
            ));
        }
        for (index, view) in self.views.iter().enumerate() {
            if let Some(refusal) = view.refusal(index) {
                return Err(refusal);
            }
            for (option, entry) in view.options.iter().enumerate() {
                if entry.pop && index == 0 {
                    return Err(Refusal::new(
                        "root_pop",
                        format!("views[0].options[{option}]"),
                    ));
                }
                if let Some(child) = entry.view {
                    if child == index {
                        return Err(Refusal::new(
                            "option_opens_itself",
                            format!("views[{index}].options[{option}]"),
                        ));
                    }
                    if child >= self.views.len() {
                        return Err(Refusal::new(
                            "view_out_of_range",
                            format!(
                                "views[{index}].options[{option}]: {child} of {}",
                                self.views.len()
                            ),
                        ));
                    }
                }
            }
        }
        Ok(())
    }

    /// The root's own 1-based selection, clamped to the options it actually has.
    pub fn root_focus(&self) -> usize {
        let selected = self.views[0].selected.unwrap_or(1).max(1);
        selected.min(self.views[0].options_len().max(1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(views: Value) -> String {
        json!({"command": "/nodes", "captured_at": 1_000, "views": views}).to_string()
    }

    fn root(extra: Value) -> Value {
        let mut view =
            json!({"title": "Nodes", "lines": ["one peer"], "options": [{"label": "laptop"}]});
        if let (Some(object), Some(more)) = (view.as_object_mut(), extra.as_object()) {
            for (key, value) in more {
                object.insert(key.clone(), value.clone());
            }
        }
        view
    }

    #[test]
    fn a_plain_list_is_accepted() {
        let parsed = ViewSet::parse(&set(json!([root(json!({}))])), "/nodes").unwrap();
        assert_eq!(parsed.command, "/nodes");
        assert_eq!(parsed.captured_at, 1_000);
        assert_eq!(parsed.views[0].options[0].label, "laptop");
        assert_eq!(parsed.root_focus(), 1);
    }

    #[test]
    fn the_name_it_is_filed_under_is_the_name_it_claims() {
        let error = ViewSet::parse(&set(json!([root(json!({}))])), "/wakes").unwrap_err();
        assert_eq!(error.code, "command_mismatch");
        // The detail says what it was filed as, never what the spec contained.
        assert!(!error.detail.contains("Nodes"));
    }

    #[test]
    fn a_command_that_is_not_a_slash_word_is_refused() {
        let text = json!({"command": "nodes", "views": [root(json!({}))]}).to_string();
        assert_eq!(
            ViewSet::parse(&text, "nodes").unwrap_err().code,
            "command_unreadable"
        );
        let text = json!({"command": "/no des", "views": [root(json!({}))]}).to_string();
        assert_eq!(
            ViewSet::parse(&text, "/no des").unwrap_err().code,
            "command_unreadable"
        );
    }

    #[test]
    fn an_empty_or_missing_stack_is_refused() {
        assert_eq!(
            ViewSet::parse(&set(json!([])), "/nodes").unwrap_err().code,
            "views_missing"
        );
        assert_eq!(
            ViewSet::parse(&json!({"command": "/nodes"}).to_string(), "/nodes")
                .unwrap_err()
                .code,
            "views_missing"
        );
    }

    #[test]
    fn a_link_that_points_nowhere_is_refused() {
        let child = json!({"title": "laptop", "options": [{"label": "Back", "pop": true}]});
        let text = set(json!([
            root(json!({"options": [{"label": "laptop", "view": 7}]})),
            child
        ]));
        assert_eq!(
            ViewSet::parse(&text, "/nodes").unwrap_err().code,
            "view_out_of_range"
        );
    }

    #[test]
    fn a_panel_that_opens_itself_is_refused() {
        let text = set(json!([root(
            json!({"options": [{"label": "again", "view": 0}]})
        )]));
        assert_eq!(
            ViewSet::parse(&text, "/nodes").unwrap_err().code,
            "option_opens_itself"
        );
    }

    #[test]
    fn back_from_the_root_is_a_refusal_because_it_is_a_close() {
        let text = set(json!([root(
            json!({"options": [{"label": "Back", "pop": true}]})
        )]));
        assert_eq!(
            ViewSet::parse(&text, "/nodes").unwrap_err().code,
            "root_pop"
        );
    }

    #[test]
    fn an_option_cannot_both_open_a_panel_and_go_back() {
        let child = json!({"title": "laptop", "options": [{"label": "Back", "pop": true}]});
        let text = set(json!([
            root(json!({"options": [{"label": "x", "view": 1}]})),
            child,
            {"title": "third", "options": [{"label": "y", "view": 2, "pop": true}]}
        ]));
        assert_eq!(
            ViewSet::parse(&text, "/nodes").unwrap_err().code,
            "option_opens_and_pops"
        );
    }

    #[test]
    fn bounds_are_bounds_on_what_a_view_may_hand_the_reader_thread() {
        let long = "x".repeat(MAX_LINE_CHARS + 1);
        let text = set(json!([root(json!({"lines": [long]}))]));
        assert_eq!(
            ViewSet::parse(&text, "/nodes").unwrap_err().code,
            "line_too_long"
        );

        let many: Vec<Value> = (0..MAX_VIEWS + 1).map(|_| root(json!({}))).collect();
        assert_eq!(
            ViewSet::parse(&set(json!(many)), "/nodes")
                .unwrap_err()
                .code,
            "too_many_views"
        );

        let huge = format!(
            "{}{}",
            set(json!([root(json!({}))])),
            " ".repeat(MAX_SPEC_BYTES)
        );
        assert_eq!(
            ViewSet::parse(&huge, "/nodes").unwrap_err().code,
            "spec_too_large"
        );
    }

    #[test]
    fn a_selection_past_the_end_is_refused_rather_than_clamped_silently() {
        let text = set(json!([root(json!({"selected": 4}))]));
        assert_eq!(
            ViewSet::parse(&text, "/nodes").unwrap_err().code,
            "selected_out_of_range"
        );
    }

    #[test]
    fn the_drawn_spec_is_the_panels_own_shape() {
        let view = View {
            title: "Nodes".into(),
            lines: vec!["Cluster: none".into()],
            options: vec![ViewOption {
                label: "this node".into(),
                hint: Some("local".into()),
                view: Some(1),
                pop: false,
                run: None,
            }],
            selected: Some(1),
        };
        let spec = view.panel_spec(Some("snapshot 2m ago".into()));
        assert_eq!(spec["title"], "Nodes");
        assert_eq!(spec["lines"], json!(["Cluster: none", "snapshot 2m ago"]));
        assert_eq!(
            spec["options"],
            json!([{"label": "this node", "hint": "local"}])
        );
        assert_eq!(spec["selected"], 1);
        // A hint is optional and the panel defaults it; an absent one is an empty string, not null.
        let quiet = View {
            options: vec![ViewOption {
                label: "back".into(),
                ..Default::default()
            }],
            ..view
        };
        assert_eq!(
            quiet.panel_spec(None)["options"],
            json!([{"label": "back", "hint": ""}])
        );
    }
}
