#!/usr/bin/env bash
# The node-binaries lib must hand a caller its whole API.
#
# WHY THIS EXISTS (measured, 21/11). A stray double quote in one printf (line 548, wa_node_asset_names) turned
# everything after it into string text until the next quote, so SIX function definitions became plain words:
#   wa_node_fetch_asset, wa_node_verify_signature, wa_node_verify_dir, wa_node_cache_root,
#   wa_node_cache_entry, wa_node_binary_download
# `bash -n` still passed (the file re-balances with the next quote) and sourcing was silent with rc=0, so the
# defect only surfaced at the first call site - scripts/test-release-signing.sh reported
# `wa_node_binary_download: command not found` and read as a broken row, while scripts/release-install.sh:55
# sources the same lib and would have failed the same way on a tree-less node.
#
# The rule, asserted here: every function the file DEFINES is DEFINED after a plain source, in a plain shell
# and under set -u / set -e / set -eu, and each one is callable (not merely mentioned).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/node-binaries.sh"
[ -f "$LIB" ] || { printf 'FAILED: %s is missing\n' "$LIB" >&2; exit 1; }

fail=0
failwith() { printf 'FAILED: %s\n' "$*" >&2; fail=1; }

# The names the file defines, taken from the parser's own view of a definition, not from a grep of call sites.
names="$(grep -oE '^wa_node_[A-Za-z0-9_]*\(\)' "$LIB" | sed 's/()$//' | sort -u)"
count="$(printf '%s\n' "$names" | grep -c . )"
[ "$count" -ge 30 ] || failwith "parsed only $count wa_node_* definitions out of $LIB - the file did not parse as expected"

# 1. every one of them is defined after a plain source
for mode in plain u e eu; do
  case "$mode" in
    plain) pre='' ;;
    u)     pre='set -u;' ;;
    e)     pre='set -e;' ;;
    eu)    pre='set -eu;' ;;
  esac
  missing="$(bash -c "$pre . \"\$1\"; for f in \$(grep -oE '^wa_node_[A-Za-z0-9_]*\\(\\)' \"\$1\" | sed 's/()\$//' | sort -u); do command -v \"\$f\" >/dev/null 2>&1 || printf '%s ' \"\$f\"; done" _ "$LIB" 2>/dev/null)"
  [ -z "$missing" ] || failwith "source in a $mode shell leaves these undefined: $missing"
done

# 2. the call site that mattered: release-install.sh sources this lib by path and then calls the download.
#    Prove reachability the same way it does, and prove the function is a function (not a string that happens
#    to be found by grep).
reached="$(bash -c '. "$1"; type -t wa_node_binary_download 2>/dev/null || echo MISSING' _ "$LIB" 2>/dev/null)"
[ "$reached" = function ] || failwith "a caller that sources the lib cannot reach wa_node_binary_download (got: ${reached:-nothing})"

# 3. and the publisher's name list, whose printf carried the quote: it must print the members it is given.
got="$(bash -c '. "$1"; WA_BUNDLE_MEMBERS="wa-term wa-sentinel"; wa_node_asset_names 9eaa1dbc5a0e7040e5edd59ddb18af5ad983665b x86_64-unknown-linux-gnu' _ "$LIB" 2>/dev/null)"
case "$got" in
  *node-9eaa1dbc5a0e.manifest*wa-term-x86_64-unknown-linux-gnu-9eaa1dbc5a0e*wa-sentinel-x86_64-unknown-linux-gnu-9eaa1dbc5a0e*)
    ;;
  *) failwith "wa_node_asset_names did not print the manifest and both members (got: ${got:-nothing})" ;;
esac

if [ "$fail" = 0 ]; then
  printf 'node-binaries lib api: %s definitions are all present and callable after a plain source, in plain, -u, -e and -eu shells\n' "$count"
  printf 'node-binaries lib api: wa_node_binary_download is reachable from the release-install call shape\n'
  printf 'node-binaries lib api: the asset-name printf prints the manifest and every member of WA_BUNDLE_MEMBERS\n'
  exit 0
fi
exit 1
