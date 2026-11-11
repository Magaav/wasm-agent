# Path safety for shell scripts: the same rule the Lua guard enforces (lua/core/path_guard.lua).
#
# Measured 11/11: a test took its scratch from WASM_AGENT_HOME - inside `wa` that is the operator's
# home - and ran `rm -rf` on it. A shell script cannot ask a Lua module, so it asks this instead.
#
# Use it for every recursive delete whose target is not a literal path under this script's own control:
#
#     . "$(dirname "$0")/lib/path-safety.sh"
#     wa_safe_rm_rf "$SCRATCH_HOME"          # deletes, or refuses by name
#
# A directory counts as this run's own when it carries the marker file written by `wa_own_scratch`.
# A `mktemp -d` target is accepted without a marker only when it is under the system temp root, because
# mktemp made it and nobody else's data lives there.

WA_PATH_GUARD_MARKER=".wa-test-scratch"

wa_path_guard_reason() {
  # Prints why PATH may not be deleted; returns 1 when it must not be.
  local target="$1"
  if [ -z "$target" ]; then echo "path_guard: refusing a delete of an empty path"; return 1; fi
  case "$target" in
    *'$'*|*'`'*) echo "path_guard: refusing a delete of a shell-computed path: $target"; return 1 ;;
  esac
  # Resolve what can be resolved without deleting anything.
  local resolved
  resolved="$(cd -- "$target" 2>/dev/null && pwd -P)" || resolved="$target"
  local protected="${HOME:-}${USERPROFILE:+|$USERPROFILE}${WASM_AGENT_HOME:+|$WASM_AGENT_HOME}${WA_INSTALL_DIR:+|$WA_INSTALL_DIR}"
  local old_ifs="$IFS"; IFS='|'
  local one
  for one in $protected; do
    IFS="$old_ifs"
    [ -z "$one" ] && continue
    local real
    real="$(cd -- "$one" 2>/dev/null && pwd -P)" || real="$one"
    case "$resolved/" in
      "$real"/*) IFS='|'
        echo "path_guard: refusing to delete $target: it is or contains protected path $real. Never delete what you did not create in this run."
        return 1 ;;
    esac
    IFS='|'
  done
  IFS="$old_ifs"
  case "$resolved" in
    /|"$(printf '%s' "${HOME:-/nonexistent}")"|"$(printf '%s' "${USERPROFILE:-/nonexistent}")")
      echo "path_guard: refusing to delete a root or home: $target"; return 1 ;;
  esac
  return 0
}

wa_own_scratch() {
  # Creates a marked mktemp directory and prints it. Use instead of a path from the environment.
  local dir
  dir="$(mktemp -d 2>/dev/null || mktemp -d -t wa-scratch)" || return 1
  : > "$dir/$WA_PATH_GUARD_MARKER" || return 1
  printf '%s\n' "$dir"
}

wa_safe_rm_rf() {
  # Deletes PATH only when the guard allows it. Returns non-zero and says why otherwise.
  local target="$1"
  local reason
  if ! reason="$(wa_path_guard_reason "$target")"; then echo "$reason" >&2; return 1; fi
  if [ -e "$target" ] && [ ! -e "$target/$WA_PATH_GUARD_MARKER" ]; then
    case "$(cd -- "$target" 2>/dev/null && pwd -P)" in
      "${TMPDIR:-/tmp}"/*|/tmp/*) : ;;  # mktemp's own directory: nobody else's data
      *) echo "path_guard: refusing to delete $target: it has no $WA_PATH_GUARD_MARKER marker, so this run did not create it" >&2; return 1 ;;
    esac
  fi
  rm -rf -- "$target"
}
