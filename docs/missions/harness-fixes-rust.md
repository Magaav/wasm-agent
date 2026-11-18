# Mission change/harness-fixes-rust — items 6, 7, 8 of harness-fixes (Rust)

Base: branch change/harness-fixes (commit 62c3c064). Read its REPORT.md first: it records items 6-8 as
"not delivered: needs cargo" and the reading already done. cargo is now on PATH on this node.
Each item: a test that fails before and passes after, quoted in REPORT.md (append a section).

6. `wa-sentinel request withdraw <id>`: a queued or held request may be withdrawn (moved out of the queue
   with one audit line); a claimed/running one is refused by name. `wa-sentinel status` shows, for a held
   request, how to unblock or withdraw it. (rust/wa-sentinel/src/main.rs, request verbs ~line 2039)
7. Return-observation log spam: `return-observation-problem` (main.rs:3007) is written once per
   (id, error); after that the entry is retired or quarantined and stops being observed. Measured on work:
   ~520,000 lines, the same 5 ids every tick, error "No such file or directory".
8. A binding's `state.service` (the rendezvous/relay URL) is never stored as a peer's direct address.
   Measured: work's mesh/peers.json gives avell `addresses: ["https://rendezvous.colmeio.com"]` (source
   "roster"; the signed roster has []); every call first fails `resolve_failed:invalid port value`.
   (rust/wa-mesh, cache.rs / seam.rs per the report)

Build and test on this node only; `cargo test -p <crate>` for the crates you touch, then the fast suite.
Commit locally on change/harness-fixes-rust; never push.
