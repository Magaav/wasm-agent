# scratch-home.sh: A ROW MUST NOT WRITE INTO THE REAL HOME.
#
# 27/11, and it cost the node its mesh: a row (test-features-defaults, run straight at the binaries instead of
# through the runner) wrote a 98-byte test policy over ~/.wasm-agent/policy.json, deleting the mesh section -
# the node could not reach its peers and WhatsApp reads failed. The rows had also been leaving their scratch
# dirs (wa-outbox-*, wa-vault-sign-*, wa-release-*) inside ~/.wasm-agent/tmp, which is the same defect one
# level quieter.
#
# The rule: a row runs with HOME and WASM_AGENT_HOME pointing at a scratch dir that the row's runner CREATED,
# never at the real home and never at ~/.wasm-agent. When it does not, the row is REFUSED BY NAME instead of
# graded - a refusal that says which row and which variable is worth more than a verdict from a run that
# edited the operator's node.

# The real home is the operator's, not whatever HOME this process happens to have.
wa_real_home() {
  local u=${SUDO_USER:-${USER:-victor}} h
  h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
  [ -n "$h" ] || h=/home/$u
  echo "$h"
}

# wa_require_scratch_home <what-is-about-to-run>  -> 0 when the environment can only write to a scratch dir,
# 3 (and a named refusal on stderr) when it cannot.
wa_require_scratch_home() {
  local what=${1:?wa_require_scratch_home needs the name of what is about to run}
  local real state why=''
  real=$(wa_real_home); state=$real/.wasm-agent

  if [ "${HOME:-}" = "$real" ]; then
    why="HOME is the real home ($real)"
  elif [ -z "${HOME:-}" ]; then
    why="HOME is unset, so a row writes wherever the process happens to be"
  fi
  # An explicit WASM_AGENT_HOME overrides the derived one, and it is the file that was clobbered.
  case "${WASM_AGENT_HOME:-}" in
    ""|"$state") [ -n "${WASM_AGENT_HOME:-}" ] && why="${why:+$why; }WASM_AGENT_HOME is the real state dir ($state)";;
    *) case "$WASM_AGENT_HOME" in "$real"/*) why="${why:+$why; }WASM_AGENT_HOME is under the real home ($WASM_AGENT_HOME)";; esac;;
  esac
  case "${TMPDIR:-}" in
    "$real"|"$real"/*) why="${why:+$why; }TMPDIR is under the real home ($TMPDIR)";;
  esac

  if [ -n "$why" ]; then
    echo "REFUSED (scratch-home): $what would run against the real home and must not - $why." >&2
    echo "REFUSED (scratch-home): give it HOME and WASM_AGENT_HOME from a scratch dir you created (factory/lib/scratch-home.sh: wa_scratch_home)." >&2
    return 3
  fi
  return 0
}

# wa_scratch_home <prefix>  -> 0 with HOME, WASM_AGENT_HOME and TMPDIR exported into a fresh scratch dir, whose
# path is left in WA_SCRATCH. It must be CALLED, not captured: `$(wa_scratch_home x)` runs in a subshell and its
# exports would be thrown away - a trap worth naming, because that is how a row ends up with the real HOME again.
wa_scratch_home() {
  local d real base
  # THE BASE IS NEVER THE REAL HOME: this session's own TMPDIR points at ~/.wasm-agent/tmp, which is where those
  # 489 wa-outbox-*/wa-vault-sign-*/wa-release-* dirs came from. A scratch dir inside the operator's state dir is
  # not scratch, so the helper falls back to /tmp rather than inherit it.
  real=$(wa_real_home); base=${TMPDIR:-/tmp}
  case "$base" in "$real"|"$real"/*) base=/tmp;; esac
  d=$(mktemp -d "$base/${1:-wa-row}.XXXXXX") || return 1
  export HOME=$d WASM_AGENT_HOME=$d/.wasm-agent TMPDIR=$d/tmp WA_SCRATCH=$d
  mkdir -p "$WASM_AGENT_HOME" "$TMPDIR"
}
