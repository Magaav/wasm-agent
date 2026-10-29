# The build's progress, as the one file a `wa chat` draws as a row above its input (29/10).
#
# Sourced by deploy.sh. Writes `$WASM_AGENT_DATA/build-status.json` (else `<home>/.wasm-agent`), atomically,
# in the format rust/wa-host/src/build_status.rs renders:
#   {"state":"building|installed|failed","phase":"preflight|provisioning|fetching|compiling|proving|installing|done|...",
#    "done":n,"total":n,"crate":"..","commit":"sha12","started_at":epoch,"at":epoch}
# On `installed`, `crate` is the elapsed time ("41s"). `total` is the lockfiles' package count, an upper bound:
# an incremental build compiles a handful of them and the bar jumps to the end, which is the truth.
#
# Why here and not in the operator's script: the sentinel owns the one rebuild path, so whoever asked for the
# build - an operator syncing from a laptop, the agent deploying its own commit - sees the same progress.
# A status write can never fail the deploy: every write is `|| true`.
WA_STATUS_FILE="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}/build-status.json"
WA_STATUS_STARTED=0 WA_STATUS_TOTAL=0 WA_STATUS_COMMIT="" WA_STATUS_PHASE="" WA_STATUS_DONE=0
WA_STATUS_FOLLOWER=""

# EPOCHSECONDS (bash 5) is a read, not a fork: the follower asks the clock on every line cargo prints.
wa_status_now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }
wa_status_esc() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-160; }

# wa_status_begin ROOT COMMIT: the clock starts and the total is read from the lockfiles in ROOT.
wa_status_begin() {
  local lock n total=0
  for lock in "$1/rust/Cargo.lock" "$1/rust/wa-sentinel/Cargo.lock"; do
    n="$(grep -c '^\[\[package\]\]' "$lock" 2>/dev/null)" || n=0
    total=$((total + ${n:-0}))
  done
  WA_STATUS_TOTAL=$total WA_STATUS_COMMIT="${2:0:12}" WA_STATUS_STARTED="$(wa_status_now)" WA_STATUS_DONE=0
  mkdir -p "$(dirname "$WA_STATUS_FILE")" 2>/dev/null || true
}

# wa_status STATE PHASE [DONE] [CRATE]
wa_status() {
  [ "$WA_STATUS_STARTED" = 0 ] && return 0
  WA_STATUS_PHASE="$2"; [ -n "${3:-}" ] && WA_STATUS_DONE="$3"
  { printf '{"state":"%s","phase":"%s","done":%d,"total":%d,"crate":"%s","commit":"%s","started_at":%d,"at":%d}\n' \
    "$1" "$(wa_status_esc "$2")" "$WA_STATUS_DONE" "$WA_STATUS_TOTAL" "$(wa_status_esc "${4:-}")" "$WA_STATUS_COMMIT" \
    "$WA_STATUS_STARTED" "$(wa_status_now)" > "$WA_STATUS_FILE.$BASHPID" \
    && mv -f "$WA_STATUS_FILE.$BASHPID" "$WA_STATUS_FILE"; } 2>/dev/null || true
}

# wa_status_follow LOG PHASE: in the background, count cargo's `Compiling <crate> v..` lines as they are
# appended to LOG and write them at most once a second, with a heartbeat every 5 s so a long single-crate
# compile (or an idle wait) is not drawn as a build that died (the CLI hides a `building` row older than
# 120 s). It ends with this shell: it checks its parent on every pass, so a SIGKILLed deploy leaves no loop.
wa_status_follow() {
  wa_status_unfollow
  local log="$1" phase="$2" parent=$$
  : >> "$log" 2>/dev/null || return 0
  (
    exec 3<"$log" || exit 0
    n=$WA_STATUS_DONE crate="" last=0 dirty=1 line=""
    while kill -0 "$parent" 2>/dev/null; do
      if IFS= read -r -u 3 line; then
        case "$line" in
          *"Compiling "*" v"*) crate="${line#*Compiling }"; crate="${crate%% *}"; n=$((n + 1)); dirty=1 ;;
        esac
        continue_reading=1
      else
        continue_reading=0
      fi
      now=${EPOCHSECONDS:-$(date +%s)}
      if { [ "$dirty" = 1 ] && [ "$now" -gt "$last" ]; } || [ $((now - last)) -ge 5 ]; then
        wa_status building "$phase" "$n" "$crate"; last=$now dirty=0
      fi
      [ "$continue_reading" = 1 ] || sleep 0.25
    done
  ) &
  WA_STATUS_FOLLOWER=$!
}
wa_status_unfollow() {
  [ -n "$WA_STATUS_FOLLOWER" ] || return 0
  kill "$WA_STATUS_FOLLOWER" 2>/dev/null; wait "$WA_STATUS_FOLLOWER" 2>/dev/null
  WA_STATUS_FOLLOWER=""
}
# How many crates a finished cargo log compiled: the follower's count, re-derived from the file it read.
wa_status_compiled() { grep -c 'Compiling .* v' "$1" 2>/dev/null || true; }

# wa_phase NAME: a new phase - drawn, and the previous one's wall time said on the deploy's own output
# (`deploy: [phase] compiling 41.2s`), so "where did the minutes go" is read, not guessed.
WA_PHASE_NAME="" WA_PHASE_AT=""
wa_phase_ms() { local t="${EPOCHREALTIME:-}"; [ -n "$t" ] && { t="${t/[.,]/}"; printf '%s' "${t:0:${#t}-3}"; } || printf '%s000' "$(date +%s)"; }
wa_phase() {
  local now; now="$(wa_phase_ms)"
  if [ -n "$WA_PHASE_NAME" ]; then
    local ms=$((now - WA_PHASE_AT))
    printf 'deploy: [phase] %s %d.%01ds\n' "$WA_PHASE_NAME" $((ms / 1000)) $((ms % 1000 / 100))
  fi
  WA_PHASE_NAME="$1" WA_PHASE_AT="$now"
  [ -n "$1" ] && wa_status building "$1" "" "${2:-}"
  return 0
}
