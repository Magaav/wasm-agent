// `wa health` says which user-facing features still work on this node, and when each last worked.
//
// The Lua side (lua/core/feature_health.lua) decides and records the verdicts; this file RENDERS the two
// files it keeps, for the one command an operator types when something feels wrong. It is the same list and
// the same words - the registry's own `stale_after_s`, and the five verdicts - and it deliberately computes
// the verdict from the same two facts (the last success, the last failure) instead of reading a cached one,
// so `wa health` cannot disagree with `wa features` about a node it can see.
//
// WHY THIS IS HERE AND NOT ON THE NODE: `wa health` already prints the node's own /health document, and that
// document is answered by the running node - which is exactly what is missing when the node is the thing
// that is broken. These two files are on disk, so the answer survives a node that will not start.

use serde_json::Value;
use std::path::{Path, PathBuf};

/// The five words the Lua module uses, so an operator reads one vocabulary: working, stale, failing,
/// never, off-node.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Working,
    Stale,
    Failing,
    Never,
    OffNode,
}

impl Verdict {
    pub fn word(self) -> &'static str {
        match self {
            Verdict::Working => "working",
            Verdict::Stale => "stale",
            Verdict::Failing => "failing",
            Verdict::Never => "never",
            Verdict::OffNode => "off-node",
        }
    }
}

/// One row of the answer.
#[derive(Debug, Clone)]
pub struct Row {
    pub name: String,
    pub verdict: Verdict,
    pub last_ok_at: Option<i64>,
    /// What KIND of success the time records: 'canary' means an exercise proved it, not a user (Fable,
    /// 23/11: a synthetic pass must not read as real use). "record"/absent is a real code path.
    pub last_ok_source: Option<String>,
    pub detail: String,
}

/// ISO-8601 UTC, whole seconds. No date crate is a dependency of the sentinel (a supervisor must not share
/// a graph with what it supervises), so the civil date is computed here - fifteen lines, and a test that
/// pins the three dates that would catch a wrong epoch base.
pub fn iso_utc(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let rem = seconds.rem_euclid(86_400);
    let (hour, minute, second) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    // Howard Hinnant's civil_from_days: the days since 1970-01-01 to a proleptic Gregorian date.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    format!("{year:04}-{m:02}-{d:02}T{hour:02}:{minute:02}:{second:02}Z")
}

fn number(value: Option<&Value>) -> Option<i64> {
    value.and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

/// The verdict for one row and its snapshot entry, in the Lua module's rules (`M.verdict`): a failure at or
/// after the last success is failing; a success older than the row's own bound is stale; nothing recorded is
/// never.
pub fn verdict(stale_after_s: i64, entry: Option<&Value>, now: i64) -> (Verdict, String) {
    let Some(entry) = entry else {
        return (Verdict::Never, "nothing has been recorded for it on this node".to_string());
    };
    let last_ok = number(entry.get("last_ok_at"));
    let last_fail = number(entry.get("last_fail_at"));
    if last_ok.is_none() && last_fail.is_none() {
        return (Verdict::Never, "nothing has been recorded for it on this node".to_string());
    }
    let failed = match (last_fail, last_ok) {
        (Some(fail), None) => Some(fail),
        (Some(fail), Some(ok)) if fail >= ok => Some(fail),
        _ => None,
    };
    if let Some(fail) = failed {
        let stage = entry.get("last_fail_stage").and_then(|v| v.as_str()).unwrap_or("unknown");
        let worked = last_ok
            .map(|ok| format!("; last worked {}", iso_utc(ok)))
            .unwrap_or_else(|| "; it has never worked".to_string());
        return (Verdict::Failing, format!("last failed at {} (stage {stage}){worked}", iso_utc(fail)));
    }
    let ok = last_ok.unwrap_or(now);
    let age = now.saturating_sub(ok).max(0);
    if age > stale_after_s {
        return (Verdict::Stale, format!("last worked {} ago ({}), past its bound of {}s", age_word(age), iso_utc(ok), stale_after_s));
    }
    (Verdict::Working, format!("last worked {} ago", age_word(age)))
}

fn age_word(seconds: i64) -> String {
    if seconds < 60 {
        "just now".to_string()
    } else if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h", seconds / 3600)
    } else {
        format!("{}d", seconds / 86_400)
    }
}

/// Whether this node can run the feature at all: a role of `any`, or a component that is installed HERE
/// (its definition AND its binary - a definition with no binary is an install that did not finish).
fn applies(config: &Path, role: &str) -> (bool, String) {
    if role == "any" {
        return (true, String::new());
    }
    let Some(component) = role.strip_prefix("component:") else {
        return (false, format!("the role {role} is not one this reader understands"));
    };
    let dir = config.join("components");
    if !dir.join(format!("{component}.json")).exists() {
        return (false, format!("{component} is not installed on this node"));
    }
    if !dir.join(format!("{component}.wasm")).exists() {
        return (false, format!("{component} has a definition but no component binary on this node"));
    }
    (true, String::new())
}

/// Every feature, in registry order. `Err` names the file that could not be read - a node without the
/// registry is not a node with no features.
pub fn rows(config: &Path, now: i64) -> Result<Vec<Row>, String> {
    let registry_path = config.join("features.json");
    let text = std::fs::read_to_string(&registry_path)
        .map_err(|error| format!("{} could not be read ({error})", registry_path.display()))?;
    let registry: Value = serde_json::from_str(&text)
        .map_err(|error| format!("{} does not parse ({error})", registry_path.display()))?;
    let Some(features) = registry.get("features").and_then(|v| v.as_array()) else {
        return Err(format!("{} has no features array", registry_path.display()));
    };
    let snapshot_path = config.join("feature-health.json");
    let snapshot: Value = std::fs::read_to_string(&snapshot_path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_else(|| serde_json::json!({ "features": {} }));
    let mut out = Vec::new();
    for feature in features {
        let name = feature.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
        if name.is_empty() {
            return Err(format!("{} has a row with no name", registry_path.display()));
        }
        let role = feature.get("role").and_then(|v| v.as_str()).unwrap_or("any");
        let bound = number(feature.get("stale_after_s")).unwrap_or(0);
        let entry = snapshot.get("features").and_then(|v| v.get(&name));
        let (mut verdict, mut detail) = verdict(bound, entry, now);
        let (runs_here, why_not) = applies(config, role);
        if !runs_here {
            verdict = Verdict::OffNode;
            detail = why_not;
        }
        out.push(Row {
            name,
            verdict,
            last_ok_at: entry.and_then(|e| number(e.get("last_ok_at"))),
            last_ok_source: entry
                .and_then(|e| e.get("last_ok_source"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            detail,
        });
    }
    Ok(out)
}

/// The lines `wa health` prints after the node's own document: one summary and one row per feature, each
/// with the time it last worked - the operator's question, answered on the node that is asking.
pub fn lines(config: &Path, now: i64) -> Vec<String> {
    match rows(config, now) {
        Err(why) => vec![format!("features:  unreadable - {why}")],
        Ok(rows) => {
            let count = |verdict: Verdict| rows.iter().filter(|row| row.verdict == verdict).count();
            let mut out = vec![format!(
                "features:  {} listed  {} working  {} stale  {} failing  {} never  {} off-node",
                rows.len(),
                count(Verdict::Working),
                count(Verdict::Stale),
                count(Verdict::Failing),
                count(Verdict::Never),
                count(Verdict::OffNode)
            )];
            let width = rows.iter().map(|row| row.name.len()).max().unwrap_or(0);
            for row in rows {
                let last = row.last_ok_at.map(iso_utc).unwrap_or_else(|| "never".to_string());
                // A CANARY'S TIME SAYS SO. Until real-traffic hooks land most rows are proven by an exercise,
                // and printing that as if a user had just used the feature is the false comfort this whole
                // mechanism is against.
                let kind = if row.last_ok_source.as_deref() == Some("canary") { "  [canary]" } else { "" };
                out.push(format!(
                    "  {:<width$}  {:<8}  last worked: {last}{kind}  ({})",
                    row.name,
                    row.verdict.word(),
                    row.detail,
                    width = width
                ));
            }
            out
        }
    }
}

/// Where the two files are, from the same two roots the rest of the sentinel uses.
pub fn config_dir_for(home: &Path) -> PathBuf {
    home.join(".wasm-agent")
}
