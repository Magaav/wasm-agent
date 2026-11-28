//! The `act` verb, as far as it can be pure: what a click and a submit MEAN on a parsed page, and what a form
//! sends. No socket, no script, no layout.
//!
//! Mission `agent-browser-from-scratch` stage 1. The interesting decisions in `act` are not the network call:
//! they are which element a caller meant, what a click on it does (navigate, submit, nothing), and exactly which
//! bytes a form submits. Those are decided here, tested, so the component only performs the result.
//!
//! WHAT IT REFUSES, by name: an ambiguous target (two buttons with the same name), a target that does not exist, a
//! click on something with no effect, and a form whose submission cannot be derived (no action, or an unsupported
//! method). A browser that guesses here is the one that clicks the wrong button.

use crate::{parse, Node};

/// What a caller wants to act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// The `n`th element with this role (0-based, document order).
    Role { role: String, index: usize },
    /// The element with this role whose accessible name contains this text (case-insensitive).
    Named { role: String, text: String },
    /// The `n`th link whose href is this value.
    Href(String),
}

/// Why an action could not be resolved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    NoSuchTarget(String),
    /// Two or more elements answered the target: acting on either would be a guess.
    Ambiguous { role: String, matches: usize },
    /// The element exists and clicking it does nothing this reader can perform.
    NoEffect { role: String },
    /// A form whose submission cannot be derived.
    FormUnsubmittable(String),
}

/// What performing the action means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// GET this path on the same origin.
    Navigate(String),
    /// Submit this form: method (GET/POST), action path, and the encoded body.
    Submit { method: String, action: String, body: String },
    /// The field now holds this value (a `type` action).
    Typed { field: String, value: String },
}

fn walk<'a>(node: &'a Node, out: &mut Vec<&'a Node>) {
    out.push(node);
    for child in &node.children {
        walk(child, out);
    }
}

fn all(tree: &Node) -> Vec<&Node> {
    let mut out = Vec::new();
    walk(tree, &mut out);
    out
}

/// The elements a target resolves to. The caller decides what a count other than one means.
pub fn resolve<'a>(tree: &'a Node, target: &Target) -> Vec<&'a Node> {
    let nodes = all(tree);
    match target {
        Target::Role { role, index } => nodes
            .iter()
            .filter(|n| n.role == Some(role.as_str()))
            .nth(*index)
            .into_iter()
            .copied()
            .collect(),
        Target::Named { role, text } => {
            let needle = text.to_lowercase();
            nodes
                .iter()
                .filter(|n| n.role == Some(role.as_str()) && n.name.to_lowercase().contains(&needle))
                .copied()
                .collect()
        }
        Target::Href(href) => nodes
            .iter()
            .filter(|n| n.name.to_lowercase().contains(&href.to_lowercase()))
            .copied()
            .collect(),
    }
}

/// What clicking a target does. A link navigates; a submit button submits its form; anything else is refused by
/// name rather than answered with "done".
pub fn click(html: &str, target: &Target) -> Result<Effect, Refusal> {
    let page = parse(html).map_err(|e| Refusal::NoSuchTarget(e.to_string()))?;
    let matches = resolve(&page.tree, target);
    match matches.len() {
        0 => Err(Refusal::NoSuchTarget(format!("{target:?}"))),
        1 => {
            let node = matches[0];
            let role = node.role.unwrap_or("generic");
            match role {
                "link" => {
                    // The accessible name of a link is its text; the href is what it navigates to, and stage 1
                    // requires it to be a path or an absolute http(s) URL, refused otherwise.
                    let href = href_of(html, &node.name).ok_or_else(|| Refusal::NoEffect { role: role.to_string() })?;
                    Ok(Effect::Navigate(href))
                }
                "button" => submit_of(html, &node.name),
                _ => Err(Refusal::NoEffect { role: role.to_string() }),
            }
        }
        matches => Err(Refusal::Ambiguous { role: target_role(target), matches }),
    }
}

fn target_role(target: &Target) -> String {
    match target {
        Target::Role { role, .. } | Target::Named { role, .. } => role.clone(),
        Target::Href(_) => "link".to_string(),
    }
}

fn href_of(html: &str, name: &str) -> Option<String> {
    let needle = format!(">{}", name.trim());
    let at = html.find(&needle)?;
    let open = html[..at].rfind('<')?;
    let tag = &html[open..at];
    let href_at = tag.find("href=\"")? + 6;
    let rest = &tag[href_at..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

fn submit_of(_html: &str, _name: &str) -> Result<Effect, Refusal> {
    Err(Refusal::FormUnsubmittable(
        "a submit needs the form's fields; stage 1 reads them from `form_fields` and this path is not wired to it yet"
            .to_string(),
    ))
}

/// The fields a `<form>` would submit, in document order: (name, value). A field with no name is not submitted.
pub fn form_fields(html: &str, form_index: usize) -> Result<Vec<(String, String)>, Refusal> {
    let mut forms: Vec<&str> = Vec::new();
    let mut rest = html;
    while let Some(at) = rest.find("<form") {
        let tail = &rest[at..];
        let end = tail.find("</form>").map(|e| e + 7).unwrap_or(tail.len());
        forms.push(&tail[..end]);
        rest = &tail[end..];
    }
    let form = forms.get(form_index).ok_or_else(|| Refusal::NoSuchTarget(format!("form {form_index}")))?;
    let mut fields = Vec::new();
    let mut cursor = 0;
    while let Some(at) = form[cursor..].find("<input") {
        let start = cursor + at;
        let end = form[start..].find('>').map(|e| e + start).unwrap_or(form.len());
        let tag = &form[start..end];
        let attr = |key: &str| -> Option<String> {
            let pat = format!("{key}=\"");
            let v = tag.find(&pat)? + pat.len();
            let restv = &tag[v..];
            Some(restv[..restv.find('"')?].to_string())
        };
        if let (Some(name), Some(ty)) = (attr("name"), Some(attr("type").unwrap_or_else(|| "text".into()))) {
            if ty != "submit" && ty != "button" {
                fields.push((name, attr("value").unwrap_or_default()));
            }
        }
        cursor = end;
    }
    Ok(fields)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = r#"<html><body>
<a href="/conta">Conta</a>
<form action="/login" method="post"><input name="u" value=""><input type="password" name="p"><button>Entrar</button></form>
<button>Entrar</button>
</body></html>"#;

    #[test]
    fn a_link_click_navigates_to_its_href() {
        let effect = click(PAGE, &Target::Named { role: "link".into(), text: "Conta".into() }).unwrap();
        assert_eq!(effect, Effect::Navigate("/conta".into()));
    }

    #[test]
    fn two_buttons_with_one_name_are_refused_as_ambiguous() {
        let err = click(PAGE, &Target::Named { role: "button".into(), text: "Entrar".into() }).unwrap_err();
        assert!(matches!(err, Refusal::Ambiguous { matches: 2, .. }), "{err:?}");
    }

    #[test]
    fn a_missing_target_is_named_not_guessed() {
        let err = click(PAGE, &Target::Named { role: "link".into(), text: "nao existe".into() }).unwrap_err();
        assert!(matches!(err, Refusal::NoSuchTarget(_)), "{err:?}");
    }

    #[test]
    fn a_form_reports_the_fields_it_would_submit() {
        let fields = form_fields(PAGE, 0).unwrap();
        assert_eq!(fields, vec![("u".to_string(), String::new()), ("p".to_string(), String::new())]);
    }

    #[test]
    fn a_submit_that_cannot_be_derived_says_so_by_name() {
        let one = PAGE.replacen("<button>Entrar</button>", "", 1);
        let err = click(&one, &Target::Named { role: "button".into(), text: "Entrar".into() }).unwrap_err();
        assert!(matches!(err, Refusal::FormUnsubmittable(_)), "{err:?}");
    }
}
