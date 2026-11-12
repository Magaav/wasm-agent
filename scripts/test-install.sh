#!/usr/bin/env bash
# The front door (scripts/install.sh): which platform it thinks it is, which channel that maps to, what it
# hands the core, and that install -> update -> rollback is ONE path through it.
#
#   bash scripts/test-install.sh
#
# No network and no systemd. Two kinds of fixture:
#   * a stub core, to read the DECISION (which core path, which arguments, which refusal) without running
#     an installer at all - that is what the platform matrix is, and it must be provable on one host;
#   * the real core, pointed at `file:` indexes and bundles built here, to run the whole chain
#     (verify -> install -> re-run -> update -> rollback) against real bytes. The bundle's `wa` is
#     /bin/true - an ELF of this machine that answers `--version` - so the ELF and "candidate runs" checks
#     are real; a real `wa` binary is exercised by the measured install (docs/INSTALL.md), not here.
#
# The map of what is pinned, one line each:
#   * Linux/macOS/Windows/MSYS/unknown OS and x86_64/aarch64/unknown arch -> the channel or the refusal;
#   * macOS and Windows are refused BY NAME, before a download, and name what to run instead;
#   * --join maps to the core's --rendezvous (a fleet join, never a binding consent);
#   * the core is fetched from the COMMIT THE INDEX ENTRY NAMES, and installer_sha256 is checked when the
#     entry carries it (mismatch installs nothing and the core never runs);
#   * prerequisites are named before anything is downloaded;
#   * the core's own refusal is propagated (exit code and words unchanged);
#   * install -> re-run (idempotent, bytes unchanged) -> update to the next release (bytes change, the
#     replaced pair is kept) -> --rollback (the previous pair is back, and the record says what happened);
#   * a tampered bundle is refused by the core's own name and the installed version does not move;
#   * WA_OFFLINE=1 and a file: base without the opt-in are refusals, not downloads.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FRONT="$ROOT/scripts/install.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-install-test.XXXXXX") || { printf 'FAIL tmpdir_unavailable: cannot create a temp dir under %s (set TMPDIR)\n' "${TMPDIR:-/tmp}" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
if ! ( cp /bin/true "$T/.exec-probe" && "$T/.exec-probe" ) >/dev/null 2>&1; then
  printf 'FAIL tmpdir_noexec: %s cannot execute a file; set TMPDIR to a normal filesystem (not a noexec mount)\n' "$T" >&2
  exit 1
fi
rm -f "$T/.exec-probe"
# The front door reads HOME for its default prefix and the core writes <home>/.wasm-agent: the fixture's
# home is the only one this suite may touch.
unset WASM_AGENT_HOME
pass=0; failed=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -6 | sed 's/^/     /'; }

case "$(uname -m)" in aarch64|arm64) TARGET=aarch64-unknown-linux-gnu ;; *) TARGET=x86_64-unknown-linux-gnu ;; esac
ARCH=${TARGET%%-*}
OTHER_ARCH=$([ "$ARCH" = x86_64 ] && echo aarch64 || echo x86_64)
NODEV=24.22.1
COMMIT=0123456789abcdef0123456789abcdef01234567
COMMIT2=89abcdef0123456789abcdef0123456789abcdef
mkdir -p "$T/home" "$T/cache"

# ---- fixtures --------------------------------------------------------------------------------------
# A `uname` on PATH, because the platform matrix is the one thing the front door cannot be asked to guess
# and a runner cannot fake any other way.
mkdir -p "$T/bin"
cat > "$T/bin/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FAKE_UNAME_M:-x86_64}" ;;
  -o) printf '%s\n' "${FAKE_UNAME_O:-GNU/Linux}" ;;
  *)  printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
esac
SH
chmod +x "$T/bin/uname"

# A stub core: records the arguments it was handed and exits with $STUB_EXIT, so a refusal that happened
# BEFORE the core ran is visibly different from one the core produced.
mkstub() { # <dir> <relative path>
  mkdir -p "$(dirname "$1/$2")"
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_OUT:-/dev/null}"
exit "${STUB_EXIT:-0}"
SH
  chmod +x "$1/$2"
}

# A bundle of real shape: one top-level dir, files.sha256 over every member, bundle.manifest over that.
mkbundle() { # NAME TAG COMMIT [append-bytes] -> prints the manifest sha256; archive at $T/NAME.tar.gz
  local name=$1
  local tag=$2
  local commit=$3
  local extra=${4:-}
  local dir="$T/src/$name"
  rm -rf "$dir"; mkdir -p "$dir/ui" "$dir/scripts/linux"
  cp /bin/true "$dir/wa"; cp /bin/true "$dir/wa-sentinel"
  # A second release must differ in its BYTES, or "the update happened" could pass without a swap.
  [ -n "$extra" ] && printf '%s' "$extra" >> "$dir/wa"
  printf '<html>\n' > "$dir/ui/index.html"
  printf '//\n' > "$dir/scripts/mcp-web.mjs"
  cp "$FRONT" "$dir/scripts/install.sh"
  ( cd "$dir" && find . -type f ! -name files.sha256 ! -name bundle.manifest -printf '%P\n' | LC_ALL=C sort \
      | while IFS= read -r f; do sha256sum -- "$f"; done ) > "$dir/files.sha256"
  printf 'schema=wa-linux-bundle/1\nsource_commit=%s\ntarget_triple=%s\nnode_version=%s\nwa_version=fixture-%s\nfiles_sha256=%s\n' \
    "$commit" "$TARGET" "$NODEV" "$tag" "$(sha256sum "$dir/files.sha256" | cut -d' ' -f1)" > "$dir/bundle.manifest"
  tar -C "$T/src" -czf "$T/$name.tar.gz" "$name"
  sha256sum "$dir/bundle.manifest" | cut -d' ' -f1
}
entry() { # NAME TAG COMMIT SHA [target] [pin] -> one JSON object
  local name=$1
  local tag=$2
  local commit=$3
  local sha=$4
  local target=${5:-$TARGET}
  local pin=${6:-}
  printf '{"tag":"%s","commit":"%s","target":"%s","manifest_sha256":"%s","url":"file://%s/%s.tar.gz","size":%s,"node_version":"%s"%s}' \
    "$tag" "$commit" "$target" "$sha" "$T" "$name" "$(wc -c < "$T/$name.tar.gz" | tr -d ' ')" "$NODEV" \
    "${pin:+,\"installer_sha256\":\"$pin\"}"
}
mkindex() { # FILE ENTRIES...
  local file=$1; shift
  printf '{"schema":"wasm-agent-linux-release-index","schema_version":1,"releases":[%s]}\n' "$(IFS=,; printf '%s' "$*")" > "$file"
}
fakenode() { mkdir -p "$1/node/bin"; printf '#!/bin/sh\nprintf v%s\n' "$NODEV" > "$1/node/bin/node"; chmod +x "$1/node/bin/node"; }

# The network half of the fixtures: a base tree shaped like raw.githubusercontent.com, one directory per
# commit, each holding the REAL core and the index the front door reads. `file:` bases need the explicit
# opt-in the front door documents.
mkbase() { # DIR COMMIT INDEXFILE...
  local dir=$1 commit=$2; shift 2
  mkdir -p "$dir/$commit/scripts/linux" "$dir/$commit/releases" "$dir/main/releases"
  cp "$ROOT/scripts/linux/bootstrap.sh" "$dir/$commit/scripts/linux/bootstrap.sh"
  cp "$FRONT" "$dir/$commit/scripts/install.sh"
  local f
  for f in "$@"; do
    cp "$f" "$dir/$commit/releases/index-linux.json"
    cp "$f" "$dir/main/releases/index-linux.json"
  done
}

front() { # [env...] -- <args...>   -> $out / $rc
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  out=$(env HOME="$T/home" PATH="$T/bin:$PATH" "${envs[@]}" sh "$FRONT" "$@" 2>&1); rc=$?
}

# ---- 0. the command is the documented command -----------------------------------------------------
# One line in the README, the same line in this file's own header: a front door nobody can find is the
# state this change exists to end.
README_LINE='curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh'
grep -qF "$README_LINE" "$ROOT/README.md" && ok 'the README documents the one-command install' \
  || bad 'README does not document the one-command install'
grep -qF "$README_LINE" "$FRONT" && ok 'and the installer header documents the same command' \
  || bad 'install.sh header does not carry the documented command line'
grep -qF 'docs/INSTALL.md' "$ROOT/README.md" && ok 'the README points at the design and research notes' \
  || bad 'README does not point at docs/INSTALL.md'

# The Node pin: this file stopped downloading Node itself, and two other files read the pin OUT of it
# (release-linux.sh stamps the bundle manifest and the index entry; build-requirements.sh provisions the
# toolchain). Dropping the line with the rewrite broke both - so the line, and its readers, are pinned here.
PIN=$(sed -n 's/^NODE_VERSION="\([0-9.]*\)"/\1/p' "$FRONT" | head -1)
[ -n "$PIN" ] && ok "the Node pin is still in install.sh ($PIN)" || bad 'install.sh lost NODE_VERSION'
grep -q 'NODE_VERSION=' "$ROOT/scripts/release-linux.sh" && grep -q 'NODE_VERSION=' "$ROOT/scripts/lib/build-requirements.sh" \
  && ok 'and both readers still name it' || bad 'the Node pin readers are not both present'

# ====================================================================================================
# 1. the platform matrix: which channel, or which named refusal
# ====================================================================================================
say_matrix() { # label uname_s uname_m prefix -> sets $out/$rc
  local label=$1 s=$2 m=$3 prefix=${4:-}
  out=$(env HOME="$T/home" PATH="$T/bin:$PATH" FAKE_UNAME_S="$s" FAKE_UNAME_M="$m" PREFIX="$prefix" \
        WA_INSTALL_BASE="file://$T/empty-base" WA_INSTALL_ALLOW_LOCAL=1 \
        sh "$FRONT" --check --no-service 2>&1); rc=$?
}

say_matrix 'linux x86_64' Linux x86_64
if printf '%s' "$out" | grep -q 'channel: linux bundle'; then
  ok 'linux/x86_64 -> the Linux bundle channel'
else bad 'linux/x86_64 chooses the Linux channel' "$out"; fi
# The channel is chosen before any network use: with an empty base the failure is about the index, not the OS.
if printf '%s' "$out" | grep -q 'index_unreachable'; then ok 'the Linux channel is chosen before any download'
else bad 'linux/x86_64 fails at the index, not at the platform' "$out"; fi

say_matrix 'linux aarch64' Linux aarch64
if printf '%s' "$out" | grep -q 'channel: linux bundle'; then ok 'linux/aarch64 -> the Linux bundle channel'
else bad 'linux/aarch64' "$out"; fi

say_matrix 'android via PREFIX' Linux aarch64 /data/data/com.termux/files/usr
if printf '%s' "$out" | grep -q 'channel: Termux preview' && printf '%s' "$out" | grep -q 'scripts/termux/bootstrap.sh'; then
  ok 'Termux (PREFIX=com.termux) -> the phone channel and its core'
else bad 'android detection' "$out"; fi

say_matrix 'android via uname -s' Linux aarch64 ''
out=$(env HOME="$T/home" PATH="$T/bin:$PATH" FAKE_UNAME_S=Android FAKE_UNAME_M=aarch64 \
      WA_INSTALL_BASE="file://$T/empty-base" WA_INSTALL_ALLOW_LOCAL=1 sh "$FRONT" --check 2>&1); rc=$?
if printf '%s' "$out" | grep -q 'channel: Termux preview'; then ok 'uname -s Android -> the phone channel'
else bad 'android via uname' "$out"; fi

say_matrix 'macos' Darwin arm64
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'no_published_bundle_for_macos'; then
  ok 'macOS is refused by name (no published bundle)'
else bad 'macOS refusal' "$out"; fi
if printf '%s' "$out" | grep -q 'scripts/deploy.sh'; then ok 'and names what to run instead'
else bad 'macOS refusal names the alternative' "$out"; fi

out=$(env HOME="$T/home" PATH="$T/bin:$PATH" FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64 sh "$FRONT" --check 2>&1); rc=$?
if [ "$rc" != 0 ] && ! printf '%s' "$out" | grep -q 'index_unreachable'; then ok 'macOS is refused before any download'
else bad 'macOS refused without touching the network' "$out"; fi

say_matrix 'windows (msys)' MINGW64_NT-10.0 x86_64
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'no_published_bundle_for_windows' && printf '%s' "$out" | grep -q 'install.ps1'; then
  ok 'Windows is refused by name and points at install.ps1'
else bad 'Windows refusal' "$out"; fi

say_matrix 'unknown os' Plan9 x86_64
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'os_unsupported'; then ok 'an unknown OS is os_unsupported'
else bad 'unknown OS refusal' "$out"; fi

say_matrix 'unknown arch' Linux riscv64
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'arch_unsupported'; then ok 'an unknown architecture is arch_unsupported'
else bad 'unknown arch refusal' "$out"; fi

# ====================================================================================================
# 2. what the core is handed, and what happens when the pin does not match
# ====================================================================================================
STUB="$T/stub"
mkstub "$STUB" scripts/linux/bootstrap.sh
mkstub "$STUB" scripts/termux/bootstrap.sh
STUB_SHA=$(sha256sum "$STUB/scripts/linux/bootstrap.sh" | cut -d' ' -f1)
: > "$T/stub.log"
mkdir -p "$T/stub-index"
# The front door reads the index to learn WHICH commit to take the core from, so the stub base needs one.
good=$(mkbundle good v0.0.0-test "$COMMIT")
mkindex "$T/stub-index/index.json" "$(entry good v0.0.0-test "$COMMIT" "$good" "$TARGET" "$STUB_SHA")"
mkbase "$T/stubbase" "$COMMIT" "$T/stub-index/index.json" 2>/dev/null || true
# …but the stub core, not the real one, is what must run: overwrite the copy mkbase placed.
mkstub "$T/stubbase/$COMMIT" scripts/linux/bootstrap.sh

front STUB_OUT="$T/stub.log" WA_INSTALL_BASE="file://$T/stubbase" WA_INSTALL_ALLOW_LOCAL=1 \
  -- --check --join https://rendezvous.example.invalid --prefix "$T/p0" --port 59997 --client-port 59998 --no-service >/dev/null 2>&1
args=$(cat "$T/stub.log")
eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', wanted '$3')"; }
eq 'the stub core ran and the front door exited 0' "$rc" 0
case "$args" in *"--rendezvous https://rendezvous.example.invalid"*) ok '--join becomes the core --rendezvous (a fleet join, not a consent)' ;;
  *) bad '--join mapping' "$args" ;; esac
case "$args" in *"--check"*) ok '--check is passed to the core' ;; *) bad '--check forwarding' "$args" ;; esac
case "$args" in *"--prefix $T/p0"*) ok 'the prefix the operator named is the prefix the core installs to' ;; *) bad 'prefix forwarding' "$args" ;; esac
case "$args" in *"--no-service"*) ok '--no-service is passed through' ;; *) bad '--no-service forwarding' "$args" ;; esac
case "$args" in *"--port 59997 --client-port 59998"*) ok 'ports are passed through in order' ;; *) bad 'port forwarding' "$args" ;; esac

: > "$T/stub.log"
front STUB_OUT="$T/stub.log" WA_INSTALL_BASE="file://$T/stubbase" WA_INSTALL_ALLOW_LOCAL=1 -- --port 59997 >/dev/null 2>&1
args=$(cat "$T/stub.log")
case "$args" in *"--rendezvous"*) bad 'no --join means no rendezvous argument' "$args" ;; *) ok 'no --join means no rendezvous argument' ;; esac

# A wrong pin installs nothing and does not run the core at all.
: > "$T/stub.log"
mkindex "$T/stub-index/badpin.json" "$(entry good v0.0.0-test "$COMMIT" "$good" "$TARGET" "0000000000000000000000000000000000000000000000000000000000000000")"
mkbase "$T/badpinbase" "$COMMIT" "$T/stub-index/badpin.json"
mkstub "$T/badpinbase/$COMMIT" scripts/linux/bootstrap.sh
front STUB_OUT="$T/stub.log" WA_INSTALL_BASE="file://$T/badpinbase" WA_INSTALL_ALLOW_LOCAL=1 -- --check >/dev/null 2>&1
[ "$rc" != 0 ] && ok 'a wrong installer pin exits non-zero' || bad 'wrong pin exit'
if printf '%s' "$out" | grep -q 'installer_hash_mismatch'; then ok 'and names installer_hash_mismatch'; else bad 'wrong pin refusal name' "$out"; fi
[ -s "$T/stub.log" ] && bad 'the core must not run when the pin does not match' "$(cat "$T/stub.log")" || ok 'the core never ran under a wrong pin'

# No entry for this machine's architecture: the index's own word, before anything is downloaded.
mkindex "$T/stub-index/otherarch.json" "$(entry good v0.0.0-test "$COMMIT" "$good" "$OTHER_ARCH-unknown-linux-gnu")"
mkdir -p "$T/otherarchbase/main/releases"; cp "$T/stub-index/otherarch.json" "$T/otherarchbase/main/releases/index-linux.json"
front WA_INSTALL_BASE="file://$T/otherarchbase" WA_INSTALL_ALLOW_LOCAL=1 -- --check >/dev/null 2>&1
[ "$rc" != 0 ] && ok 'only another architecture published -> non-zero' || bad 'other-arch exit'
if printf '%s' "$out" | grep -q 'no_release_for_target'; then ok 'and the index names no_release_for_target'; else bad 'other-arch refusal' "$out"; fi

# Unparseable index: refused by name, not by a crash.
mkdir -p "$T/garbagebase/main/releases"; printf 'not json\n' > "$T/garbagebase/main/releases/index-linux.json"
front WA_INSTALL_BASE="file://$T/garbagebase" WA_INSTALL_ALLOW_LOCAL=1 -- --check >/dev/null 2>&1
if printf '%s' "$out" | grep -q 'index_invalid'; then ok 'an unparseable index is index_invalid'; else bad 'garbage index refusal' "$out"; fi

# The network is never touched without being asked, and file: is never read without the opt-in.
front WA_OFFLINE=1 -- --check >/dev/null 2>&1
if printf '%s' "$out" | grep -q '^install: offline:'; then ok 'WA_OFFLINE=1 refuses before any request'; else bad 'offline refusal' "$out"; fi
out=$(env HOME="$T/home" PATH="$T/bin:$PATH" sh "$FRONT" --base "file://$T/stub-index" --check 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'local_url_refused'; then ok 'a file: base needs WA_INSTALL_ALLOW_LOCAL=1'
else bad 'file: opt-in refusal' "$out"; fi
front WA_INSTALL_BASE="file://$T/no-such-base" WA_INSTALL_ALLOW_LOCAL=1 -- --check >/dev/null 2>&1
if printf '%s' "$out" | grep -q 'index_unreachable'; then ok 'a base with no index is index_unreachable'; else bad 'unreachable index' "$out"; fi

# A core's refusal is propagated unchanged - exit code and words.
front WA_INSTALL_BASE="file://$T/stubbase" WA_INSTALL_ALLOW_LOCAL=1 STUB_EXIT=7 -- --check >/dev/null 2>&1
if [ "$rc" = 7 ] && printf '%s' "$out" | grep -q 'refused (exit 7)'; then ok "the core's exit code and refusal are propagated"
else bad 'core refusal propagation' "$out"; fi

# An option a channel cannot honour is refused, not dropped.
out=$(env HOME="$T/home" PATH="$T/bin:$PATH" FAKE_UNAME_S=Android FAKE_UNAME_M=aarch64 sh "$FRONT" --join https://x.invalid 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'join_unsupported_on_android'; then ok '--join on the phone channel is a named refusal'
else bad 'android join refusal' "$out"; fi

# ====================================================================================================
# 3. one path: install -> re-run -> update -> rollback, against the REAL core
# ====================================================================================================
# The real core is run with file: bundles. `--no-service` keeps systemd out of it, `WA_LINUX_RELEASE_INDEX_URL`
# points the core at the fixture index the front door's base names, and a fake Node keeps the MCP runtime
# step from downloading one.
P="$T/prefix"; fakenode "$P"
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
rec() { sed -n "s/^$1=//p" "$P/installed.txt" 2>/dev/null | head -1; }
real_front() { # base-index-url args...
  local index=$1; shift
  out=$(env HOME="$T/home" PATH="$T/bin:$PATH" WA_INSTALL_ALLOW_LOCAL=1 WA_LINUX_RELEASE_ALLOW_LOCAL=1 \
        WA_LINUX_RELEASE_INDEX_URL="file://$index" \
        sh "$FRONT" --base "file://$T/realbase" --prefix "$P" --no-service --rendezvous none \
        --port 59997 --client-port 59998 "$@" 2>&1); rc=$?
}
r1=$(mkbundle rel1 v0.0.0-test "$COMMIT")
mkindex "$T/i1.json" "$(entry rel1 v0.0.0-test "$COMMIT" "$r1")"
mkbase "$T/realbase" "$COMMIT" "$T/i1.json"

real_front "$T/i1.json"
[ "$rc" = 0 ] && ok "fresh install through the front door (exit $rc)" || bad 'fresh install' "$out"
[ -x "$P/wa" ] && ok 'the bundle binary is installed' || bad 'binary missing' "$out"
eq 'installed.txt names the release' "$(rec release)" v0.0.0-test
eq 'installed.txt says how it arrived' "$(rec via)" linux-bootstrap
eq 'and records the updater that came with it' "$(rec updater)" scripts/install.sh
[ -f "$P/scripts/install.sh" ] && ok 'the updater is installed beside the binary (a bundle member, verified with it)' \
  || bad 'updater not installed' "$(ls "$P/scripts" 2>/dev/null)"
wa_before=$(sha_of "$P/wa")

real_front "$T/i1.json"
[ "$rc" = 0 ] && ok 'a re-run is not an error (idempotent)' || bad 'idempotent re-run' "$out"
if printf '%s' "$out" | grep -q 'bootstrap: install .*: current'; then ok 'and says current rather than reinstalling'
else bad 're-run reports current' "$out"; fi
eq 'the binary was not rewritten' "$(sha_of "$P/wa")" "$wa_before"

# Release 2: same target, next commit, different bytes.
r2=$(mkbundle rel2 v0.0.0-test2 "$COMMIT2" '-second-release')
mkindex "$T/i2.json" "$(entry rel2 v0.0.0-test2 "$COMMIT2" "$r2")" "$(entry rel1 v0.0.0-test "$COMMIT" "$r1")"
mkbase "$T/realbase" "$COMMIT2" "$T/i2.json"
real_front "$T/i2.json"
[ "$rc" = 0 ] && ok 'update through the same command (exit 0)' || bad 'update' "$out"
eq 'the record moved to the new release' "$(rec release)" v0.0.0-test2
[ "$(sha_of "$P/wa")" != "$wa_before" ] && ok 'the installed bytes changed (the update really swapped them)' \
  || bad 'the binary did not change'
eq 'the replaced release is kept for rollback' "$(sed -n 's/^release=//p' "$P/.prev/installed.txt" 2>/dev/null | head -1)" v0.0.0-test
[ -f "$P/.prev/wa" ] && ok 'and its binary with it' || bad 'previous binary not kept'

real_front "$T/i1.json" --rollback
[ "$rc" = 0 ] && ok 'rollback (exit 0)' || bad 'rollback' "$out"
eq 'rollback put the previous bytes back' "$(sha_of "$P/wa")" "$wa_before"
eq 'and the record says so' "$(rec rollback_of)" v0.0.0-test2

# A tampered bundle is refused by the core's own name, and the installed version does not move.
r3=$(mkbundle rel3 v0.0.0-test3 "$COMMIT2")
bad_index=$(entry rel3 v0.0.0-test3 "$COMMIT2" "0000000000000000000000000000000000000000000000000000000000000000")
mkindex "$T/i3.json" "$bad_index"
mkbase "$T/realbase" "$COMMIT2" "$T/i3.json"
real_front "$T/i3.json" >/dev/null 2>&1
[ "$rc" != 0 ] && ok 'a bundle that does not match the index is refused (non-zero)' || bad 'checksum refusal exit'
if printf '%s' "$out" | grep -q 'hash_mismatch'; then ok 'and the core names hash_mismatch'; else bad 'checksum refusal name' "$out"; fi
eq 'nothing was installed by the refused update' "$(rec release)" v0.0.0-test

# Offline: the front door refuses by name instead of half-installing.
out=$(env HOME="$T/home" PATH="$T/bin:$PATH" WA_OFFLINE=1 sh "$FRONT" --update --prefix "$P" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^install: offline:' && ok 'an offline update refuses cleanly, by name' \
  || bad 'offline update refusal' "$out"
eq 'and leaves the install exactly as it was' "$(rec release)" v0.0.0-test

# ====================================================================================================
if [ "$failed" -gt 0 ]; then
  printf 'install front door: %s failed of %s checks\n' "$failed" "$((pass+failed))"
  exit 1
fi
printf 'install front door ok (%s checks)\n' "$pass"
