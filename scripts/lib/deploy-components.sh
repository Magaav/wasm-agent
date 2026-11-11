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
# Where the bytes come from, in the order a node that never built wasm should try them: the bytes
# already installed (a repeat deploy), the bundle this node fetched for the same lock, and finally
# the release `components-<short sha of components.lock>` (scripts/publish-components.sh builds and
# uploads it once; wasm is portable, so one artifact serves every node). A download is verified
# against components.lock BEFORE it is cached or staged, and the cache is keyed by the lock's sha,
# so a repeated deploy does not refetch and a corrupt cache is never trusted - staging re-hashes
# everything it copies. WA_DEPLOY_COMPONENT_SOURCE and a local build (WA_DEPLOY_COMPONENT_REPIN=1)
# stay as the explicit overrides.
#
# Sourced by scripts/deploy.sh (and shipped beside it) and exercised by
# scripts/test-deploy-components.sh.

# Where this machine's node reads components from. Same expression as
# `components::component_dir()` in rust/wa-kernel-runtime/src/components.rs: an explicit WA_COMPONENTS_DIR
# wins, else the home directory's `.wasm-agent/components`.
wa_components_dir() {
  if [ -n "${WA_COMPONENTS_DIR:-}" ]; then
    printf '%s\n' "$WA_COMPONENTS_DIR"
    return 0
  fi
  printf '%s\n' "${HOME:-${USERPROFILE:-.}}/.wasm-agent/components"
}

wa_component_sha256() {
  # The file is fed on **stdin**, not named on the command line. GNU `sha256sum` escapes a filename
  # that contains a backslash by prefixing the whole line with one (`\1d22…  C:\\Users\\…`), and a
  # Windows path is exactly that: `awk` then hands back a hash that starts with a backslash. Measured
  # on wasm_the_first, 11/11: the deploy computed the components-lock identity as `\1d22f2ced44`,
  # asked GitHub for the release `components-\1d22f2ced44` (which cannot exist), fell back to building
  # wa-whatsapp from the tree, and refused the deploy `component_hash_mismatch` - while
  # `components-1d22f2ced448` was published all along. A hash is a property of the bytes, not of the
  # path they were read from.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{print $1}'
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

# ---------------------------------------------------------------------------------------------------
# Distribution: the release bundle for this lock, fetched once and cached by sha
# ---------------------------------------------------------------------------------------------------

# <repo> -> sha256 of <repo>/components.lock (2 when there is no lock file, 7 without a sha tool).
# This is the identity of a release: the tag is `components-` plus its first 12 hex characters, so a
# node can name the exact bundle its pins describe without reading anything but the pins.
wa_component_lock_sha() {
  local lock="$1/components.lock"
  [ -f "$lock" ] || return 2
  wa_component_sha256 "$lock" || return 7
}

# <repo> -> the release tag that publishes the components this lock pins.
wa_component_release_tag() {
  local sha
  sha="$(wa_component_lock_sha "$1")" || return $?
  printf 'components-%s\n' "${sha:0:12}"
}

# <repo> -> owner/repo the release lives in. WA_COMPONENT_RELEASE_REPO wins (a fork, a mirror); else
# origin's own GitHub slug; else the source of truth every tree in this fleet is a worktree of
# (AGENTS.md). The fallback is deliberate: a node's origin is often a local path (a worktree, a
# sandbox copy) and it is exactly those nodes that need the release.
wa_component_release_repo() {
  local repo="$1" url
  if [ -n "${WA_COMPONENT_RELEASE_REPO:-}" ]; then
    printf '%s\n' "$WA_COMPONENT_RELEASE_REPO"
    return 0
  fi
  url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null)"
  case "$url" in
    *github.com[:/]*)
      url="${url##*github.com[:/]}"
      url="${url%.git}"
      case "$url" in
        */*) printf '%s\n' "$url"; return 0 ;;
      esac ;;
  esac
  printf '%s\n' "Magaav/wasm-agent"
}

# <install_dir> -> where fetched bundles are cached. Under the install directory on purpose: it is
# the one directory a deploy owns and that a node's user can clean, and a cache is install state.
wa_component_cache_root() {
  if [ -n "${WA_COMPONENTS_CACHE:-}" ]; then
    printf '%s\n' "$WA_COMPONENTS_CACHE"
  else
    printf '%s\n' "${1:-.}/components-cache"
  fi
}

# <repo> <tag> <name> <dest> [base]
#
# Fill <dest> with <name>.wasm, <name>.json and components.lock of the release bundle. Returns 0 or 8
# (not reachable). Nothing here verifies hashes: that is wa_component_download's job, on what landed.
#   WA_COMPONENT_RELEASE_URL=<dir>|file://<dir>  read that bundle instead of the network (the stub the
#                                               tests use, and the way a hand-copied bundle is tried)
#   WA_COMPONENT_RELEASE_URL=https://...        the base URL of the assets
#   unset                                       `gh release download`, then the public release URL
wa_component_fetch_assets() {
  local repo="$1" tag="$2" name="$3" dest="$4" base="${5:-}" asset local_base url_base
  [ -d "$repo" ] && repo="$(wa_component_release_repo "$repo")"
  local assets="$name.wasm $name.json components.lock"
  local_base=""
  url_base=""
  case "$base" in
    file://*) local_base="${base#file://}" ;;
    http://*|https://*) url_base="$base" ;;
    ?*)
      if [ -d "$base" ]; then local_base="$base"
      else
        # A path that is not a directory is not a URL either: say so instead of handing it to curl.
        echo "component_release_url_unusable: WA_COMPONENT_RELEASE_URL=$base is neither an existing directory nor an http(s) URL" >&2
        return 8
      fi ;;
  esac
  if [ -n "$local_base" ]; then
    for asset in $assets; do
      [ -f "$local_base/$asset" ] || { echo "component_release_incomplete: $local_base/$asset" >&2; return 8; }
      cp -f "$local_base/$asset" "$dest/$asset" || return 8
    done
    return 0
  fi
  if [ -n "$url_base" ]; then
    command -v curl >/dev/null 2>&1 || return 8
    for asset in $assets; do
      curl -fsSL -m 60 "$url_base/$asset" -o "$dest/$asset" 2>/dev/null \
        || { echo "component_release_unreachable: $url_base/$asset" >&2; rm -f "$dest/$asset"; return 8; }
    done
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    if gh release download "$tag" -R "$repo" -D "$dest" \
      -p "$name.wasm" -p "$name.json" -p components.lock >/dev/null 2>&1 \
      && [ -f "$dest/$name.wasm" ] && [ -f "$dest/$name.json" ] && [ -f "$dest/components.lock" ]; then
      return 0
    fi
    # gh without a token on the node, a release that is not there yet: the anonymous URL may still work.
    echo "component_release_gh_failed: gh could not download $tag from $repo; trying the public asset URL" >&2
    rm -f "$dest/$name.wasm" "$dest/$name.json" "$dest/components.lock"
  fi
  command -v curl >/dev/null 2>&1 || return 8
  for asset in $assets; do
    curl -fsSL -m 60 "https://github.com/$repo/releases/download/$tag/$asset" -o "$dest/$asset" 2>/dev/null \
      || { echo "component_release_unreachable: https://github.com/$repo/releases/download/$tag/$asset" >&2; rm -f "$dest/$asset"; return 8; }
  done
  return 0
}

# <repo> <name> <cache_root>
#
# Fetch the release bundle this tree's lock names and cache it under the lock's sha. Prints the cached
# directory on success. Returns 2 pin_missing, 5 pinned bytes refused (a bundle that does not match
# components.lock, or a bundle whose own components.lock is another lock), 6 size_mismatch, 7 no sha
# tool, 8 nothing reached - and 8 is the only one a caller may answer by building the tree instead,
# because a refusal means the bytes that claim to be pinned are not the pinned ones.
wa_component_download() {
  local repo="$1" name="$2" cache_root="$3" pin pin_sha pin_bytes lock_sha tag entry tmp actual size bundle_lock_sha
  if ! pin="$(wa_component_pin "$repo" "$name")"; then
    case $? in
      2) echo "component_pin_missing: no $repo/components.lock" >&2 ;;
      *) echo "component_pin_missing: $name is not pinned in components.lock" >&2 ;;
    esac
    return 2
  fi
  pin_sha="${pin%% *}"
  pin_bytes="${pin##* }"
  lock_sha="$(wa_component_lock_sha "$repo")" || return 7
  tag="components-${lock_sha:0:12}"
  entry="$cache_root/$lock_sha"
  tmp="$cache_root/.incoming.$$"
  # A fetch killed mid-copy leaves its own .incoming.<pid>; this deploy only ever removes its own, so
  # the ones older than a day are swept here. Never a cache entry: those are read through a sha check.
  for stale in "$cache_root"/.incoming.*; do
    [ -d "$stale" ] || continue
    [ "$stale" = "$tmp" ] && continue
    [ -n "$(find "$stale" -maxdepth 0 -mmin +${WA_COMPONENTS_INCOMING_AGE:-1440} 2>/dev/null)" ] && rm -rf "$stale"
  done
  rm -rf "$tmp"
  mkdir -p "$tmp" || { printf 'component_cache_unwritable: %s\n' "$cache_root"; return 8; }
  if ! wa_component_fetch_assets "$repo" "$tag" "$name" "$tmp" "${WA_COMPONENT_RELEASE_URL:-}"; then
    rm -rf "$tmp"
    printf 'component_release_unavailable: %s is not cached and the %s bundle could not be fetched (WA_COMPONENT_RELEASE_URL=%s)\n' \
      "$name" "$tag" "${WA_COMPONENT_RELEASE_URL:-unset}"
    return 8
  fi
  # The bundle's own components.lock is the release's identity: a tag names one lock, and a bundle
  # carrying another lock is not this release even if one of its components happens to match.
  bundle_lock_sha="$(wa_component_sha256 "$tmp/components.lock")" || { rm -rf "$tmp"; return 7; }
  if [ "$bundle_lock_sha" != "$lock_sha" ]; then
    rm -rf "$tmp"
    printf 'component_release_lock_mismatch: %s bundle components.lock is %s, this tree pins %s (%s)\n' \
      "$name" "$bundle_lock_sha" "$lock_sha" "$tag"
    return 5
  fi
  actual="$(wa_component_sha256 "$tmp/$name.wasm" 2>/dev/null)" || { rm -rf "$tmp"; return 7; }
  if [ "$actual" != "$pin_sha" ]; then
    rm -rf "$tmp"
    printf 'component_hash_mismatch: %s bundle has %s, components.lock pins %s\n' "$name" "$actual" "$pin_sha"
    return 5
  fi
  if [ "$pin_bytes" != "-" ]; then
    size="$(wc -c < "$tmp/$name.wasm" | tr -d '[:space:]')"
    if [ "$size" != "$pin_bytes" ]; then
      rm -rf "$tmp"
      printf 'component_size_mismatch: %s bundle has %s bytes, components.lock pins %s\n' "$name" "$size" "$pin_bytes"
      return 6
    fi
  fi
  # Commit the verified bundle only. The marker goes last, so a fetch interrupted anywhere above
  # leaves no directory a later deploy would read as a cache hit.
  rm -rf "$entry"
  mv "$tmp" "$entry" || { rm -rf "$tmp"; printf 'component_cache_unwritable: %s\n' "$entry"; return 8; }
  printf '%s %s\n' "$name" "$actual" > "$entry/.complete" || { printf 'component_cache_unwritable: %s\n' "$entry"; return 8; }
  printf '%s\n' "$entry"
  return 0
}

# <repo> <name> <install_dir>
#
# Which directory holds the pinned bytes for <name>, asking the cheapest source first:
#   1. the component directory the core reads (an already-installed, matching component);
#   2. this node's cache entry for the lock (a previous deploy's download);
#   3. the release (gh, else curl), cached.
# Prints the directory on success (0) and the reason on 8 (nothing local and nothing downloadable - the
# caller may build the tree instead) or on a refusal (5/6: the bytes that claim to be pinned are not).
wa_component_source_resolve() {
  local repo="$1" name="$2" install="${3:-}" pin pin_sha lock_sha cache_root dir
  if ! pin="$(wa_component_pin "$repo" "$name")"; then
    case $? in
      2) printf 'component_pin_missing: no %s/components.lock\n' "$repo" ;;
      *) printf 'component_pin_missing: %s is not pinned in components.lock\n' "$name" ;;
    esac
    return 2
  fi
  pin_sha="${pin%% *}"
  dir="$(wa_components_dir)"
  if [ -f "$dir/$name.wasm" ] && [ -f "$dir/$name.json" ] \
    && [ "$(wa_component_sha256 "$dir/$name.wasm" 2>/dev/null)" = "$pin_sha" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  lock_sha="$(wa_component_lock_sha "$repo")" || { printf 'component_pin_unreadable: no %s/components.lock\n' "$repo"; return 7; }
  cache_root="$(wa_component_cache_root "$install")"
  dir="$cache_root/$lock_sha"
  if [ -f "$dir/.complete" ] && [ -f "$dir/$name.json" ] && [ -f "$dir/$name.wasm" ] \
    && [ "$(wa_component_sha256 "$dir/$name.wasm" 2>/dev/null)" = "$pin_sha" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  wa_component_download "$repo" "$name" "$cache_root"
}

# <repo> <stage> <install_dir> <name>...
#
# The component step of a deploy: resolve where the pinned bytes are (see
# wa_component_source_resolve), then stage and verify them into <stage> with wa_component_stage. One
# `component_source:` line per component on stdout. Returns 0, or the refusal of the first component
# that cannot be staged (with its reason already printed). Installs nothing: staging is a filesystem
# copy under the install directory, the swap is wa_component_install.
wa_components_prepare() {
  local repo="$1" stage="$2" install="$3" name out rc source
  shift 3
  for name in "$@"; do
    if [ -n "${WA_DEPLOY_COMPONENT_SOURCE:-}" ]; then
      out="$(wa_component_stage "$repo" "$name" "$stage" 2>&1)"; rc=$?
      [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return "$rc"; }
      [ -z "$out" ] || printf '%s\n' "$out"
      printf 'component_source: %s %s (WA_DEPLOY_COMPONENT_SOURCE)\n' "$name" "$WA_DEPLOY_COMPONENT_SOURCE"
      continue
    fi
    source="$(wa_component_source_resolve "$repo" "$name" "$install")"; rc=$?
    case "$rc" in
      0)
        out="$(WA_DEPLOY_COMPONENT_SOURCE="$source" wa_component_stage "$repo" "$name" "$stage" 2>&1)"; rc=$?
        [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return "$rc"; }
        [ -z "$out" ] || printf '%s\n' "$out"
        printf 'component_source: %s %s (pinned bytes)\n' "$name" "$source" ;;
      8)
        printf 'component_source: %s this tree (no pinned bytes available: %s)\n' "$name" "$source"
        out="$(wa_component_stage "$repo" "$name" "$stage" 2>&1)"; rc=$?
        [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return "$rc"; }
        [ -z "$out" ] || printf '%s\n' "$out" ;;
      *)
        printf '%s\n' "$source"; return "$rc" ;;
    esac
  done
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

# ---------------------------------------------------------------------------------------------------
# The shipped set: every name components.lock pins, installed and rolled back as one set
# ---------------------------------------------------------------------------------------------------

# <repo> - the names components.lock pins, one per line, in the lock's own order.
#
# This is what a deploy installs. Before 08/11 the deploy named `graph` on its own command lines and
# the other eight production components were built, tested and never installed, so their
# `WA_*_COMPONENT` flags had nothing to turn on (docs/FEATURES.md). A name is shipped by being pinned in
# components.lock; nothing else in the tree decides it, and a lock that pins nothing installs nothing
# (the deploy refuses that rather than reporting a successful install of nothing).
wa_components_shipped() {
  local lock="$1/components.lock"
  [ -f "$lock" ] || return 2
  awk '/^[[:space:]]*(#|$)/ {next} $1 != "" && $2 ~ /^[0-9a-f]+$/ {print $1}' "$lock"
}

# <component_dir> <name>... - record the set that is installed NOW, before it is replaced, in
# `<dir>/.prev/components.set` (`<name> <sha256|absent>` per line, sorted as given).
#
# The rollback already restores each component from its own `.prev/` triple; this record is what makes
# the *set* answerable: which components were installed before this deploy, and which the deploy added
# (they are `absent` here, so the rollback removes them instead of leaving a component this node never
# had). It is written last-to-temporary then renamed, so a reader never sees half a set.
wa_components_record_set() {
  local dest="$1" name sha tmp
  shift
  mkdir -p "$dest/.prev" || { echo "component_dir_unwritable: $dest" >&2; return 3; }
  tmp="$dest/.prev/.components.set.tmp"
  : > "$tmp" || { echo "component_dir_unwritable: $dest" >&2; return 3; }
  for name in "$@"; do
    if [ -f "$dest/$name.wasm" ]; then
      sha="$(wa_component_sha256 "$dest/$name.wasm" 2>/dev/null)"
      printf '%s %s\n' "$name" "${sha:-unreadable}" >> "$tmp" || return 3
    else
      printf '%s absent\n' "$name" >> "$tmp" || return 3
    fi
  done
  mv -f "$tmp" "$dest/.prev/components.set" || { echo "component_dir_unwritable: $dest" >&2; return 3; }
  return 0
}

# <stage_dir> <component_dir> <name>... - install every staged triple, in the lock's order.
#
# One output line per component (`component_installed: …`) and the first refusal returned as-is: a
# deploy that installs seven of nine and reports success is the failure this refuses.
wa_components_install_set() {
  local stage="$1" dest="$2" name out rc installed=""
  shift 2
  for name in "$@"; do
    out="$(wa_component_install "$stage" "$dest" "$name" 2>&1)"; rc=$?
    [ -z "$out" ] || printf '%s\n' "$out"
    installed="$installed $name"
    if [ "$rc" -ne 0 ]; then
      # Nothing half-installed: the components this set already replaced go back to what they were, and
      # the one that failed (whose bytes may already have landed) goes back too, before the refusal is
      # returned. The caller's own rollback is then a no-op, never a second repair.
      wa_components_restore_set "$dest" $installed >/dev/null 2>&1 || true
      return "$rc"
    fi
  done
  # What landed is what was verified, for the set as well as each component: a set whose sha lines do
  # not match the files it just installed is not an install.
  for name in "$@"; do
    [ "$(wa_component_sha256 "$dest/$name.wasm" 2>/dev/null)" = "$(cat "$dest/$name.wasm.sha256" 2>/dev/null)" ] \
      || { echo "component_hash_mismatch: $dest/$name.wasm does not match its pin after install" >&2; return 5; }
  done
  return 0
}

# <component_dir> <name>... - put the whole previous set back, in reverse order, and report each.
wa_components_restore_set() {
  local dest="$1" name rc=0 out
  shift
  for name in $(printf '%s\n' "$@" | awk '{lines[NR]=$0} END {for (i=NR;i>0;i--) print lines[i]}'); do
    out="$(wa_component_restore "$dest" "$name" 2>&1)" || rc=3
    [ -z "$out" ] || printf '%s\n' "$out"
  done
  return "$rc"
}
