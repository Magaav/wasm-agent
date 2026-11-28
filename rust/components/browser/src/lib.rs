//! `wa:browser` - a page as text and as an accessibility-style tree, with no layout and no rendering.
//!
//! Stage 1 of mission `agent-browser-from-scratch`, DARK: nothing in the node calls this component, and it opens
//! no socket. The reading lives in `browser-html`, which its own tests judge, so this file is the ABI and nothing
//! else - which is where a component should keep its logic, on the other side of the seam.

wit_bindgen::generate!({ world: "browser", path: "../../../wit/browser/browser.wit" });

use exports::wa::browser::page::{Guest, Refusal};

struct Browser;

fn refusal_of(err: browser_html::Refusal) -> Refusal {
    match err {
        browser_html::Refusal::UnclosedRawText(tag) => Refusal::UnclosedRawText(tag),
        browser_html::Refusal::Unparsable(why) => Refusal::Unparsable(why),
        browser_html::Refusal::TooDeep => Refusal::TooDeep,
    }
}

fn render(node: &browser_html::Node, depth: usize, out: &mut String) {
    if node.role.is_some() || !node.name.is_empty() {
        out.push_str(&format!(
            "{} {} {}\n",
            depth,
            node.role.unwrap_or("generic"),
            node.name.replace('\n', " ")
        ));
    }
    for child in &node.children {
        render(child, depth + 1, out);
    }
}

impl Guest for Browser {
    fn read(html: String) -> Result<String, Refusal> {
        browser_html::read(&html).map_err(refusal_of)
    }

    fn tree(html: String) -> Result<String, Refusal> {
        let tree = browser_html::tree(&html).map_err(refusal_of)?;
        let mut out = String::new();
        render(&tree, 0, &mut out);
        Ok(out)
    }
}

export!(Browser);
