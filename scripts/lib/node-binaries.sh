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
#   pins            node-<sha12>.manifest - one row per target triple, the release's own identity
#   payload         wa-<triple>-<sha12>, wa-sentinel-<triple>-<sha12>
#
# A node asks for the release its own commit names (never "the latest": a deploy installs the commit it
# holds, and a binary from another commit is not that commit's build), verifies the manifest's
# source_commit against its own 40-hex HEAD, then verifies sha256 AND size of both binaries against the
# manifest before anything is cached or staged. A refusal is never a fallback - `node_hash_mismatch`
# means the bytes that claim to be this commit's are not - and only "nothing is published for this
# commit and target" (node_release_unavailable) lets a deploy build the tree instead.
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
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 7
  fi
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
#   3. the release (gh, else curl), cached.
# Prints the directory on 0; on 8 prints the reason and the caller may build this tree instead; a
# refusal (2/5/6/7) is printed too and must stop the deploy.
wa_node_binary_source_resolve() {
  local repo="$1" commit="$2" triple="$3" install="${4:-}" dir cache_root short
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
  wa_node_binary_download "$repo" "$commit" "$triple" "$cache_root"
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
# Resolve (fetch + verify), then stage `wa` and `wa-sentinel` into <stage>. One `binary_source:` line on
# stdout on 0, the same line naming the reason on 8 (nothing published for this commit/triple, or this
# host has no published target at all - a Windows deploy builds, as it always did), and the refusal
# itself on 2/5/6/7.
wa_node_binaries_prepare() {
  local repo="$1" commit="$2" stage="$3" install="${4:-}" triple out rc dir
  triple="$(wa_node_target_triple)"; rc=$?
  if [ "$rc" != 0 ] || [ -z "$triple" ]; then
    printf 'binary_source: this tree (no prebuilt target for %s/%s; the published targets are Linux aarch64 and x86_64)\n' \
      "$(uname -s 2>/dev/null)" "$(uname -m 2>/dev/null)"
    return 8
  fi
  out="$(wa_node_binary_source_resolve "$repo" "$commit" "$triple" "$install" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$out"
    return "$rc"
  fi
  dir="$out"
  out="$(wa_node_binary_stage "$stage" "$dir" "$commit" "$triple" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$out"
    return "$rc"
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  if [ -n "${WA_DEPLOY_BINARY_SOURCE:-}" ]; then
    printf 'binary_source: %s %s (WA_DEPLOY_BINARY_SOURCE)\n' "$triple" "$dir"
  else
    printf 'binary_source: %s %s (verified against %s)\n' "$triple" "$dir" "$(wa_node_release_tag "$commit")"
  fi
  return 0
}
