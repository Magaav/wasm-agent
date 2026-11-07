#!/usr/bin/env bash
# Proof for the telemetry sink (docs/OBSERVABILITY.md, "The sink"), self-contained and localhost only:
# no node, no collector, no network beyond 127.0.0.1, no deploy.
#
#   bash scripts/test-telemetry-sink.sh          # unit + integration tests, then the measurements
#   WA_SINK_NO_COMPONENT=1 bash scripts/test-telemetry-sink.sh   # skip the wasm build
#
# What it proves, in order:
#   1. `cargo test -p wa-telemetry-sink` - the records, the redaction rules, the bus codec, the bounded
#      buffer, the JSONL writer and the OTLP edge (the exporter tests bind 127.0.0.1 and nothing else);
#   2. the two measurement tests, printed: a 10 000-event burst (producer latency before/after, drops
#      counted) and the optimization check (latency + RSS before/after with the sink on);
#   3. the component builds for wasm32-wasip2 and its manifest grants `subscribe = ["*"]` and nothing to
#      publish - a sink that could publish is a way to forge the record it is supposed to keep.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
checks=0; fails=0
ok()   { checks=$((checks + 1)); echo "ok   $*"; }
bad()  { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
skip() { echo "SKIP $*"; }

if ! command -v cargo >/dev/null 2>&1; then
  echo "telemetry sink: SKIPPED (no cargo on PATH)"
  exit 0
fi

# Offline by default: the crate has no dependencies to fetch, and a test that silently downloads is a
# test that cannot run on a node with no registry access. `WA_SINK_FETCH=1` opts into a fetch.
offline=(--offline)
[ "${WA_SINK_FETCH:-0}" = 1 ] && offline=()

echo "== cargo test -p wa-telemetry-sink"
if cargo test -p wa-telemetry-sink "${offline[@]}" --manifest-path rust/Cargo.toml > /tmp/wa-sink-test.log 2>&1; then
  ok "cargo test -p wa-telemetry-sink ($(grep -c '^test result: ok' /tmp/wa-sink-test.log) suites)"
  grep -E '^test result' /tmp/wa-sink-test.log | sed 's/^/     /'
else
  bad "cargo test -p wa-telemetry-sink"
  tail -20 /tmp/wa-sink-test.log
fi

if command -v cargo-clippy >/dev/null 2>&1 || cargo clippy --version >/dev/null 2>&1; then
  if cargo clippy -p wa-telemetry-sink "${offline[@]}" --all-targets --manifest-path rust/Cargo.toml > /tmp/wa-sink-clippy.log 2>&1; then
    ok "cargo clippy -p wa-telemetry-sink"
  else
    bad "cargo clippy -p wa-telemetry-sink"; grep -E '^(warning|error)' /tmp/wa-sink-clippy.log | head -10
  fi
else
  skip "clippy not installed"
fi

echo "== measurements (release build, printed not asserted)"
cargo test --release -p wa-telemetry-sink "${offline[@]}" --manifest-path rust/Cargo.toml \
  --test burst --test optimization -- --nocapture --test-threads=1 2>/dev/null \
  | grep -E 'burst=|optimization:' | sed 's/^/     /'

echo "== component (wa:telemetry, wasm32-wasip2)"
if [ "${WA_SINK_NO_COMPONENT:-0}" = 1 ]; then
  skip "component build (WA_SINK_NO_COMPONENT=1)"
else
  manifest=rust/components/telemetry-sink/manifest.json
  if command -v node >/dev/null 2>&1; then
    bus=$(node -e 'const fs=require("fs");const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(JSON.stringify(m.capabilities.bus))' "$manifest" 2>/dev/null)
    case "$bus" in
      '{"publish":[],"subscribe":["*"]}') ok "manifest grants subscribe=[\"*\"] and publish=[]" ;;
      *) bad "manifest bus grant is $bus, want {\"publish\":[],\"subscribe\":[\"*\"]}" ;;
    esac
  else
    skip "manifest grant check (no node)"
  fi
  if cargo build --release --target wasm32-wasip2 "${offline[@]}" \
      --manifest-path rust/components/telemetry-sink/Cargo.toml > /tmp/wa-sink-component.log 2>&1; then
    wasm="${CARGO_TARGET_DIR:-rust/components/telemetry-sink/target}/wasm32-wasip2/release/telemetry_sink.wasm"
    if [ -f "$wasm" ]; then ok "component built: $(wc -c < "$wasm" | tr -d '[:space:]') bytes"
    else bad "component built but $wasm is missing"; fi
  else
    bad "component build"
    tail -15 /tmp/wa-sink-component.log
  fi
fi

echo "telemetry sink: $((checks - fails))/$checks checks passed"
[ "$fails" -eq 0 ] || exit 1
