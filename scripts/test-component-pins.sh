#!/usr/bin/env bash
# A pinned component's bytes are the build of the source this tree ships.
#
# WHY. 13/11: `change/waroute` added the `contacts` op to `rust/components/wa-whatsapp` (and to the
# seam it shares with the node, `rust/wa-whatsapp-index`), landed, and deployed - and `components.lock`
# still pinned the artifact built before it. Every deploy installed those old bytes, so the tool on the
# account node answered `whatsapp_contacts_bad_op`, retried and dead-lettered the job; waroute's
# contract tests were green because they ran against the component SOURCE (`cargo test --lib`), which
# no deploy ever installs. Nothing in the gate compared "what this tree builds" with "what this tree
# pins", so a component change could ship as source and never as bytes.
#
# WHAT THIS CHECKS. Two halves, and the first one never skips.
#
#   1. PIN vs SOURCE (always: git only, no cargo, no network, no wasi-sdk). For every component
#      `components.lock` pins that has a source tree under `rust/components/<name>/`, if the judged
#      range (the merge base with `origin/main` .. HEAD, plus the working tree) changes any file under
#      that tree - or under any crate it depends on through a `path =` dependency, resolved
#      transitively - then the lock's line for that component must change in the same range. If it
#      does not, this fails and names the files: that is the waroute shape.
#
#      A change that provably cannot move the bytes (a comment, a doc line, a `#[cfg(test)]` helper)
#      still needs a record, because no check on a machine without the toolchain can tell it from a
#      change that does. The record is a commit trailer in the judged range:
#
#        Components-Unchanged: <name> <what changed and why the bytes do not>
#
#      It is one line, reviewable, and it says a person looked. A trailer with no reason is refused.
#
#   2. PIN vs BYTES (the artifact the deploy installs). Verifies the pinned `wa-whatsapp.wasm` against
#      its own pin (sha256 AND size) and asserts the bytes know every op the seam defines: the op list
#      is READ from `rust/wa-whatsapp-index` (`Op::ALL`, `Op::as_str`, `Op::tool`), never copied here,
#      and each tool name must appear in the module - together with the `bad_op` refusal that proves the
#      validation path is in there, and without the unknown op the seam's own test refuses
#      (`contacts_v2`), so a scan that matches anything fails instead of passing by accident. Measured
#      on the two artifacts: the build pinned before waroute (8,554,548 bytes) contains
#      `whatsapp_contacts` 0 times, the build of this tree (8,557,078) 2 times. The bare word `contacts`
#      is not discriminating: the old build carries it 3 times already (the map, the protocol library).
#
#      Where the bytes come from, first pin that matches: `$WA_PINNED_COMPONENTS_DIR`, the component
#      directory the core reads (`$WA_COMPONENTS_DIR`, else `~/.wasm-agent/components`), `build/
#      components-pinned/`, this worktree's git dir (`wa-pinned-components/`), and finally the public
#      release `components-<lock sha12>` (public: the deploy fetches it with no credentials either).
#      A downloaded file is verified against the pin before it is cached, and a mismatch is a failure,
#      never a fallback. When no candidate is reachable this prints `SKIP wa-whatsapp-pin: ...` with
#      the command that produces the bytes; `WA_PIN_CHECK_REQUIRE=1` turns that skip into a failure
#      (the fail-closed setting for a release gate).
#
# WHY NOT "rebuild and compare the sha256". A component with a `path =` dependency is NOT
# byte-reproducible across checkout paths, and `wa-whatsapp` has two (`wa-whatsapp-outbox`,
# `wa-whatsapp-index`): measured 13/11, two checkouts of this same commit gave 8,557,078 bytes /
# `0bf8762a…` and 8,557,275 bytes / `67a9414f…`, because Cargo's `-C metadata` for a path package is a
# hash of its canonical absolute path (`libwa_whatsapp_index-49271f4b…` in one tree,
# `-5caf7479…` in the other) - docs/COMPONENTS.md, "Reproducible builds". So half 1 is the gate that
# can run everywhere, and half 2 is what proves the shipped bytes, on the machine that has (or can
# fetch) them.
#
#   bash scripts/test-component-pins.sh                     # judge this tree
#   bash scripts/test-component-pins.sh --base <ref>         # judge <merge-base(ref,HEAD)>..HEAD
#   bash scripts/test-component-pins.sh --repo <dir>         # judge another checkout
#   bash scripts/test-component-pins.sh --artifact <dir>     # where the pinned bytes are
#   bash scripts/test-component-pins.sh --source-only         # half 1 only (the gate's fallback)
#   bash scripts/test-component-pins.sh --bytes-only          # half 2 only (the artifact's op list)
#   bash scripts/test-component-pins.sh --artifact <dir>      # the bytes are exactly these
#   bash scripts/test-component-pins.sh --self-test           # prove both directions on fixtures
#
# WA_PIN_CHECK_RELEASE_BASE (default https://github.com) is a URL base only - the slug, tag and file name
# still come from the lock - so `--self-test` can prove the fetch and its cache under parallel rows with
# no network. The fetch writes a temporary file of its own (`mktemp` in the cache directory) and renames
# it into place only after the pin matches, and `judge_bytes` judges a private copy of what it verified:
# two rows of one gate share that cache, and a fixed temporary name made them hash each other's
# half-written download (measured 13/11: `is not the pinned build` for correct bytes).
#
# Exit: 0 every pin agrees with the source and the bytes; 1 a pin disagrees (the line says which and
# the command that fixes it); 2 this checkout cannot be judged (no components.lock, no git).
set -uo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
repo="$ROOT"
base_ref="${WA_COMPONENT_PINS_BASE:-origin/main}"
artifact_dir="${WA_PINNED_COMPONENTS_DIR:-}"
source_only=0
bytes_only=0
self_test=0
require="${WA_PIN_CHECK_REQUIRE:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:?--repo needs a directory}; shift 2 ;;
    --base) base_ref=${2:?--base needs a ref}; shift 2 ;;
    --artifact) artifact_dir=${2:?--artifact needs a directory}; shift 2 ;;
    --source-only) source_only=1; shift ;;
    --bytes-only) bytes_only=1; shift ;;
    --require) require=1; shift ;;
    --self-test) self_test=1; shift ;;
    -h|--help) sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test-component-pins: unknown argument $1" >&2; exit 2 ;;
  esac
done

say() { printf 'component-pins: %s\n' "$*"; }
# The private directory this run judges a copy in (`judge_bytes`), removed whichever way the check ends:
# a failure path exits from deep inside the comparisons and a leaked 8.5 MB copy per failed row is
# exactly the kind of scratch `wa clean` would have to reclaim.
PIN_SCRATCH=''
fail() { [ -n "$PIN_SCRATCH" ] && rm -rf "$PIN_SCRATCH"; printf 'FAIL component-pins: %s\n' "$*" >&2; exit 1; }

sha_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'
             else shasum -a 256 < "$1" | awk '{print $1}'; fi; }
bytes_in() { wc -c < "$1" | tr -d '[:space:]'; }

# ---- pins ----------------------------------------------------------------------------------------
# <lock> -> "<name> <sha256> <bytes>" for every pinned line, in file order. The deploy's own reader
# (`wa_component_pin`, scripts/lib/deploy-components.sh) accepts exactly this shape; a blank or
# comment line is never a pin.
pins_of() {
  [ -f "$1" ] || return 1
  awk '/^[[:space:]]*(#|$)/ {next} $1 != "" && $2 ~ /^[0-9a-f]+$/ {print $1, $2, ($3 == "" ? "-" : $3)}' "$1"
}
pin_of() { pins_of "$1" | awk -v want="$2" '$1 == want {print $2, $3; found = 1; exit} END {exit !found}'; }

# ---- the inputs of a component's build ------------------------------------------------------------
# <repo> <crate-dir> -> one repo-relative prefix per line: the crate itself and every crate it depends
# on through a `path =` dependency, transitively. A component's bytes are a function of all of them:
# the seam crate IS the op list (`wa-whatsapp-index`), and a change there changes what the guest
# accepts even though no file under `rust/components/<name>/` moved.
component_inputs() {
  local root="$1" crate="$2"
  local -a queue=() seen=()
  queue=("$crate")
  while [ "${#queue[@]}" -gt 0 ]; do
    local dir="${queue[0]}"
    queue=("${queue[@]:1}")
    case " ${seen[*]-} " in *" $dir "*) continue ;; esac
    seen+=("$dir")
    printf '%s/\n' "${dir%/}"
    [ -f "$root/$dir/Cargo.toml" ] || continue
    local dep
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      local resolved
      resolved="$(CDPATH= cd -- "$root/$dir/$dep" 2>/dev/null && pwd)" || continue
      case "$resolved" in
        "$root"/*) queue+=("${resolved#"$root"/}") ;;
        *) : ;; # outside this tree: not a file this tree can change
      esac
    done < <(path_dependencies "$root/$dir/Cargo.toml")
  done
}
# <Cargo.toml> -> each dependency's `path = "..."`, both spellings Cargo accepts: an inline table
# (`foo = { path = "../foo" }`) and a table of its own (`[dependencies.foo]` + `path = "../foo"`).
# `[lib] path = "src/lib.rs"`, `[[bin]]` and the workspace tables name files, not crates, and are not
# dependencies: only the dependency tables are read.
path_dependencies() {
  awk '
    /^[[:space:]]*\[/ {
      section = $0
      gsub(/[[:space:]]/, "", section)
      in_dep = (section ~ /^\[(dev-|build-)?dependencies\./) || (section ~ /^\[target\..*dependencies\./)
      next
    }
    {
      line = $0
      sub(/#.*/, "", line)
      if (in_dep && line ~ /path[[:space:]]*=/) { if (match(line, /path[[:space:]]*=[[:space:]]*"[^"]*"/)) {
        value = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", value); sub(/"$/, "", value); print value } }
      else if (line ~ /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*\{/ && line ~ /path[[:space:]]*=[[:space:]]*"/) {
        if (match(line, /path[[:space:]]*=[[:space:]]*"[^"]*"/)) {
          value = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", value); sub(/"$/, "", value); print value } }
    }
  ' "$1" 2>/dev/null
}

# ---- half 1: the pin against the source ------------------------------------------------------------
judge_source() {
  local root="$1" base_ref="$2"
  [ -f "$root/components.lock" ] || { echo "test-component-pins: no $root/components.lock" >&2; return 2; }
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { echo "test-component-pins: $root is not a git checkout" >&2; return 2; }
  local base=""
  if [ -n "$base_ref" ] && git -C "$root" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null 2>&1; then
    base="$(git -C "$root" merge-base "$base_ref" HEAD 2>/dev/null)"
  fi
  [ -n "$base" ] || base="$(git -C "$root" rev-parse HEAD)"
  say "judging $root: $(git -C "$root" rev-parse --short "$base")..HEAD ($(git -C "$root" rev-parse --abbrev-ref HEAD)) plus the working tree"

  # Every path the range touches, committed or not: the working tree is what a landing would commit.
  local changed
  changed="$(
    { git -C "$root" diff --name-only "$base"..HEAD 2>/dev/null
      git -C "$root" diff --name-only 2>/dev/null
      git -C "$root" diff --name-only --cached 2>/dev/null
      git -C "$root" ls-files --others --exclude-standard 2>/dev/null
    } | sed 's#^\./##' | LC_ALL=C sort -u
  )"
  # The reason a person may record instead of a repin, per component.
  local trailers
  trailers="$(git -C "$root" log --format=%B "$base"..HEAD 2>/dev/null | sed -n 's/^Components-Unchanged:[[:space:]]*\([^[:space:]]*\)\([[:space:]]\+\(.*\)\)\?$/\1|\3/p')"

  local judged=0 failures=0 line name pin baseline changed_inputs trailer_reason
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="$(printf '%s' "$line" | awk '{print $1}')"
    [ -d "$root/rust/components/$name" ] || { say "$name: pinned, no source tree here (a fixture or a shipped-only artifact) - nothing to compare"; continue; }
    judged=$((judged + 1))
    local -a inputs=()
    while IFS= read -r dep; do [ -n "$dep" ] && inputs+=("$dep"); done < <(component_inputs "$root" "rust/components/$name")
    changed_inputs=""
    local path dep
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      for dep in "${inputs[@]}"; do
        case "$path" in "$dep"*) changed_inputs="$changed_inputs$path"$'\n'; break ;; esac
      done
    done <<< "$changed"
    changed_inputs="$(printf '%s' "$changed_inputs" | sed '/^$/d')"
    [ -n "$changed_inputs" ] || continue

    # The pin must move with the source. "Moved" = the lock's line for this name differs from the one
    # the range starts at (a landing commits the lock with the change; an uncommitted repin counts).
    baseline=""
    if git -C "$root" cat-file -e "$base:components.lock" 2>/dev/null; then
      baseline="$(git -C "$root" show "$base:components.lock" 2>/dev/null | awk -v want="$name" '
        /^[[:space:]]*(#|$)/ {next}
        $1 == want && $2 ~ /^[0-9a-f]+$/ {print $2, ($3 == "" ? "-" : $3); found = 1; exit}
        END {exit !found}
      ')"
    fi
    pin="$(pin_of "$root/components.lock" "$name" 2>/dev/null)"
    if [ -n "$baseline" ] && [ "$baseline" = "$pin" ]; then
      trailer_reason=""
      local entry
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in
          "$name|"*) trailer_reason="${entry#*|}" ;;
        esac
      done <<< "$trailers"
      if [ -z "$trailer_reason" ]; then
        failures=$((failures + 1))
        printf 'FAIL component-pins: %s source changed and its pin did not\n' "$name" >&2
        printf '  changed under this component%s inputs:\n' "" >&2
        printf '%s\n' "$changed_inputs" | sed 's/^/    /' >&2
        printf '  components.lock: %s %s\n' "$name" "$pin" >&2
        printf '  fix: rebuild and pin the build (the artifact the deploy will install):\n' >&2
        printf '    WASI_SDK=<dir> WA_COMPONENTS_DIR=<artifact-dir> bash scripts/build-components.sh %s\n' "$name" >&2
        printf '    bash scripts/publish-components.sh --from <artifact-dir>   # verifies, prints the pin line and the gh command\n' >&2
        printf '  or, when the change cannot move the bytes, record that in the commit message:\n' >&2
        printf '    Components-Unchanged: %s <what changed and why the bytes are the same>\n' "$name" >&2
        continue
      fi
      say "$name: source changed, pin kept on purpose: $trailer_reason"
      continue
    fi
    say "$name: source and pin moved together ($pin)"
  done < <(pins_of "$root/components.lock")

  [ "$judged" -gt 0 ] || say "no pinned component has a source tree in this checkout - nothing to compare"
  [ "$failures" = 0 ] || return 1
  say "source and pins agree"
  return 0
}

# ---- half 2: the pin against the bytes the deploy installs -----------------------------------------
# The op list, read from the seam that owns it. `Op::ALL` is the one list three call sites enumerate
# (`the_bad_op_refusal_lists_every_op`, the host capability's contract, this check), so a new op cannot
# be half-added here.
seam_ops() {
  local lib="$1/rust/wa-whatsapp-index/src/lib.rs"
  [ -f "$lib" ] || return 1
  local variants block
  block="$(sed -n '/pub const ALL: \[Op;/,/^    \];/p' "$lib")"
  variants="$(printf '%s' "$block" | grep -oE 'Op::[A-Z][A-Za-z0-9]*' | sed 's/^Op:://' | LC_ALL=C sort -u)"
  [ -n "$variants" ] || return 1
  local v
  for v in $variants; do
    local name tool
    name="$(fn_arm "$lib" 'pub fn as_str' "$v")"
    tool="$(fn_arm "$lib" 'pub fn tool' "$v")"
    [ -n "$name" ] && [ -n "$tool" ] || return 1
    printf '%s %s %s\n' "$v" "$name" "$tool"
  done
}
# <lib.rs> <function-start-pattern> <variant> -> the literal that variant maps to in that function.
fn_arm() {
  awk -v start="$2" -v want="Op::$3" '
    index($0, start) { inside = 1 }
    inside && index($0, want " =>") {
      line = $0; sub(/.*=>[[:space:]]*"/, "", line); sub(/".*/, "", line); print line; exit
    }
    inside && /^    }$/ { exit }
  ' "$1"
}

# <path> <literal> -> 0 when the bytes contain it.
contains() { grep -c -a -F -q -- "$2" "$1" 2>/dev/null; }

has_artifact() {
  local repo="$1" name="$2" want_sha="$3"
  # An explicitly named directory is an assertion, not a hint: when the caller says where the pinned
  # bytes are, a file that is not the pinned build is a failure (the caller names the path), never a
  # reason to go looking for a candidate that happens to match.
  if [ -n "$artifact_dir" ]; then
    [ -f "$artifact_dir/$name.wasm" ] && printf '%s\n' "$artifact_dir/$name.wasm"
    return $?
  fi
  local -a candidates=()
  candidates+=("$( ( [ -n "${WA_COMPONENTS_DIR:-}" ] && printf '%s' "$WA_COMPONENTS_DIR" ) || printf '%s' "${HOME:-.}/.wasm-agent/components")/$name.wasm")
  candidates+=("$repo/build/components-pinned/$name.wasm")
  local gitpath
  # --absolute-git-dir, not --git-path: for a linked worktree the latter is already absolute, and
  # joining it to the checkout twice was a candidate path that never existed (measured: the pinned
  # copy in this worktree's git dir was reported unreachable while it sat there).
  gitpath="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)"
  gitpath="${gitpath:+$gitpath/wa-pinned-components}"
  [ -n "$gitpath" ] && candidates+=("$gitpath/$name.wasm")
  candidates+=("${WA_COMPONENTS_CACHE:-${HOME:-.}/.wasm-agent/components-cache}/$( (cd "$repo" && . scripts/lib/deploy-components.sh && wa_component_lock_sha .) 2>/dev/null)/$name.wasm")
  local c
  for c in "${candidates[@]}"; do
    [ -f "$c" ] || continue
    if [ "$(sha_file "$c")" = "$want_sha" ]; then printf '%s\n' "$c"; return 0; fi
  done
  # None of them is the pinned build: fetch it from the release the lock names (public; the deploy
  # fetches it the same way). Verified against the pin before it is used or cached.
  [ "${WA_PIN_CHECK_FETCH:-1}" = 0 ] && return 1
  command -v curl >/dev/null 2>&1 || return 1
  [ -n "$gitpath" ] || return 1
  local sha tag slug url dest
  sha="$( (cd "$repo" && . scripts/lib/deploy-components.sh && wa_component_lock_sha .) 2>/dev/null)" || return 1
  tag="$( (cd "$repo" && . scripts/lib/deploy-components.sh && wa_component_release_tag .) 2>/dev/null)" || return 1
  slug="$( (cd "$repo" && . scripts/lib/deploy-components.sh && wa_component_release_repo .) 2>/dev/null)" || return 1
  [ -n "$sha" ] && [ -n "$tag" ] || return 1
  # The release host is a knob so the fetch and its race can be proved on a machine with no network
  # (`--self-test`, "parallel rows fetch the same bytes"). It is a URL base only: the slug, the tag and
  # the file name are still the lock's.
  url="${WA_PIN_CHECK_RELEASE_BASE:-https://github.com}/$slug/releases/download/$tag/$name.wasm"
  dest="$gitpath"
  mkdir -p "$dest" 2>/dev/null || return 1
  # ONE TEMPORARY FILE PER PROCESS, RENAMED ATOMICALLY. Two rows of the same gate judge the same repo
  # from the same git dir, so a fixed `.wa-whatsapp.wasm.tmp` was a shared file: one row's `curl` was
  # writing it while the other row hashed it, and the second row's `mv` then failed or moved a partial
  # download over the cache. Measured 13/11 on the landing gate: `wa-whatsapp` reported as "not the
  # pinned build" while the bytes in the cache were the pinned bytes. `mktemp` in the destination
  # directory (same filesystem, so `mv` is a rename) and the verification happens on the file THIS
  # process wrote, before anyone else can see it under the published name.
  local tmp
  tmp="$(mktemp "$dest/.$name.wasm.XXXXXX" 2>/dev/null)" || return 1
  # ON STDERR, because `has_artifact` is read by its CALLER'S command substitution: a line printed on
  # stdout here became part of the "path" the caller got back ("component-pins: wa-whatsapp: no local
  # copy...\n/…/wa-whatsapp.wasm"), so a fetch that worked could never be judged - measured on this
  # fixture: `cannot be copied for judging`. Only the path belongs on stdout.
  say "$name: no local copy of the pinned bytes; fetching $url" >&2
  if ! curl -sSfL --max-time 60 -o "$tmp" "$url" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  if [ "$(sha_file "$tmp")" != "$want_sha" ]; then
    rm -f "$tmp"
    say "$name: the release $tag does not hold the pinned bytes (sha256 mismatch) - that is a publication gap, not a pass" >&2
    return 1
  fi
  mv -f "$tmp" "$dest/$name.wasm" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$dest/$name.wasm"
  return 0
}

judge_bytes() {
  local root="$1"
  [ -f "$root/rust/wa-whatsapp-index/src/lib.rs" ] || { say "no rust/wa-whatsapp-index here: the artifact half applies to this repository only"; return 0; }
  local pin sha bytes
  pin="$(pin_of "$root/components.lock" wa-whatsapp)" || fail "wa-whatsapp is not pinned in $root/components.lock"
  sha="${pin%% *}"; bytes="${pin##* }"
  local wasm
  if ! wasm="$(has_artifact "$root" wa-whatsapp "$sha")"; then
    local reason="no reachable copy of the pinned wa-whatsapp bytes (sha256 ${sha:0:12}…) - looked in \${WA_PINNED_COMPONENTS_DIR}, the component directory, build/components-pinned, this worktree's git dir and the release; build it once: WA_COMPONENTS_DIR=<dir> bash scripts/build-components.sh wa-whatsapp"
    if [ "$require" = 1 ]; then fail "$reason"; fi
    printf 'SKIP wa-whatsapp-pin: %s\n' "$reason"
    return 0
  fi
  # ONE HASH, ONE FILE, AND THE FILE THAT IS JUDGED IS THE FILE THAT WAS VERIFIED.
  #
  # `$wasm` can be a cache several parallel rows share (`<git-dir>/wa-pinned-components`), and another
  # row may rename a fresh copy over it at any moment - so the sha, the size and the `contains` scans
  # below were three reads of a path somebody else could change between them. Measured 13/11 on the
  # landing gate: `sha256` matched and the next read saw a different file, so the row failed for a
  # component whose bytes were correct. The verified file is copied into this run's own directory and
  # every judgement below reads that copy, which nothing else can touch.
  PIN_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/wa-pin-bytes-XXXXXX")" || fail "mktemp failed: cannot prepare a private copy to judge"
  local verified="$wasm"
  wasm="$PIN_SCRATCH/$(basename "$verified")"
  cp -f "$verified" "$wasm" 2>/dev/null || fail "$verified cannot be copied for judging (it vanished or is unreadable)"
  [ "$(sha_file "$wasm")" = "$sha" ] || fail "$verified is not the pinned build (pin $sha)"
  if [ "$bytes" != "-" ]; then
    local got; got="$(bytes_in "$wasm")"
    [ "$got" = "$bytes" ] || fail "$verified is $got bytes, components.lock pins $bytes"
  fi
  say "pinned bytes: $verified ($bytes bytes, sha256 ${sha:0:12}…), judged from a private copy"

  local ops
  if ! ops="$(seam_ops "$root")"; then
    fail "cannot read the op list from rust/wa-whatsapp-index/src/lib.rs (Op::ALL with an as_str and a tool arm per op) - this check parses that source on purpose and will not guess"
  fi
  local count; count="$(printf '%s\n' "$ops" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  [ "$count" -gt 0 ] || fail "the seam lists no op"
  # The tool names first: they are what discriminates. The bare op name is not - measured, the build
  # pinned before waroute contains the word `contacts` three times already (from the map and the
  # protocol library) and `whatsapp_contacts` not once, so only the tool name tells the two builds apart.
  local variant name tool
  while IFS=' ' read -r variant name tool; do
    [ -n "$variant" ] || continue
    contains "$wasm" "$tool" || fail "the pinned bytes do not know $tool (Op::$variant): the build is older than the seam - rebuild and repin (scripts/publish-components.sh prints the line)"
    contains "$wasm" "$name" || fail "the pinned bytes do not carry the op name '$name' (Op::$variant): rebuild and repin"
  done <<< "$ops"
  # The validation path itself, by a wording both builds carry: the refusal sentence a bad op answers.
  # (The sentence's own words are not pinned here - they are prose and were reworded on 13/11; the op
  # names above are the contract.)
  contains "$wasm" 'op must be' || fail "the pinned bytes carry no 'op must be' refusal: they are not a build of a component that validates ops"
  contains "$wasm" 'contacts_v2' && fail "the pinned bytes contain 'contacts_v2', which only a test names: this is not a release build"
  say "the pinned bytes answer all $count ops the seam defines: $(printf '%s\n' "$ops" | awk '{printf "%s%s", (NR > 1 ? ", " : ""), $3}')"
  rm -rf "$PIN_SCRATCH"; PIN_SCRATCH=''
  return 0
}

# ---- the check is proved, not trusted --------------------------------------------------------------
# A fixture repository per direction: the shape that shipped (source moved, pin did not), the pin that
# moved with it, an unrelated change, a path dependency, and the recorded trailer. `--self-test` runs
# them all and exits 0 only when exactly the right ones fail.
self_test() {
  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/wa-component-pins-XXXXXX")" || { echo "self-test: mktemp failed" >&2; return 2; }
  local rc=0 fixtures=0
  fixture() { # <dir> -> a repository with one pinned component, a path dependency and one commit
    local dir="$1"
    mkdir -p "$dir/rust/components/fixture-comp/src" "$dir/rust/fixture-dep/src"
    printf 'fixture-comp 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef 100\n' > "$dir/components.lock"
    printf '[package]\nname = "fixture-comp"\n\n[dependencies]\nfixture-dep = { path = "../../fixture-dep" }\n' > "$dir/rust/components/fixture-comp/Cargo.toml"
    printf 'pub fn a() -> u32 { 1 }\n' > "$dir/rust/components/fixture-comp/src/lib.rs"
    printf '[package]\nname = "fixture-dep"\n\n[lib]\npath = "src/lib.rs"\n' > "$dir/rust/fixture-dep/Cargo.toml"
    printf 'pub fn b() -> u32 { 2 }\n' > "$dir/rust/fixture-dep/src/lib.rs"
    printf 'readme\n' > "$dir/README.md"
    git -C "$dir" init -q -b main
    git -C "$dir" -c user.email=t@example -c user.name=t add -A
    git -C "$dir" -c user.email=t@example -c user.name=t commit -q -m "fixture: base"
    git -C "$dir" branch -q -f base HEAD
  }
  commit() { git -C "$1" -c user.email=t@example -c user.name=t commit -q -a -m "$2"; }
  expect() { # <label> <expected exit> <dir> <args...>
    local label="$1" want="$2" dir="$3"; shift 3
    fixtures=$((fixtures + 1))
    local out got
    out="$(bash "$0" --repo "$dir" --base base --source-only "$@" 2>&1)"; got=$?
    if [ "$got" = "$want" ]; then say "self-test ok: $label (exit $got)"
    else rc=1; printf 'self-test FAILED: %s wanted exit %s, got %s\n%s\n' "$label" "$want" "$got" "$out" >&2; fi
  }

  local d
  d="$work/waroute"; fixture "$d"
  mkdir -p "$d/rust/components/wa-whatsapp/src"; printf 'pub fn a() -> u32 { 2 }\n' > "$d/rust/components/wa-whatsapp/src/lib.rs"
  printf 'fixture-comp 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef 100\nwa-whatsapp 1111111111111111111111111111111111111111111111111111111111111111 200\n' > "$d/components.lock"
  printf 'pub fn a() -> u32 { 3 } // contacts\n' > "$d/rust/components/fixture-comp/src/lib.rs"
  commit "$d" "change the component, forget the pin"
  expect "source moved, pin did not" 1 "$d"

  d="$work/repinned"; fixture "$d"
  printf 'pub fn a() -> u32 { 3 }\n' > "$d/rust/components/fixture-comp/src/lib.rs"
  printf 'fixture-comp fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 101\n' > "$d/components.lock"
  commit "$d" "change the component and repin"
  expect "source and pin moved together" 0 "$d"

  d="$work/unrelated"; fixture "$d"
  printf 'a doc\n' > "$d/README.md"
  commit "$d" "a docs-only change"
  expect "a change outside every pinned tree" 0 "$d"

  d="$work/dependency"; fixture "$d"
  printf 'pub fn b() -> u32 { 9 }\n' > "$d/rust/fixture-dep/src/lib.rs"
  commit "$d" "change the crate the component depends on"
  expect "a path dependency moved, pin did not" 1 "$d"

  d="$work/trailer"; fixture "$d"
  printf 'pub fn a() -> u32 { 3 } // a comment cannot reach the bytes\n' > "$d/rust/components/fixture-comp/src/lib.rs"
  commit "$d" "touch the component

Components-Unchanged: fixture-comp a comment line, the optimizer emits the same bytes"
  expect "source moved, the commit records why the pin is unchanged" 0 "$d"

  d="$work/empty-trailer"; fixture "$d"
  printf 'pub fn a() -> u32 { 3 }\n' > "$d/rust/components/fixture-comp/src/lib.rs"
  commit "$d" "touch the component

Components-Unchanged: fixture-comp"
  expect "a trailer with no reason is not a record" 1 "$d"

  d="$work/uncommitted"; fixture "$d"
  printf 'pub fn a() -> u32 { 4 }\n' > "$d/rust/components/fixture-comp/src/lib.rs"
  expect "an uncommitted component change is judged too" 1 "$d"

  # ---- the race: parallel rows judging the same pinned bytes from one cache ---------------------
  #
  # WHAT HAPPENED (13/11, the landing gate). Every row of a gate judges the same checkout, so
  # `has_artifact` fetches into the same `<git-dir>/wa-pinned-components/wa-whatsapp.wasm` and
  # `judge_bytes` re-hashes that shared path. The fetch wrote a fixed `.wa-whatsapp.wasm.tmp`, so one
  # row was writing it while another hashed it, and the loser reported `is not the pinned build` about
  # bytes that were the pinned bytes. This fixture is that shape on a `file://` release: eight rows,
  # one cache, one pin, and every one of them must pass. It fails on the fixed-temp-name code and it
  # cannot pass by luck on this one, because each row verifies the file it wrote itself and judges a
  # copy nobody else can rename.
  local race="$work/race"
  mkdir -p "$race/rust/wa-whatsapp-index/src" "$race/scripts/lib" "$race/components-pinned-src"
  cp -f "$ROOT/scripts/lib/deploy-components.sh" "$race/scripts/lib/deploy-components.sh"
  cat > "$race/rust/wa-whatsapp-index/src/lib.rs" <<'SEAM'
pub const ALL: [Op; 2] = [
    Op::Query,
    Op::Contacts,
];
pub fn as_str(self) -> &'static str {
    match self {
        Op::Query => "query",
        Op::Contacts => "contacts",
    }
}
pub fn tool(self) -> &'static str {
    match self {
        Op::Query => "whatsapp_query",
        Op::Contacts => "whatsapp_contacts",
    }
}
SEAM
  # The bytes, as the artifact half judges them: every op's tool name and op name, the refusal wording,
  # and not the unknown op a test-only build carries.
  printf 'whatsapp_query query whatsapp_contacts contacts op must be\n' > "$race/components-pinned-src/wa-whatsapp.wasm"
  local race_sha race_bytes lock_sha tag
  race_sha="$(sha_file "$race/components-pinned-src/wa-whatsapp.wasm")"
  race_bytes="$(bytes_in "$race/components-pinned-src/wa-whatsapp.wasm")"
  printf 'wa-whatsapp %s %s\n' "$race_sha" "$race_bytes" > "$race/components.lock"
  git -C "$race" init -q -b main
  git -C "$race" -c user.email=t@example -c user.name=t add -A
  git -C "$race" -c user.email=t@example -c user.name=t commit -q -m "fixture: a pinned component with a seam"
  lock_sha="$(sha_file "$race/components.lock")"; tag="components-${lock_sha:0:12}"
  mkdir -p "$work/release/fixture/repo/releases/download/$tag" "$work/home"
  cp -f "$race/components-pinned-src/wa-whatsapp.wasm" "$work/release/fixture/repo/releases/download/$tag/wa-whatsapp.wasm"
  rm -rf "$race/components-pinned-src"
  race_run() { # <n> -> exit code, output in $work/race-$n.log
    HOME="$work/home" WA_COMPONENTS_DIR="$work/home/components" WA_COMPONENTS_CACHE="$work/home/cache" \
      WA_COMPONENT_RELEASE_REPO=fixture/repo WA_PIN_CHECK_RELEASE_BASE="file://$work/release" \
      bash "$0" --repo "$race" --bytes-only > "$work/race-$1.log" 2>&1
  }
  local n rc_race=0
  for n in 1 2 3 4 5 6 7 8; do race_run "$n" & done
  for n in 1 2 3 4 5 6 7 8; do wait %$n 2>/dev/null; done
  for n in 1 2 3 4 5 6 7 8; do
    if ! grep -q "^component-pins: the pinned bytes answer all 2 ops the seam defines" "$work/race-$n.log"; then
      rc_race=1
      printf 'self-test FAILED: parallel row %s did not judge the pinned bytes\n' "$n" >&2
      sed 's/^/    /' "$work/race-$n.log" >&2
    fi
  done
  fixtures=$((fixtures + 1))
  if [ "$rc_race" = 0 ] && [ "$(sha_file "$race/.git/wa-pinned-components/wa-whatsapp.wasm")" = "$race_sha" ]; then
    say "self-test ok: eight rows fetched and judged one cache at once, all eight passed (8 rows, 1 pin)"
  else
    rc=1; printf 'self-test FAILED: the cache after eight parallel rows is not the pinned build\n' >&2
  fi
  # The negative control: the same fixture with a pin that is not these bytes still fails, so the race
  # case above cannot pass by accepting anything.
  printf 'wa-whatsapp 0000000000000000000000000000000000000000000000000000000000000000 %s\n' "$race_bytes" > "$race/components.lock"
  git -C "$race" -c user.email=t@example -c user.name=t commit -q -am "fixture: a pin that is not these bytes"
  fixtures=$((fixtures + 1))
  if HOME="$work/home" WA_COMPONENTS_DIR="$work/home/components" WA_COMPONENTS_CACHE="$work/home/cache" \
       WA_COMPONENT_RELEASE_REPO=fixture/repo WA_PIN_CHECK_RELEASE_BASE="file://$work/release" \
       bash "$0" --repo "$race" --bytes-only --require > "$work/race-negative.log" 2>&1; then
    rc=1; printf 'self-test FAILED: a pin that is not these bytes passed\n' >&2
  else
    say "self-test ok: a pin that is not these bytes still fails"
  fi

  rm -rf "$work"
  [ "$rc" = 0 ] && say "self-test ok: $fixtures fixtures, exactly the waroute shape fails"
  return "$rc"
}

if [ "$self_test" = 1 ]; then self_test; exit $?; fi
[ "$bytes_only" = 1 ] || judge_source "$repo" "$base_ref" || exit $?
[ "$source_only" = 1 ] && exit 0
judge_bytes "$repo"
