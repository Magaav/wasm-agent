#!/bin/bash
# Install a node binary from a published artifact — and refuse to leave the node worse than it was.
#
#   fleet-install.sh <artifact-url> [--sha SHA256] [--sig SIGHEX --pub PUBKEY --manifest TEXT]
#
# Why every check below exists, in the order a failure would hurt:
#
# 1. **sha256** — the bytes are the ones that were published, not whatever a proxy served.
# 2. **the signature (optional)** — a manifest signed by the operator's `fleet-release` key, verified
#    offline with the node's own ed25519 (`wa` + `host.verify`), the same pattern the roster uses.
# 3. **the glibc floor, named** — the newest `GLIBC_<version>` symbol in the artifact against this host's
#    `ldd --version`. The measurement is the block carried inline below, the lib's own text. The
#    exec test below catches this class too, but it catches it as "the artifact does not run here:
#    GLIBC_2.39 not found", one line of a failure that took two days to read on mail (18/11). This step
#    names both versions before anything is executed.
# 3b. **it runs here, before anything is replaced** — `--version` on the downloaded file. On 17/11 a
#    native build (glibc 2.39) was installed on two hosts whose glibc is 2.31 and 2.35; both nodes died
#    on restart and could not be reached at all, because the node *is* the channel you would fix it
#    through. A three-second exec test turns that into a refusal with the old binary still in place.
# 4. **backup, then swap** — `wa.prev.<utc>` beside the binary, so the way back is one `cp`.
# 5. **health, then rollback** — after the restart the node must answer `/health`; if it does not, the
#    backup is put back and the node restarted again, so the failure ends with a working node and a
#    named reason instead of a dead one and a silent night.
set -uo pipefail

URL=${1:?artifact url}
shift
SHA=; SIG=; PUB=; MANIFEST=
while [ $# -gt 0 ]; do
  case $1 in
    --sha) SHA=${2:?}; shift 2 ;;
    --sig) SIG=${2:?}; shift 2 ;;
    --pub) PUB=${2:?}; shift 2 ;;
    --manifest) MANIFEST=${2:?}; shift 2 ;;
    --bin) TARGET=${2:?}; shift 2 ;;
    --force) FORCE=1; shift ;;
    --reason) REASON=${2:?reason text}; shift 2 ;;
    *) echo "fleet-install: unknown_option $1" >&2; exit 2 ;;
  esac
done
TARGET=${TARGET:-$HOME/.local/bin/wa}
HEALTH=${HEALTH:-http://127.0.0.1:8799/health}
# How long a restarted node gets to answer /health. 30 s was too short: after a pkill the sentinel
# restarts the node on its own next check, and a boot measured 17/11 took ~80 s - a healthy artifact was
# rolled back as dead (and the rollback then looked dead too).
UNIT=${UNIT:-}
FORCE=${FORCE:-0}; REASON=${REASON:-}
# The record writer and the ancestry verdict (scripts/lib/install-record.sh): this script installs bytes it
# did not build, so only the binary can say which commit they are (18/11: a record named a commit the bytes
# were not).
HERE="$(cd "$(dirname "$0")" && pwd)"
for fi_lib in "${WA_INSTALL_RECORD_LIB:-}" "$HERE/lib/install-record.sh" "$HERE/../scripts/lib/install-record.sh"; do
  [ -n "$fi_lib" ] && [ -f "$fi_lib" ] && . "$fi_lib" && break
done
command -v wa_build_info >/dev/null 2>&1 \
  || { printf 'fleet-install: install_record_lib_missing: scripts/lib/install-record.sh is not beside this script; it is what writes installed.txt from the binary and what asks whether this artifact goes backwards; nothing was installed\n' >&2; exit 2; }
# The node's own pin store (scripts/lib/node-pins.sh): where a rollback wrote "this node stays here" on THIS node.
NODE_PIN_LIB=""
for nl in "${WA_NODE_PINS_LIB:-}" "$HERE/lib/node-pins.sh" "$HERE/../scripts/lib/node-pins.sh"; do
  [ -n "$nl" ] && [ -f "$nl" ] && { NODE_PIN_LIB="$nl"; break; }
done
if [ -n "$NODE_PIN_LIB" ]; then . "$NODE_PIN_LIB"; else
  printf 'fleet-install: node_pins_lib_missing: scripts/lib/node-pins.sh is not beside this script, so this node cannot read its own pin; nothing was installed\n' >&2
  exit 2
fi
say() { printf 'fleet-install: %s\n' "$*"; }
die() { printf 'fleet-install: %s\n' "$*" >&2; exit 1; }

# The glibc floor measurement is shared with the publisher and the other two installers
# (scripts/lib/glibc-floor.sh) - and this script is ALSO handed out on its own: one file over curl, or a
# copy kept beside a node that has no lib. It therefore carries the block itself, copied VERBATIM from the
# lib between the markers below (scripts/test-glibc-floor.sh diffs the two blocks and fails on one
# differing line, so there is one behaviour and provably one implementation). A copy without the lib used
# to refuse every install with `glibc_floor_lib_missing`, which is a floor check that is off exactly where
# it is needed - and the fleet install is the one that killed mail.
#
# AND IT SOURCES NOTHING, ON PURPOSE. 3b01caea sourced the lib from `$(dirname -- "$0")/lib` when that
# file was there - and under `curl ... | bash` `$0` is `bash`, so the path was
# `./lib/glibc-floor.sh`: a file in whatever directory the operator happened to be standing in. A
# floor check - the one gate that keeps a node alive across a restart, on the node that IS the channel you
# would fix it through - must not be replaceable by a file in the cwd. The lookup bought nothing: the block
# below IS the lib's text, byte for byte (scripts/test-glibc-floor.sh fails on one differing line), so
# sourcing it on top could only ever be a no-op or a bug. There is no lib read here at all: not relatively,
# not from $0, not from BASH_SOURCE. A test plants a `./lib/glibc-floor.sh` in the cwd, runs this file as
# `bash -s` (the curl shape) and as a bare relative path, and proves the plant is never read.
# wa-glibc-floor-begin
# THE MEASUREMENT AND THE GUARD - four functions, ONE behaviour, copied verbatim into
# scripts/fleet-install.sh between the same two markers (see the header of this file). Nothing in here may
# call anything outside this block: a standalone copy runs these four and nothing else.
#
# WHY THE MEASUREMENT IS A BYTE SCAN AND NOT `objdump -T`. A publisher reads artifacts of the OTHER
# architecture - that is what a cross build is - and `objdump` on the publishing host may not know a foreign
# machine (`objdump -T wa-aarch64` on an x86_64 binutils is "file format not recognized"). Every versioned
# symbol's name lives in the ELF's .dynstr as the literal string `GLIBC_<version>`, and the loader enforces
# the newest one, so `grep -a` over the bytes answers the same question for every artifact this project
# ships, on every host that can read a file. The cost of that shortcut, stated plainly: the scan counts ANY
# `GLIBC_x.y` string in the file, so a doc string, or an embedded copy of some other binary's floor, is read
# as a floor these bytes do not have, and a host below it would refuse a binary it can actually run.
# scripts/test-glibc-floor.sh measures the scan against `readelf -V`'s .gnu.version_r on real linked
# binaries - the check that catches such a string.

# Is this host's `sort` able to order versions? Answered by MEASURING an ordering only a version sort gets
# right - 2.9 below 2.10 - never by the name of the tool and never by a pair a byte sort also happens to
# get right (`2.2.5` vs `2.31` is that pair: a plain sort answers 2.31 too). Both ways a host can be
# without version order are caught here: a busybox `sort` REJECTS -V and every pipeline below answers
# nothing ("nothing" read as "not covered"), and a `sort` that ignores the flag silently answers byte
# order, which is wrong for 2.9 vs 2.10. Either way the comparison is "unknown" below, not "refused": it
# was a broken tool being blamed on every artifact in the fleet.
wa_glibc_sort_orders_versions() {
  [ "$(printf '%s\n%s\n' 2.9 2.10 | LC_ALL=C sort -V 2>/dev/null | tail -1)" = "2.10" ]
}

# <file> -> the newest glibc symbol version the file needs ("2.39"), empty when it needs none (a static
# binary, a PE, a shell script) or when this host cannot order the versions it finds. 2 when the file is not
# there.
#
# GLIBC_2.2.5 (the base every x86_64/aarch64 build needs) and GLIBC_2.31 are compared as VERSIONS, not as
# text: `sort -V` orders 2.2.5 below 2.31, and a plain sort puts "2.2.5" last ("2.2" > "2.3" byte-wise),
# which would report a floor of 2.2.5 as the newest thing in a 2.31 artifact. LC_ALL=C so a host's collation
# cannot change the answer `sort -V` gives.
wa_glibc_max_symbol() {
  local file="${1:-}" symbols newest
  [ -n "$file" ] && [ -f "$file" ] || return 2
  symbols="$(grep -a -o 'GLIBC_[0-9][0-9.]*[0-9]' "$file" 2>/dev/null | sed 's/^GLIBC_//')"
  [ -n "$symbols" ] || return 0
  newest="$(printf '%s\n' "$symbols" | LC_ALL=C sort -uV 2>/dev/null | tail -1)"
  if [ -z "$newest" ]; then
    # Symbol versions in the bytes and no way to order them here: "unknown" said out loud, on STDERR,
    # because a silent empty answer from this function reads as "the file needs nothing" - for a binary
    # that may need 2.39. The caller captures stdout, so STDERR is the channel the operator sees.
    printf 'glibc_floor_unknown: %s carries GLIBC symbol versions but this host\047s sort cannot order them (no -V), so its floor was not measured here; the exec/health proof downstream is the check that speaks for these bytes\n' \
      "$(basename "$file")" >&2
    return 0
  fi
  printf '%s\n' "$newest"
}

# <have> <need> -> 0 when <have> is at least <need>, as versions ("2.2.5" < "2.31" < "2.39"). 2 when the
# question cannot be answered here - a missing argument, or a `sort` with no version order - and 2 is
# "unknown", NOT "refused": the caller stands aside on 2 and lets the exec/health proof speak. A host whose
# `sort` has no -V refused every binary in this fleet before that distinction existed.
wa_glibc_covers() {
  local have="${1:-}" need="${2:-}" newest
  [ -n "$have" ] && [ -n "$need" ] || return 2
  wa_glibc_sort_orders_versions || return 2
  newest="$(printf '%s\n%s\n' "$have" "$need" | LC_ALL=C sort -V 2>/dev/null | tail -1)"
  [ -n "$newest" ] || return 2
  [ "$newest" = "$have" ]
}

# -> the host's glibc version ("2.35") on stdout, non-zero when this host has no glibc to compare with
# (musl, macOS, Windows). Called DIRECTLY (not in `$(...)`) it also sets the two globals the refusal
# sentence needs - `WA_GLIBC_HOST_VALUE` (the same version) and `WA_GLIBC_HOST_FROM` (where it came
# from). A command substitution runs in a subshell, so a caller that wants the "where from" half calls this
# directly and reads the globals; a caller that wants only the number may substitute it.
#
# `ldd --version` first, as the mission and the node's own operators read it ("ldd (GNU libc) 2.44",
# "ldd (Ubuntu GLIBC 2.35-0ubuntu3.8) 2.35"); the first `<major>.<minor>` in its first line is the version,
# including on the distributions that put the package version after it. A musl `ldd` answers "musl libc
# ... Version 1.2.5": that is NOT a glibc version and is refused as "unknown" instead of compared, because a
# glibc-linked binary cannot run there at all and the exec proof downstream is the check that can say so.
#
# WA_GLIBC_HOST stands in for the probe in fixtures only (the same pattern as WA_BOOTSTRAP_LIBC in
# scripts/linux/bootstrap.sh): a test cannot change the libc of the machine it runs on, and a check that can
# only be tested on one glibc version is not tested.
wa_glibc_host_version() {
  local out
  WA_GLIBC_HOST_FROM=''
  WA_GLIBC_HOST_VALUE=''
  if [ -n "${WA_GLIBC_HOST:-}" ]; then
    WA_GLIBC_HOST_FROM='WA_GLIBC_HOST, a fixture stand-in for `ldd --version`'
    WA_GLIBC_HOST_VALUE="$WA_GLIBC_HOST"
    printf '%s\n' "$WA_GLIBC_HOST"
    return 0
  fi
  if command -v ldd >/dev/null 2>&1; then
    out="$(ldd --version 2>&1 | head -1)"
    case "$out" in
      *musl*|*Musl*) return 1 ;;
    esac
    out="$(printf '%s\n' "$out" | grep -o '[0-9][0-9]*\.[0-9][0-9]*' | head -1)"
    if [ -n "$out" ]; then
      WA_GLIBC_HOST_FROM='ldd --version'
      WA_GLIBC_HOST_VALUE="$out"
      printf '%s\n' "$out"
      return 0
    fi
  fi
  if command -v getconf >/dev/null 2>&1; then
    out="$(getconf GNU_LIBC_VERSION 2>/dev/null)"
    case "$out" in
      glibc\ [0-9]*)
        WA_GLIBC_HOST_FROM='getconf GNU_LIBC_VERSION'
        WA_GLIBC_HOST_VALUE="${out#glibc }"
        printf '%s\n' "${out#glibc }"
        return 0 ;;
    esac
  fi
  return 1
}

# <binary> [<label>] -> 0 when this host can run it, or when the question cannot be asked here (no file, no
# glibc symbol in it, a host whose libc is not glibc, or no version order on this host's `sort` - the
# exec/health proof downstream is the check that speaks for those). 3 when the binary needs a newer glibc
# than this host has: the refusal sentence is printed on STDOUT, both versions in it, for the caller to
# print in its own vocabulary. An "unknown" is a note on STDERR and an ALLOW, never a refusal.
#
# The callers do NOT swap, restart or record anything before this returns 0 - that is the whole point:
# "GLIBC_2.39 not found" arrives once per supervisor retry on a node that is already dead, and there is no
# remote channel left to send a correction through.
wa_glibc_guard() {
  local file="${1:-}" label need have covered
  [ -n "$file" ] && [ -f "$file" ] || return 0
  label="${2:-$(basename "$file")}"
  need="$(wa_glibc_max_symbol "$file")" || return 0
  [ -n "$need" ] || return 0
  # Called directly, never in `$(...)`: the "where from" half lives in a global (a substitution would be a
  # subshell and the refusal would have to guess the probe's name).
  wa_glibc_host_version >/dev/null || return 0
  have="$WA_GLIBC_HOST_VALUE"
  [ -n "$have" ] || return 0
  wa_glibc_covers "$have" "$need"
  covered=$?
  case "$covered" in
    0) return 0 ;;
    2)
      # Both versions are known and the comparison is not: that is "unknown", so the bytes are allowed
      # through and the note goes where the operator reads it (a caller captures STDOUT and discards an
      # allow). Nothing is worse than a check that refuses a binary it simply could not measure.
      printf 'glibc_floor_unknown: %s needs GLIBC_%s and this host has glibc %s (%s), but this host cannot compare the two (its sort has no -V), so it was allowed through; the exec/health proof downstream is the check that speaks for it\n' \
        "$label" "$need" "$have" "${WA_GLIBC_HOST_FROM:-ldd --version}" >&2
      return 0 ;;
  esac
  printf 'glibc_floor_exceeded: %s needs GLIBC_%s and this host has glibc %s (%s), so it was refused before anything was replaced and the installed binary was left alone. The artifact was linked against a newer libc than this node runs: publish it with a floor this fleet can run (cargo zigbuild --target <triple>.<floor>), or install a static musl build\n' \
    "$label" "$need" "$have" "${WA_GLIBC_HOST_FROM:-ldd --version}"
  return 3
}
# wa-glibc-floor-end

# The staging directory is beside the target, not in /tmp: a node whose /tmp is mounted `noexec` would
# refuse every binary as "does not run here", and the guard would cry wolf until nobody believed it.
stage_parent=$(dirname "$TARGET")
mkdir -p "$stage_parent" 2>/dev/null
tmp=$(mktemp -d "$stage_parent/.fleet-install.XXXXXX") || die "no_stage_dir"
trap 'rm -rf "$tmp"' EXIT

say "download $URL"
# Bounded and retried: 17/11 a download from the work container hung for 10 minutes on a stalled HTTP/2
# stream, and the install waited with it.
curl -fsSL --retry 4 --retry-all-errors --connect-timeout 20 --max-time "${DOWNLOAD_TIMEOUT:-300}" \
  -o "$tmp/wa" "$URL" || die "download_failed"

# 1. the bytes
if [ -n "$SHA" ]; then
  got=$(sha256sum "$tmp/wa" | cut -d' ' -f1)
  [ "$got" = "$SHA" ] || die "sha_mismatch got=$got want=$SHA"
  say "sha ok ($SHA)"
fi

# 2. who signed it (optional; nodes that pin a fleet-release key pass these three)
if [ -n "$SIG" ] && [ -n "$PUB" ]; then
  [ -n "$MANIFEST" ] || die "signature_given_without_manifest"
  probe="$tmp/verify.lua"
  cat > "$probe" <<'LUA'
local manifest = host.getenv('FI_MANIFEST') or ''
local signature = host.getenv('FI_SIG') or ''
local pubkey = host.getenv('FI_PUB') or ''
if manifest == '' or signature == '' or pubkey == '' then print('false') return end
print(tostring(host.verify(pubkey, manifest, signature)))
LUA
  # The verifier is the node's **own** binary, never the downloaded artifact: a binary must not be asked
  # to certify itself, and the installed one is the ed25519 implementation this node already trusts.
  verifier=$(command -v wa 2>/dev/null || echo "$TARGET")
  verified=$(FI_MANIFEST="$MANIFEST" FI_SIG="$SIG" FI_PUB="$PUB" \
    WA_SCRIPT="$probe" "$verifier" --db "$tmp/v.db" 2>/dev/null | tail -1)
  [ "$verified" = "true" ] || die "signature_invalid ($verified)"
  say "signature ok"
fi

# 3. the glibc floor this artifact was built for, against the libc this host runs
if ! glibc_refusal="$(wa_glibc_guard "$tmp/wa" "$(basename "$TARGET")")"; then
  die "$glibc_refusal — nothing was replaced"
fi

# 3b. does it run HERE, before anything is replaced
chmod +x "$tmp/wa"
if ! "$tmp/wa" --version >/dev/null 2>&1; then
  detail=$("$tmp/wa" --version 2>&1 | head -1)
  die "artifact_does_not_run_here: $detail — nothing was replaced"
fi
say "runs here: $("$tmp/wa" --version)"

# 3b. WHICH COMMIT ARE THESE BYTES, AND DO THEY CONTAIN WHAT IS RUNNING?
#
# The artifact's name is a claim; `wa --build-info` is the answer (rust/wa-host/build.rs). And an artifact
# that does not contain the commit the node runs now is a downgrade: it is refused by name, listing what
# would be lost, unless the operator says --force --reason <text> - which the record then carries.
CANDIDATE_COMMIT=""; CANDIDATE_TREE=""; CANDIDATE_DIRTY=""; RECORD_BUILD=absent
if CANDIDATE_INFO="$(wa_build_info "$tmp/wa")"; then
  RECORD_BUILD=yes
  CANDIDATE_COMMIT="$(wa_build_field "$CANDIDATE_INFO" commit)"
  CANDIDATE_TREE="$(wa_build_field "$CANDIDATE_INFO" tree)"
  CANDIDATE_DIRTY="$(wa_build_field "$CANDIDATE_INFO" dirty)"
  [ "$CANDIDATE_COMMIT" = unknown ] && CANDIDATE_COMMIT=""
fi
if [ -z "$CANDIDATE_COMMIT" ]; then
  say "WARNING: this artifact cannot report its own build (older than --build-info); the record will say commit=unknown rather than what this script meant to install"
else
  say "artifact reports its own build: ${CANDIDATE_COMMIT:0:12} (tree ${CANDIDATE_TREE:0:12}, dirty $CANDIDATE_DIRTY)"
fi
# WHAT IS RUNNING HERE, asked of the binary first and of the record only when the record is about THESE bytes
# (wa_running_identity, scripts/lib/install-record.sh). This script used to ask only the binary and treat "it
# cannot say" as free passage, so a node whose binary predates --build-info was replaced with no ancestry
# question at all, and a record naming another sha256 was never noticed.
wa_running_identity "$(dirname "$TARGET")"
RUNNING_COMMIT="$WA_RUNNING_COMMIT"; RUNNING_SOURCE="$WA_RUNNING_SOURCE"
RUNNING_WHY="$WA_RUNNING_WHY"; RUNNING_DIRTY="$WA_RUNNING_DIRTY"
if [ -z "$WA_RUNNING_BIN" ] && [ -x "$TARGET" ] && RUNNING_INFO="$(wa_build_info "$TARGET")"; then
  RUNNING_COMMIT="$(wa_build_field "$RUNNING_INFO" commit)"
  [ "$RUNNING_COMMIT" = unknown ] && RUNNING_COMMIT=""
  RUNNING_DIRTY="$(wa_build_field "$RUNNING_INFO" dirty)"; [ -n "$RUNNING_DIRTY" ] || RUNNING_DIRTY=unknown
  RUNNING_SOURCE="binary"; RUNNING_WHY="the running binary reports it"
fi
say "running here: ${RUNNING_COMMIT:-nothing that names a commit} (${RUNNING_SOURCE:-none}, dirty ${RUNNING_DIRTY})"
FORCE_REASON=""
[ "$FORCE" = 1 ] && FORCE_REASON="$REASON"
force_needs_reason() { # <what this artifact would lose>
  if [ "$FORCE" = 1 ] && [ -n "$FORCE_REASON" ]; then
    ANCESTRY_STATE=override
    say "OVERRIDE, recorded: $1; going on because --force --reason says so"
    say "force_requested reason=$FORCE_REASON by=$(id -un 2>/dev/null || echo unknown) at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
  fi
  return 1
}
ANCESTRY_STATE=unknown
if [ "$RUNNING_SOURCE" = record_mismatch ]; then
  # The record beside the running binary names another sha256: its commit= says nothing about what is running.
  if ! force_needs_reason "the install record is not these bytes"; then
    die "downgrade_unprovable(record_not_this_binary): $(dirname "$TARGET")/installed.txt names a sha256 that is not the running binary's, so the record says nothing about what is installed here ($RUNNING_WHY). Nothing was replaced. Pass --force --reason <text> and the override is recorded in installed.txt."
  fi
elif [ "$RUNNING_DIRTY" = true ]; then
  # Those bytes are a commit PLUS uncommitted edits: no commit anywhere contains them, and the ancestry
  # question below cannot see them at all.
  if ! force_needs_reason "the running binary reports dirty=true, so its bytes carry uncommitted work"; then
    die "downgrade_refused(dirty_running_binary): the running binary reports commit ${RUNNING_COMMIT:0:12} with dirty=true, so those bytes are a commit PLUS edits no commit contains - installing this artifact destroys them and no rollback brings them back. Nothing was replaced. Commit them in that tree and rebuild, or pass --force --reason <text> to lose them on purpose (recorded)."
  fi
elif [ -z "$RUNNING_COMMIT" ]; then
  # A FIRST INSTALL IS THE ONE FREE CASE, AND IT MEANS NOTHING IS INSTALLED (round-3 item 1). This used to be
  # "nothing names a commit", which is also true of a binary that predates --build-info beside a record with no
  # sha256= - so an install nothing could identify was replaced as if the directory were empty. The binary's own
  # presence is the test, not the silence about it.
  if wa_running_first_install && [ ! -e "$TARGET" ]; then
    say "nothing is installed at $TARGET - a first install, not a downgrade"
    ANCESTRY_STATE=first_install
  else
    if ! force_needs_reason "a binary is installed at $TARGET and nothing can prove which commit it is ($RUNNING_WHY)"; then
      die "refused(running_commit_unprovable): ${RUNNING_WHY:-the binary at $TARGET cannot name its own commit}. Something IS installed here and nothing can show whether this artifact contains it, so replacing it could remove work that exists nowhere else. Nothing was replaced. Make it answerable (write a record whose sha256= is the binary's: sha256sum < $TARGET), or pass --force --reason <text> and the override is recorded in installed.txt."
    fi
  fi
elif [ -z "$CANDIDATE_COMMIT" ]; then
  # The artifact cannot say which commit it is, so nothing can be compared. Unknown refuses.
  if ! force_needs_reason "the artifact cannot name its own commit, so it cannot be shown to contain what is running"; then
    die "refused(ancestry_unknown): this artifact cannot report its own build (it predates --build-info), so nothing can show it contains the running commit $RUNNING_COMMIT. Nothing was replaced. Publish (or fetch) an artifact built with the current build.rs, or pass --force --reason <text> and the override is recorded."
  fi
else
  wa_ancestry_verdict "" "$CANDIDATE_COMMIT" "$RUNNING_COMMIT" "$tmp/wa"
  case $? in
    0) ANCESTRY_STATE=yes
       say "ancestry ok: this artifact contains the running commit ${RUNNING_COMMIT:0:12}" ;;
    1) if ! force_needs_reason "this artifact does not contain the running commit ${RUNNING_COMMIT:0:12}"; then
         die "downgrade_refused: this artifact (${CANDIDATE_COMMIT:0:12}) does not contain the RUNNING commit ${RUNNING_COMMIT:0:12} (${WA_ANCESTRY_WHY:-reason unknown}) - installing it would remove work that is running now. Nothing was replaced. To go back on purpose: 'wa update <node> --rollback' (records a pin), or --force --reason <text>"
       fi ;;
    *) if ! force_needs_reason "nothing could establish whether this artifact goes backwards (${WA_ANCESTRY_WHY:-unknown})"; then
         die "refused(ancestry_unknown): nothing can establish whether this artifact goes backwards: ${WA_ANCESTRY_WHY:-the verdict answered nothing}. Nothing was replaced. Make it answerable (an artifact built by the current build.rs carries its own ancestry), or pass --force --reason <text> and the override is recorded."
       fi ;;
  esac
fi

PIN_TARGET="${CANDIDATE_COMMIT:-}"; PIN_TREE=""
# THE NODE'S OWN PIN. A pin in the coordinator's store gates requests made THROUGH the coordinator; an install
# started here never reads that store, so the node keeps its own copy (written by a rollback, see
# lua/core/remote_update.lua and scripts/lib/node-pins.sh) and it is read before anything is replaced.
# "Cannot tell" is not a release: only a target that IS the pinned commit, IS the awaited commit, or
# CONTAINS it releases the pin, and that release is said out loud.
# THE PIN IS READ, OR THE INSTALL IS REFUSED. This block used to be wrapped in
# "$if [ -n "${NODE_PIN_LIB:-}" ]" - so a copy of this script that could not find scripts/lib/node-pins.sh
# SKIPPED the pin, silently, which is the exact fail-open the lib exists to close (round-3 item 6). The loader at
# the top of this file already refuses a missing lib; this is the same rule at the point of use, so the two cannot
# drift apart. Nothing is replaced on an unreadable pin.
if command -v wa_node_pin_gate >/dev/null 2>&1; then
  NODE_NAME="$(wa_node_name)"
  PIN_STATE=0; PIN_REPORT="$(wa_node_pin_gate "$NODE_NAME" "" "${PIN_TARGET:-}" "${PIN_TREE:-}" 2>&1)" || PIN_STATE=$?
  [ -n "$PIN_REPORT" ] && say "$PIN_REPORT"
  if [ "$PIN_STATE" != 0 ]; then
    if [ "$FORCE" = 1 ] && [ -n "$REASON" ]; then
      ANCESTRY_STATE=override
      say "OVERRIDE, recorded: $NODE_NAME is pinned and this install does not release it; going on because --force --reason says so"
      say "force_requested rule=node_pinned reason=$REASON by=$(id -un 2>/dev/null || echo unknown) at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
      die "node_pinned: $NODE_NAME carries an active pin, so this install was refused - a pin is a record that the node was put somewhere on purpose, and an ordinary install is exactly what undoes it (measured 18/11: three hand-made rollbacks did not survive the next one). Nothing was replaced. $(wa_pin_escape "$NODE_NAME")"
    fi
  fi
else
  die "refused(node_pin_reader_missing): scripts/lib/node-pins.sh was not loaded, so nothing can read this node's own pin and this install could walk over a rollback nobody can see. Nothing was replaced. Ship the lib beside this script (or point WA_NODE_PINS_LIB at it)."
fi

# 4. backup and swap
backup="$TARGET.prev.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$TARGET" "$backup" 2>/dev/null || say "no previous binary to back up"
install -m755 "$tmp/wa" "$TARGET" || die "install_failed"
say "installed $TARGET (backup $backup)"

# 4b. the Lua tree beside the binary outranks the one compiled into it (wa-host main.rs "An installed Lua
# tree"): a binary install keeps the tree it finds, so the node runs the OLD Lua while `wa --version`
# reports the new build. 17/11: four installs of the codeact fix and every one of them executed commit
# 14963b6f's Lua - presence is not freshness, in the payload too. Move it aside; the way back is `mv`.
lua_dir="$(dirname "$TARGET")/lua-core"
if [ -f "$lua_dir/manifest.txt" ]; then
  stale="$lua_dir.stale.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$lua_dir" "$stale" || die "cannot_move_stale_lua_tree ($lua_dir)"
  say "moved aside the installed Lua tree ($(sed -n 's/^commit //p' "$stale/manifest.txt" | head -1)): $stale"
fi

# 5. restart, prove it, roll back if it does not
restart() {
  if [ -n "$UNIT" ]; then systemctl --user restart "$UNIT" 2>/dev/null || sudo -n systemctl restart "$UNIT" 2>/dev/null; fi
  if command -v pkill >/dev/null 2>&1; then pkill -f "wa serve --port 8799" 2>/dev/null; fi
}
restart
code=000
for _ in $(seq 1 "${HEALTH_WAIT:-150}"); do
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$HEALTH" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && break
  sleep 1
done
if [ "$code" != "200" ]; then
  say "UNHEALTHY after restart (last=$code) — rolling back"
  if [ -f "$backup" ]; then
    install -m755 "$backup" "$TARGET" && say "restored $backup"
    restart
    for _ in $(seq 1 "${HEALTH_WAIT:-150}"); do
      code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$HEALTH" 2>/dev/null || echo 000)
      [ "$code" = "200" ] && break
      sleep 1
    done
    [ "$code" = "200" ] && die "rolled_back_healthy_after_all (the artifact was refused)" \
                         || die "rolled_back_still_unhealthy: check $TARGET by hand"
  fi
  die "unhealthy_and_no_backup"
fi
# 6. the Lua the node actually loads has to be the one this artifact was built with. `mode()` answering
# nil for a mode the env declares is the signature of a tree (or a build) that predates the code: it is a
# check a healthy `/health` cannot make, and the reason a green install shipped a dead fix.
probe="$tmp/lua.lua"
cat > "$probe" <<'LUA'
local ok, raw = pcall(dofile, 'lua/core/raw_code.lua')
if not ok or type(raw) ~= 'table' or type(raw.native_run) ~= 'function' then print('unloadable') return end
-- ONE path (Victor 21/11): the run tool is the door, and the switch that used to choose a second one
-- is refused by name. A node whose env still exports it refuses every run, so the verdict says so.
local refusal = type(raw.switch_refusal) == 'function' and raw.switch_refusal() or nil
if refusal then print('ok_switch_still_set: this node exports ' .. tostring(refusal.value)
  .. ' and every run will refuse until it is removed') return end
print('ok')
LUA
verdict=$("$TARGET" --db "$tmp/l.db" >/dev/null 2>&1; WA_SCRIPT="$probe" "$TARGET" --db "$tmp/l.db" 2>/dev/null | tail -1)
case "$verdict" in
  ok*) say "lua matches this artifact ($verdict)" ;;
  *)
    say "LUA MISMATCH after install ($verdict) — rolling back"
    if [ -f "$backup" ]; then install -m755 "$backup" "$TARGET"; fi
    if [ -n "${stale:-}" ] && [ -d "$stale" ]; then mv "$stale" "$lua_dir"; fi
    restart
    die "rolled_back_lua_mismatch: $verdict"
    ;;
esac

# 7. the record, written FROM the binary that is now installed. This script installed bytes and cannot say
# which commit they are; the binary can (rust/wa-host/build.rs), and a record written from anything else is the
# belief that made an installed.txt say commit=14963b6f for other bytes on 18/11.
record_dir="$(dirname "$TARGET")"
{
  [ -n "${CANDIDATE_COMMIT:-}" ] && printf 'source_commit=%s\n' "$CANDIDATE_COMMIT"
  printf 'artifact_url=%s\n' "$URL"
  [ -n "$SHA" ] && printf 'artifact_sha256=%s\n' "$SHA"
  printf 'previous_binary=%s\n' "${backup:-none}"
  printf 'ancestry=%s\n' "$ANCESTRY_STATE"
  [ "$ANCESTRY_STATE" = override ] && printf 'ancestry_override=%s\nancestry_override_by=%s\n' "$(printf '%s' "$REASON" | tr '\r\n' '  ')" "$(id -un 2>/dev/null || echo unknown)"
  printf 'via=fleet-install.sh\nat=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  true
} > "$tmp/record_extra" 2>/dev/null || true
mapfile -t RECORD_EXTRA < "$tmp/record_extra" 2>/dev/null || RECORD_EXTRA=()
wa_record_install "$record_dir" "$TARGET" "${RECORD_EXTRA[@]}" \
  || say "the binary is installed and healthy, but installed.txt was not rewritten: it still names the previous pair"
say "healthy (200) — installed $(basename "$TARGET") from $URL (record: $(sed -n 's/^commit=//p' "$record_dir/installed.txt" 2>/dev/null | head -1))"
