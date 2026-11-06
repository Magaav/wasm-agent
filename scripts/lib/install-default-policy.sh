#!/usr/bin/env bash
# Install the shipped default grant policy (`policies/default.json`) into a node's state directory -
# but ONLY where the operator has no policy file. Two rules make this safe to run on every deploy:
#
#   * a policy file's PRESENCE is what turns the policy layer on (`docs/GRANT-POLICY.md`, "Manifest
#     mode"): with no file the manifest grant stays the only gate. Writing this file on a node that
#     had none therefore CHANGES what the node enforces, which is why it happens once, by name, and
#     says so on the deploy log;
#   * the operator's file is never touched. An existing file - theirs, an older default, a broken
#     one, a directory, a symlink - wins, and the deploy says "kept". A default installed once is
#     never refreshed afterwards: rate limits and allow lists are the operator's, not the release's.
#
# This lives in its own file with a function because `scripts/test.sh` runs it against scratch
# directories: "an existing policy.json is untouched" is measured by running the code a deploy runs,
# not by reading the deploy script. Nothing here parses JSON; the file is copied byte for byte.
#
#   install_default_policy <source> <destination>   -> 0 installed or kept, 2 no default in this tree, 1 failure
#   policy_unlisted_components <policy> <dir>       -> installed component names the file does not name

install_default_policy() { # source destination
  local source="$1" destination="$2" staged
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    printf 'policy: kept %s (a policy file is already there; a deploy never overwrites one)\n' "$destination"
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
  printf 'policy: installed %s (from %s; a deploy will not touch it again)\n' "$destination" "$source"
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
