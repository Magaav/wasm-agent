// serde_json's side of a seam payload: what parsing and re-serialising the SAME bytes Lua wrote
// costs, so the seam's JSON share is one number from two parsers (scripts/bench-seams.lua).
//
//   cargo run --release -p wa-host-support --example json-cost -- <payload-dir>
//
// Every *.json file in the directory is measured: serde_json::from_str into a Value (the parse the
// host does on what Lua sent) and to_string (the encode it does on the way back). p50/p99 in
// microseconds over 500 rounds, one file at a time, printed as TSV:
//
//   serde <name> <bytes> <parse_p50_us> <parse_p99_us> <encode_p50_us> <encode_p99_us>
//
// No payloads: the caller prints the SKIP and its reason.
use std::time::Instant;

fn pct(samples: &mut Vec<f64>, p: f64) -> f64 {
    if samples.is_empty() { return 0.0; }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let i = ((samples.len() as f64 * p).ceil() as usize).clamp(1, samples.len()) - 1;
    samples[i]
}

fn main() {
    let dir = match std::env::args().nth(1) {
        Some(d) => d,
        None => { eprintln!("usage: json-cost <payload-dir>"); std::process::exit(2); }
    };
    let mut names = Vec::new();
    match std::fs::read_dir(&dir) {
        Ok(entries) => {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("json") {
                    if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                        names.push(stem.to_string());
                    }
                }
            }
        }
        Err(error) => { eprintln!("json-cost: cannot read {dir}: {error}"); std::process::exit(2); }
    }
    names.sort();
    if names.is_empty() {
        eprintln!("json-cost: no *.json payload in {dir} - a check that measures nothing is not a pass");
        std::process::exit(3);
    }
    for name in names {
        let path = format!("{dir}/{name}.json");
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(error) => { eprintln!("json-cost: {path}: {error}"); continue; }
        };
        let rounds = 500usize;
        let mut parse = Vec::with_capacity(rounds);
        let mut encode = Vec::with_capacity(rounds);
        let mut value = serde_json::Value::Null;
        for _ in 0..rounds {
            let t0 = Instant::now();
            match serde_json::from_str::<serde_json::Value>(&text) {
                Ok(v) => value = v,
                Err(error) => { eprintln!("json-cost: {path}: not JSON ({error})"); break; }
            }
            parse.push(t0.elapsed().as_nanos() as f64 / 1000.0);
            let t1 = Instant::now();
            let _ = serde_json::to_string(&value);
            encode.push(t1.elapsed().as_nanos() as f64 / 1000.0);
        }
        if parse.is_empty() { continue; }
        println!("serde\t{}\t{}\t{:.1}\t{:.1}\t{:.1}\t{:.1}",
            name, text.len(), pct(&mut parse, 0.50), pct(&mut parse, 0.99),
            pct(&mut encode, 0.50), pct(&mut encode, 0.99));
    }
}
