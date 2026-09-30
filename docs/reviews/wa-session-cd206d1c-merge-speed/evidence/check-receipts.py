# Reviewer's receipt checker (read-only). Re-hashes each run's retained gate log and compares it with
# the sha256 the run itself recorded, and prints the fields this review quotes.
# Usage: python check-receipts.py
import hashlib, json, os

BASE = r"C:\Users\Victor\.wasm-agent"
RUNS = [
    ("cold",      "merge-lane-landing-cold"),
    ("warm",      "merge-lane-landing-warm"),
    ("broken",    "merge-lane-landing-broken"),
    ("restored1", "merge-lane-landing-restored"),
    ("restored2", "merge-lane-landing-restored2"),
]
print("%-10s %-12s %-6s %-8s %-13s %-8s %-6s %-8s %s" % (
    "run", "gate.ms", "g.exit", "lane.exit", "slot", "reused", "tree", "log ok", "dirt/toolchain"))
for name, stem in RUNS:
    d = json.load(open(os.path.join(BASE, stem + ".json")))
    log = d["gate"]["log"]
    real = hashlib.sha256(open(log, "rb").read()).hexdigest()
    print("%-10s %-12s %-6s %-8s %-13s %-8s %-6s %-8s dirt=%s toolchain=%s" % (
        name, d["gate"]["ms"], d["gate"]["exit"], d.get("exit_code"),
        "#" + str(d["gate"]["lane"].get("request")), d["clone"]["reused"],
        d["candidate"]["tree"][:12], real == d["gate"]["log_sha256"],
        d["clone"].get("reuse_dirt_discarded"), d["clone"].get("toolchain_cleared")))
