#!/usr/bin/env bash
# Install the shipped default grant policy (`policies/default.json`) into a node's state directory.
#
# Two rules make this safe to run on every deploy:
#
#   * a policy file's PRESENCE is what turns the policy layer on (`docs/GRANT-POLICY.md`, "Manifest
#     mode"): with no file the manifest grant stays the only gate. Writing this file on a node that
#     had none therefore CHANGES what the node enforces, which is why it says so on the deploy log;
#   * the operator's file is never touched. A file this release can PROVE is unmodified - byte for
#     byte one of the defaults the tree has shipped (`policies/shipped/*.json`, plus the current
#     `policies/default.json` itself) - is refreshed to the current default, because nobody's choice
#     is being overwritten: it is still the release's text. Anything else (an edited cap, an extra
#     chat, a broken file, a directory, a symlink) wins, and the deploy says "kept".
#
# The refresh exists for exactly one migration: `whatsapp.send` moved from "our own chat and the
# alerts chat" to "any chat, under a global 20/min, a per-chat 6/min and a daily 500 cap" (the owner's
# decision of 06/11, `docs/GRANT-POLICY.md`). A node that never edited its policy file gets the new
# rule on its next deploy; a node whose operator ranked their own limits keeps them, and the deploy
# names the one-line edit instead (`docs/GRANT-POLICY.md`, "The shipped default").
#
# This lives in its own file with a function because `scripts/test.sh` runs it against scratch
# directories: "an existing policy.json is only ever refreshed when it is still the shipped default"
# is measured by running the code a deploy runs, not by reading the deploy script. Nothing here parses
# JSON; the files are compared and copied byte for byte.
#
#   install_default_policy <source> <destination>   -> 0 installed / refreshed / kept, 2 no default in
#                                                      this tree, 1 failure
#   policy_unlisted_components <policy> <dir>       -> installed component names the file does not name

# The shipped defaults a policy file may be identical to, given the source being installed: every
# `policies/shipped/*.json` beside it, plus the source itself. Sorted, so the log line is stable.
install_default_policy_known_defaults() { # source
  local source="$1" shipped
  shipped="$(dirname "$source")/shipped"
  printf '%s\n' "$source"
  [ -d "$shipped" ] || return 0
  for candidate in "$shipped"/*.json; do
    [ -f "$candidate" ] && printf '%s\n' "$candidate"
  done
  return 0
}

# Is this file byte-identical to a default this tree shipped? Prints the matching default when it is,
# nothing when it is not (an editor's file, a partial write, a broken file - all "not ours").
install_default_policy_matches() { # destination source -> matching default or empty
  local destination="$1" source="$2" known
  while IFS= read -r known; do
    [ -n "$known" ] && [ -f "$known" ] || continue
    if cmp -s "$known" "$destination"; then
      printf '%s\n' "$known"
      return 0
    fi
  done <<EOF
$(install_default_policy_known_defaults "$source")
EOF
  return 0
}

install_default_policy() { # source destination
  local source="$1" destination="$2" staged match
  if [ ! -f "$source" ] && { [ ! -e "$destination" ] && [ ! -L "$destination" ]; }; then
    printf 'policy: no default policy at %s; nothing installed\n' "$source"
    return 2
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    # An existing file is refreshed ONLY when this release can prove it is the release's own text.
    match="$(install_default_policy_matches "$destination" "$source")"
    if [ -z "$match" ]; then
      printf 'policy: kept %s (it names the operator%s, so a deploy never overwrites it)\n' "$destination" "'s own limits"
      return 0
    fi
    if [ ! -f "$source" ]; then
      printf 'policy: kept %s (it is the shipped default %s, and this tree has no default to refresh it with)\n' "$destination" "$(basename "$match")"
      return 0
    fi
    if cmp -s "$source" "$destination"; then
      printf 'policy: kept %s (already the current default)\n' "$destination"
      return 0
    fi
    staged="$destination.refresh.$$"
    cp -f "$source" "$staged" \
      || { rm -f "$staged"; printf 'policy: cannot stage %s\n' "$staged" >&2; return 1; }
    # The file may have been edited while this ran: judge it again, and let the operator's edit win.
    if [ "$(install_default_policy_matches "$destination" "$source")" != "$match" ]; then
      rm -f "$staged"
      printf 'policy: kept %s (it changed while the refresh was staging)\n' "$destination"
      return 0
    fi
    mv -f "$staged" "$destination" \
      || { rm -f "$staged"; printf 'policy: cannot move %s into place\n' "$destination" >&2; return 1; }
    cmp -s "$source" "$destination" \
      || { printf 'policy: refreshed %s does not match %s\n' "$destination" "$source" >&2; return 1; }
    printf 'policy: refreshed %s (it was the unmodified shipped default %s: the whatsapp.send rule now allows any chat under the release caps)\n' \
      "$destination" "$(basename "$match")"
    return 0
  fi
  if [ ! -f "$source" ]; then
    printf 'policy: no default policy at %s; nothing installed\n' "$source"
    return 2
  fi
  mkdir -p "$(dirname "$destination")" \
    || { printf 'policy: cannot create %s\n' "$(dirname "$destination")" >&2; return 1; }
  # Someone (the operator, a running node, another deploy) may have written it in the meantime: check
  # again immediately before staging, and once more before the rename, and let their file win both
  # times. A policy file that appears while this runs is not ours to replace.
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    printf 'policy: kept %s (appeared while installing)\n' "$destination"
    return 0
  fi
  staged="$destination.install.$$"
  cp -f "$source" "$staged" \
    || { rm -f "$staged"; printf 'policy: cannot stage %s\n' "$staged" >&2; return 1; }
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    rm -f "$staged"
    printf 'policy: kept %s (appeared while installing)\n' "$destination"
    return 0
  fi
  mv -f "$staged" "$destination" \
    || { rm -f "$staged"; printf 'policy: cannot move %s into place\n' "$destination" >&2; return 1; }
  cmp -s "$source" "$destination" \
    || { printf 'policy: installed %s does not match %s\n' "$destination" "$source" >&2; return 1; }
  printf 'policy: installed %s (from %s; a deploy will only ever refresh it while it is still that default)\n' "$destination" "$source"
  return 0
}

# Which installed components does the policy file say nothing about? The moment that file exists, a
# component it does not name has every sensitive capability refused with `no_policy`, so the deploy
# names them instead of letting the operator discover it as a refused write at 03:12. Advisory: the
# caller notes it and nothing fails. Component names are `[a-z0-9-]` (`components::valid_name`), so
# the pattern below cannot be a surprise.
policy_unlisted_components() { # policy-file components-dir
  local policy="$1" dir="$2" wasm name
  [ -f "$policy" ] || return 0
  [ -d "$dir" ] || return 0
  for wasm in "$dir"/*.wasm; do
    [ -f "$wasm" ] || continue
    name="$(basename "$wasm" .wasm)"
    grep -q "\"$name\"[[:space:]]*:" "$policy" 2>/dev/null && continue
    printf '%s\n' "$name"
  done
  return 0
}
