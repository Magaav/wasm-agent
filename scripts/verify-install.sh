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
# The one file that answers "where does this machine's node live", shared with deploy.sh so the verifier and
# the deploy cannot disagree about which directory they are talking about. If it is missing (an install
# older than this rule), fall back to the expression that was here and say so in the checks below.
WA_LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/service-target.sh"
[ -f "$WA_LIB" ] && . "$WA_LIB"
PORT="${WA_PORT:-8799}"
if command -v wa_install_target >/dev/null 2>&1; then
  INSTALL_DIR="$(wa_install_target)"
  CONFIG="$(wa_config_dir)"
  wa_read_service_claim || true
  HAD_SERVICE_LIB=1
else
  INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/AppData/Local/wasm-agent}"
  [ -d "$INSTALL_DIR" ] || INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/share/wasm-agent}"
  CONFIG="${WASM_AGENT_HOME:-${USERPROFILE:-$HOME}}"; CONFIG="$CONFIG/.wasm-agent"
  WA_SERVICE_DIR=""; WA_SERVICE_CLAIM=""; HAD_SERVICE_LIB=0
fi

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
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\r\n' '  '; }

# The tree the install was built from: WA_DEPLOY_ROOT, else `..` when it really is a work tree, else the
# runtime worktree upgrade.sh records. Same order deploy.sh uses; a check that cannot run is a skip.
resolve_root() {
  if [ -n "${WA_DEPLOY_ROOT:-}" ]; then printf '%s' "$WA_DEPLOY_ROOT"; return; fi
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf '%s' "$ROOT"; return; fi
  if [ -f "$INSTALL_DIR/runtime-worktree.txt" ]; then tr -d '\r\n' < "$INSTALL_DIR/runtime-worktree.txt"; return; fi
  printf ''
}

# 0. This run is verifying the install the machine actually runs. Without this, every check below can pass
#    while the service keeps running a different directory - which is what happened on 2026-09-29: the unit
#    ran a ten-day-old install, the deploy wrote a newer one elsewhere, and the node restarted 61,117 times
#    under a verifier that had no opinion about which of them was the node.
if [ "$HAD_SERVICE_LIB" = "0" ]; then
  record skip "the install is where the service runs it" "no scripts/lib/service-target.sh beside this script: nothing asked the machine where its node lives"
elif [ -n "${WA_SERVICE_DIR:-}" ] && ! wa_same_dir "$WA_SERVICE_DIR" "$INSTALL_DIR"; then
  record fail "the install is where the service runs it" \
    "the service runs the node from $WA_SERVICE_DIR (${WA_SERVICE_CLAIM:-no source named}), and this run read $INSTALL_DIR - they are different installs"
elif [ -n "${WA_SERVICE_DIR:-}" ]; then
  record ok "the install is where the service runs it" "$WA_SERVICE_DIR (${WA_SERVICE_CLAIM:-named by the machine})"
else
  record ok "the install is where the service runs it" "no service definition and no node on :$PORT that this can name; nothing on this machine contradicts $INSTALL_DIR"
fi

# 1. the install record
if [ -f "$INSTALL_DIR/installed.txt" ]; then
  RECORD_COMMIT="$(sed_field commit)"
  record ok "installed.txt present" "commit=${RECORD_COMMIT:-?} via=$(sed_field via)"
  # A record that names a different directory is a record about another install - the shape of a file copied
  # or written beside the node instead of in it, which is how `~/.wasm-agent/installed.txt` came to exist,
  # empty, while the node that looped was reading neither.
  RECORD_DIR="$(sed_field install_dir)"
  if [ -n "$RECORD_DIR" ]; then
    record "$(wa_same_dir "$RECORD_DIR" "$INSTALL_DIR" && echo ok || echo fail)" \
      "the record was written for this install" "installed.txt names install_dir=$RECORD_DIR, read from $INSTALL_DIR"
  fi
else
  record fail "installed.txt present" "no $INSTALL_DIR/installed.txt - nothing to verify against"
  RECORD_COMMIT=""
fi

# 1b. A record in the node's config directory is not a record of the node. `<install>/installed.txt` is
#     where the deploy writes it and where this verifier reads it; a second one under the config directory
#     is bookkeeping that cannot be compared with anything, which is the state the cloud node was found in.
STRAY_RECORD="$CONFIG/installed.txt"
if [ -f "$STRAY_RECORD" ] && ! wa_same_dir "$CONFIG" "$INSTALL_DIR"; then
  record fail "there is no second install record" \
    "$STRAY_RECORD exists but the node's install is $INSTALL_DIR - a record beside the config verifies nothing (it is $(wc -c < "$STRAY_RECORD" | tr -d ' ') byte(s))"
elif [ -f "$STRAY_RECORD" ]; then
  record ok "there is no second install record" "$STRAY_RECORD is the install directory itself"
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

  for rel in scripts/deploy.sh scripts/upgrade.sh; do
    src="$TREE/$rel"; dst="$INSTALL_DIR/$rel"
    if [ -f "$src" ]; then
      record "$([ -f "$dst" ] && cmp -s "$src" "$dst" && echo ok || echo fail)" \
        "shipped $rel == repo" "$dst"
    else
      record skip "shipped $rel == repo" "no $src in the tree"
    fi
  done
  if [ -d "$TREE/skills" ]; then
    while IFS= read -r -d '' src; do
      rel="${src#"$TREE/"}"; dst="$CONFIG/$rel"
      record "$([ -f "$dst" ] && cmp -s "$src" "$dst" && echo ok || echo fail)" \
        "shipped $rel == repo" "$dst"
    done < <(find "$TREE/skills" -type f -print0)
  else
    record skip "shipped skills == repo" "no skills in the tree"
  fi
else
  record skip "worktree comparison" "no worktree resolvable (WA_DEPLOY_ROOT / runtime-worktree.txt) - hash calls not run"
fi

# The current writer and runtime reader share wa_config_dir. Legacy <home>/skills
# may be unrelated user content; actual shipped skills above must match the tree.
WRITER_CONFIG="$(wa_config_dir)"
record "$(wa_same_dir "$WRITER_CONFIG" "$CONFIG" && echo ok || echo fail)" \
  "the skills a deploy writes are the skills the node reads" \
  "upgrade and runtime use $WRITER_CONFIG/skills"

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
      "$(cut -f1 <<<"$r")" "$(json_escape "$(cut -f2 <<<"$r")")" "$(json_escape "$(cut -f3 <<<"$r")")"
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
