//! UI renderer compiled to WASM.
//!
//! Turns an assistant reply into safe HTML: the text is escaped first, then a
//! small markdown subset is applied — headings, bullet and numbered lists, fenced
//! code, and tables. The web UI loads this and uses it for every reply, so HTML
//! safety lives in one audited WASM module rather than in string concatenation
//! spread across the front end.
//!
//! It is a subset on purpose. A model asked for a table writes a table, so a table
//! has to look like one; everything else it writes is prose, and prose that wraps
//! is the requirement there.
use std::mem;
use std::slice;

fn packed(value: String) -> i64 {
    let bytes = value.into_bytes();
    let length = bytes.len() as i64;
    let pointer = bytes.as_ptr() as i64;
    mem::forget(bytes);
    (pointer << 32) | (length & 0xffff_ffff)
}

#[no_mangle]
pub extern "C" fn alloc(length: i32) -> i32 {
    let mut buffer = Vec::<u8>::with_capacity(length.max(0) as usize);
    let pointer = buffer.as_mut_ptr() as i32;
    mem::forget(buffer);
    pointer
}

#[no_mangle]
pub extern "C" fn render(pointer: i32, length: i32) -> i64 {
    let input = unsafe { slice::from_raw_parts(pointer as *const u8, length.max(0) as usize) };
    packed(render_markdown(&String::from_utf8_lossy(input)))
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn render_inline(line: &str) -> String {
    let escaped = escape(line);
    let mut out = String::new();
    let mut chars = escaped.chars().peekable();
    let mut in_code = false;
    let mut in_bold = false;
    while let Some(c) = chars.next() {
        if c == '`' {
            in_code = !in_code;
            out.push_str(if in_code { "<code>" } else { "</code>" });
        } else if c == '*' && chars.peek() == Some(&'*') {
            chars.next();
            in_bold = !in_bold;
            out.push_str(if in_bold { "<strong>" } else { "</strong>" });
        } else {
            out.push(c);
        }
    }
    // An unterminated span would swallow the rest of the message.
    if in_code {
        out.push_str("</code>");
    }
    if in_bold {
        out.push_str("</strong>");
    }
    out
}

/// A table row is `| a | b |`; the leading and trailing pipes are optional in most
/// markdown, and models write both forms.
fn split_row(line: &str) -> Vec<&str> {
    let trimmed = line.trim().trim_start_matches('|').trim_end_matches('|');
    trimmed.split('|').map(|cell| cell.trim()).collect()
}

fn is_table_row(line: &str) -> bool {
    let trimmed = line.trim();
    trimmed.starts_with('|') || (trimmed.contains('|') && trimmed.matches('|').count() >= 2)
}

/// `|---|:--:|` — the line that turns the row above it into a header.
fn is_table_separator(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() || !trimmed.contains('-') {
        return false;
    }
    let cells = split_row(trimmed);
    !cells.is_empty()
        && cells.iter().all(|cell| {
            let cell = cell.trim();
            !cell.is_empty()
                && cell.starts_with(':') == false && cell.ends_with(':') == false
                || cell.chars().all(|c| c == '-' || c == ':' || c == ' ')
        })
        && cells
            .iter()
            .all(|cell| cell.chars().filter(|c| *c == '-').count() >= 1)
}

fn bullet_prefix(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    for marker in ["- ", "* ", "+ "] {
        if let Some(rest) = trimmed.strip_prefix(marker) {
            return Some(rest);
        }
    }
    None
}

fn ordered_prefix(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    let digits: String = trimmed.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    let rest = &trimmed[digits.len()..];
    for marker in [". ", ") "] {
        if let Some(text) = rest.strip_prefix(marker) {
            return Some(text);
        }
    }
    None
}

fn heading_level(line: &str) -> Option<usize> {
    let trimmed = line.trim_start();
    let hashes = trimmed.chars().take_while(|c| *c == '#').count();
    if hashes >= 1 && hashes <= 6 && trimmed.chars().nth(hashes) == Some(' ') {
        return Some(hashes);
    }
    None
}

fn render_markdown(input: &str) -> String {
    let lines: Vec<&str> = input.split('\n').collect();
    let mut out = String::new();
    let mut index = 0;
    while index < lines.len() {
        let line = lines[index];
        let trimmed = line.trim_end();

        // Fenced code: verbatim, no inline markup inside, and wrapped so a long
        // line scrolls in its own box instead of widening the whole transcript.
        if trimmed.trim_start().starts_with("```") {
            let mut body = String::new();
            index += 1;
            while index < lines.len() && !lines[index].trim_start().starts_with("```") {
                body.push_str(lines[index]);
                body.push('\n');
                index += 1;
            }
            index += 1; // the closing fence
            out.push_str("<pre><code>");
            out.push_str(&escape(body.trim_end_matches('\n')));
            out.push_str("</code></pre>");
            continue;
        }

        // A table: a row followed by a separator row. The wrapper is what makes a
        // wide table scroll on its own rather than push the page sideways.
        if is_table_row(trimmed) && index + 1 < lines.len() && is_table_separator(lines[index + 1]) {
            let header = split_row(trimmed);
            index += 2;
            let mut rows: Vec<Vec<&str>> = Vec::new();
            while index < lines.len() && is_table_row(lines[index]) && !is_table_separator(lines[index])
            {
                rows.push(split_row(lines[index]));
                index += 1;
            }
            out.push_str("<div class=\"md-table\"><table><thead><tr>");
            for cell in &header {
                out.push_str("<th>");
                out.push_str(&render_inline(cell));
                out.push_str("</th>");
            }
            out.push_str("</tr></thead><tbody>");
            for row in &rows {
                out.push_str("<tr>");
                for cell in &row {
                    out.push_str("<td>");
                    out.push_str(&render_inline(cell));
                    out.push_str("</td>");
                }
                out.push_str("</tr>");
            }
            out.push_str("</tbody></table></div>");
            continue;
        }

        if let Some(level) = heading_level(trimmed) {
            let text = trimmed.trim_start().chars().skip(level).collect::<String>();
            out.push_str(&format!("<h{0}>{1}</h{0}>", level, render_inline(text.trim())));
            index += 1;
            continue;
        }

        if bullet_prefix(trimmed).is_some() {
            out.push_str("<ul>");
            while index < lines.len() {
                match bullet_prefix(lines[index].trim_end()) {
                    Some(text) => {
                        out.push_str("<li>");
                        out.push_str(&render_inline(text));
                        out.push_str("</li>");
                        index += 1;
                    }
                    None => break,
                }
            }
            out.push_str("</ul>");
            continue;
        }

        if ordered_prefix(trimmed).is_some() {
            out.push_str("<ol>");
            while index < lines.len() {
                match ordered_prefix(lines[index].trim_end()) {
                    Some(text) => {
                        out.push_str("<li>");
                        out.push_str(&render_inline(text));
                        out.push_str("</li>");
                        index += 1;
                    }
                    None => break,
                }
            }
            out.push_str("</ol>");
            continue;
        }

        if trimmed.trim().is_empty() {
            out.push_str("<br>");
            index += 1;
            continue;
        }

        out.push_str(&render_inline(trimmed));
        out.push_str("<br>");
        index += 1;
    }
    out
}
