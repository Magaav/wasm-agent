#!/usr/bin/env bash
# Install the shipped default grant policy (`policies/default.json`) into a node's state directory - and
# bring a later release's NEW rules into the file a node already has.
#
# Three rules make this safe to run on every deploy:
#
#   * a policy file's PRESENCE is what turns the policy layer on (`docs/GRANT-POLICY.md`, "Manifest
#     mode"): with no file the manifest grant stays the only gate. Writing this file on a node that had
#     none therefore CHANGES what the node enforces, which is why it says so on the deploy log;
#   * the operator's EDITS are never overwritten. The unit of that promise is the RULE, not the file:
#     `scripts/lib/policy-merge.mjs` merges base = the shipped default this file was installed from,
#     ours = the node's file, theirs = the default this release ships, and a rule the operator changed is
#     kept byte for byte (a rule both sides changed is a conflict: the node's version wins and the deploy
#     says so);
#   * a rule the release ADDED arrives. This is the failure of openclaw 07/11: `ix/*` was added to
#     `wa-whatsapp`'s `kv.write` in `policies/default.json`, the deploy kept the node's (older, but
#     unedited) file whole, and every index write was refused until the rule was added by hand. Keeping
#     the whole file when only one rule was the operator's is what was wrong.
#
# The base is recorded, not guessed: the install writes the bytes it installed from to
# `<state>/policy.base.json` and their sha256 (plus where they came from) to `<state>/policy.base.sha256`,
# so the NEXT release merges against exactly the text this node started from. A node installed before
# that record existed has no base; then the base is the oldest default in `policies/default.json`'s git
# history whose bytes are the node's own (the release records in `policies/shipped/*.json` are tried
# after it), and when nothing matches, the merge is additions-only: new rules and new components are
# added, an EXISTING rule is never touched (adding entries to an `allow` list the operator narrowed would
# widen the limit the policy exists to enforce), and the entries the release has and the node lacks are
# printed so the operator has the one-line edit instead of a refused write at 03:12.
#
# When the merge cannot run at all (no `node` on PATH, or the tool is not beside this helper - the
# installed copy of deploy.sh may not carry it), the old narrow rule still applies: a file that is
# byte-identical to a default this tree shipped (`policies/shipped/*.json`, plus the current
# `policies/default.json` itself) is refreshed to the current default, because nobody's choice is being
# overwritten - the bytes are the release's own. Anything else is kept and the deploy says why.
#
# This lives in its own file with functions because `scripts/test.sh` runs it against scratch
# directories: "a rule the operator changed is kept, a rule the release added arrives" is measured by
# running the code a deploy runs, not by reading the deploy script.
#
#   install_default_policy <source> <destination>   -> 0 installed / merged / refreshed / kept, 2 no
#                                                      default in this tree, 1 failure
#   policy_merge_warnings <policy>                  -> the last merge's conflicts and hints, one line
#   policy_unlisted_components <policy> <dir>       -> installed component names the file does not name

# Where the merge tool is. Beside this helper in a checkout (`$ROOT/scripts/lib/policy-merge.mjs`); the
# installed copy of deploy.sh has no `lib/`, and then this answers nothing and the caller degrades to the
# byte-identity refresh instead of guessing.
policy_merge_tool() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || return 1
  [ -f "$dir/policy-merge.mjs" ] || return 1
  printf '%s\n' "$dir/policy-merge.mjs"
}

policy_sha256() { # file -> hex, empty when it cannot be read
  local out=""
  out="$(sha256sum < "$1" 2>/dev/null | awk '{print $1}')"
  [ -n "$out" ] || out="$(shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}')"
  printf '%s' "$out"
}

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

# Record which shipped default this file now stands on: the bytes and their sha256. Written on every
# install, merge and no-op alike, so the next release has a base even when this one changed nothing.
# The sha is what makes the copy a base: a truncated or hand-edited copy is not one, and a WRONG base
# would let a release "change" a rule the operator wrote.
install_default_policy_record_base() { # source destination [label]
  local source="$1" destination="$2" label="${3:-}" state sha staged
  state="$(dirname "$destination")"
  [ -f "$source" ] || return 0
  sha="$(policy_sha256 "$source")"
  [ -n "$sha" ] || { printf 'policy: cannot hash %s, so the base of %s is not recorded\n' "$source" "$destination" >&2; return 1; }
  [ -d "$state" ] || mkdir -p "$state" || return 1
  staged="$state/.policy.base.json.$$"
  cp -f "$source" "$staged" \
    || { rm -f "$staged"; printf 'policy: cannot stage %s\n' "$staged" >&2; return 1; }
  mv -f "$staged" "$state/policy.base.json" \
    || { rm -f "$staged"; printf 'policy: cannot record the policy base in %s\n' "$state" >&2; return 1; }
  printf '%s  %s\n' "$sha" "${label:-$(basename "$source")}" > "$state/.policy.base.sha256.$$" \
    && mv -f "$state/.policy.base.sha256.$$" "$state/policy.base.sha256" \
    || { rm -f "$state/.policy.base.sha256.$$"; printf 'policy: cannot record the policy base sha in %s\n' "$state" >&2; return 1; }
  return 0
}

# Record the base, and never fail the deploy over it: a base nobody could write means the NEXT release
# falls back to the history search (or to an additions-only merge) - a smaller merge, not a broken node.
# Saying so is the point; refusing the install over a 6 KB copy would leave the node on the old binary too.
install_default_policy_keep_base() { # source destination [label]
  install_default_policy_record_base "$1" "$2" "${3:-}" \
    || printf 'policy: WARNING the base of %s is not recorded; a later release falls back to its history, or to an additions-only merge\n' "$2" >&2
  return 0
}

# The base this install recorded, when its sha still matches the copy (a copy that was tampered with, or
# half-written, is not a base: merging against it could report the operator's rule as "the release
# changed this" and overwrite it).
install_default_policy_recorded_base() { # destination -> path or empty
  local destination="$1" state base recorded
  state="$(dirname "$destination")"
  base="$state/policy.base.json"
  [ -f "$base" ] || return 0
  recorded="$(sed -n '1s/[[:space:]].*//p' "$state/policy.base.sha256" 2>/dev/null)"
  [ -n "$recorded" ] || return 0
  [ "$(policy_sha256 "$base")" = "$recorded" ] || return 0
  printf '%s\n' "$base"
}

# The oldest default in this tree's history whose bytes are the node's own file - the base of a node that
# was installed before this record existed. `--reverse` is the point: several releases may ship the same
# bytes, and the oldest one is the text the node actually started from.
# Prints "history:<sha12><TAB><path>" or nothing.
install_default_policy_history_base() { # source destination scratch -> label<TAB>path or empty
  local source="$1" destination="$2" scratch="$3" repo revs rev path
  command -v git >/dev/null 2>&1 || return 0
  repo="${WA_POLICY_REPO_ROOT:-$(cd "$(dirname "$source")/.." 2>/dev/null && pwd)}"
  [ -n "$repo" ] || return 0
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  revs="$(git -C "$repo" log --reverse --format=%H -- policies/default.json 2>/dev/null)" || return 0
  [ -n "$revs" ] || return 0
  while IFS= read -r rev; do
    [ -n "$rev" ] || continue
    git -C "$repo" show "$rev:policies/default.json" 2>/dev/null | cmp -s - "$destination" || continue
    path="$scratch/base-from-history.json"
    git -C "$repo" show "$rev:policies/default.json" > "$path" 2>/dev/null || return 0
    printf 'history:%s\t%s\n' "$(printf '%s' "$rev" | cut -c1-12)" "$path"
    return 0
  done <<EOF
$revs
EOF
  return 0
}

# Replace a file this release can PROVE is its own text with the release's text, byte for byte. The
# pre-merge fallback (no node, no tool) and the "node never edited a rule" case of a merge both end here,
# so a node that never edited its policy ends up on exactly the bytes the release ships.
install_default_policy_refresh() { # source destination match
  local source="$1" destination="$2" match="$3" staged
  staged="$destination.refresh.$$"
  cp -f "$source" "$staged" \
    || { rm -f "$staged"; printf 'policy: cannot stage %s\n' "$staged" >&2; return 1; }
  # The file may have been edited while this ran: judge it again, and let the operator's edit win.
  if ! cmp -s "$match" "$destination"; then
    rm -f "$staged"
    printf 'policy: kept %s (it changed while the refresh was staging)\n' "$destination"
    return 0
  fi
  install_default_policy_keep_mode "$destination" "$staged"
  mv -f "$staged" "$destination" \
    || { rm -f "$staged"; printf 'policy: cannot move %s into place\n' "$destination" >&2; return 1; }
  cmp -s "$source" "$destination" \
    || { printf 'policy: refreshed %s does not match %s\n' "$destination" "$source" >&2; return 1; }
  [ "$(policy_sha256 "$destination")" = "$(policy_sha256 "$source")" ] || { printf 'policy: refreshed %s changed under the refresh\n' "$destination" >&2; return 1; }
  printf 'policy: refreshed %s (it was the unmodified shipped default %s; the release now ships it as %s)\n' \
    "$destination" "$(basename "$match")" "$(basename "$source")"
  return 0
}

# Keep the operator's file mode on the file that replaces it: a 0640 policy that becomes 0644 on a deploy
# is a permission change nobody asked for.
install_default_policy_keep_mode() { # destination staged
  local bits
  bits="$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)"
  [ -n "$bits" ] || return 0
  chmod "$bits" "$2" 2>/dev/null || true
  return 0
}

# The last merge's report, for `installed.txt`: the rules both sides changed (the node's version was kept)
# and the entries the release has and the node lacks. One line, empty when there is nothing to warn about.
policy_merge_warnings() { # policy-file -> one line, empty when nothing
  local destination="$1" state report line out=""
  state="$(dirname "$destination")"
  report="$state/policy.merge.txt"
  [ -f "$report" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      conflict=*|hint=*) out="${out}${out:+; }${line#*=}" ;;
    esac
  done < "$report"
  [ ${#out} -le 480 ] || out="${out:0:477}..."
  printf '%s' "$out"
}

# Bring this release's rules into a file that already exists, per rule, and print what happened.
# 0 = merged, or kept because the file already carries every rule (both are a deploy that continues);
# 1 = the file could not be written. A file that does not parse, or a merge that cannot run, is a KEPT
# file with a warning: a policy nobody can read is still the operator's, and refusing the deploy over it
# would leave the node on the old binary as well.
install_default_policy_merge() { # source destination -> 0 merged/kept, 1 failure
  local source="$1" destination="$2" state tool scratch base label mode changed node_edits status
  local out summary staged before report applied match recorded history tab
  state="$(dirname "$destination")"
  # A tab, written as an escape so it stays visible in this file: `install_default_policy_history_base`
  # prints `label<TAB>path` and nothing else.
  tab=$'\t'
  tool="$(policy_merge_tool)" || {
    printf 'policy: kept %s (scripts/lib/policy-merge.mjs is not beside the installer, so this release cannot merge its rules in)\n' "$destination"
    match="$(install_default_policy_matches "$destination" "$source")"
    if [ -n "$match" ]; then
      install_default_policy_refresh "$source" "$destination" "$match" || return 1
      install_default_policy_keep_base "$source" "$destination" "installed-from:$(basename "$source")"
    fi
    return 0
  }
  if ! command -v node >/dev/null 2>&1; then
    printf 'policy: kept %s (node is not on PATH, so this release cannot merge its rules in)\n' "$destination"
    match="$(install_default_policy_matches "$destination" "$source")"
    if [ -n "$match" ]; then
      install_default_policy_refresh "$source" "$destination" "$match" || return 1
      install_default_policy_keep_base "$source" "$destination" "installed-from:$(basename "$source")"
    fi
    return 0
  fi
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/wa-policy-merge-XXXXXX")" || {
    printf 'policy: kept %s (no scratch directory to merge in)\n' "$destination"
    return 0
  }
  # --- which text is this file's base? --------------------------------------------------------------
  base=""
  label="none"
  recorded="$(install_default_policy_recorded_base "$destination")"
  if [ -n "$recorded" ]; then
    base="$recorded"
    label="recorded:policy.base.json"
  else
    history="$(install_default_policy_history_base "$source" "$destination" "$scratch")"
    if [ -n "$history" ]; then
      label="${history%%$tab*}"
      base="${history#*$tab}"
    else
      match="$(install_default_policy_matches "$destination" "$source")"
      if [ -n "$match" ]; then
        label="shipped:$(basename "$match")"
        base="$match"
      fi
    fi
  fi
  # --- the merge ------------------------------------------------------------------------------------
  # The node's file as it is RIGHT NOW: if it changes while the merge runs, that change wins (the same
  # rule the install and refresh paths apply - an edit made during a deploy is not ours to overwrite).
  before="$(policy_sha256 "$destination")"
  out="$destination.merge.$$"
  summary="$scratch/summary.txt"
  if [ -z "$base" ]; then
    node "$tool" --additions-only --ours "$destination" --theirs "$source" \
      --out "$out" --summary "$summary" > "$scratch/report.txt" 2>&1
  else
    node "$tool" --base "$base" --base-label "$label" --ours "$destination" --theirs "$source" \
      --out "$out" --summary "$summary" > "$scratch/report.txt" 2>&1
  fi
  status=$?
  case $status in
    0) ;;
    3)
      # The node's file is not JSON at all. Keeping it is the old contract and the right one: the node
      # refuses its sensitive capabilities and says why, and a default written over it would hide that.
      printf 'policy: kept %s (it is not valid JSON, so this release cannot merge its rules in; the node refuses its sensitive capabilities until it is fixed)\n' "$destination"
      rm -f "$out"
      printf 'mode=three-way\nbase=%s\nchanged=0\nnode_edits=0\nhint=%s\n' "$label" \
        "$destination is not valid JSON; no shipped rule could be merged into it" > "$summary"
      ;;
    5)
      # The merge ran but would have dropped something the node already had (a top-level member or a
      # component rule) without recording it as a deletion. Writing that file would take a grant away in
      # silence, so the node's own bytes stay and the deploy says exactly what the merge refused to do.
      printf 'policy: kept %s (merging this release would have dropped rules the node has: %s)\n' "$destination" "$(tail -1 "$scratch/report.txt" 2>/dev/null)"
      rm -f "$out"
      printf 'mode=three-way\nbase=%s\nchanged=0\nnode_edits=0\nhint=%s\n' "${label:-none}" \
        "merging would have dropped rules the node has; its file was kept" > "$summary"
      ;;
    *)
      printf 'policy: kept %s (the rule merge could not run: %s)\n' "$destination" "$(tail -1 "$scratch/report.txt" 2>/dev/null)"
      rm -f "$out"
      printf 'mode=three-way\nbase=%s\nchanged=0\nnode_edits=0\nhint=%s\n' "${label:-none}" \
        "the rule merge could not run for $destination" > "$summary"
      ;;
  esac
  # The report, verbatim, is what the operator reads on the deploy log - and only when the merge ran: a
  # merge that could not run has already said so above, and printing the tool's own message again would
  # make one problem read like two.
  if [ "$status" = 0 ]; then
    while IFS= read -r report; do
      [ -n "$report" ] || continue
      printf 'policy: %s\n' "$report"
    done < "$scratch/report.txt"
  fi
  cp -f "$summary" "$state/policy.merge.txt" 2>/dev/null || true
  [ "$status" = 0 ] || { rm -rf "$scratch"; return 0; }
  mode="$(sed -n 's/^mode=//p' "$summary" | head -1)"
  changed="$(sed -n 's/^changed=//p' "$summary" | head -1)"
  node_edits="$(sed -n 's/^node_edits=//p' "$summary" | head -1)"
  applied="$(sed -n 's/^applied=//p' "$summary" | head -1)"
  if [ "$changed" != 1 ]; then
    printf 'policy: kept %s (it already carries every rule this release ships)\n' "$destination"
    rm -rf "$scratch"
    install_default_policy_keep_base "$source" "$destination" "installed-from:$(basename "$source")"
    return 0
  fi
  # A three-way merge with no node edits means this file is still the release's own text: install the
  # release's bytes, so an unedited node file stays byte-identical to `policies/default.json` (and the
  # next release compares against exactly the shipped text).
  staged="$destination.merge.staged.$$"
  if [ "$mode" = three-way ] && [ "$node_edits" = 0 ]; then
    cp -f "$source" "$staged"
  else
    cp -f "$out" "$staged"
  fi || { rm -f "$staged" "$out"; rm -rf "$scratch"; printf 'policy: cannot stage %s\n' "$staged" >&2; return 1; }
  rm -f "$out"
  # The merged file must be a policy before it is allowed to replace one.
  if ! node "$tool" --verify "$staged" >/dev/null 2>&1; then
    rm -f "$staged"; rm -rf "$scratch"
    printf 'policy: kept %s (the merged file did not parse; nothing was written)\n' "$destination"
    return 0
  fi
  # Judge the node's file again immediately before the swap, and let an edit made while this ran win.
  install_default_policy_keep_mode "$destination" "$staged"
  if [ "$(policy_sha256 "$destination")" != "$before" ]; then
    rm -f "$staged"; rm -rf "$scratch"
    printf 'policy: kept %s (it changed while the merge was staging)\n' "$destination"
    return 0
  fi
  # The operator's text is kept beside the file it replaces, so a merge they disagree with can be undone
  # by hand instead of by memory. Written only once the swap is certain (after the race check), so the copy
  # is always the file that was actually replaced.
  cp -f "$destination" "$state/.policy.prev.json.$$" \
    && mv -f "$state/.policy.prev.json.$$" "$state/policy.prev.json" \
    || rm -f "$state/.policy.prev.json.$$"
  mv -f "$staged" "$destination" \
    || { rm -f "$staged"; rm -rf "$scratch"; printf 'policy: cannot move %s into place\n' "$destination" >&2; return 1; }
  node "$tool" --verify "$destination" >/dev/null 2>&1 \
    || { rm -rf "$scratch"; printf 'policy: merged %s does not parse\n' "$destination" >&2; return 1; }
  printf 'policy: merged %s (%s; %s; the file it replaced is kept at %s)\n' \
    "$destination" "$mode" "${applied:-no shipped rule changed}" "$state/policy.prev.json"
  rm -rf "$scratch"
  install_default_policy_keep_base "$source" "$destination" "installed-from:$(basename "$source")"
  return 0
}

install_default_policy() { # source destination
  local source="$1" destination="$2" state staged
  state="$(dirname "$destination")"
  if [ ! -f "$source" ] && [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    printf 'policy: no default policy at %s; nothing installed\n' "$source"
    return 2
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    # A path that is not a regular file (a directory, a dangling symlink) is not something to write
    # through and not ours to remove.
    if [ ! -f "$destination" ]; then
      printf 'policy: kept %s (it is not a regular file, so this deploy writes nothing there)\n' "$destination"
      return 0
    fi
    if [ ! -f "$source" ]; then
      printf 'policy: kept %s (this tree has no default to merge with)\n' "$destination"
      return 0
    fi
    if cmp -s "$source" "$destination"; then
      printf 'policy: kept %s (already the current default)\n' "$destination"
      install_default_policy_keep_base "$source" "$destination" "installed-from:$(basename "$source")"
      return 0
    fi
    install_default_policy_merge "$source" "$destination"
    return $?
  fi
  if [ ! -f "$source" ]; then
    printf 'policy: no default policy at %s; nothing installed\n' "$source"
    return 2
  fi
  mkdir -p "$state" \
    || { printf 'policy: cannot create %s\n' "$state" >&2; return 1; }
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
  printf 'policy: installed %s (from %s; the base it was installed from is recorded beside it, so a later release merges its new rules in per rule)\n' \
    "$destination" "$source"
  install_default_policy_keep_base "$source" "$destination" "installed-from:$(basename "$source")"
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
