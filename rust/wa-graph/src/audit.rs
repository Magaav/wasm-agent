//! Patch impact leads, not a proof of patch correctness or complete static resolution.
//! Only a changed definition with a resolved incoming call can produce a lead.

use crate::extract;
use crate::store::{Result, Store};
use rusqlite::params;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::path::{Path, PathBuf};
use tree_sitter::Node;

#[derive(Clone, Copy)]
struct Scope {
    start: u32,
    end: u32,
}

#[derive(Clone, Copy)]
struct ByteRange {
    start: usize,
    end: usize,
}

fn is_definition(kind: &str) -> bool {
    matches!(
        kind,
        "function_item"
            | "function_signature_item"
            | "struct_item"
            | "enum_item"
            | "trait_item"
            | "union_item"
            | "mod_item"
            | "function_declaration"
            | "generator_function_declaration"
            | "function_signature"
            | "class_declaration"
            | "abstract_class_declaration"
            | "interface_declaration"
            | "enum_declaration"
            | "method_definition"
            | "method_signature"
            | "variable_declarator"
            | "assignment_expression"
            | "assignment_statement"
            | "field"
            | "function_definition"
            | "function_statement"
    )
}

fn collect_scopes(node: Node<'_>, out: &mut Vec<Scope>) {
    if is_definition(node.kind()) {
        out.push(Scope {
            start: node.start_position().row as u32 + 1,
            end: node.end_position().row as u32 + 1,
        });
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        collect_scopes(child, out);
    }
}

fn collect_comment_ranges(node: Node<'_>, out: &mut Vec<ByteRange>) {
    if node.kind().contains("comment") {
        out.push(ByteRange {
            start: node.start_byte(),
            end: node.end_byte(),
        });
        return;
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        collect_comment_ranges(child, out);
    }
}

// Blank and comment-only lines carry no executable or declarative syntax. Keeping them in
// `changed_lines` preserves the patch size, while excluding them from graph coverage avoids
// presenting a license/header edit as an unresolved dependency risk. A line containing any code
// remains semantic, including a top-level assignment followed by a trailing comment.
fn source_lines(source: &str) -> Vec<(usize, &str)> {
    let mut offset = 0usize;
    source
        .split('\n')
        .map(|raw| {
            let start = offset;
            offset += raw.len() + 1;
            (start, raw)
        })
        .collect()
}

fn nonsemantic_line(lines: &[(usize, &str)], comments: &[ByteRange], line: u32) -> bool {
    let Some((line_start, raw)) = lines.get(line.saturating_sub(1) as usize).copied() else {
        return false;
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return true;
    }
    let content_start = line_start + raw.find(trimmed).unwrap_or(0);
    let content_end = content_start + trimmed.len();
    comments
        .iter()
        .any(|range| range.start <= content_start && content_end <= range.end)
}

fn relative_path(root: &Path, raw: &str) -> std::result::Result<String, String> {
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    let candidate = PathBuf::from(raw);
    let absolute = if candidate.is_absolute() {
        candidate
    } else {
        root.join(candidate)
    };
    let absolute = absolute.canonicalize().map_err(|e| e.to_string())?;
    let relative = absolute
        .strip_prefix(&root)
        .map_err(|_| "path_outside_graph_root")?;
    Ok(relative.to_string_lossy().replace('\\', "/"))
}

impl Store {
    /// Audit changed source lines against resolved incoming calls. A result is a review lead;
    /// absence of leads never certifies that a patch is safe (dynamic calls are invisible here).
    pub fn audit_json(&self, root: &Path, request: &Value) -> Result<Value> {
        let changes = request
            .get("changes")
            .and_then(Value::as_array)
            .ok_or("changes_required")?;
        if changes.len() > 64 {
            return Err("too_many_changed_files".into());
        }
        let reviewed = request.get("reviewed").and_then(Value::as_array);
        let mut reviewed_paths = BTreeSet::new();
        if let Some(reviewed) = reviewed {
            if reviewed.len() > 256 {
                return Err("too_many_reviewed_files".into());
            }
            for item in reviewed {
                if let Some(path) = item.as_str() {
                    if let Ok(path) = relative_path(root, path) {
                        reviewed_paths.insert(path);
                    }
                }
            }
        }
        let mut changed_paths = BTreeSet::new();
        let mut normalized = Vec::new();
        let mut gaps = Vec::new();
        for change in changes {
            let Some(raw) = change.get("path").and_then(Value::as_str) else {
                gaps.push(json!({"reason":"path_required"}));
                continue;
            };
            match relative_path(root, raw) {
                Ok(path) => {
                    changed_paths.insert(path.clone());
                    normalized.push((path, change));
                }
                Err(reason) => gaps.push(json!({"path":raw,
                    "reason":change.get("gap").and_then(Value::as_str).unwrap_or(&reason)})),
            }
        }

        let mut total_lines = 0usize;
        let mut mapped_lines = 0usize;
        let mut ignored_lines = 0usize;
        let mut leads = BTreeMap::new();
        let mut changed_symbols = BTreeMap::new();
        for (path, change) in normalized {
            let Some(lines) = change.get("lines").and_then(Value::as_array) else {
                let reason = change
                    .get("gap")
                    .and_then(Value::as_str)
                    .unwrap_or("changed_lines_missing");
                gaps.push(json!({"path":path,"reason":reason}));
                continue;
            };
            if lines.len() > 4096 {
                return Err("too_many_changed_lines".into());
            }
            let Some(lang) = extract::language_for(&path) else {
                gaps.push(json!({"path":path,"reason":"unsupported_language"}));
                continue;
            };
            let Some(mut parser) = extract::parser_for(lang) else {
                gaps.push(json!({"path":path,"reason":"no_parser"}));
                continue;
            };
            let source = std::fs::read_to_string(root.join(&path))?;
            let Some(tree) = parser.parse(&source, None) else {
                gaps.push(json!({"path":path,"reason":"parse_failed"}));
                continue;
            };
            let mut scopes = Vec::new();
            collect_scopes(tree.root_node(), &mut scopes);
            let mut comments = Vec::new();
            collect_comment_ranges(tree.root_node(), &mut comments);
            let source_lines = source_lines(&source);
            let mut definitions = Vec::new();
            let mut stmt = self.conn.prepare(
                "SELECT id,kind,name,line FROM nodes WHERE path=?1 AND kind IN
                 ('fn','method','class','interface','enum','struct','trait','union','module')",
            )?;
            let rows = stmt.query_map(params![path], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, u32>(3)?,
                ))
            })?;
            for row in rows {
                definitions.push(row?);
            }
            let mut touched = BTreeSet::new();
            for raw_line in lines {
                let Some(line) = raw_line.as_u64().and_then(|n| u32::try_from(n).ok()) else {
                    gaps.push(json!({"path":path,"reason":"invalid_changed_line"}));
                    continue;
                };
                total_lines += 1;
                if nonsemantic_line(&source_lines, &comments, line) {
                    ignored_lines += 1;
                    continue;
                }
                let chosen = definitions
                    .iter()
                    .filter_map(|(id, kind, name, def_line)| {
                        scopes
                            .iter()
                            .filter(|scope| {
                                scope.start == *def_line && scope.start <= line && line <= scope.end
                            })
                            .min_by_key(|scope| scope.end - scope.start)
                            .map(|scope| (id, kind, name, def_line, scope.end - scope.start))
                    })
                    .min_by_key(|(_, _, _, _, span)| *span);
                if let Some((id, kind, name, def_line, _)) = chosen {
                    mapped_lines += 1;
                    touched.insert(*id);
                    changed_symbols.insert(
                        *id,
                        json!({"id":id,"kind":kind,"name":name,
                        "path":path,"line":def_line}),
                    );
                } else {
                    gaps.push(json!({"path":path,"line":line,"reason":"no_enclosing_definition"}));
                }
            }
            for id in touched {
                let mut stmt = self.conn.prepare(
                    "SELECT n.name,e.path,e.line,e.kind FROM edges e
                     JOIN nodes n ON n.id=e.dst WHERE e.dst=?1 AND e.kind='calls'
                     ORDER BY e.path,e.line",
                )?;
                let edges = stmt.query_map(params![id], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                })?;
                for edge in edges {
                    let (symbol, caller_path, caller_line, kind) = edge?;
                    if caller_path == path
                        || changed_paths.contains(&caller_path)
                        || reviewed_paths.contains(&caller_path)
                    {
                        continue;
                    }
                    let key = format!("{caller_path}:{caller_line}:{symbol}");
                    leads.insert(
                        key,
                        json!({"path":caller_path,"line":caller_line,
                        "kind":kind,"changed_path":path,"symbol":symbol,
                        "reason":"resolved_call_into_changed_definition"}),
                    );
                }
            }
        }
        let lead_count = leads.len();
        let gap_count = gaps.len();
        let lead_rows: Vec<Value> = leads.into_values().take(20).collect();
        let changed_symbol_count = changed_symbols.len();
        Ok(json!({
            "verdict": if !gaps.is_empty() { "incomplete" } else if lead_count > 0 { "leads" } else { "no_leads" },
            "leads": lead_rows, "lead_count": lead_count, "truncated": lead_count > 20,
            "changed_lines": total_lines, "mapped_lines": mapped_lines,
            "ignored_lines": ignored_lines,
            "changed_symbol_count": changed_symbol_count,
            "changed_symbols": changed_symbols.into_values().collect::<Vec<_>>(),
            "gap_count": gap_count, "gaps": gaps.into_iter().take(20).collect::<Vec<_>>(),
            "scope": "resolved_calls_only_not_a_correctness_proof",
        }))
    }

    /// Expand changed definitions through resolved relationships. The result is a review map with
    /// provenance, not a safety score: dynamic dispatch and unsupported syntax remain explicit gaps.
    pub fn impact_json(&self, root: &Path, request: &Value) -> Result<Value> {
        let audit = self.audit_json(root, request)?;
        let generation = self.generation()?;
        let direction = request
            .get("direction")
            .and_then(Value::as_str)
            .unwrap_or("both");
        if !matches!(direction, "inbound" | "outbound" | "both") {
            return Err("invalid_impact_direction".into());
        }
        let depth = request
            .get("depth")
            .and_then(Value::as_u64)
            .unwrap_or(2)
            .clamp(1, 4) as i64;
        let limit = request
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(50)
            .clamp(1, 200) as usize;
        let max_bytes = request
            .get("max_bytes")
            .and_then(Value::as_u64)
            .unwrap_or(24_000)
            .clamp(2_048, 200_000) as usize;
        let digest = crate::store::fnv1a(&serde_json::to_vec(&json!({
            "changes":request.get("changes"),"direction":direction,"depth":depth
        }))?);
        let mut offset = request.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        if let Some(cursor) = request.get("cursor").and_then(Value::as_str) {
            let parts: Vec<&str> = cursor.split('.').collect();
            if parts.len() != 3 || parts[0] != generation || parts[2] != digest {
                return Err("stale_or_mismatched_impact_cursor".into());
            }
            offset = parts[1]
                .parse::<usize>()
                .map_err(|_| "invalid_impact_cursor")?;
        }

        let changed = audit
            .get("changed_symbols")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let changed_total = changed.len();
        let changed_public: Vec<Value> = changed
            .iter()
            .take(limit)
            .map(|symbol| {
                json!({
                    "kind":symbol.get("kind"),"name":symbol.get("name"),
                    "path":symbol.get("path"),"line":symbol.get("line")
                })
            })
            .collect();
        let mut visited: HashMap<i64, i64> = HashMap::new();
        let mut queue = VecDeque::new();
        for symbol in &changed {
            if let Some(id) = symbol.get("id").and_then(Value::as_i64) {
                visited.insert(id, 0);
                queue.push_back(id);
            }
        }
        let changed_ids: BTreeSet<i64> = visited.keys().copied().collect();
        let mut impacted: BTreeMap<i64, Value> = BTreeMap::new();
        while let Some(current) = queue.pop_front() {
            let hop = *visited.get(&current).unwrap_or(&0);
            if hop >= depth {
                continue;
            }
            if matches!(direction, "inbound" | "both") {
                let mut stmt = self.conn.prepare(
                    "SELECT n.id,n.kind,n.name,n.path,n.line,e.kind,e.path,e.line,
                            e.resolution,e.confidence
                     FROM edges e JOIN nodes n ON n.id=e.src
                     WHERE e.dst=?1 AND e.kind<>'mentions' ORDER BY n.path,n.line",
                )?;
                let rows = stmt.query_map(params![current], impact_row)?;
                for row in rows {
                    let (id, mut value) = row?;
                    let next_hop = hop + 1;
                    if visited.get(&id).map_or(true, |old| next_hop < *old) {
                        visited.insert(id, next_hop);
                        queue.push_back(id);
                    }
                    if !changed_ids.contains(&id) {
                        value["hop"] = json!(next_hop);
                        value["direction"] = json!("caller");
                        impacted.entry(id).or_insert(value);
                    }
                }
            }
            if matches!(direction, "outbound" | "both") {
                let mut stmt = self.conn.prepare(
                    "SELECT n.id,n.kind,n.name,n.path,n.line,e.kind,e.path,e.line,
                            e.resolution,e.confidence
                     FROM edges e JOIN nodes n ON n.id=e.dst
                     WHERE e.src=?1 AND e.dst IS NOT NULL AND e.kind<>'mentions'
                     ORDER BY n.path,n.line",
                )?;
                let rows = stmt.query_map(params![current], impact_row)?;
                for row in rows {
                    let (id, mut value) = row?;
                    let next_hop = hop + 1;
                    if visited.get(&id).map_or(true, |old| next_hop < *old) {
                        visited.insert(id, next_hop);
                        queue.push_back(id);
                    }
                    if !changed_ids.contains(&id) {
                        value["hop"] = json!(next_hop);
                        value["direction"] = json!("dependency");
                        impacted.entry(id).or_insert(value);
                    }
                }
            }
        }
        let mut rows: Vec<Value> = impacted.into_values().collect();
        rows.sort_by(|a, b| {
            a["hop"]
                .as_i64()
                .cmp(&b["hop"].as_i64())
                .then_with(|| a["path"].as_str().cmp(&b["path"].as_str()))
                .then_with(|| a["line"].as_i64().cmp(&b["line"].as_i64()))
        });
        let total = rows.len();
        if offset > total {
            return Err("impact_offset_out_of_range".into());
        }
        let mut selected = rows
            .into_iter()
            .skip(offset)
            .take(limit)
            .collect::<Vec<_>>();
        let build = |selected: &[Value]| {
            let next = offset + selected.len();
            json!({
                "generation":generation,"freshness":"verified_snapshot",
                "direction":direction,"depth":depth,
                "changed_symbols":{"total":changed_total,"returned":changed_public.len(),
                    "truncated":changed_public.len() < changed_total,"rows":changed_public},
                "impact":{"total":total,"offset":offset,"returned":selected.len(),
                    "truncated":next < total,"rows":selected,
                    "next_cursor":if next < total { json!(format!("{generation}.{next}.{digest}")) } else { Value::Null }},
                "coverage":{"changed_lines":audit.get("changed_lines"),
                    "mapped_lines":audit.get("mapped_lines"),"ignored_lines":audit.get("ignored_lines"),
                    "gap_count":audit.get("gap_count"),"gaps":audit.get("gaps")},
                "scope":"resolved_static_edges_only_not_a_correctness_or_risk_score"
            })
        };
        let mut output = build(&selected);
        while serde_json::to_vec(&output)?.len() > max_bytes && !selected.is_empty() {
            selected.pop();
            output = build(&selected);
        }
        if serde_json::to_vec(&output)?.len() > max_bytes {
            return Err(if total > offset {
                "impact_budget_too_small_for_one_row"
            } else {
                "impact_budget_too_small_for_metadata"
            }
            .into());
        }
        Ok(output)
    }
}

fn impact_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<(i64, Value)> {
    let id = row.get::<_, i64>(0)?;
    let path = row.get::<_, String>(3)?;
    Ok((
        id,
        json!({
            "kind":row.get::<_, String>(1)?,"name":row.get::<_, String>(2)?,
            "path":path,"line":row.get::<_, i64>(4)?,
            "module":path.split('/').next().unwrap_or("."),
            "test":path.starts_with("tests/") || path.contains("/tests/")
                || path.contains("/test_") || path.contains("/test-"),
            "via":{"kind":row.get::<_, String>(5)?,"path":row.get::<_, String>(6)?,
                "line":row.get::<_, i64>(7)?,"resolution":row.get::<_, String>(8)?,
                "confidence":row.get::<_, i64>(9)?}
        }),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn changed_lua_body_reports_only_unreviewed_resolved_callers() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir =
            std::env::temp_dir().join(format!("wa-graph-audit-{}-{unique}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("source.lua"),
            "function M.changed()\n  return 2\nend\nfunction M.other()\n  return 1\nend\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("caller.lua"),
            "local M = require('source')\nfunction use_changed() return M.changed() end\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("other.lua"),
            "local M = require('source')\nfunction use_other() return M.other() end\n",
        )
        .unwrap();
        let mut store = Store::open(dir.join("graph.db")).unwrap();
        store.index(&dir, false).unwrap();
        let report = store
            .audit_json(
                &dir,
                &json!({
                    "changes":[{"path":"source.lua","lines":[2]}],"reviewed":[]
                }),
            )
            .unwrap();
        assert_eq!(report["verdict"], "leads");
        assert_eq!(report["mapped_lines"], 1);
        assert_eq!(report["lead_count"], 1, "{report}");
        assert_eq!(report["leads"][0]["path"], "caller.lua");
        assert_eq!(report["leads"][0]["line"], 2);
        let reviewed = store
            .audit_json(
                &dir,
                &json!({
                    "changes":[{"path":"source.lua","lines":[2]}],"reviewed":["caller.lua"]
                }),
            )
            .unwrap();
        assert_eq!(reviewed["lead_count"], 0);
        assert_eq!(reviewed["verdict"], "no_leads");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn top_level_edit_is_an_explicit_coverage_gap() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "wa-graph-audit-gap-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("source.lua"),
            "local setting = 2\nfunction M.f() return setting end\n",
        )
        .unwrap();
        let mut store = Store::open(dir.join("graph.db")).unwrap();
        store.index(&dir, false).unwrap();
        let report = store
            .audit_json(
                &dir,
                &json!({
                    "changes":[{"path":"source.lua","lines":[1]}],"reviewed":[]
                }),
            )
            .unwrap();
        assert_eq!(report["verdict"], "incomplete");
        assert_eq!(report["mapped_lines"], 0);
        assert_eq!(report["gaps"][0]["reason"], "no_enclosing_definition");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn blank_and_comment_only_lines_are_not_coverage_gaps() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "wa-graph-audit-comments-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("source.lua"),
            "-- module header\n\nlocal setting = 2 -- semantic\n--[[\nmore notes\n]]\n",
        )
        .unwrap();
        let mut store = Store::open(dir.join("graph.db")).unwrap();
        store.index(&dir, false).unwrap();
        let report = store
            .audit_json(
                &dir,
                &json!({
                    "changes":[{"path":"source.lua","lines":[1,2,3,4,5,6]}],"reviewed":[]
                }),
            )
            .unwrap();
        assert_eq!(report["changed_lines"], 6);
        assert_eq!(report["ignored_lines"], 5);
        assert_eq!(report["gap_count"], 1, "{report}");
        assert_eq!(report["gaps"][0]["line"], 3);
        assert_eq!(report["gaps"][0]["reason"], "no_enclosing_definition");
        std::fs::remove_dir_all(&dir).ok();
    }
}
