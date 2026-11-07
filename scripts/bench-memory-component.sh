#!/usr/bin/env bash
# What each memory operation costs through the component, and whether the host's deadlines are still
# 10 × the measured p99 (docs/MEMORY.md, "The memory seam"; rust/wa-memory-bench).
#
#   bash scripts/bench-memory-component.sh [--iterations N] [--keep]
#
# Builds the `memory` component for wasm32-wasip2, builds the bench, seeds a scratch store (10 000
# facts, 50 000 messages, FTS) and prints p50/p99/max per operation. Exit 1 when the shipped deadline
# is tighter than 10 × the measured p99 — the numbers are a claim, and a claim nobody re-measured
# should fail loudly.
#
# The store lives in a temp directory and is removed afterwards (`--keep` keeps it for an inspection,
# printing its path). Nothing here touches a node: no serve, no network, no ~/.wasm-agent.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
iterations=""
keep=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --iterations) iterations="--iterations ${2:?}"; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench: unknown option $1" >&2; exit 2 ;;
  esac
done

target="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
work="$(mktemp -d "${TMPDIR:-/tmp}/wa-memory-bench-XXXXXX")"
cleanup() { [ "$keep" = 1 ] && echo "bench: store kept in $work" || rm -rf "$work"; }
trap cleanup EXIT

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
# A bench is not a node: a scratch home, no rendezvous, no relay, no managed flag.
export WASM_AGENT_HOME="$(native "$work/home")"
export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0
# The component cache writes compiled artifacts into $HOME/.wasm-agent; the bench has no node state,
# so it is off (a cold compile is paid once, in the warm-up call).
export WA_COMPONENT_CACHE=0
mkdir -p "$work/home"

echo "bench: building the memory component (wasm32-wasip2, release)"
cargo build --manifest-path rust/components/memory/Cargo.toml --target wasm32-wasip2 --release >/dev/null
wasm="$target/wasm32-wasip2/release/memory.wasm"
#[ -f "$wasm" ] || wasm="rust/components/memory/target/wasm32-wasip2/release/memory.wasm"
[ -f "$wasm" ] || { echo "bench: no memory.wasm produced in $target" >&2; exit 2; }

echo "bench: building wa-memory-bench (release)"
cargo build --release --manifest-path rust/wa-memory-bench/Cargo.toml >/dev/null
bin="$target/release/wa-memory-bench"
[ -x "$bin" ] || bin="$bin.exe"
[ -x "$bin" ] || { echo "bench: no wa-memory-bench built in $target/release" >&2; exit 2; }

echo
"$bin" --db "$(native "$work/memory.db")" --component "$(native "$wasm")" \
  --manifest "$(native "$ROOT/rust/components/memory/manifest.json")" $iterations
