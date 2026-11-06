#!/usr/bin/env bash
# Pinned components, installed beside the core (stream C of docs/KERNEL.md).
#
# A component is three files in the directory the core reads (`WA_COMPONENTS_DIR`, else
# `$HOME/.wasm-agent/components`): `<name>.wasm`, its pin `<name>.wasm.sha256` (required - an
# unpinned component is refused, docs/COMPONENTS.md) and its manifest `<name>.json`.
#
# The graph is one of them, and it is not optional any more: every `host.graph_*` call runs the
# `graph` component, so a node that gets the new core and no `graph.wasm` answers every graph verb
# with `graph_component_unavailable: component_not_installed:graph`. A core and its components are
# therefore one install, and `components.lock` at the repository root pins the bytes this tree's
# core expects (`<name> <sha256> <bytes>`).
#
# Nothing here installs a component whose bytes are not the pinned ones, and nothing here leaves a
# half-installed one: the module and the manifest land first, the pin last (a reader that sees the
# old pin refuses the new module, never runs it), and the previous triple is kept in
# `<dir>/.prev/` for the deploy's rollback.
#
# Sourced by scripts/deploy.sh (and shipped beside it) and exercised by
# scripts/test-deploy-components.sh.

# Where this machine's node reads components from. Same expression as
# `components::component_dir()` in rust/wa-host/src/components.rs: an explicit WA_COMPONENTS_DIR
# wins, else the home directory's `.wasm-agent/components`.
wa_components_dir() {
  if [ -n "${WA_COMPONENTS_DIR:-}" ]; then
    printf '%s\n' "$WA_COMPONENTS_DIR"
    return 0
  fi
  printf '%s\n' "${HOME:-${USERPROFILE:-.}}/.wasm-agent/components"
}

wa_component_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# <repo> <name> -> "<sha256> <bytes|->" on stdout, 2 when the pin file is missing, 3 when the
# component is not pinned in it. A blank line is never a pin: the caller refuses instead.
wa_component_pin() {
  local repo="$1" name="$2" lock="$1/components.lock" line
  [ -f "$lock" ] || return 2
  line="$(awk -v want="$name" '
    /^[[:space:]]*(#|$)/ {next}
    $1 == want && $2 ~ /^[0-9a-f]+$/ {print $2, ($3 == "" ? "-" : $3); found = 1; exit}
    END {exit !found}
  ' "$lock")" || return 3
  [ -n "$line" ] || return 3
  printf '%s
' "$line"
}

# <repo> <name> <out_dir>
#
# Stage one component into <out_dir> and verify it against components.lock.
#   WA_DEPLOY_COMPONENT_SOURCE=<dir>  install the artifacts another machine built (the supported
#                                     path for a node without a wasm toolchain)
#   unset                             build this tree's component (scripts/build-components.sh;
#                                     the graph needs wasi-sdk because tree-sitter and SQLite are C)
# Returns 0 on success, or 2 pin_missing, 3 component_missing, 4 build_failed,
# 5 component_hash_mismatch, 6 component_size_mismatch, 7 no_sha256_tool - each already printed.
wa_component_stage() {
  local repo="$1" name="$2" out="$3" pin pin_sha pin_bytes wasm json source build_log actual size
  if ! pin="$(wa_component_pin "$repo" "$name")"; then
    case $? in
      2) echo "component_pin_missing: no $repo/components.lock" >&2 ;;
      *) echo "component_pin_missing: $name is not pinned in components.lock" >&2 ;;
    esac
    return 2
  fi
  pin_sha="${pin%% *}"
  pin_bytes="${pin##* }"
  wasm="$out/$name.wasm"
  json="$out/$name.json"
  mkdir -p "$out" || { echo "component_stage_unwritable: $out" >&2; return 3; }
  rm -f "$wasm" "$json" "$out/$name.wasm.sha256"

  source="${WA_DEPLOY_COMPONENT_SOURCE:-}"
  if [ -n "$source" ]; then
    [ -f "$source/$name.wasm" ] || { echo "component_missing: $source/$name.wasm" >&2; return 3; }
    [ -f "$source/$name.json" ] || { echo "component_missing: $source/$name.json" >&2; return 3; }
    cp -f "$source/$name.wasm" "$wasm" && cp -f "$source/$name.json" "$json" \
      || { echo "component_stage_unwritable: $out" >&2; return 3; }
  else
    build_log="$out/.build-$name.log"
    WA_COMPONENTS_DIR="$out" bash "$repo/scripts/build-components.sh" "$name" >"$build_log" 2>&1
    if [ $? -ne 0 ] || [ ! -f "$wasm" ] || [ ! -f "$json" ]; then
      echo "component_build_failed: $name (log $build_log)" >&2
      return 4
    fi
    rm -f "$build_log"
  fi

  actual="$(wa_component_sha256 "$wasm")" || { echo "component_sha256_unavailable: no sha256sum or shasum" >&2; return 7; }
  if [ "$actual" != "$pin_sha" ]; then
    # A build made from this tree cannot match the pin byte for byte outside the checkout that
    # produced the pin (see components.lock). Pinned artifacts must always match; a local build may
    # differ only when the deploy says it accepts that, and then the hash it installed is reported
    # and recorded by the deploy - components.lock is never rewritten here.
    if [ "${WA_DEPLOY_COMPONENT_REPIN:-0}" = 1 ] && [ -z "$source" ]; then
      echo "component_repinned: $name components.lock pins $pin_sha, this build is $actual (installed and recorded, components.lock unchanged)"
      printf '%s
' "$actual" > "$out/.$name.wasm.sha256.tmp" && mv -f "$out/.$name.wasm.sha256.tmp" "$out/$name.wasm.sha256"         || { echo "component_stage_unwritable: $out" >&2; return 3; }
      return 0
    fi
    echo "component_hash_mismatch: $name expected $pin_sha from components.lock, staged bytes are $actual" >&2
    return 5
  fi
  if [ "$pin_bytes" != "-" ]; then
    size="$(wc -c < "$wasm" | tr -d '[:space:]')"
    if [ "$size" != "$pin_bytes" ]; then
      echo "component_size_mismatch: $name expected $pin_bytes bytes, staged bytes are $size" >&2
      return 6
    fi
  fi
  printf '%s\n' "$actual" > "$out/.$name.wasm.sha256.tmp" && mv -f "$out/.$name.wasm.sha256.tmp" "$out/$name.wasm.sha256" \
    || { echo "component_stage_unwritable: $out" >&2; return 3; }
  return 0
}

# <stage_dir> <component_dir> <name>
#
# Install the staged triple into the component directory, keeping the previous one in `.prev/` so
# `wa_component_restore` can put it back. The module and manifest are renamed into place first and
# the pin last, so a reader never pairs a new module with the old pin.
wa_component_install() {
  local stage="$1" dest="$2" name="$3" file actual
  for file in "$name.wasm" "$name.json" "$name.wasm.sha256"; do
    [ -f "$stage/$file" ] || { echo "component_missing: $stage/$file" >&2; return 3; }
  done
  mkdir -p "$dest/.prev" || { echo "component_dir_unwritable: $dest" >&2; return 3; }
  for file in "$name.wasm" "$name.json" "$name.wasm.sha256"; do
    if [ -f "$dest/$file" ]; then
      cp -pf "$dest/$file" "$dest/.prev/$file" || { echo "component_backup_failed: $dest/$file" >&2; return 3; }
    else
      rm -f "$dest/.prev/$file"
    fi
  done
  if [ "${WA_DEPLOY_COMPONENTS_DRY_RUN:-0}" = 1 ]; then
    echo "component_would_install: $dest/$name.wasm"
    return 0
  fi
  for file in "$name.wasm" "$name.json"; do
    cp -f "$stage/$file" "$dest/.$file.tmp" && mv -f "$dest/.$file.tmp" "$dest/$file" \
      || { echo "component_install_failed: $dest/$file" >&2; return 3; }
  done
  cp -f "$stage/$name.wasm.sha256" "$dest/.$name.wasm.sha256.tmp" \
    && mv -f "$dest/.$name.wasm.sha256.tmp" "$dest/$name.wasm.sha256" \
    || { echo "component_install_failed: $dest/$name.wasm.sha256" >&2; return 3; }
  # What landed is what was verified: a torn copy is not a component.
  actual="$(wa_component_sha256 "$dest/$name.wasm")" || return 7
  if [ "$actual" != "$(cat "$dest/$name.wasm.sha256" 2>/dev/null)" ]; then
    echo "component_hash_mismatch: $dest/$name.wasm does not match its own pin after install" >&2
    return 5
  fi
  echo "component_installed: $dest/$name.wasm ($actual)"
  return 0
}

# <component_dir> <name> - put back what `wa_component_install` replaced (or remove the triple when
# there was no previous component: this node did not have it installed).
wa_component_restore() {
  local dest="$1" name="$2" file restored=0 removed=0
  for file in "$name.wasm" "$name.json" "$name.wasm.sha256"; do
    if [ -f "$dest/.prev/$file" ]; then
      cp -pf "$dest/.prev/$file" "$dest/.$file.tmp" && mv -f "$dest/.$file.tmp" "$dest/$file" || return 3
      restored=$((restored + 1))
    elif [ -f "$dest/$file" ]; then
      rm -f "$dest/$file" || return 3
      removed=$((removed + 1))
    fi
  done
  echo "component_restored: $name files=$restored removed=$removed"
  return 0
}
