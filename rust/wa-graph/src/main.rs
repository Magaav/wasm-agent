//! CLI for the graph. Hand-rolled argument parsing, matching the project's zero-framework style.

use std::path::PathBuf;
use std::process::ExitCode;
use wa_graph::Store;

const USAGE: &str = "\
wa-graph — query wasm-agent's code as a graph

USAGE:
  wa-graph index [--root DIR] [--db FILE] [--force]
  wa-graph explain <name> [--db FILE] [--json]
  wa-graph path <from> <to> [--db FILE] [--json]
  wa-graph query <text> [--db FILE] [--json]
  wa-graph search <concept> [--db FILE] [--json] [--prefer-implementations]
  wa-graph caps [--db FILE]
  wa-graph stats [--db FILE]

ENV:
  WA_GRAPH_DB   database path (default: <root>/.wa-graph/graph.db)
";

struct Args {
    positional: Vec<String>,
    root: PathBuf,
    db: Option<PathBuf>,
    force: bool,
    json: bool,
    prefer_implementations: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut positional = Vec::new();
    let mut root = std::env::current_dir().map_err(|e| e.to_string())?;
    let mut db = None;
    let mut force = false;
    let mut json = false;
    let mut prefer_implementations = false;
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--root" => root = PathBuf::from(it.next().ok_or("--root needs a value")?),
            "--db" => db = Some(PathBuf::from(it.next().ok_or("--db needs a value")?)),
            "--force" => force = true,
            "--prefer-implementations" => prefer_implementations = true,
            "--json" => json = true,
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            other => positional.push(other.to_string()),
        }
    }
    Ok(Args {
        positional,
        root,
        db,
        force,
        json,
        prefer_implementations,
    })
}

fn db_path(args: &Args) -> PathBuf {
    if let Some(db) = &args.db {
        return db.clone();
    }
    if let Ok(env) = std::env::var("WA_GRAPH_DB") {
        if !env.is_empty() {
            return PathBuf::from(env);
        }
    }
    args.root.join(".wa-graph").join("graph.db")
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("wa-graph: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    let cmd = args
        .positional
        .first()
        .map(String::as_str)
        .unwrap_or("")
        .to_string();
    if cmd.is_empty() {
        print!("{USAGE}");
        return Ok(());
    }
    let db = db_path(&args);
    match cmd.as_str() {
        "index" => {
            let mut store = Store::open(&db).map_err(|e| e.to_string())?;
            let report = store
                .index(&args.root, args.force)
                .map_err(|e| e.to_string())?;
            if args.json {
                println!(
                    "{{\"indexed\":{},\"unchanged\":{},\"removed\":{},\"nodes\":{},\"edges\":{},\"resolved\":{},\"unresolved\":{},\"db\":{}}}",
                    report.indexed, report.unchanged, report.removed, report.nodes, report.edges,
                    report.resolved, report.unresolved, json_str(&db.to_string_lossy())
                );
            } else {
                println!(
                    "indexed {} ({} unchanged, {} removed) · {} nodes · {} edges · {}/{} refs resolved",
                    report.indexed,
                    report.unchanged,
                    report.removed,
                    report.nodes,
                    report.edges,
                    report.resolved,
                    report.edges,
                );
                println!("db: {}", db.display());
            }
        }
        "explain" => {
            let name = args.positional.get(1).ok_or("explain needs a name")?;
            let store = Store::open(&db).map_err(|e| e.to_string())?;
            let rows = store.explain(name).map_err(|e| e.to_string())?;
            if rows.is_empty() {
                println!("no definition matches {name:?}");
                return Ok(());
            }
            if args.json {
                print!("[");
                for (i, (n, out, inc)) in rows.iter().enumerate() {
                    if i > 0 {
                        print!(",");
                    }
                    print!(
                        "{{\"node\":{},\"outgoing\":{},\"incoming\":{}}}",
                        node_json(n),
                        edges_json(out),
                        edges_json(inc)
                    );
                }
                println!("]");
            } else {
                for (n, out, inc) in rows {
                    println!("{} {}  {}:{}", n.kind, n.name, n.path, n.line);
                    if let Some(d) = &n.detail {
                        println!("    {d}");
                    }
                    if !out.is_empty() {
                        println!("  → uses:");
                        for e in out {
                            let dst = e
                                .dst_path
                                .as_ref()
                                .map(|p| format!("  → {}:{}", p, e.dst_line.unwrap_or(0)))
                                .unwrap_or_default();
                            println!("    {:9} {}{}", e.kind, e.target, dst);
                        }
                    }
                    if !inc.is_empty() {
                        println!("  ← used by:");
                        for e in inc {
                            println!("    {:9} {}:{}", e.kind, e.path, e.line);
                        }
                    }
                }
            }
        }
        "path" => {
            let from = args.positional.get(1).ok_or("path needs <from> <to>")?;
            let to = args.positional.get(2).ok_or("path needs <from> <to>")?;
            let store = Store::open(&db).map_err(|e| e.to_string())?;
            match store.path(from, to).map_err(|e| e.to_string())? {
                Some(chain) => {
                    for (i, (n, label)) in chain.iter().enumerate() {
                        if i == 0 {
                            println!("{} {}  {}:{}", n.kind, n.name, n.path, n.line);
                        } else {
                            println!("  --{label}-->");
                            println!("{} {}  {}:{}", n.kind, n.name, n.path, n.line);
                        }
                    }
                }
                None => println!("no path from {from:?} to {to:?}"),
            }
        }
        "query" => {
            let text = args.positional.get(1).ok_or("query needs text")?;
            let store = Store::open(&db).map_err(|e| e.to_string())?;
            let rows = store.query(text, 12).map_err(|e| e.to_string())?;
            if args.json {
                print!("[");
                for (i, n) in rows.iter().enumerate() {
                    if i > 0 {
                        print!(",");
                    }
                    print!("{}", node_json(n));
                }
                println!("]");
            } else {
                for n in rows {
                    println!("{} {}  {}:{}", n.kind, n.name, n.path, n.line);
                }
            }
        }
        "search" => {
            let text = args.positional.get(1).ok_or("search needs a concept")?;
            let store = Store::open(&db).map_err(|e| e.to_string())?;
            let rows = store.search_symbols_json_with_preference(
                text, 12, args.prefer_implementations,
            ).map_err(|e| e.to_string())?;
            if args.json {
                println!("{rows}");
            } else if let Some(hits) = rows.as_array() {
                for hit in hits {
                    let name = hit["name"].as_str().unwrap_or("?");
                    let kind = hit["kind"].as_str().unwrap_or("?");
                    let path = hit["path"].as_str().unwrap_or("?");
                    let line = hit["line"].as_i64().unwrap_or(0);
                    let confidence = hit["confidence"].as_str().unwrap_or("?");
                    println!("{confidence:6} {kind:8} {name}  {path}:{line}");
                }
            }
        }
        "caps" => {
            let store = Store::open(&db).map_err(|e| e.to_string())?;
            for (name, uses) in store.capabilities().map_err(|e| e.to_string())? {
                println!("{uses:5}  {name}");
            }
        }
        "stats" => {
            let store = Store::open(&db).map_err(|e| e.to_string())?;
            let s = store.stats().map_err(|e| e.to_string())?;
            println!(
                "files {} · nodes {} · edges {} · resolved {} · unresolved {}",
                s.files, s.nodes, s.edges, s.resolved, s.unresolved
            );
            for (kind, n) in s.by_kind {
                println!("  {n:6}  {kind}");
            }
        }
        other => return Err(format!("unknown command {other:?}\n\n{USAGE}")),
    }
    Ok(())
}

fn json_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn node_json(n: &wa_graph::NodeRow) -> String {
    format!(
        "{{\"id\":{},\"kind\":{},\"name\":{},\"path\":{},\"line\":{},\"detail\":{}}}",
        n.id,
        json_str(&n.kind),
        json_str(&n.name),
        json_str(&n.path),
        n.line,
        n.detail
            .as_deref()
            .map(json_str)
            .unwrap_or_else(|| "null".into())
    )
}

fn edges_json(edges: &[wa_graph::store::EdgeRow]) -> String {
    let items: Vec<String> = edges
        .iter()
        .map(|e| {
            format!(
                "{{\"kind\":{},\"target\":{},\"path\":{},\"line\":{},\"dst\":{}}}",
                json_str(&e.kind),
                json_str(&e.target),
                json_str(&e.path),
                e.line,
                e.dst
                    .map(|d| d.to_string())
                    .unwrap_or_else(|| "null".into())
            )
        })
        .collect();
    format!("[{}]", items.join(","))
}
