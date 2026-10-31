#!/usr/bin/env bash
# Fixture suite for the Linux release channel (scripts/linux/bootstrap.sh): index parse, the
# architecture pick, every hash refusal, the foreign-install refusal, --check, and the idempotent
# re-run. No network and no systemd: real bundles built from local files, `file:` index URLs under the
# explicit WA_LINUX_RELEASE_ALLOW_LOCAL=1 opt-in, a fake pinned Node, and --no-service.
# The binaries are /bin/true - an ELF of this machine that answers `--version` - so the ELF and
# "candidate runs" checks are real; a real `wa` is proven by the end-to-end run, not here.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BOOT="$ROOT/scripts/linux/bootstrap.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-linux-release-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
# The installer writes its config under WASM_AGENT_HOME when set; the gate exports one, so the fixture's
# own HOME is the only home here (30/10: the gate found the config in its home, not the fixture's).
unset WASM_AGENT_HOME
pass=0; failed=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -5 | sed 's/^/     /'; }
case "$(uname -m)" in aarch64|arm64) TARGET=aarch64-unknown-linux-gnu; OTHER=x86_64-unknown-linux-gnu ;; *) TARGET=x86_64-unknown-linux-gnu; OTHER=aarch64-unknown-linux-gnu ;; esac
MUSL=${TARGET%-gnu}-musl
NODEV=24.22.1
COMMIT=0123456789abcdef0123456789abcdef01234567

mkbundle() { # NAME [tamper] [target] -> prints manifest sha; archive at $T/NAME.tar.gz
  local name=$1 dir="$T/src/$1" btarget=${3:-$TARGET} bin=/bin/true; rm -rf "$dir"; mkdir -p "$dir/ui" "$dir/scripts"
  [ "${2:-}" = norun ] && bin=/bin/false
  cp "$bin" "$dir/wa"; cp /bin/true "$dir/wa-sentinel"; echo '<html>' > "$dir/ui/index.html"; echo '//' > "$dir/scripts/mcp-web.mjs"
  ( cd "$dir" && find . -type f ! -name files.sha256 -printf '%P\n' | LC_ALL=C sort | while read -r f; do sha256sum -- "$f"; done ) > "$dir/files.sha256"
  printf 'schema=wa-linux-bundle/1\nsource_commit=%s\ntarget_triple=%s\nnode_version=%s\nwa_version=fixture\nfiles_sha256=%s\n' \
    "$COMMIT" "$btarget" "$NODEV" "$(sha256sum "$dir/files.sha256" | cut -d' ' -f1)" > "$dir/bundle.manifest"
  case "${2:-}" in member) echo tampered >> "$dir/ui/index.html" ;; elf) printf 'not an elf at all, padded to be long enough' > "$dir/wa-sentinel" ;; esac
  tar -C "$T/src" -czf "$T/$name.tar.gz" "$name"
  sha256sum "$dir/bundle.manifest" | cut -d' ' -f1
}
mkindex() { # FILE ENTRIES_JSON
  printf '{"schema":"wasm-agent-linux-release-index","schema_version":1,"releases":[%s]}\n' "$2" > "$1"
}
entry() { # NAME SHA TARGET [size]
  local size=${4:-$(wc -c < "$T/$1.tar.gz" | tr -d ' ')}
  printf '{"tag":"v0.0.0-test","commit":"%s","target":"%s","manifest_sha256":"%s","url":"file://%s","size":%s,"node_version":"%s"}' \
    "$COMMIT" "$3" "$2" "$T/$1.tar.gz" "$size" "$NODEV"
}
run() { # INDEX PREFIX [args...] -> output in $out, status in $rc
  local index=$1 prefix=$2; shift 2
  out=$(HOME="$T/home" XDG_CACHE_HOME="$T/cache" WA_LINUX_RELEASE_ALLOW_LOCAL=1 bash "$BOOT" --index "file://$index" \
        --prefix "$prefix" --no-service --rendezvous none --port 59997 --client-port 59998 "$@" 2>&1); rc=$?
}
fakenode() { mkdir -p "$1/node/bin"; printf '#!/bin/sh\necho v%s\n' "$NODEV" > "$1/node/bin/node"; chmod +x "$1/node/bin/node"; }
mkdir -p "$T/home"

good=$(mkbundle good)

# index parse
echo '{"schema":"something-else","schema_version":1,"releases":[]}' > "$T/i-schema.json"
run "$T/i-schema.json" "$T/p0"; [ $rc -ne 0 ] && grep -q index_invalid <<<"$out" && ok 'a foreign schema is refused by name (index_invalid)' || bad 'index schema refusal' "$out"
echo 'not json' > "$T/i-garbage.json"
run "$T/i-garbage.json" "$T/p0"; [ $rc -ne 0 ] && grep -q index_invalid <<<"$out" && ok 'an unparseable index is refused' || bad 'garbage index' "$out"
run "$T/missing.json" "$T/p0"; [ $rc -ne 0 ] && grep -q index_unreachable <<<"$out" && ok 'an unreachable index is refused' || bad 'missing index' "$out"
mkindex "$T/i-local.json" "$(entry good "$good" "$TARGET")"
out=$(HOME="$T/home" XDG_CACHE_HOME="$T/cache" bash "$BOOT" --index "file://$T/i-local.json" --prefix "$T/p0" --no-service --rendezvous none 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q local_url_refused <<<"$out" && ok 'file: URLs need the explicit local opt-in' || bad 'file: opt-in' "$out"

# architecture pick
mkindex "$T/i-other.json" "$(entry good "$good" "$OTHER")"
run "$T/i-other.json" "$T/p0"; [ $rc -ne 0 ] && grep -q no_release_for_target <<<"$out" && ok "only another target published: no_release_for_target" || bad 'arch refusal' "$out"
mkindex "$T/i-mixed.json" "$(entry good "$good" "$OTHER"),$(entry good "$good" "$TARGET")"
run "$T/i-mixed.json" "$T/p0" --check; [ $rc -eq 0 ] && grep -q "for $TARGET" <<<"$out" && ok 'the newest entry for this machine is picked past another target' || bad 'arch pick' "$out"
[ ! -e "$T/p0/wa" ] && ok '--check installs nothing' || bad '--check wrote files'

# hash refusals: nothing installed after any of them
mkindex "$T/i-badsha.json" "$(entry good "$(printf '%064d' 0)" "$TARGET")"
run "$T/i-badsha.json" "$T/p1"; [ $rc -ne 0 ] && grep -q 'hash_mismatch: bundle.manifest' <<<"$out" && [ ! -e "$T/p1/wa" ] && ok 'a manifest hash the index does not record is refused; nothing installed' || bad 'manifest hash refusal' "$out"
mkindex "$T/i-size.json" "$(entry good "$good" "$TARGET" 12)"
run "$T/i-size.json" "$T/p1"; [ $rc -ne 0 ] && grep -q download_truncated <<<"$out" && ok 'a size other than the index records is refused (download_truncated)' || bad 'size refusal' "$out"
member=$(mkbundle member member)
mkindex "$T/i-member.json" "$(entry member "$member" "$TARGET")"
run "$T/i-member.json" "$T/p1"; [ $rc -ne 0 ] && grep -q 'hash_mismatch: a bundle member' <<<"$out" && [ ! -e "$T/p1/wa" ] && ok 'a tampered member is refused even with a matching manifest' || bad 'member refusal' "$out"
elfb=$(mkbundle elfbad elf)
# the elf-tampered bundle must still pass the member hashes to reach the ELF check: rebuild its sums
( cd "$T/src/elfbad" && find . -type f ! -name bundle.manifest ! -name files.sha256 -printf '%P\n' | LC_ALL=C sort | while read -r f; do sha256sum -- "$f"; done ) > "$T/src/elfbad/files.sha256"
sed -i "s/^files_sha256=.*/files_sha256=$(sha256sum "$T/src/elfbad/files.sha256" | cut -d' ' -f1)/" "$T/src/elfbad/bundle.manifest"
tar -C "$T/src" -czf "$T/elfbad.tar.gz" elfbad; elfb=$(sha256sum "$T/src/elfbad/bundle.manifest" | cut -d' ' -f1)
mkindex "$T/i-elf.json" "$(entry elfbad "$elfb" "$TARGET")"
run "$T/i-elf.json" "$T/p1"; [ $rc -ne 0 ] && grep -q elf_machine_mismatch <<<"$out" && ok 'a binary that is not an ELF of this machine is refused' || bad 'ELF refusal' "$out"

# fresh install, then the idempotent re-run
fakenode "$T/p2"
mkindex "$T/i-good.json" "$(entry good "$good" "$TARGET")"
run "$T/i-good.json" "$T/p2"
if [ $rc -eq 0 ] && grep -q '^via=linux-bootstrap$' "$T/p2/installed.txt" && grep -q '^release=v0.0.0-test$' "$T/p2/installed.txt" \
   && [ -x "$T/p2/wa" ] && [ -f "$T/p2/ui/index.html" ] && [ -f "$T/p2/scripts/mcp-web.mjs" ]; then ok 'fresh install: files, ui/, scripts/ and installed.txt (via, release)'
else bad 'fresh install' "$out"; fi
grep -q "^WA_NODE=$T/p2/node/bin/node$" "$T/home/.wasm-agent/env" && ok 'WA_NODE points at the pinned Node' || bad 'WA_NODE in env' "$(cat "$T/home/.wasm-agent/env" 2>/dev/null)"
before=$(stat -c %Y.%i "$T/p2/wa")
sleep 1
run "$T/i-good.json" "$T/p2"
[ $rc -eq 0 ] && grep -q 'install .*: current' <<<"$out" && [ "$(stat -c %Y.%i "$T/p2/wa")" = "$before" ] \
  && ok 're-run with the same bundle: current, nothing replaced' || bad 'idempotent re-run' "$out"
[ "$(grep -c '^WA_NODE=' "$T/home/.wasm-agent/env")" = 1 ] && ok 'config keys are written once' || bad 'config duplicated'

# any libc (30/10): the static musl entry is preferred over a glibc-linked one, the detection is printed,
# Node follows the libc, and a binary that cannot run says why instead of guessing
musl=$(mkbundle musl '' "$MUSL")
mkindex "$T/i-libc.json" "$(entry good "$good" "$TARGET"),$(entry musl "$musl" "$MUSL")"
run "$T/i-libc.json" "$T/p4" --check; [ $rc -eq 0 ] && grep -q "for $MUSL" <<<"$out" && ok 'the static musl entry is picked over a glibc-linked one' || bad 'musl preference' "$out"
grep -q "^bootstrap: detected: .*-> bundle $MUSL, Node " <<<"$out" && ok 'one line names the detected arch/libc and the choice' || bad 'detected line' "$out"
run "$T/i-good.json" "$T/p0" --check; [ $rc -eq 0 ] && grep -q "for $TARGET" <<<"$out" && ok 'an index with only a glibc-linked entry still installs it (back-compat)' || bad 'gnu back-compat' "$out"
out=$(WA_BOOTSTRAP_LIBC='glibc 2.17' HOME="$T/home5" XDG_CACHE_HOME="$T/cache" WA_LINUX_RELEASE_ALLOW_LOCAL=1 bash "$BOOT" --index "file://$T/i-libc.json" \
      --prefix "$T/p5" --no-service --rendezvous none --port 59997 --client-port 59998 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q 'node_runtime_skipped: glibc 2.17 is older than Node' <<<"$out" && [ -x "$T/p5/wa" ] && ! grep -q '^WA_NODE=' "$T/home5/.wasm-agent/env" 2>/dev/null \
  && ok 'glibc older than Node 2.28: the node installs, Node is skipped by name, no WA_NODE' || bad 'old glibc node skip' "$out"
norun=$(mkbundle norun norun "$MUSL")
mkindex "$T/i-norun.json" "$(entry norun "$norun" "$MUSL")"
run "$T/i-norun.json" "$T/p6"; [ $rc -ne 0 ] && grep -q "candidate_does_not_run: wa --version failed on this machine (.*bundle $MUSL)" <<<"$out" && [ ! -e "$T/p6/wa" ] \
  && ok 'a binary that cannot run is refused with the libc and bundle named; nothing installed' || bad 'candidate refusal' "$out"

# an install this script did not make
mkdir -p "$T/p3"; cp /bin/true "$T/p3/wa"; printf 'commit=deadbeef\nvia=deploy.sh\n' > "$T/p3/installed.txt"
run "$T/i-good.json" "$T/p3"; [ $rc -ne 0 ] && grep -q existing_install_not_ours <<<"$out" && ok 'a deploy-managed install is refused' || bad 'foreign refusal' "$out"
fakenode "$T/p3"
run "$T/i-good.json" "$T/p3" --adopt; [ $rc -eq 0 ] && grep -q '^via=linux-bootstrap$' "$T/p3/installed.txt" && ls -d "$T"/p3.pre-bootstrap-* >/dev/null 2>&1 \
  && ok '--adopt backs the old install up, then installs' || bad '--adopt' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" = 0 ] && echo 'ALL PASS' || { echo 'FAIL'; exit 1; }
