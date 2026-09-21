#!/usr/bin/env bash
# Verify that what is installed is what was built, and that the supervisor is watching it.
#
# This exists because verifying a deploy was a reasoning exercise: eight round-trips reading
# installed.txt, hashing two binaries, diffing scripts, asking /health, reading serve.pid and the
# sentinel status, every single time. None of those steps needs a model - they are comparisons. One
# command, one verdict, so a run (or an operator) reads PASS/FAIL instead of re-deriving it.
#
#   bash scripts/verify-install.sh [--json]
#
# Exit 0 when nothing failed. `skip` is not `ok`: with no worktree to compare against, the hash checks
# cannot run, and this says so rather than printing the sentence a passing run prints.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/AppData/Local/wasm-agent}"
[ -d "$INSTALL_DIR" ] || INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/share/wasm-agent}"
PORT="${WA_PORT:-8799}"
CONFIG="${WASM_AGENT_HOME:-${USERPROFILE:-$HOME}}"; CONFIG="$CONFIG/.wasm-agent"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

checks=0; failed=0; skipped=0
results=()

record() { # status name detail
  checks=$((checks + 1))
  case "$1" in
    ok) ;;
    skip) skipped=$((skipped + 1)) ;;
    fail) failed=$((failed + 1)) ;;
  esac
  results+=("$(printf '%s\t%s\t%s' "$1" "$2" "${3:-}")")
  if [ "$JSON" = "0" ]; then
    case "$1" in
      ok)   printf '  ok   %s%s\n' "$2" "${3:+ - $3}" ;;
      skip) printf '  skip %s%s\n' "$2" "${3:+ - $3}" ;;
      fail) printf '  FAIL %s%s\n' "$2" "${3:+ - $3}" ;;
    esac
  fi
}

sha() { # file -> hash, empty when unreadable
  [ -f "$1" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" 2>/dev/null | awk '{print $1}'
  else shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'; fi
}

sed_field() { sed -n "s/^$1=//p" "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1 | tr -d '[:space:]'; }

# The tree the install was built from: WA_DEPLOY_ROOT, else `..` when it really is a work tree, else the
# runtime worktree upgrade.sh records. Same order deploy.sh uses; a check that cannot run is a skip.
resolve_root() {
  if [ -n "${WA_DEPLOY_ROOT:-}" ]; then printf '%s' "$WA_DEPLOY_ROOT"; return; fi
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf '%s' "$ROOT"; return; fi
  if [ -f "$INSTALL_DIR/runtime-worktree.txt" ]; then tr -d '\r\n' < "$INSTALL_DIR/runtime-worktree.txt"; return; fi
  printf ''
}

# 1. the install record
if [ -f "$INSTALL_DIR/installed.txt" ]; then
  RECORD_COMMIT="$(sed_field commit)"
  record ok "installed.txt present" "commit=${RECORD_COMMIT:-?} via=$(sed_field via)"
else
  record fail "installed.txt present" "no $INSTALL_DIR/installed.txt - nothing to verify against"
  RECORD_COMMIT=""
fi

# 2. worktree comparison (hash equality is the only honest proof that what runs is what is in the tree)
TREE="$(resolve_root)"
if [ -n "$TREE" ] && git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HEAD_COMMIT="$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null)"
  if [ -n "$RECORD_COMMIT" ]; then
    if [ "$RECORD_COMMIT" = "$HEAD_COMMIT" ]; then
      record ok "installed commit is the tree HEAD" "$HEAD_COMMIT"
    elif git -C "$TREE" merge-base --is-ancestor "$RECORD_COMMIT" HEAD 2>/dev/null; then
      record skip "installed commit is the tree HEAD" \
        "tree is ahead by $(git -C "$TREE" rev-list --count "$RECORD_COMMIT"..HEAD 2>/dev/null) - deploy pending"
    else
      record fail "installed commit is the tree HEAD" \
        "installed $RECORD_COMMIT is not an ancestor of tree $HEAD_COMMIT (the install is ahead - a downgrade)"
    fi
  fi
  if [ -n "$(git -C "$TREE" status --porcelain 2>/dev/null)" ]; then
    record fail "the tree is clean" "uncommitted changes in $TREE - an install from here is not reproducible"
  else
    record ok "the tree is clean"
  fi

  INSTALLED_WA="$INSTALL_DIR/wa.exe"; [ -x "$INSTALLED_WA" ] || INSTALLED_WA="$INSTALL_DIR/wa"
  BUILT_WA="$TREE/rust/target/release/wa.exe"; [ -f "$BUILT_WA" ] || BUILT_WA="$TREE/rust/target/release/wa"
  if [ -f "$BUILT_WA" ]; then
    record "$([ "$(sha "$INSTALLED_WA")" = "$(sha "$BUILT_WA")" ] && echo ok || echo fail)" \
      "installed node == built node" "installed $(sha "$INSTALLED_WA" | head -c 12) built $(sha "$BUILT_WA" | head -c 12)"
    record "$([ "$(sha "$INSTALLED_WA")" = "$(sed_field sha256)" ] && echo ok || echo fail)" \
      "installed node == installed.txt sha256"
  else
    record skip "installed node == built node" "no built node at $BUILT_WA"
  fi

  BUILT_SENT="$TREE/rust/wa-sentinel/target/release/wa-sentinel.exe"
  [ -f "$BUILT_SENT" ] || BUILT_SENT="$TREE/rust/wa-sentinel/target/release/wa-sentinel"
  INSTALLED_SENT="$INSTALL_DIR/wa-sentinel.exe"; [ -x "$INSTALLED_SENT" ] || INSTALLED_SENT="$INSTALL_DIR/wa-sentinel"
  if [ -f "$BUILT_SENT" ]; then
    record "$([ "$(sha "$INSTALLED_SENT")" = "$(sha "$BUILT_SENT")" ] && echo ok || echo fail)" \
      "installed sentinel == built sentinel" "installed $(sha "$INSTALLED_SENT" | head -c 12) built $(sha "$BUILT_SENT" | head -c 12)"
    record "$([ "$(sha "$INSTALLED_SENT")" = "$(sed_field sentinel_sha256)" ] && echo ok || echo fail)" \
      "installed sentinel == installed.txt sentinel_sha256"
  else
    record skip "installed sentinel == built sentinel" "no built sentinel at $BUILT_SENT"
  fi

  for pair in "scripts/deploy.sh:$TREE/scripts/deploy.sh" \
              "scripts/upgrade.sh:$TREE/scripts/upgrade.sh" \
              "skills/self-update/SKILL.md:$TREE/skills/self-update/SKILL.md"; do
    rel="${pair%%:*}"; src="${pair#*:}"
    dst="$INSTALL_DIR/$rel"
    [ "$rel" = "skills/self-update/SKILL.md" ] && dst="$CONFIG/$rel"
    if [ -f "$src" ]; then
      record "$([ -f "$dst" ] && cmp -s "$src" "$dst" && echo ok || echo fail)" \
        "shipped $rel == repo" "${dst:-missing}"
    else
      record skip "shipped $rel == repo" "no $src in the tree"
    fi
  done
else
  record skip "worktree comparison" "no worktree resolvable (WA_DEPLOY_ROOT / runtime-worktree.txt) - hash calls not run"
fi

# 3. the node answers, and the pid answering is the pid the install recorded
HEALTH="$(curl -s -m 6 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
record "$([ -n "$HEALTH" ] && echo ok || echo fail)" "the node answers /health on $PORT"
SERVE_PID="$(tr -d '[:space:]' < "$INSTALL_DIR/serve.pid" 2>/dev/null)"
if command -v powershell.exe >/dev/null 2>&1; then
  LISTENER="$(powershell.exe -NoProfile -Command "Get-NetTCPConnection -State Listen -LocalPort $PORT -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { \$_.OwningProcess }" 2>/dev/null | tr -d '\r')"
else
  LISTENER="$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" { if (match($0,/pid=[0-9]+/)) print substr($0,RSTART+4,RLENGTH-4) }' | head -1)"
fi
record "$([ -n "$SERVE_PID" ] && [ "$SERVE_PID" = "$LISTENER" ] && echo ok || echo fail)" \
  "the listener is the recorded pid" "serve.pid ${SERVE_PID:-none}, listener ${LISTENER:-none}"

# 4. the supervisor
SENTINEL="$INSTALL_DIR/wa-sentinel.exe"; [ -x "$SENTINEL" ] || SENTINEL="$INSTALL_DIR/wa-sentinel"
if [ -x "$SENTINEL" ]; then
  STATUS="$("$SENTINEL" status 2>&1)"
  record "$(grep -q 'watching (pid' <<<"$STATUS" && echo ok || echo fail)" \
    "the sentinel is watching" "$(grep 'sentinel:' <<<"$STATUS" | head -1 | sed 's/^ *//')"
  record "$(grep -q 'requests:' <<<"$STATUS" && echo ok || echo fail)" \
    "the request box is readable" "$(grep 'requests:' <<<"$STATUS" | head -1 | sed 's/^ *//')"
else
  record fail "the sentinel is watching" "no wa-sentinel in $INSTALL_DIR"
fi

# 5. verdict
if [ "$JSON" = "1" ]; then
  printf '{"suite":"verify-install","checks":%d,"failed":%d,"skipped":%d,"ok":%s,"results":[' \
    "$checks" "$failed" "$skipped" "$([ "$failed" -eq 0 ] && echo true || echo false)"
  first=1
  for r in "${results[@]}"; do
    [ "$first" = "1" ] || printf ','
    first=0
    printf '{"status":"%s","name":"%s","detail":"%s"}' \
      "$(cut -f1 <<<"$r")" "$(cut -f2 <<<"$r" | sed 's/"/\\"/g')" "$(cut -f3 <<<"$r" | sed 's/"/\\"/g')"
  done
  printf ']}\n'
else
  if [ "$failed" -eq 0 ]; then
    printf 'verify-install ok (%d checks, %d skipped)\n' "$checks" "$skipped"
  else
    printf 'verify-install FAILED (%d of %d, %d skipped)\n' "$failed" "$checks" "$skipped"
  fi
fi
[ "$failed" -eq 0 ] || exit 1
