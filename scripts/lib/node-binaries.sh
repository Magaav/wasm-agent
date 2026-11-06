#!/usr/bin/env bash
# Prebuilt node binaries: built once on the machine that has the toolchain, installed everywhere
# (docs/COMPONENTS.md, "The node binary itself").
#
# WHY. A node deploy ends in a `cargo build` of `wa` and `wa-sentinel`. That is fine on a machine with
# 16 threads and a warm cargo cache and it is not fine on openclaw (Ubuntu arm64, 2 cores, disk 99%
# full): the wasmtime 50 upgrade it needs is a full rebuild of ~600 crates, which that box can neither
# fit nor afford. The components already solved this problem for wasm (one portable artifact, pinned in
# `components.lock`, fetched from a release by the node that needs it); a binary is not portable, so the
# pin has to be per target triple, and that is the only difference:
#
#   release tag     node-<first 12 hex of the source commit>
#   pins            node-<sha12>.manifest - one row per target triple, the release's own identity, plus
#                   `compiled_inputs=<sha256>`: the digest of the paths a binary is compiled from
#   payload         wa-<triple>-<sha12>, wa-sentinel-<triple>-<sha12>
#
# A node asks first for the release its own commit names (never "the latest": a deploy installs the commit
# it holds, and a binary from another commit is not that commit's build), verifies the manifest's
# source_commit against its own 40-hex HEAD, then verifies sha256 AND size of both binaries against the
# manifest before anything is cached or staged. A refusal is never a fallback - `node_hash_mismatch`
# means the bytes that claim to be this commit's are not - and only "nothing is published for this
# commit and target" (node_release_unavailable) lets a deploy build the tree instead.
#
# THE ONE EXCEPTION, and it is not "the latest": a commit that changes no compiled input does not need a
# binary of its own, so when no release names this commit the node looks for the NEWEST published release
# whose `compiled_inputs=` digest equals the digest of its own commit (wa_compiled_inputs_digest /
# wa_node_release_digest_search). A docs-only or Lua-only commit is then installed from an older commit's
# verified bytes instead of being compiled - the case this exists for is a node that cannot compile at all
# (openclaw). The digest is the same classification `deploy.sh`'s Lua fast path already uses (see
# wa_compiled_input for the one definition), and the bytes are still verified against the manifest they
# came with, so a mismatched release refuses exactly as before.
#
# What this lib deliberately does NOT do: decide whether building is affordable (that is deploy.sh, with
# scripts/check-disk-floor.sh, because only the deploy knows the tree and the install), and publish
# (scripts/publish-node-binaries.sh prints the `gh` command for a human; nothing here ever runs gh).
#
# Sourced by scripts/deploy.sh and by scripts/publish-node-binaries.sh; exercised by
# scripts/test-node-binaries.sh (the publish half) and scripts/test-deploy-node-binaries.sh (this half).

# <file> -> sha256 on stdout; 7 when no sha tool exists. Same expression as the component lib, on
# purpose: a deploy that can verify one pin can verify the other.
wa_node_sha256() {
  wa_node_sha256_stdin < "$1"
}

# stdin -> sha256 of those bytes on stdout; 7 when no sha tool exists. The compiled-inputs digest is a
# hash of a *stream* (a sorted list, not a file on disk), and it must be the same hash on every host.
wa_node_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 7
  fi
}

# ---- compiled inputs: which paths a binary is built from (job relmatch) ---------------------------
#
# WHY THIS IS ONE FUNCTION. `deploy.sh`'s Lua fast path already answers "does this change need a new
# binary?" by classifying every changed path, and a published release now answers the same question from
# the other end: the manifest carries a digest of the COMPILED INPUTS of the commit it was built from, and
# a deploy accepts that release for any commit whose compiled inputs hash to the same digest. Two
# spellings of "compiled input" would let the fast path and the digest disagree about the same file, and
# the disagreement would be invisible until a node installed a binary that is not its commit's build. So
# the classification lives here, and both halves call it.
#
# <path> -> 0 when a change to this path changes the compiled binary (rust/, wit/, Cargo files, code-mode
# build inputs, config, the lock files ...), 1 when it does not (the Lua tree the binary loads from disk
# and pins by capability digest, docs, tests, UI, modules, skills, jobs, reviews, fixtures, the vault, and
# every script except the ones that build the binary). A top-level `<name>.md` is documentation; any other
# top-level file (Cargo.lock, components.lock, .gitignore) is an input.
wa_compiled_input() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  case "$path" in
    lua/*|docs/*|tests/*|ui/*|modules/*|skills/*|jobs/*|benchmarks/*|review/*|reviews/*|review-evidence/*|fixtures/*|vault/*|scripts/*)
      # Not compiled - except the scripts that ARE build inputs: the code-mode bundle and its provisioning
      # decide what a release binary embeds (publish-node-binaries.sh sets WA_CODEMODE_BUILD_ASSETS).
      case "$path" in
        scripts/codemode*|scripts/build-*|scripts/provision-codemode*) return 0 ;;
      esac
      return 1 ;;
  esac
  case "$path" in
    */*) return 0 ;;
    *.md) return 1 ;;
    *) return 0 ;;
  esac
}

# The digest's own identity, hashed as the first line: a future change to wa_compiled_input (a path
# reclassified) MUST invalidate every old manifest's digest rather than silently re-match, and bumping this
# string is how it does that.
WA_COMPILED_INPUTS_SCHEMA='wasm-agent-compiled-inputs/1'

# <repo> <commit> -> sha256 over the sorted `<path> <blob sha>` lines of every compiled-input path in that
# commit's tree, on stdout. 2 when the commit is not in this tree, 7 when no sha tool exists.
#
# Sorted and path-first on purpose: two commits with the same compiled inputs produce the same bytes here
# whatever order git lists them in, and the digest covers a tree (not a diff), so it does not matter which
# commit a deploy starts from.
wa_compiled_inputs_digest() {
  local repo="$1" commit="${2:-}" meta path sha
  git -C "$repo" rev-parse --verify -q "$commit^{commit}" >/dev/null 2>&1 || {
    printf 'compiled_inputs_commit_unknown: %s is not a commit in %s\n' "${commit:-?}" "$repo" >&2
    return 2
  }
  {
    printf '%s\n' "$WA_COMPILED_INPUTS_SCHEMA"
    # IFS is set ONCE for the loop, not per iteration: `while IFS=$(printf '\t') read` forks a command
    # substitution on every line, which over this tree's ~2,500 paths took 24s here and hung outright under
    # fork pressure (measured on wasm_the_first, 06/11). Everything in the loop body is a builtin.
    git -C "$repo" ls-tree -r --full-tree "$commit" 2>/dev/null \
      | { IFS=$'\t'; while read -r meta path; do
            [ -n "$path" ] || continue
            wa_compiled_input "$path" || continue
            sha="${meta##* }"
            printf '%s %s\n' "$path" "$sha"
          done; } \
      | LC_ALL=C sort
  } | wa_node_sha256_stdin
}

# [uname -s] [uname -m] -> the target triple a release publishes for this machine, or non-zero when this
# machine is not one of the published targets (Windows: the deploy builds, exactly as before).
# WA_NODE_TARGET overrides the detection (a cross-built node, or a test naming a triple); WA_NODE_UNAME_S /
# WA_NODE_UNAME_M stand in for the two probes, the way WA_BOOTSTRAP_LIBC does in scripts/linux/bootstrap.sh,
# so a test can ask "what would a Windows node do" without a Windows node.
wa_node_target_triple() {
  local sys="${1:-${WA_NODE_UNAME_S:-$(uname -s 2>/dev/null)}}" mach="${2:-${WA_NODE_UNAME_M:-$(uname -m 2>/dev/null)}}" arch libc
  if [ -n "${WA_NODE_TARGET:-}" ]; then
    printf '%s\n' "$WA_NODE_TARGET"
    return 0
  fi
  case "$sys" in
    Linux) ;;
    *) return 1 ;;
  esac
  case "$mach" in
    aarch64|arm64) arch=aarch64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *) return 1 ;;
  esac
  # Which C library decides which row of the manifest this node reads. A musl node cannot run a
  # glibc-linked binary, so the two are different releases, not a preference.
  if ls /lib/ld-musl-* >/dev/null 2>&1 || (ldd --version 2>&1 | grep -qi musl); then
    libc=musl
  elif getconf GNU_LIBC_VERSION >/dev/null 2>&1 || ldd --version 2>&1 | grep -qi 'glibc\|GNU C Library'; then
    libc=gnu
  else
    libc=gnu
  fi
  printf '%s-unknown-linux-%s\n' "$arch" "$libc"
}

# <40-hex commit> -> `node-<first 12>`; 2 when it is not a full commit id. The full id is what the
# manifest is checked against, so a tag that collides on 12 hex cannot install another commit's bytes.
wa_node_release_tag() {
  case "${1:-}" in
    *[!0-9a-f]*) return 2 ;;
    ????????????????????????????????????????) printf 'node-%s\n' "${1:0:12}" ;;
    *) return 2 ;;
  esac
}

# <40-hex commit | 12-hex short> -> the short sha the asset names carry. Both spellings are accepted
# because a tag (`node-<sha12>`) and a commit are the same identity seen from two callers.
wa_node_short_sha() {
  local value="${1:-}"
  case "$value" in *[!0-9a-f]*) return 2 ;; esac
  case "${#value}" in
    12) printf '%s\n' "$value" ;;
    40) printf '%s\n' "${value:0:12}" ;;
    *) return 2 ;;
  esac
}

# <repo> -> owner/repo the node-binary release lives in. WA_NODE_RELEASE_REPO wins (fork, mirror), else
# origin's own GitHub slug, else the source of truth every tree in this fleet is a worktree of. A node's
# origin is often a local path, and it is exactly those nodes that need the release.
wa_node_release_repo() {
  local repo="$1" url
  if [ -n "${WA_NODE_RELEASE_REPO:-}" ]; then
    printf '%s\n' "$WA_NODE_RELEASE_REPO"
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

# <manifest> <key> -> the value of a KEY=VALUE line (empty when absent). The header is KEY=VALUE; the
# target rows are not, which is how the two are told apart without a second file.
wa_node_manifest_value() {
  [ -f "$1" ] || return 2
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# <manifest> <triple> -> "<sha256> <bytes> <sentinel sha256> <sentinel bytes>"; 2 no manifest, 3 unpinned.
# A row is a line whose first field is not KEY=VALUE and which has the five fields a pin needs.
wa_node_manifest_pin() {
  local manifest="$1" triple="$2" line
  [ -f "$manifest" ] || return 2
  line="$(awk -v want="$triple" '
    /^[[:space:]]*(#|$)/ {next}
    index($1, "=") {next}
    $1 == want && $2 ~ /^[0-9a-f]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9a-f]+$/ && $5 ~ /^[0-9]+$/ {print $2, $3, $4, $5; found = 1; exit}
    END {exit !found}
  ' "$manifest")" || return 3
  [ -n "$line" ] || return 3
  printf '%s\n' "$line"
}

# <file> -> "elf:<hex machine>" / "pe" / "unknown". Two bytes of header are enough to refuse a binary the
# node cannot execute (an x86_64 `wa` installed on arm64 fails at exec time, after the swap).
wa_node_binary_shape() {
  local file="$1" magic machine
  [ -f "$file" ] || { printf 'missing\n'; return 2; }
  magic="$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    7f454c46) machine="$(od -An -tx1 -j18 -N1 "$file" 2>/dev/null | tr -d ' \n')"; printf 'elf:%s\n' "${machine:-??}" ;;
    4d5a*) printf 'pe\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# <triple> -> the ELF machine byte a binary of that triple must carry (EM_AARCH64 b7, EM_X86_64 3e),
# empty for a triple this lib does not check. The publish script and the deploy both read it from here,
# so the check cannot drift between the two halves.
wa_node_triple_machine() {
  case "${1:-}" in
    aarch64-unknown-linux-*) printf 'b7\n' ;;
    x86_64-unknown-linux-*) printf '3e\n' ;;
    *) printf '' ;;
  esac
}

# <tag> -> the base wa_node_fetch_asset should read that tag's assets from. The ordinary channel builds the
# tag into its own URL (`https://github.com/<repo>/releases/download/<tag>/<asset>`, or `gh release
# download <tag>`), so the base is passed through untouched. A local stub directory - what the tests and a
# hand-copied release use - may hold ONE SUBDIRECTORY PER TAG (`<dir>/node-<sha12>/`), which is how several
# releases are stood up without a network; when that subdirectory exists it is the base for that tag.
wa_node_tag_base() {
  local tag="$1" base="${WA_NODE_BINARIES_URL:-}"
  case "$base" in file://*) base="${base#file://}" ;; esac
  if [ -n "$base" ] && [ -d "$base/$tag" ]; then printf '%s\n' "$base/$tag"; return 0; fi
  printf '%s\n' "${WA_NODE_BINARIES_URL:-}"
}

# <repo> <limit> -> the newest `node-<sha12>` release tags, one per line, newest first, at most <limit>.
#
# WHERE THE LIST COMES FROM, in this order, so a test never touches the network and a node with no token
# still gets an answer:
#   1. WA_NODE_BINARIES_URL=<dir> with a `releases.txt` in it (one tag per line, newest first) - the stub a
#      test uses to stand up several releases without GitHub;
#   2. WA_NODE_BINARIES_URL=<dir> holding `node-<sha12>` subdirectories - newest by modification time;
#   3. `gh api` on the repository's releases (what the coordinator's gh token can see);
#   4. the public API, `https://api.github.com/repos/<repo>/releases` - anonymous, rate-limited, enough
#      for the handful of releases a digest search looks at.
# Anything that is not `node-<twelve hex>` is not this channel's release and is dropped here, once.
wa_node_release_list() {
  local repo="$1" limit="${2:-20}" base="${WA_NODE_BINARIES_URL:-}" dir tags
  [ -d "$repo" ] && repo="$(wa_node_release_repo "$repo")"
  case "$base" in file://*) base="${base#file://}" ;; esac
  if [ -n "$base" ] && [ -d "$base" ]; then
    if [ -f "$base/releases.txt" ]; then
      sed -n 's/^[[:space:]]*//;s/[[:space:]]*$//p' "$base/releases.txt" \
        | grep -E '^node-[0-9a-f]{12}$' | head -n "$limit"
      return 0
    fi
    for dir in $(ls -1dt "$base"/node-* 2>/dev/null); do
      printf '%s\n' "${dir##*/}"
    done | grep -E '^node-[0-9a-f]{12}$' | head -n "$limit"
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    tags="$(gh api "repos/$repo/releases?per_page=$limit" --jq '.[].tag_name' 2>/dev/null \
      | grep -E '^node-[0-9a-f]{12}$' | head -n "$limit")"
    if [ -n "$tags" ]; then printf '%s\n' "$tags"; return 0; fi
  fi
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsSL -m 60 "https://api.github.com/repos/$repo/releases?per_page=$limit" 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\(node-[0-9a-f]\{12\}\)".*/\1/p' \
    | head -n "$limit"
  return 0
}

# <repo> <commit> <triple> -> the three asset names of one target's row, on stdout, one per line.
# The manifest is the release's identity, so it is fetched first and the binaries are named from it.
wa_node_asset_names() {
  local commit="$1" triple="$2" short
  short="$(wa_node_short_sha "$commit")" || return 2
  printf 'node-%s.manifest\nwa-%s-%s\nwa-sentinel-%s-%s\n' "$short" "$triple" "$short" "$triple" "$short"
}

# <repo> <tag> <asset> <dest> [base]
#
# Fetch one release asset into <dest>. Returns 0, or 8 with the reason printed; 8 is the only code a
# caller may answer by building instead.
#   WA_NODE_BINARIES_URL=<dir>|file://<dir>  read those assets instead of the network (the stub the tests
#                                            use, and the way a hand-copied release is tried)
#   WA_NODE_BINARIES_URL=https://...         the base URL of the assets
#   unset                                    `gh release download`, then the public release URL
wa_node_fetch_asset() {
  local repo="$1" tag="$2" asset="$3" dest="$4" base="${5:-}" local_base url_base
  [ -d "$repo" ] && repo="$(wa_node_release_repo "$repo")"
  mkdir -p "$dest" || { printf 'node_cache_unwritable: %s
' "$dest"; return 8; }
  local_base=""
  url_base=""
  case "$base" in
    file://*) local_base="${base#file://}" ;;
    http://*|https://*) url_base="$base" ;;
    ?*)
      if [ -d "$base" ]; then local_base="$base"
      else
        printf 'node_release_url_unusable: WA_NODE_BINARIES_URL=%s is neither an existing directory nor an http(s) URL
' "$base"
        return 8
      fi ;;
    '') ;;
  esac
  if [ -n "$local_base" ]; then
    [ -f "$local_base/$asset" ] || { printf 'node_release_incomplete: %s
' "$local_base/$asset"; return 8; }
    cp -f "$local_base/$asset" "$dest/$asset" || { printf 'node_cache_unwritable: %s
' "$dest/$asset"; return 8; }
    return 0
  fi
  if [ -n "$url_base" ]; then
    command -v curl >/dev/null 2>&1 || { printf 'node_release_unreachable: no curl for %s
' "$url_base"; return 8; }
    curl -fsSL -m 120 "$url_base/$asset" -o "$dest/$asset" 2>/dev/null       || { printf 'node_release_unreachable: %s/%s
' "$url_base" "$asset"; rm -f "$dest/$asset"; return 8; }
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    if gh release download "$tag" -R "$repo" -D "$dest" -p "$asset" >/dev/null 2>&1 && [ -f "$dest/$asset" ]; then
      return 0
    fi
    # gh without a token on the node, or a release that is not there yet: the anonymous URL may work.
    printf 'node_release_gh_failed: gh could not download %s/%s; trying the public asset URL
' "$tag" "$asset"
    rm -f "$dest/$asset"
  fi
  command -v curl >/dev/null 2>&1 || { printf 'node_release_unreachable: no curl and no gh for %s
' "$tag"; return 8; }
  curl -fsSL -m 120 "https://github.com/$repo/releases/download/$tag/$asset" -o "$dest/$asset" 2>/dev/null     || { printf 'node_release_unreachable: %s/%s
' "$tag" "$asset"; rm -f "$dest/$asset"; return 8; }
  return 0
}

# <dir> <commit> <triple>
#
# Verify a directory that claims to hold this commit's build for this triple: the manifest names this
# exact 40-hex commit and carries a row for the triple, then both binaries match the row's sha256 AND
# size. Prints nothing on 0; the refusal (5 hash, 6 size, 2 not-this-commit/not-pinned, 7 no sha tool) on
# stderr, so a caller can print it and stop.
wa_node_verify_dir() {
  local dir="$1" commit="$2" triple="$3" manifest pin want_sha want_bytes want_ssha want_sbytes got size
  local short
  short="$(wa_node_release_tag "$commit")" || { printf 'node_commit_invalid: %s is not a 40-hex commit id\n' "$commit" >&2; return 2; }
  short="${short#node-}"
  manifest="$dir/node-$short.manifest"
  [ -f "$manifest" ] || { printf 'node_manifest_missing: %s\n' "$manifest" >&2; return 2; }
  if [ "$(wa_node_manifest_value "$manifest" source_commit)" != "$commit" ]; then
    printf 'node_manifest_commit_mismatch: %s names source_commit=%s, this tree is %s\n' \
      "$manifest" "$(wa_node_manifest_value "$manifest" source_commit)" "$commit" >&2
    return 2
  fi
  # A cross-built binary that could not embed the code-mode assets starts every run with
  # `codemode_not_ready` (rust/wa-host/build.rs refuses to produce that silently for a host release, and a
  # cross build is exempt there because it is not the BUILD host's artifact - it is the node's). Installing
  # one would replace a working node with a silent one, so the manifest's own codemode= row is the gate.
  if [ "$(wa_node_manifest_value "$manifest" codemode)" = empty ] && [ "${WA_DEPLOY_ALLOW_EMPTY_CODEMODE:-0}" != 1 ]; then
    printf 'node_codemode_empty: %s records codemode=empty - a binary built this way starts every run with codemode_not_ready (WA_DEPLOY_ALLOW_EMPTY_CODEMODE=1 installs it anyway)\n' "$manifest" >&2
    return 2
  fi
  if ! pin="$(wa_node_manifest_pin "$manifest" "$triple")"; then
    printf 'node_target_unpublished: %s is not pinned in %s (published: %s)\n' \
      "$triple" "$manifest" "$(awk '!/=/ && NF >= 5 && $1 !~ /^#/ {printf "%s ", $1}' "$manifest")" >&2
    return 2
  fi
  read -r want_sha want_bytes want_ssha want_sbytes <<< "$pin"
  for pair in "wa-$triple-$short:$want_sha:$want_bytes" "wa-sentinel-$triple-$short:$want_ssha:$want_sbytes"; do
    local file="${pair%%:*}" rest="${pair#*:}"
    local sha="${rest%%:*}" bytes="${rest##*:}"
    [ -f "$dir/$file" ] || { printf 'node_binary_missing: %s\n' "$dir/$file" >&2; return 2; }
    got="$(wa_node_sha256 "$dir/$file")" || { printf 'node_sha256_unavailable: no sha256sum or shasum\n' >&2; return 7; }
    if [ "$got" != "$sha" ]; then
      printf 'node_hash_mismatch: %s is %s, the manifest pins %s\n' "$file" "$got" "$sha" >&2
      return 5
    fi
    size="$(wc -c < "$dir/$file" | tr -d '[:space:]')"
    if [ "$size" != "$bytes" ]; then
      printf 'node_size_mismatch: %s is %s bytes, the manifest pins %s\n' "$file" "$size" "$bytes" >&2
      return 6
    fi
    local machine want_machine
    machine="$(wa_node_binary_shape "$dir/$file")"
    want_machine="$(wa_node_triple_machine "$triple")"
    if [ -n "$want_machine" ] && [ "$machine" != "elf:$want_machine" ]; then
      printf 'node_machine_mismatch: %s is %s, %s needs elf:%s\n' "$file" "$machine" "$triple" "$want_machine" >&2
      return 5
    fi
  done
  return 0
}

# <install> -> where fetched binaries are cached. Under the install directory on purpose: it is the one
# directory a deploy owns and a node's user can clean, and a cache is install state.
wa_node_cache_root() {
  if [ -n "${WA_NODE_BINARIES_CACHE:-}" ]; then
    printf '%s\n' "$WA_NODE_BINARIES_CACHE"
  else
    printf '%s\n' "${1:-.}/node-binaries"
  fi
}

# <cache_root> <commit> <triple> -> the directory a verified download of this commit/triple lives in.
wa_node_cache_entry() {
  local short
  short="$(wa_node_release_tag "$2")" || return 2
  printf '%s/%s/%s\n' "$1" "${short#node-}" "$3"
}

# <repo> <commit> <triple> <cache_root> -> the cached directory (0) after fetching and verifying it.
# 8 when nothing is reachable; 2/5/6/7 are refusals and a caller must stop. The `.complete` marker is
# written last, so a fetch interrupted anywhere above leaves no directory a later deploy reads as a hit.
wa_node_binary_download() {
  local repo="$1" commit="$2" triple="$3" cache_root="$4" tag entry tmp short rc stale out published file
  tag="$(wa_node_release_tag "$commit")" || { printf 'node_commit_invalid: %s\n' "$commit" >&2; return 2; }
  short="${tag#node-}"
  entry="$(wa_node_cache_entry "$cache_root" "$commit" "$triple")"
  tmp="$cache_root/.incoming.$$.$triple"
  for stale in "$cache_root"/.incoming.*; do
    [ -d "$stale" ] || continue
    [ "$stale" = "$tmp" ] && continue
    [ -n "$(find "$stale" -maxdepth 0 -mmin +${WA_NODE_INCOMING_AGE:-1440} 2>/dev/null)" ] && rm -rf "$stale"
  done
  rm -rf "$tmp"
  mkdir -p "$tmp" || { printf 'node_cache_unwritable: %s\n' "$cache_root" >&2; return 8; }
  # The manifest comes first, and it is fetched without the payload: it is the release's identity. A
  # manifest that names this commit but has no row for this triple is NOT a refusal - it says "this
  # release does not publish aarch64", which is exactly the case where building here is the answer. A row
  # that exists and a binary that is not there is a malformed release, and that refuses.
  if ! out="$(wa_node_fetch_asset "$repo" "$tag" "node-$short.manifest" "$tmp" "${WA_NODE_BINARIES_URL:-}" 2>&1)"; then
    rm -rf "$tmp"
    printf 'node_release_unavailable: no prebuilt for %s at %s (%s)\n' "$triple" "$tag" "${out:-WA_NODE_BINARIES_URL=${WA_NODE_BINARIES_URL:-unset}}" >&2
    return 8
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  if ! wa_node_manifest_pin "$tmp/node-$short.manifest" "$triple" >/dev/null; then
    published="$(awk '!/=/ && NF >= 5 && $1 !~ /^#/ {printf "%s ", $1}' "$tmp/node-$short.manifest")"
    rm -rf "$tmp"
    printf 'node_target_unpublished: %s is not in %s (it publishes: %s)\n' "$triple" "$tag" "${published:-nothing}" >&2
    return 8
  fi
  for file in "wa-$triple-$short" "wa-sentinel-$triple-$short"; do
    if ! out="$(wa_node_fetch_asset "$repo" "$tag" "$file" "$tmp" "${WA_NODE_BINARIES_URL:-}" 2>&1)"; then
      rm -rf "$tmp"
      printf 'node_binary_missing: %s pins %s but the release does not carry it (%s)\n' "$tag" "$file" "$out" >&2
      return 2
    fi
    [ -z "$out" ] || printf '%s\n' "$out" >&2
  done
  # The status has to be read from the command, not from the `if !` in front of it: `rc=$?` after a
  # negated test is the test's status, and it read 0 for every refusal - the bug this line was.
  out="$(wa_node_verify_dir "$tmp" "$commit" "$triple" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    rm -rf "$tmp"
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  rm -rf "$entry"
  mkdir -p "$(dirname "$entry")" 2>/dev/null
  mv "$tmp" "$entry" || { rm -rf "$tmp"; printf 'node_cache_unwritable: %s\n' "$entry" >&2; return 8; }
  printf '%s %s %s\n' "$short" "$triple" "$(wa_node_sha256 "$entry/wa-$triple-$short")" > "$entry/.complete" \
    || { printf 'node_cache_unwritable: %s\n' "$entry" >&2; return 8; }
  printf '%s\n' "$entry"
  return 0
}

# <repo> <commit> <triple> <cache_root>
#
# The digest fallback (job relmatch). A commit that changes no compiled input does not need a new binary,
# so a deploy of a docs-only descendant of a published commit must not fall back to compiling (openclaw
# cannot). This searches the newest `node-<sha12>` releases for the first manifest whose
# `compiled_inputs=` equals the digest of <commit> and returns that release's verified directory, cached
# under the RELEASE's source commit - the bytes' own identity, not this tree's.
#
# On 0, stdout is three lines: the directory, then `release_tag=` and `release_commit=` - the two facts a
# deploy must record (`installed.txt`'s binary_release=/binary_source_commit=) and cannot derive from the
# tree it holds. On 8 nothing published matches (the same answer as "nothing is published for this
# commit", so the caller's build-or-refuse rule is unchanged); 2/5/6/7 is a refusal about a release whose
# manifest MATCHED the digest - a broken release - and the caller must stop rather than shop around.
#
# A candidate is skipped, not refused, when it has no manifest, no compiled_inputs row (an artifact from a
# publisher older than this digest), a different digest, or no row for this triple: none of those is a
# statement about this commit. Once the digest matches, everything the manifest says is a statement about
# the bytes this deploy would install.
# <cache_root> <triple> <digest> -> the cached entries whose manifest's `compiled_inputs=` is that digest
# and which pin that triple, newest first (by the entry's own mtime). This is what lets a repeated deploy of
# the same docs-only commit answer from the cache even when the release it came from is gone (an offline
# node, a deleted release): the entry's manifest is that release's identity, and it is re-verified before it
# is used. A directory without `.complete` is an interrupted fetch and is not an entry.
wa_node_cached_digest_entries() {
  local cache_root="$1" triple="$2" want="$3" dir manifest
  for dir in $(ls -1dt "$cache_root"/*/"$triple" 2>/dev/null); do
    [ -f "$dir/.complete" ] || continue
    manifest="$(ls -1 "$dir"/node-*.manifest 2>/dev/null | head -1)"
    [ -n "$manifest" ] || continue
    [ "$(wa_node_manifest_value "$manifest" compiled_inputs)" = "$want" ] || continue
    wa_node_manifest_pin "$manifest" "$triple" >/dev/null 2>&1 || continue
    printf '%s\n' "$dir"
  done
}

wa_node_release_digest_search() {
  local repo="$1" commit="$2" triple="$3" cache_root="$4"
  local want tag short tmp entry source digest pin out rc seen file published
  want="$(wa_compiled_inputs_digest "$repo" "$commit" 2>/dev/null)" || {
    printf 'node_compiled_inputs_unavailable: %s has no readable compiled-input digest, so no published release can be matched to it\n' "${commit:-?}" >&2
    return 8
  }
  [ -n "$want" ] || { printf 'node_compiled_inputs_unavailable: no sha256 tool for the compiled-input digest\n' >&2; return 8; }
  seen=0
  for tag in $(wa_node_release_list "$repo" "${WA_NODE_RELEASE_SEARCH:-20}"); do
    seen=$((seen + 1))
    short="${tag#node-}"
    entry="$cache_root/$short/$triple"
    # A previous deploy of this release cached its bytes: the manifest inside the entry is that release's
    # identity, so it answers "does this match" without touching the network, and the entry is re-verified
    # (the cache is a directory on disk like any other, not a promise).
    if [ -f "$entry/.complete" ] && [ -f "$entry/node-$short.manifest" ]; then
      source="$(wa_node_manifest_value "$entry/node-$short.manifest" source_commit)"
      digest="$(wa_node_manifest_value "$entry/node-$short.manifest" compiled_inputs)"
      if [ "$digest" = "$want" ] && wa_node_manifest_pin "$entry/node-$short.manifest" "$triple" >/dev/null 2>&1; then
        out="$(wa_node_verify_dir "$entry" "$source" "$triple" 2>&1)"; rc=$?
        if [ "$rc" != 0 ]; then printf '%s\n' "$out" >&2; return "$rc"; fi
        printf '%s\nrelease_tag=%s\nrelease_commit=%s\n' "$entry" "$tag" "$source"
        return 0
      fi
    fi
    tmp="$cache_root/.candidate.$$.$triple"
    rm -rf "$tmp"
    mkdir -p "$tmp" || { printf 'node_cache_unwritable: %s\n' "$cache_root" >&2; return 8; }
    if ! out="$(wa_node_fetch_asset "$repo" "$tag" "node-$short.manifest" "$tmp" "$(wa_node_tag_base "$tag")" 2>&1)"; then
      rm -rf "$tmp"
      continue
    fi
    source="$(wa_node_manifest_value "$tmp/node-$short.manifest" source_commit)"
    digest="$(wa_node_manifest_value "$tmp/node-$short.manifest" compiled_inputs)"
    if [ -z "$digest" ] || [ "$digest" != "$want" ]; then rm -rf "$tmp"; continue; fi
    # The digest matches: from here on the manifest's claims are about the bytes this deploy would install.
    case "$source" in
      ''|*[!0-9a-f]*) source="" ;; esac
    if [ "${#source}" != 40 ]; then
      rm -rf "$tmp"
      printf 'node_manifest_commit_mismatch: %s names source_commit=%s, which is not a 40-hex commit id\n' \
        "$tag" "$(wa_node_manifest_value "$tmp/node-$short.manifest" source_commit)" >&2
      return 2
    fi
    if [ "${source:0:12}" != "$short" ]; then
      rm -rf "$tmp"
      printf 'node_manifest_commit_mismatch: %s names source_commit=%s, whose sha12 is not the tag\n' "$tag" "$source" >&2
      return 2
    fi
    if ! pin="$(wa_node_manifest_pin "$tmp/node-$short.manifest" "$triple")"; then
      published="$(awk '!/=/ && NF >= 5 && $1 !~ /^#/ {printf "%s ", $1}' "$tmp/node-$short.manifest")"
      rm -rf "$tmp"
      printf 'node_target_unpublished: %s is not in %s (it publishes: %s)\n' "$triple" "$tag" "${published:-nothing}" >&2
      return 8
    fi
    for file in "wa-$triple-$short" "wa-sentinel-$triple-$short"; do
      if ! out="$(wa_node_fetch_asset "$repo" "$tag" "$file" "$tmp" "$(wa_node_tag_base "$tag")" 2>&1)"; then
        rm -rf "$tmp"
        printf 'node_binary_missing: %s pins %s but the release does not carry it (%s)\n' "$tag" "$file" "$out" >&2
        return 2
      fi
    done
    out="$(wa_node_verify_dir "$tmp" "$source" "$triple" 2>&1)"; rc=$?
    if [ "$rc" != 0 ]; then rm -rf "$tmp"; printf '%s\n' "$out" >&2; return "$rc"; fi
    rm -rf "$entry"
    mkdir -p "$(dirname "$entry")" 2>/dev/null
    mv "$tmp" "$entry" || { rm -rf "$tmp"; printf 'node_cache_unwritable: %s\n' "$entry" >&2; return 8; }
    printf '%s %s %s\n' "$short" "$triple" "$(wa_node_sha256 "$entry/wa-$triple-$short")" > "$entry/.complete" \
      || { printf 'node_cache_unwritable: %s\n' "$entry" >&2; return 8; }
    printf '%s\nrelease_tag=%s\nrelease_commit=%s\n' "$entry" "$tag" "$source"
    return 0
  done
  # Nothing listed matched - but an earlier deploy of this same commit may already have cached the answer,
  # and a node that cannot reach the release (or a release that was deleted) must still be able to use it.
  for entry in $(wa_node_cached_digest_entries "$cache_root" "$triple" "$want"); do
    short="$(basename "$(dirname "$entry")")"
    source="$(wa_node_manifest_value "$entry/node-$short.manifest" source_commit)"
    out="$(wa_node_verify_dir "$entry" "$source" "$triple" 2>&1)"; rc=$?
    if [ "$rc" != 0 ]; then printf '%s\n' "$out" >&2; return "$rc"; fi
    printf '%s\nrelease_tag=%s\nrelease_commit=%s\n' "$entry" "node-$short" "$source"
    return 0
  done
  printf 'node_release_unavailable: none of the newest %s published releases was built from the compiled inputs of %s (compiled_inputs=%s) for %s\n' \
    "$seen" "${commit:0:12}" "$want" "$triple" >&2
  return 8
}

# <root> -> 0 when this machine can pay for a build, 1 (with the floor's own numbers on stdout) when it
# cannot. The fallback question is not "is there a prebuilt" but "is there a prebuilt OR a disk": a node
# below the floor that also has no prebuilt must refuse by name instead of dying in a compiler.
wa_node_disk_floor_ok() {
  local root="$1" floor="$1/scripts/check-disk-floor.sh" out rc
  if [ ! -f "$floor" ]; then
    printf 'node_disk_floor_missing: no %s, so a build after a missing prebuilt cannot be costed\n' "$floor"
    return 1
  fi
  if [ -n "${WA_NODE_DISK_FLOOR_BYTES:-}" ]; then
    out="$(bash "$floor" --path "$root" --floor-bytes "$WA_NODE_DISK_FLOOR_BYTES" 2>&1)"; rc=$?
  else
    out="$(bash "$floor" --path "$root" 2>&1)"; rc=$?
  fi
  [ "$rc" = 0 ] && return 0
  printf '%s\n' "$out" | tail -3
  return 1
}

# <repo> <commit> <triple> <install> -> the directory holding this commit's verified binaries.
#   1. WA_DEPLOY_BINARY_SOURCE=<dir>, when set: what an operator or another machine put there by hand;
#      verified against node-<sha12>.manifest when that file is present (its absence is recorded, not
#      trusted - the deploy's own digest and prove gate still run);
#   2. this node's cache entry for the commit and triple (a previous deploy's download);
#   3. the release (gh, else curl), cached - the EXACT commit's release first, always;
#   4. when 3 answers "nothing usable is published for this commit and this target", the newest release
#      whose `compiled_inputs=` digest matches this commit's (wa_node_release_digest_search): a docs-only
#      or Lua-only descendant of a published commit needs no binary of its own.
# Prints the directory on 0, and - only when the bytes are an older release's build - the two extra lines
# `release_tag=` and `release_commit=`; on 8 prints the reason and the caller may build this tree instead;
# a refusal (2/5/6/7) is printed too and must stop the deploy.
wa_node_binary_source_resolve() {
  local repo="$1" commit="$2" triple="$3" install="${4:-}" dir cache_root short out rc
  short="$(wa_node_release_tag "$commit")" || { printf 'node_commit_invalid: %s is not a 40-hex commit id\n' "$commit"; return 2; }
  short="${short#node-}"
  if [ -n "${WA_DEPLOY_BINARY_SOURCE:-}" ]; then
    dir="$WA_DEPLOY_BINARY_SOURCE"
    case "$dir" in
      /*) ;;
      [A-Za-z]:[\\/]*) ;;
      *) dir="$(cd "$repo" 2>/dev/null && cd "$dir" 2>/dev/null && pwd || printf '%s' "$dir")" ;;
    esac
    if [ ! -f "$dir/wa-$triple-$short" ] && [ ! -f "$dir/wa" ]; then
      printf 'node_binary_missing: %s holds neither wa-%s-%s nor wa\n' "$dir" "$triple" "$short"
      return 2
    fi
    printf '%s\n' "$dir"
    return 0
  fi
  cache_root="$(wa_node_cache_root "$install")"
  dir="$(wa_node_cache_entry "$cache_root" "$commit" "$triple")"
  if [ -f "$dir/.complete" ] && [ -f "$dir/wa-$triple-$short" ]; then
    local got
    got="$(wa_node_sha256 "$dir/wa-$triple-$short" 2>/dev/null)"
    if [ -n "$got" ] && [ "$got" = "$(awk '{print $3}' "$dir/.complete" 2>/dev/null)" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  fi
  wa_node_binary_download "$repo" "$commit" "$triple" "$cache_root"; rc=$?
  [ "$rc" = 8 ] || return "$rc"
  # rc 8 is the one answer a caller may build after - "nothing usable is published for this commit and
  # this target" - and it is exactly where the digest fallback belongs: before the deploy pays for a
  # compiler it must ask whether the commit needs one at all.
  out="$(wa_node_release_digest_search "$repo" "$commit" "$triple" "$cache_root" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# <repo> <commit> <triple> <install>
#
# The dry run: say where the binary WOULD come from without fetching, caching or staging anything. This
# is what a test and an operator read to see the decision before a deploy pays for it.
wa_node_binary_plan() {
  local repo="$1" commit="$2" triple="$3" install="${4:-}" short dir
  short="$(wa_node_release_tag "$commit")" || { printf 'node_commit_invalid: %s\n' "$commit"; return 2; }
  if [ -n "${WA_DEPLOY_BINARY_SOURCE:-}" ]; then
    printf 'binary_source: override %s (WA_DEPLOY_BINARY_SOURCE)\n' "$WA_DEPLOY_BINARY_SOURCE"
    return 0
  fi
  dir="$(wa_node_cache_entry "$(wa_node_cache_root "$install")" "$commit" "$triple")"
  if [ -f "$dir/.complete" ]; then
    printf 'binary_source: cache %s\n' "$dir"
    return 0
  fi
  printf 'binary_source: release %s (%s, %s); would cache in %s and fall back to a build of this tree only if nothing is published\n' \
    "$short" "$triple" "$(wa_node_release_repo "$repo")" "$dir"
  printf 'binary_fallback: the newest published release whose compiled_inputs digest matches this commit, before any build\n'
}

# <dir> <commit> <triple> -> the SENTINEL file a verified directory holds, on stdout:
# `wa-sentinel-<triple>-<sha12>` when the release named it the way the manifest does, else a plain
# `wa-sentinel` (the second shape is what WA_DEPLOY_BINARY_SOURCE allows). 2 when neither is there.
#
# The deploy's install step takes the supervisor from here and not from the staging directory, because a
# prebuilt deploy deletes its staging directory as soon as the node's bytes have been copied to their
# hash-named candidate - and a step that reads a path the same run has removed refuses an install that
# is otherwise complete (openclaw, 06/11: the node went in, then `could not install wa-sentinel`).
wa_node_sentinel_file() {
  local dir="$1" commit="$2" triple="$3" short named
  short="$(wa_node_release_tag "$commit")" || { printf 'node_commit_invalid: %s is not a 40-hex commit id\n' "${commit:-}" >&2; return 2; }
  short="${short#node-}"
  named="$dir/wa-sentinel-$triple-$short"
  if [ -f "$named" ]; then printf '%s\n' "$named"; return 0; fi
  if [ -f "$dir/wa-sentinel" ]; then printf '%s\n' "$dir/wa-sentinel"; return 0; fi
  printf 'node_binary_missing: %s holds neither wa-sentinel-%s-%s nor wa-sentinel\n' "$dir" "$triple" "$short" >&2
  return 2
}

# <dir> <commit> <triple> -> the sha256 the directory's manifest pins for that triple's sentinel, on
# stdout. 3 when there is no manifest or no row for the triple: an operator's directory, or a hand-copied
# one, is *unpinned*, and that is a fact the caller has to say out loud rather than read as a pass. 2 when
# the commit is not a 40-hex id.
wa_node_sentinel_pin() {
  local dir="$1" commit="$2" triple="$3" pin short
  short="$(wa_node_short_sha "$commit")" \
    || { printf 'node_commit_invalid: %s is not a 40-hex (or 12-hex) commit id\n' "${commit:-}" >&2; return 2; }
  pin="$(wa_node_manifest_pin "$dir/node-$short.manifest" "$triple")" || return 3
  printf '%s\n' "$pin" | awk '{print $3}'
}

# <stage> <source dir> <commit> <triple>
#
# Copy the verified binaries into <stage> under the names the deploy installs (`wa`, `wa-sentinel`) and
# keep the manifest beside them, so the install record can name what was installed and from where.
wa_node_binary_stage() {
  local stage="$1" dir="$2" commit="$3" triple="$4" short file src
  short="$(wa_node_release_tag "$commit")" || return 2
  short="${short#node-}"
  mkdir -p "$stage" || { printf 'node_stage_unwritable: %s\n' "$stage" >&2; return 8; }
  for file in wa wa-sentinel; do
    src="$dir/$file-$triple-$short"
    [ -f "$src" ] || src="$dir/$file"          # WA_DEPLOY_BINARY_SOURCE may name plain `wa`/`wa-sentinel`
    [ -f "$src" ] || { printf 'node_binary_missing: %s\n' "$src" >&2; return 2; }
    cp -f "$src" "$stage/$file" || { printf 'node_stage_unwritable: %s\n' "$stage/$file" >&2; return 8; }
    chmod +x "$stage/$file" 2>/dev/null || true
  done
  if [ -f "$dir/node-$short.manifest" ]; then
    cp -f "$dir/node-$short.manifest" "$stage/node-binaries.manifest" || return 8
  fi
  return 0
}

# <repo> <commit> <stage> <install>   -- the deploy's one call.
#
# Resolve (fetch + verify), then stage `wa` and `wa-sentinel` into <stage>. On 0, two lines on stdout: the
# machine-readable `binary_verified: <triple> <dir> <sha12>` (so the deploy can name the verified directory
# to its sentinel step without parsing prose) and the `binary_source:` line for the operator's log - plus,
# when the bytes are an older release's build of the same compiled inputs, `binary_release: <tag> <40-hex
# source commit>` so the deploy can record both facts. On 8, the same source line naming the reason
# (nothing published for this commit/triple, or this host has no published target at all - a Windows
# deploy builds, as it always did); on 2/5/6/7 the refusal itself.
wa_node_binaries_prepare() {
  local repo="$1" commit="$2" stage="$3" install="${4:-}" triple out rc dir line release_tag release_commit stage_commit
  triple="$(wa_node_target_triple)"; rc=$?
  if [ "$rc" != 0 ] || [ -z "$triple" ]; then
    printf 'binary_source: this tree (no prebuilt target for %s/%s; the published targets are Linux aarch64 and x86_64)\n' \
      "$(uname -s 2>/dev/null)" "$(uname -m 2>/dev/null)"
    return 8
  fi
  # Stdout ONLY: the resolver's stdout is its answer (the directory, then the release's identity), while
  # its reasons go to stderr and belong in this deploy's log - not in a value this function parses. Merging
  # the two here made the first refusal line of the exact-commit attempt look like the directory.
  out="$(wa_node_binary_source_resolve "$repo" "$commit" "$triple" "$install")"; rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$out"
    return "$rc"
  fi
  # The resolver prints the directory first, then - only for a digest match - the release's identity. Read
  # line by line rather than by field, because the directory is prose-free but may contain spaces.
  dir=""; release_tag=""; release_commit=""
  while IFS= read -r line; do
    case "$line" in
      release_tag=*) release_tag="${line#release_tag=}" ;;
      release_commit=*) release_commit="${line#release_commit=}" ;;
      *) if [ -z "$dir" ]; then dir="$line"; fi ;;
    esac
  done <<RESOLVED
$out
RESOLVED
  # The release's own names are what the release carries, so staging is told the commit the bytes belong to.
  stage_commit="${release_commit:-$commit}"
  out="$(wa_node_binary_stage "$stage" "$dir" "$stage_commit" "$triple" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$out"
    return "$rc"
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  # The machine-readable half of the same answer: the triple, the verified directory and its sha12. The
  # deploy needs the directory itself for the sentinel install step, and reading it out of the prose line
  # below would break on a directory with a space in it - so it is said as its own line, on purpose.
  printf 'binary_verified: %s %s %s\n' "$triple" "$dir" "$(wa_node_short_sha "$stage_commit")"
  if [ -n "${WA_DEPLOY_BINARY_SOURCE:-}" ]; then
    printf 'binary_source: %s %s (WA_DEPLOY_BINARY_SOURCE)\n' "$triple" "$dir"
  elif [ -n "$release_tag" ]; then
    # A docs-only (or Lua-only) descendant: this release is the newest published build of the same
    # compiled inputs, and its source commit is what the record has to name beside the release tag.
    printf 'binary_release: %s %s\n' "$release_tag" "$release_commit"
    printf 'binary_source: %s %s (verified against %s, the build of %s; this commit changes no compiled input)\n' \
      "$triple" "$dir" "$release_tag" "${release_commit:0:12}"
  else
    printf 'binary_source: %s %s (verified against %s)\n' "$triple" "$dir" "$(wa_node_release_tag "$commit")"
  fi
  return 0
}
