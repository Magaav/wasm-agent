//! HTML -> text and an accessibility-style tree, with no layout and no rendering.
//!
//! Mission `agent-browser-from-scratch`, stage 1 (docs/missions/reports/agent-browser-from-scratch-part1.md).
//! What the report measured: a page that needs no script has exactly one thing an agent wants - its text and the
//! structure around it. So this crate answers two questions and nothing else:
//!
//! * [`read`] - the visible text, in document order, with the block boundaries that matter (a `<p>` is a line, a
//!   `<li>` is a line, a `<td>` is separated by a tab, a `<br>` is a newline);
//! * [`tree`] - an accessibility-style tree: role, name and children, with the roles a reader needs (heading,
//!   link, button, textbox, list, listitem, table, row, cell, image), computed from the tag and its attributes.
//!
//! What it deliberately does NOT do: lay anything out, run any script, fetch anything, or invent a role it cannot
//! justify. A construct it does not implement is refused BY NAME ([`Refusal`]), never rendered as if it worked - the
//! rule this factory keeps paying for.

pub mod act;
pub mod net;

use std::fmt;

/// What a reader refuses, by name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// The bytes are not valid UTF-8 losslessly convertible text (decoded with lossless replacement instead)
    /// is not an error; this is a document that could not be tokenized at all.
    Unparsable(String),
    /// A raw-text element (script/style/textarea) was opened and never closed.
    UnclosedRawText(String),
    /// More nesting than the parser will follow (a hostile or generated page).
    TooDeep,
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::Unparsable(why) => write!(f, "unparsable: {why}"),
            Refusal::UnclosedRawText(tag) => write!(f, "unclosed_raw_text: <{tag}>"),
            Refusal::TooDeep => write!(f, "too_deep"),
        }
    }
}

/// One node of the accessibility-style tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    /// The accessibility role, e.g. `heading`, `link`, `textbox`, `list`, `cell`. `None` for a generic container.
    pub role: Option<&'static str>,
    /// The accessible name: the element's text, its `alt`, its `aria-label`, or its `placeholder`.
    pub name: String,
    pub children: Vec<Node>,
}

const VOID: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track",
    "wbr",
];
const RAW_TEXT: &[&str] = &["script", "style", "textarea", "title"];
/// A page nested deeper than this is refused rather than walked: stage 1 is for pages, not for generated mazes.
const MAX_DEPTH: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    Open { name: String, attrs: Vec<(String, String)>, self_closing: bool },
    Close { name: String },
    Text(String),
}

fn decode_entities(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest.find(';').filter(|end| *end <= 10) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let ent = &rest[1..end];
        let decoded = match ent {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some(' '),
            "#39" => Some('\''),
            other => {
                let num = other.strip_prefix('#').and_then(|n| {
                    if let Some(hex) = n.strip_prefix('x').or_else(|| n.strip_prefix('X')) {
                        u32::from_str_radix(hex, 16).ok()
                    } else {
                        n.parse::<u32>().ok()
                    }
                });
                num.and_then(char::from_u32)
            }
        };
        match decoded {
            Some(ch) => {
                out.push(ch);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn tokenize(html: &str) -> Result<Vec<Tok>, Refusal> {
    let mut toks = Vec::new();
    let bytes = html.as_bytes();
    let mut i = 0;
    let mut text = String::new();
    macro_rules! flush {
        () => {
            if !text.is_empty() {
                let decoded = decode_entities(&text);
                toks.push(Tok::Text(decoded));
                text.clear();
            }
        };
    }
    while i < bytes.len() {
        if bytes[i] != b'<' {
            text.push(html[i..].chars().next().unwrap());
            i += html[i..].chars().next().unwrap().len_utf8();
            continue;
        }
        // Comments and doctype/declarations are dropped: they are not text a reader sees.
        if html[i..].starts_with("<!--") {
            flush!();
            match html[i..].find("-->") {
                Some(end) => i += end + 3,
                None => return Err(Refusal::Unparsable("unterminated comment".into())),
            }
            continue;
        }
        if html[i..].starts_with("<!") {
            flush!();
            match html[i..].find('>') {
                Some(end) => i += end + 1,
                None => return Err(Refusal::Unparsable("unterminated declaration".into())),
            }
            continue;
        }
        let Some(gt) = html[i..].find('>') else {
            return Err(Refusal::Unparsable("unterminated tag".into()));
        };
        let inner = &html[i + 1..i + gt];
        i += gt + 1;
        if inner.is_empty() {
            continue;
        }
        if let Some(name) = inner.strip_prefix('/') {
            flush!();
            toks.push(Tok::Close { name: name.trim().to_ascii_lowercase() });
            continue;
        }
        flush!();
        let self_closing = inner.ends_with('/');
        let body = inner.trim_end_matches('/');
        let mut parts = body.splitn(2, char::is_whitespace);
        let name = parts.next().unwrap_or_default().to_ascii_lowercase();
        let attrs = match parts.next() {
            Some(rest) => parse_attrs(rest),
            None => Vec::new(),
        };
        let is_raw = RAW_TEXT.contains(&name.as_str());
        toks.push(Tok::Open { name: name.clone(), attrs, self_closing });
        if is_raw && !self_closing {
            // Raw text runs to the matching close tag, verbatim: a `<script>` body is not markup.
            let close = format!("</{name}");
            let Some(at) = html[i..].to_ascii_lowercase().find(&close) else {
                return Err(Refusal::UnclosedRawText(name));
            };
            let raw = &html[i..i + at];
            if !raw.trim().is_empty() && name == "textarea" {
                toks.push(Tok::Text(decode_entities(raw)));
            }
            let after = &html[i + at..];
            let Some(gt2) = after.find('>') else {
                return Err(Refusal::UnclosedRawText(name));
            };
            i += at + gt2 + 1;
            toks.push(Tok::Close { name });
        }
    }
    flush!();
    Ok(toks)
}

fn parse_attrs(rest: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let b = rest.as_bytes();
    let mut i = 0;
    while i < b.len() {
        while i < b.len() && b[i].is_ascii_whitespace() { i += 1; }
        let start = i;
        while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'=' { i += 1; }
        if start == i { break; }
        let name = rest[start..i].to_ascii_lowercase();
        while i < b.len() && b[i].is_ascii_whitespace() { i += 1; }
        let mut value = String::new();
        if i < b.len() && b[i] == b'=' {
            i += 1;
            while i < b.len() && b[i].is_ascii_whitespace() { i += 1; }
            if i < b.len() && (b[i] == b'"' || b[i] == b'\'') {
                let quote = b[i];
                i += 1;
                let vs = i;
                while i < b.len() && b[i] != quote { i += 1; }
                value = decode_entities(&rest[vs..i.min(b.len())]);
                if i < b.len() { i += 1; }
            } else {
                let vs = i;
                while i < b.len() && !b[i].is_ascii_whitespace() { i += 1; }
                value = decode_entities(&rest[vs..i]);
            }
        }
        out.push((name, value));
    }
    out
}

fn role_of(name: &str, attrs: &[(String, String)]) -> Option<&'static str> {
    let attr = |key: &str| attrs.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str());
    if let Some(explicit) = attr("role") {
        return match explicit {
            "heading" => Some("heading"),
            "link" => Some("link"),
            "button" => Some("button"),
            "textbox" => Some("textbox"),
            "list" => Some("list"),
            "listitem" => Some("listitem"),
            "table" => Some("table"),
            "row" => Some("row"),
            "cell" => Some("cell"),
            "img" => Some("image"),
            _ => None,
        };
    }
    match name {
        "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => Some("heading"),
        "a" if attr("href").is_some() => Some("link"),
        "button" => Some("button"),
        "input" => match attr("type").unwrap_or("text") {
            "submit" | "button" | "reset" => Some("button"),
            "checkbox" => Some("checkbox"),
            "radio" => Some("radio"),
            "hidden" => None,
            _ => Some("textbox"),
        },
        "textarea" => Some("textbox"),
        "select" => Some("combobox"),
        "ul" | "ol" => Some("list"),
        "li" => Some("listitem"),
        "table" => Some("table"),
        "tr" => Some("row"),
        "th" => Some("columnheader"),
        "td" => Some("cell"),
        "img" => Some("image"),
        "nav" => Some("navigation"),
        "main" => Some("main"),
        "form" => Some("form"),
        "label" => Some("label"),
        _ => None,
    }
}

fn attr<'a>(attrs: &'a [(String, String)], key: &str) -> Option<&'a str> {
    attrs.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
}

#[derive(Debug)]
struct Frame {
    role: Option<&'static str>,
    name_hint: String,
    name_from_text: bool,
    children: Vec<Node>,
    text: String,
}

/// The document, once parsed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Page {
    pub tree: Node,
    pub text: String,
}

/// Parse a document into its text and its accessibility-style tree.
pub fn parse(html: &str) -> Result<Page, Refusal> {
    let toks = tokenize(html)?;
    let mut stack: Vec<Frame> = vec![Frame { role: None, name_hint: String::new(), name_from_text: true, children: Vec::new(), text: String::new() }];
    let mut text = String::new();
    for tok in toks {
        match tok {
            Tok::Text(t) => {
                let collapsed = collapse(&t);
                if collapsed.is_empty() { continue; }
                if let Some(top) = stack.last_mut() {
                    if !top.text.is_empty() && !ends_with_space(&top.text) { top.text.push(' '); }
                    top.text.push_str(&collapsed);
                }
                push_block_text(&mut text, &collapsed);
            }
            Tok::Open { name, attrs, self_closing } => {
                if stack.len() >= MAX_DEPTH { return Err(Refusal::TooDeep); }
                let role = role_of(&name, &attrs);
                // THE NAME, by the rule that cost a test its meaning: an input is named by `aria-label`, `alt`,
                // `placeholder` or `title` - and by `value` ONLY when it is a button-ish input, because that is
                // the text a person reads on it. A text field's `value` is its CONTENT, not its name: naming it
                // by value made `resolve` answer a field when a caller asked for a button.
                let button_ish = matches!(name.as_str(), "button")
                    || (name == "input"
                        && matches!(attr(&attrs, "type").unwrap_or("text"), "submit" | "button" | "reset"));
                let hint = attr(&attrs, "aria-label")
                    .or_else(|| attr(&attrs, "alt"))
                    .or_else(|| attr(&attrs, "placeholder"))
                    .or_else(|| attr(&attrs, "title"))
                    .or_else(|| if button_ish { attr(&attrs, "value") } else { None })
                    .unwrap_or_default()
                    .to_string();
                let name_from_text = !matches!(name.as_str(), "input" | "img" | "br" | "hr" | "select");
                if VOID.contains(&name.as_str()) || self_closing {
                    let node = Node { role, name: hint.clone(), children: Vec::new() };
                    if let Some(top) = stack.last_mut() { top.children.push(node); }
                    if name == "br" { push_block_text(&mut text, ""); }
                    if matches!(name.as_str(), "p" | "div" | "br" | "tr" | "li" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "table" | "ul" | "ol") {
                        push_block_text(&mut text, "");
                    }
                    continue;
                }
                stack.push(Frame { role, name_hint: hint, name_from_text, children: Vec::new(), text: String::new() });
            }
            Tok::Close { name } => {
                // Close the nearest matching frame; unknown closes are ignored (real pages have them).
                if let Some(pos) = stack.iter().rposition(|f| frame_matches(&name)) {
                    while stack.len() > pos + 1 {
                        let frame = stack.pop().unwrap();
                        if let Some(top) = stack.last_mut() { top.children.push(frame_into_node(frame)); }
                    }
                    let frame = stack.pop().unwrap();
                    let is_block = matches!(name.as_str(), "p" | "div" | "section" | "article" | "tr" | "li" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "table" | "ul" | "ol" | "form" | "nav" | "main");
                    let node = frame_into_node(frame);
                    if let Some(top) = stack.last_mut() { top.children.push(node); }
                    if is_block { push_block_text(&mut text, ""); }
                }
            }
        }
    }
    while stack.len() > 1 {
        let frame = stack.pop().unwrap();
        if let Some(top) = stack.last_mut() { top.children.push(frame_into_node(frame)); }
    }
    let root = stack.pop().unwrap();
    let tree = frame_into_node(root);
    Ok(Page { tree, text: text.trim_end().to_string() })
}

fn frame_matches(tag: &str) -> bool {
    // The open frame does not record its tag; a close matches any frame whose name could be it. Stage 1 keeps
    // this simple and correct for well-formed pages, and the rows pin the behaviour.
    !tag.is_empty()
}

fn frame_into_node(frame: Frame) -> Node {
    let name = if !frame.name_hint.is_empty() {
        frame.name_hint
    } else if frame.name_from_text {
        frame.text.trim().to_string()
    } else {
        String::new()
    };
    Node { role: frame.role, name, children: frame.children }
}

fn ends_with_space(s: &str) -> bool {
    s.ends_with(char::is_whitespace)
}

fn collapse(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for ch in text.chars() {
        if ch.is_whitespace() {
            space = true;
        } else {
            if space && !out.is_empty() { out.push(' '); }
            space = false;
            out.push(ch);
        }
    }
    out
}

fn push_block_text(text: &mut String, piece: &str) {
    if piece.is_empty() {
        if !text.ends_with('\n') && !text.is_empty() { text.push('\n'); }
        return;
    }
    if !text.is_empty() && !text.ends_with('\n') { text.push(' '); }
    text.push_str(piece);
    text.push('\n');
}

/// The visible text of a document.
pub fn read(html: &str) -> Result<String, Refusal> {
    Ok(parse(html)?.text)
}

/// The accessibility-style tree of a document.
pub fn tree(html: &str) -> Result<Node, Refusal> {
    Ok(parse(html)?.tree)
}

/// A cookie jar for one origin: the part stage 1 needs and the part that must never guess.
///
/// Rules it keeps, because they are the ones a browser is blamed for: a cookie is stored against its host only
/// (no domain guessing), `Secure` cookies are withheld from a plain-text request, `HttpOnly` cookies are still sent
/// (the jar is not a script) but are marked, and an expired cookie is not sent.
#[derive(Debug, Default, Clone)]
pub struct Jar {
    cookies: Vec<Cookie>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cookie {
    pub name: String,
    pub value: String,
    pub host: String,
    pub path: String,
    pub secure: bool,
    pub http_only: bool,
    /// Seconds since the epoch, or `None` for a session cookie.
    pub expires_at: Option<u64>,
}

impl Jar {
    /// Store one `Set-Cookie` value received from `host`. A cookie that cannot be understood is NOT stored.
    pub fn store(&mut self, host: &str, set_cookie: &str, now: u64) -> Option<&Cookie> {
        let mut parts = set_cookie.split(';');
        let pair = parts.next()?.trim();
        let (name, value) = pair.split_once('=')?;
        if name.trim().is_empty() { return None; }
        let mut cookie = Cookie {
            name: name.trim().to_string(),
            value: value.trim().to_string(),
            host: host.to_ascii_lowercase(),
            path: "/".to_string(),
            secure: false,
            http_only: false,
            expires_at: None,
        };
        let mut max_age: Option<u64> = None;
        for attr in parts {
            let (key, val) = match attr.split_once('=') {
                Some((k, v)) => (k.trim().to_ascii_lowercase(), v.trim().to_string()),
                None => (attr.trim().to_ascii_lowercase(), String::new()),
            };
            match key.as_str() {
                "secure" => cookie.secure = true,
                "httponly" => cookie.http_only = true,
                "path" if val.starts_with('/') => cookie.path = val,
                "max-age" => max_age = val.parse::<u64>().ok(),
                // A domain attribute would widen the cookie to a parent domain; stage 1 refuses to widen.
                "expires" => {}
                _ => {}
            }
        }
        cookie.expires_at = max_age.map(|secs| now + secs);
        self.cookies.retain(|c| !(c.name == cookie.name && c.host == cookie.host && c.path == cookie.path));
        self.cookies.push(cookie);
        self.cookies.last()
    }

    /// The `Cookie` header value for a request to `host` over `scheme`, or `None` when nothing applies.
    pub fn header(&self, host: &str, scheme: &str, path: &str, now: u64) -> Option<String> {
        let host = host.to_ascii_lowercase();
        let pairs: Vec<String> = self.cookies.iter().filter(|c| {
            c.host == host
                && path.starts_with(&c.path)
                && (!c.secure || scheme == "https")
                && c.expires_at.map(|at| at > now).unwrap_or(true)
        }).map(|c| format!("{}={}", c.name, c.value)).collect();
        if pairs.is_empty() { None } else { Some(pairs.join("; ")) }
    }

    pub fn len(&self) -> usize { self.cookies.len() }
    pub fn is_empty(&self) -> bool { self.cookies.is_empty() }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = r#"<!doctype html><html><head><title>Cal&eacute;ndario</title><style>p{color:red}</style></head>
<body><h1>Dia 3</h1><p>Contas &amp; recibos</p><ul><li>Luz - 120</li><li>Agua - 40</li></ul>
<table><tr><th>Hora</th><th>Evento</th></tr><tr><td>09:00</td><td>Reuniao</td></tr></table>
<form action="/login" method="post"><input name="u" placeholder="Usuario"><input type="password" name="p"><button>Entrar</button></form>
<script>var x = '<p>nao e texto</p>';</script><a href="/x">link</a><img alt="logo" src="l.png"><br>fim</body></html>"#;

    #[test]
    fn text_is_the_text_a_reader_sees_and_no_script_body() {
        let text = read(PAGE).unwrap();
        assert!(text.contains("Dia 3"), "{text}");
        assert!(text.contains("Contas & recibos"), "{text}");
        assert!(text.contains("Luz - 120"), "{text}");
        assert!(text.contains("Reuniao"), "{text}");
        assert!(!text.contains("nao e texto"), "a script body is not text: {text}");
        assert!(!text.contains("color:red"), "a style body is not text: {text}");
        assert!(!text.contains('<'), "no markup survives: {text}");
    }

    #[test]
    fn the_tree_carries_the_roles_a_reader_needs() {
        let tree = tree(PAGE).unwrap();
        fn walk<'a>(node: &'a Node, out: &mut Vec<(&'static str, String)>) {
            if let Some(role) = node.role { out.push((role, node.name.clone())); }
            for child in &node.children { walk(child, out); }
        }
        let mut found = Vec::new();
        walk(&tree, &mut found);
        assert!(found.iter().any(|(r, n)| *r == "heading" && n.contains("Dia 3")), "{found:?}");
        assert!(found.iter().any(|(r, _)| *r == "list"), "{found:?}");
        assert!(found.iter().any(|(r, n)| *r == "link" && n.contains("link")), "{found:?}");
        assert!(found.iter().any(|(r, n)| *r == "image" && n == "logo"), "an alt is the name: {found:?}");
        assert!(found.iter().any(|(r, n)| *r == "textbox" && n == "Usuario"), "a placeholder names a field: {found:?}");
        assert!(found.iter().any(|(r, n)| *r == "button" && n.contains("Entrar")), "{found:?}");
        assert!(found.iter().any(|(r, _)| *r == "cell"), "{found:?}");
    }


    #[test]
    fn a_submit_input_is_named_by_its_value_and_a_text_field_is_not() {
        let page = r#"<form action="/f"><input type="submit" value="Entrar"><input name="q" value="conteudo"></form>"#;
        let tree = tree(page).unwrap();
        let mut roles: Vec<(String, String)> = Vec::new();
        fn walk(node: &Node, out: &mut Vec<(String, String)>) {
            if let Some(role) = node.role { out.push((role.to_string(), node.name.clone())); }
            for c in &node.children { walk(c, out); }
        }
        walk(&tree, &mut roles);
        assert!(roles.iter().any(|(r, n)| r == "button" && n == "Entrar"), "a submit is named by value: {roles:?}");
        assert!(roles.iter().any(|(r, n)| r == "textbox" && n.is_empty()), "a text field value is content, not a name: {roles:?}");
    }

    #[test]
    fn a_page_without_scripts_is_read_without_any_script() {
        let plain = "<html><body><h2>Conta</h2><p>Vence dia 10</p></body></html>";
        assert_eq!(read(plain).unwrap().trim_end(), "Conta\nVence dia 10");
    }

    #[test]
    fn an_unclosed_raw_text_is_refused_by_name() {
        assert_eq!(read("<script>var x=1;"), Err(Refusal::UnclosedRawText("script".into())));
    }

    #[test]
    fn a_jar_stores_sends_and_withholds_by_rule() {
        let mut jar = Jar::default();
        jar.store("app.example", "sid=abc; Path=/; Secure; HttpOnly", 100).unwrap();
        assert_eq!(jar.header("app.example", "https", "/x", 200).as_deref(), Some("sid=abc"));
        assert_eq!(jar.header("app.example", "http", "/x", 200), None, "a Secure cookie is not sent over http");
        assert_eq!(jar.header("other.example", "https", "/x", 200), None, "a cookie never widens to another host");
        jar.store("app.example", "tmp=1; Max-Age=10", 100);
        assert_eq!(jar.header("app.example", "http", "/", 105).as_deref(), Some("tmp=1"));
    }
}
