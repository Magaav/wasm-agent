#!/usr/bin/env bash
# WHICH node? One answer for every script a deploy runs, and one refusal when there is none.
#
# WHY (21/11). `wa update <node> --binary` runs scripts/deploy.sh from the node's own serve operation, and
# that operation's PATH is the service's PATH: it does not carry the user's Node install (mail and nextcloud
# keep theirs at ~/.local/bin/node/bin/node). Step 0c, the runtime-install binding, therefore died with
# "line 436: node: command not found" and the deploy refused - a correct refusal with an absurd cause, and
# the operator's only fix was to hand-install node where the service happens to look.
#
# THE ANSWER. One resolver, used by every node call a deploy or an upgrade makes (scripts/deploy.sh,
# scripts/upgrade.sh) and carried into the wrapper lua/core/remote_update.lua writes for a peer, so the next
# node call cannot be the one that was forgotten. It looks, in this order:
#
#   1. WA_NODE_BIN, when the operator names one - and a WA_NODE_BIN that is not executable is a REFUSAL,
#      never a reason to fall back to another node: the operator said which one to use;
#   2. `node`, then `nodejs`, on PATH;
#   3. the places a user's own install actually lives - ~/.local/bin/node/bin (the node's own layout on
#      mail and nextcloud), mise/nvm/asdf/volta shims and installs, and the node this repository
#      provisioned (<WASM_AGENT_HOME>/.wasm-agent/node/bin, scripts/lib/build-requirements.sh);
#   4. the system's own directories last (WA_NODE_SYSTEM_DIRS, default /usr/local/bin:/usr/bin:/bin:
#      /opt/homebrew/bin) - an operator's node is the one their builds are tested with, and a system node
#      is usually older.
#
# A MACHINE WITH NO NODE GETS A NAME, NOT A SHELL ERROR. wa_node_require answers nothing on stdout and the
# sentence from `wa_node_refusal` names every place that was looked in, so the call site can refuse with
# node_runtime_missing instead of "command not found" from a line number nobody can act on.

# -> every directory this resolver WOULD look in, one per line - existing or not. The search keeps only the
# ones that are there; a REFUSAL names this list, because the operator's next move is to put node in one of
# these places.
wa_node_candidate_dirs() {
  local dir
  for dir in \
    "${HOME:-}/.local/bin/node/bin" \
    "${HOME:-}/.local/share/mise/shims" \
    "${HOME:-}/.volta/bin" \
    "${HOME:-}/.asdf/shims" \
    "${WASM_AGENT_HOME-${HOME:-}}/.wasm-agent/node/bin" \
    ; do
    [ -n "$dir" ] && printf '%s\n' "$dir"
  done
  for dir in "${HOME:-}"/.nvm/versions/node/*/bin "${HOME:-}"/.local/share/mise/installs/node/*/bin; do
    [ -d "$dir" ] && printf '%s\n' "$dir"
  done
  local system="${WA_NODE_SYSTEM_DIRS-/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin}"
  local saved_ifs="$IFS"
  IFS=':'
  for dir in $system; do
    [ -n "$dir" ] && printf '%s\n' "$dir"
  done
  IFS="$saved_ifs"
  return 0
}

# -> the directories searched after PATH, one per line, in the order above. Testable: the system directories
# and the whole list are driven by environment a test sets on a scratch HOME.
wa_node_search_dirs() {
  local dir
  for dir in \
    "${HOME:-}/.local/bin/node/bin" \
    "${HOME:-}/.local/share/mise/shims" \
    "${HOME:-}/.volta/bin" \
    "${HOME:-}/.asdf/shims" \
    "${WASM_AGENT_HOME:-${HOME:-}}/.wasm-agent/node/bin" \
    ; do
    [ -n "$dir" ] && [ -d "$dir" ] && printf '%s\n' "$dir"
  done
  # A version manager keeps one directory per version; each is a candidate, and the loop below takes the
  # first that carries an executable node. Nothing here sorts versions - a resolver that picked "newest"
  # would be choosing a toolchain for the operator.
  for dir in "${HOME:-}"/.nvm/versions/node/*/bin; do
    [ -d "$dir" ] && printf '%s\n' "$dir"
  done
  for dir in "${HOME:-}"/.local/share/mise/installs/node/*/bin; do
    [ -d "$dir" ] && printf '%s\n' "$dir"
  done
  local system="${WA_NODE_SYSTEM_DIRS-/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin}"
  local saved_ifs="$IFS"
  IFS=':'
  for dir in $system; do
    [ -n "$dir" ] && [ -d "$dir" ] && printf '%s\n' "$dir"
  done
  IFS="$saved_ifs"
  return 0
}

# -> an executable node (or nodejs) on stdout and 0; nothing on stdout and 3 when there is none. A WA_NODE_BIN
# that is set but not executable is 3 as well: "the operator named one and it is not there" is not "look
# somewhere else".
wa_node_bin() {
  local candidate dir
  if [ -n "${WA_NODE_BIN:-}" ]; then
    if [ -f "$WA_NODE_BIN" ] && [ -x "$WA_NODE_BIN" ]; then
      printf '%s\n' "$WA_NODE_BIN"
      return 0
    fi
    return 3
  fi
  candidate="$(command -v node 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  candidate="$(command -v nodejs 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  local dirs
  dirs="$(wa_node_search_dirs)"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    for candidate in "$dir/node" "$dir/nodejs"; do
      if [ -f "$candidate" ] && [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
  done <<EOF
$dirs
EOF
  return 3
}

# -> the DETAIL a call site refuses with: `fail \"refused(node_runtime_missing): $(wa_node_refusal)\"`. The code
# is spelled at the call site (this project's refusals are `refused(<reason>): <detail>`) and the detail names
# every place that was looked in, because the operator's next move is either to install node there or to name
# theirs with WA_NODE_BIN.
wa_node_refusal() {
  local places="" dir
  # EVERY place, including the ones that do not exist here: a refusal that lists only what it found on a
  # machine where it found nothing (the case it exists for) tells the operator nothing.
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    places="${places:+$places }$dir"
  done <<EOF
$(wa_node_candidate_dirs)
EOF
  if [ -n "${WA_NODE_BIN:-}" ]; then
    printf 'WA_NODE_BIN names %s, which is not an executable file, and a named node is never replaced by a search' "$WA_NODE_BIN"
    return 0
  fi
  printf 'no node (or nodejs) was found, so a step that runs node cannot run. Looked on PATH (%s), then in: %s. Install Node 18 or newer, or name one with WA_NODE_BIN=<path>' \
    "${PATH:-unset}" "${places:-no other place}"
}

# -> the node on stdout and 0, or nothing on stdout and 3. Call sites: NODE_BIN="$(wa_node_require)" ||
# fail "$(wa_node_refusal)".
wa_node_require() {
  wa_node_bin
}

# -> 0 after putting the found node's directory FIRST on PATH (exported, so a child script - deploy.sh's
# policy installer, upgrade.sh's neighbours - resolves the same node), 3 with `wa_node_refusal` on stdout
# when there is none. This is what a script that only hands PATH to children needs.
wa_node_path() {
  local bin dir
  bin="$(wa_node_bin)" || { wa_node_refusal; return 3; }
  case "$bin" in
    */*) dir="${bin%/*}" ;;
    *) dir="." ;;
  esac
  case ":${PATH:-}:" in
    *":$dir:"*) ;;
    *) PATH="$dir:${PATH:-}"; export PATH ;;
  esac
  return 0
}
