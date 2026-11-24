#!/usr/bin/env bash
# A release asset download that says WHY it failed, and that a slow minute does not kill (24/11).
#
# WHY. `wa update` on `work` (24/11 20:30Z) refused: the digest fallback chose the right release
# (node-9a0c589adfa0), then the 55.3 MB asset download "failed" and the deploy stopped. From the same host
# twenty-five minutes later the same asset arrived in 13.6 s. The line was
# `curl -fsSL -m 120 ... 2>/dev/null || node_release_unreachable` (scripts/lib/node-binaries.sh:531 before
# this change): `-m 120` caps the whole transfer, so 55 MB had to arrive faster than ~460 kB/s or the update
# refused, and `2>/dev/null` threw away the one fact that would have said whether it was slow, a 404 or a
# dropped connection.
#
# WHAT THIS ROW MEASURES, all against a LOCAL stub HTTP server (scripts/lib/http-stub.py on
# 127.0.0.1, no network, no fleet), through the real functions (wa_node_fetch_asset /
# wa_node_binary_download from scripts/lib/node-binaries.sh):
#   a. a 55 MB body served at 300 kB/s - a transfer that takes OVER 120 s - succeeds and verifies;
#   b. a connection dropped at 40% once: the next attempt resumes with `-C -`, the bytes match and the
#      signed release verifies;
#   c. a 404: ONE request, one refusal that names HTTP 404, and no URL in the line;
#   d. a stall (bytes then nothing): retried, then a refusal that names the stall, not "unreachable";
#   e. a resumed body with one wrong byte: refused by the manifest's sha256, by name, and the file is gone;
#   f. progress: the phase file a follower reads (scripts/lib/build-status.sh) carries
#      `downloading wa-<triple>: N of 55 MB` during (a), at most one line every few seconds.
#
# The rows that read a store create their own scratch home and refuse the operator's: `. scripts/lib/
# scratch-home.sh; wa_scratch_home_guard` (row at the top). The stub server is killed by PID at exit, never
# by pattern.
#
#   bash scripts/test-node-download.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# THE SCRATCH TREE IS NOT UNDER TMPDIR. A node session runs with TMPDIR inside its own store
# (~/.wasm-agent/tmp), and a scratch home under it is INSIDE the operator store - the guard below refused it
# (measured: refused(real_node_home)). /tmp is outside every node home, which is the point of this row.
WORK="$(mktemp -d /tmp/wa-node-download.XXXXXX)" || { echo 'no scratch directory' >&2; exit 1; }
STUB_PID=""
cleanup() {
  [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null
  [ -z "$STUB_PID" ] || wait "$STUB_PID" 2>/dev/null
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "node download FAILED: $*" >&2; exit 1; }
contains() { grep -qF -- "$2" <<< "$1" || fail "$3: '$2' not in: $1"; ok; }
absent() { grep -qF -- "$2" <<< "$1" && fail "$3: '$2' unexpectedly in: $1"; ok; }
expect_status() { [ "$2" = "$1" ] || fail "$3: expected status $1, got $2"; ok; }

# ---- a scratch node home, and a refusal when it is the operator's -----------------------------------
. "$ROOT/scripts/lib/scratch-home.sh"
SCRATCH_HOME="$WORK/home"
mkdir -p "$SCRATCH_HOME"
wa_scratch_home_guard "$SCRATCH_HOME" || { echo 'node download REFUSED: the scratch home is the operator node home' >&2; exit 2; }
export HOME="$SCRATCH_HOME" WASM_AGENT_HOME="$SCRATCH_HOME"
export WASM_AGENT_DATA="$SCRATCH_HOME/.wasm-agent"
mkdir -p "$WASM_AGENT_DATA"
case "$WASM_AGENT_DATA" in
  "$SCRATCH_HOME"/*) ;;
  *) fail "the node data directory is not inside the scratch home: $WASM_AGENT_DATA" ;;
esac
ok

command -v curl >/dev/null 2>&1 || { echo 'SKIP test-node-download: no curl on this host'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'SKIP test-node-download: no python3 for the stub server'; exit 0; }

. "$ROOT/scripts/lib/node-binaries.sh"
. "$ROOT/scripts/lib/build-status.sh"
# The signature gate's own fixtures: the TEST key that signs every fixture release below.
export WA_RELEASE_KEYS="$ROOT/tests/fixtures/release-sign/keys.txt"

# `gh` must never be reached by these rows: they all name an http base.
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh" 2>/dev/null || true
PATH="$WORK/bin:$PATH"
export PATH

# ---- the stub server --------------------------------------------------------------------------------
STUB_ROOT="$WORK/stub"
PORT_FILE="$WORK/port"
mkdir -p "$STUB_ROOT"
python3 "$ROOT/scripts/lib/http-stub.py" "$STUB_ROOT" "$PORT_FILE" >"$WORK/stub.out" 2>&1 &
STUB_PID=$!
for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
[ -s "$PORT_FILE" ] || { cat "$WORK/stub.out" >&2; fail "the stub server did not name its port"; }
PORT="$(cat "$PORT_FILE")"
BASE="http://127.0.0.1:$PORT/releases"
case "$BASE" in
  http://127.0.0.1:*) ;;
  *) fail "the stub base is not loopback: $BASE" ;;
esac
ok

# <commit> -> the base URL of that commit's release directory. WA_NODE_BINARIES_URL is a BASE the asset name is
# appended to (wa_node_fetch_asset), so it names the release directory, never its parent.
base_for() { printf '%s/%s' "$BASE" "${1:0:12}"; }

requests() { # <asset name> -> how many times the stub was asked for it (0 when it never was)
  local counted
  counted="$(grep -cE "^(releases/)?$1 " "$STUB_ROOT/requests.log" 2>/dev/null)"
  printf '%s' "${counted:-0}"
}

COMMIT_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
COMMIT_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
COMMIT_D=dddddddddddddddddddddddddddddddddddddddd
COMMIT_E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
X64=x86_64-unknown-linux-gnu

mkelf() { # FILE MACHINE_HEX [BYTES]
  { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$2"; printf 'fixture-binary'; } > "$1"
  if [ -n "${3:-}" ]; then truncate -s "$3" "$1" || fail "could not size $1"; fi
}

# <tag dir> <commit> <payload bytes> -> a signed release with both payloads and the manifest, at
# $STUB_ROOT/releases/<sha12>/
mkrel() {
  local commit="$2" bytes="$3" short="${2:0:12}" dir="$STUB_ROOT/releases/${2:0:12}"
  local sha ssha sbytes ssbytes
  mkdir -p "$dir"
  mkelf "$dir/wa-$X64-$short" 3e "$bytes"
  mkelf "$dir/wa-sentinel-$X64-$short" 3e
  sha="$(wa_node_sha256 "$dir/wa-$X64-$short")"
  sbytes="$(wc -c < "$dir/wa-$X64-$short" | tr -d '[:space:]')"
  ssha="$(wa_node_sha256 "$dir/wa-sentinel-$X64-$short")"
  ssbytes="$(wc -c < "$dir/wa-sentinel-$X64-$short" | tr -d '[:space:]')"
  cat > "$dir/node-$short.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$commit
source_tree=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rustc_version=fixture
zig_version=fixture
glibc_floor=2.31
codemode=embedded
built_utc=2026-11-24T00:00:00Z
# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes
$X64 $sha $sbytes $ssha $ssbytes
MANIFEST
  python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$dir" --key A >/dev/null 2>&1 \
    || fail "could not sign the fixture release $dir"
  printf '%s' "$dir"
}

# ---- e. a resumed body with ONE WRONG BYTE is refused by the manifest, by name, and the file is gone ---
# The sidecars are written AFTER signing on purpose: they are served, never fetched, so they must not appear
# in SHA256SUMS (which lists exactly the assets a verifier must find in the directory it fetched).
dir_e="$(mkrel relE "$COMMIT_E" 400000)"
SHORT_E="${COMMIT_E:0:12}"
printf '0.4' > "$dir_e/wa-$X64-$SHORT_E.drop"
printf '1' > "$dir_e/wa-$X64-$SHORT_E.corrupt"
cache_e="$WORK/cache-e"
out="$(WA_NODE_BINARIES_CACHE="$cache_e" WA_NODE_BINARIES_URL="$(base_for "$COMMIT_E")" \
  wa_node_binary_download "$ROOT" "$COMMIT_E" "$X64" "$cache_e" 2>&1)"; rc=$?
[ "$rc" = 5 ] || fail "a resumed body with a wrong byte must be refused with the hash code (5), got $rc: $out"
contains "$out" "node_hash_mismatch: wa-$X64-$SHORT_E" "the checksum refusal names the file"
[ "$(requests "releases/${COMMIT_E:0:12}/wa-$X64-$SHORT_E")" -ge 2 ] \
  || fail "the corrupted row did not resume: the asset was asked for $(( $(requests "releases/${COMMIT_E:0:12}/wa-$X64-$SHORT_E") )) time(s)"
ok
[ -z "$(find "$cache_e" -name '*wa-*' -o -name '*.part' 2>/dev/null)" ] \
  || fail "a refused download left bytes behind: $(find "$cache_e" -name '*wa-*' -o -name '*.part' 2>/dev/null)"
ok

# ---- b. a connection dropped at 40% once resumes and verifies -----------------------------------------
dir_b="$(mkrel relB "$COMMIT_B" 800000)"
SHORT_B="${COMMIT_B:0:12}"
printf '0.4' > "$dir_b/wa-$X64-$SHORT_B.drop"
cache_b="$WORK/cache-b"
out="$(WA_NODE_BINARIES_URL="$(base_for "$COMMIT_B")" wa_node_binary_download "$ROOT" "$COMMIT_B" "$X64" "$cache_b" 2>&1)"; rc=$?
expect_status 0 "$rc" "a dropped connection is resumed, not a failed update: $out"
entry_b="$cache_b/${COMMIT_B:0:12}/$X64"
[ -f "$entry_b/wa-$X64-$SHORT_B" ] || fail "the resumed download left no verified binary at $entry_b"
ok
grep -q "bytes=" "$STUB_ROOT/requests.log" || fail "no request carried a Range header, so nothing was resumed"
ok
[ "$(requests "releases/${COMMIT_B:0:12}/wa-$X64-$SHORT_B")" -ge 2 ] || fail "the dropped asset was asked for once - no resume happened"
ok

# ---- c. a 404: one request, one refusal naming HTTP 404, and no URL in the line ----------------------
before="$(requests "releases/${COMMIT_B:0:12}/no-such-asset")"
out="$(wa_node_fetch_asset "$ROOT" "node-$SHORT_B" "no-such-asset" "$WORK/c404" "$(base_for "$COMMIT_B")" 2>&1)"; rc=$?
expect_status 8 "$rc" "a missing asset is a refusal"
contains "$out" "HTTP 404" "the refusal names the HTTP status"
contains "$out" "1 of 3 attempts" "a 404 is not retried"
absent "$out" "$BASE" "the refusal never prints the URL (a release URL can carry a token or a signed query)"
absent "$out" "http://" "the refusal carries no URL of any kind"
[ "$(requests "releases/${COMMIT_B:0:12}/no-such-asset")" = "$((before + 1))" ] \
  || fail "a 404 was requested more than once"
ok

# ---- d. a stall is retried and then named as a stall -------------------------------------------------
dir_d="$(mkrel relD "$COMMIT_D" 400000)"
SHORT_D="${COMMIT_D:0:12}"
printf '65536' > "$dir_d/wa-$X64-$SHORT_D.stall"
cache_d="$WORK/cache-d"
started="$(date +%s)"
out="$(WA_DOWNLOAD_ATTEMPTS=2 WA_NODE_BINARIES_URL="$(base_for "$COMMIT_D")" \
  wa_node_binary_download "$ROOT" "$COMMIT_D" "$X64" "$cache_d" 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - started ))
[ "$rc" != 0 ] || fail "a stalled payload was reported as a successful download"
contains "$out" "stalled" "the refusal names the stall"
contains "$out" "curl exit 28" "the refusal names curl's exit code"
contains "$out" "2 of 2 attempts" "the stall was retried before it was refused"
[ "$elapsed" -ge 30 ] || fail "the stall row finished in ${elapsed}s, faster than one --speed-time window"
ok

# ---- a. 55 MB at 300 kB/s: over 120 s of transfer, and it succeeds ------------------------------
# 55,000,000 bytes at 300,000 bytes/s is 183 s of transfer. The cap this row exists to kill was 120 s.
dir_a="$(mkrel relA "$COMMIT_A" 55000000)"
SHORT_A="${COMMIT_A:0:12}"
printf '300000' > "$dir_a/wa-$X64-$SHORT_A.rate"
cache_a="$WORK/cache-a"
# The phase file a follower reads, begun the way scripts/deploy.sh begins it (deploy.sh:413).
wa_status_begin "$ROOT" "$COMMIT_A"
wa_phase fetching
: > "$WORK/phases.txt"
started="$(date +%s)"
(
  WA_NODE_BINARIES_URL="$(base_for "$COMMIT_A")" wa_node_binary_download "$ROOT" "$COMMIT_A" "$X64" "$cache_a" \
    > "$WORK/row-a.out" 2>&1
) &
runner=$!
last_phase=""
while kill -0 "$runner" 2>/dev/null; do
  phase="$(sed -n 's/.*"phase":"\([^"]*\)".*/\1/p' "$WA_STATUS_FILE" 2>/dev/null)"
  if [ -n "$phase" ] && [ "$phase" != "$last_phase" ]; then
    printf '%s\n' "$phase" >> "$WORK/phases.txt"
    last_phase="$phase"
  fi
  sleep 0.25
done
wait "$runner"; rc=$?
elapsed=$(( $(date +%s) - started ))
out="$(cat "$WORK/row-a.out")"
expect_status 0 "$rc" "a 55 MB asset on a 300 kB/s line is downloaded, not refused: $out"
[ "$elapsed" -gt 120 ] || fail "the 55 MB row took ${elapsed}s: it did not exercise the >120 s case this row exists for"
ok
[ "$(wc -c < "$cache_a/$SHORT_A/$X64/wa-$X64-$SHORT_A" | tr -d '[:space:]')" = 55000000 ] \
  || fail "the 55 MB asset did not arrive whole"
ok
# The .complete marker is written AFTER every pin, hash and machine check passed (wa_node_binary_download),
# so its presence is the verifier's own answer about these bytes - not a claim of this test.
[ -f "$cache_a/$SHORT_A/$X64/.complete" ] || fail "the 55 MB download left no verified cache entry"
ok

# ---- f. progress: the phase line a follower reads, at most one every few seconds ---------------------
grep -cE '^downloading wa-x86_64-unknown-linux-gnu: [0-9]+ of 55 MB$' "$WORK/phases.txt" > "$WORK/progress.count" \
  || true
progress="$(tr -d '[:space:]' < "$WORK/progress.count")"
[ "${progress:-0}" -ge 3 ] || fail "the download reported $progress progress line(s), not the at least 3 a 183 s transfer must give: $(cat "$WORK/phases.txt")"
ok
budget=$(( elapsed / 3 + 3 ))
[ "$progress" -le "$budget" ] \
  || fail "the download wrote $progress progress lines in ${elapsed}s: more than the one-per-3s throttle allows ($budget)"
ok

# The same label rule the line above depends on, stated once.
[ "$(wa_download_label "wa-$X64-$SHORT_A")" = "wa-$X64" ] || fail "wa_download_label did not shorten a payload name to wa-<triple>"
ok
[ "$(wa_download_label "node-$SHORT_A.manifest")" = "node-$SHORT_A.manifest" ] || fail "wa_download_label mangled a manifest name"
ok

# ---- the same transfer for a COMPONENT BUNDLE (scripts/lib/deploy-components.sh) ----------------------
# A component is a release asset too, and it had its own capped curl with the reason thrown away: the same
# slow-minute refusal. Both fetchers now go through wa_download_asset.
. "$ROOT/scripts/lib/deploy-components.sh"
mkdir -p "$STUB_ROOT/bundles/good" "$STUB_ROOT/bundles/broken" "$WORK/cgood" "$WORK/cbad"
printf 'graph-wasm-fixture' > "$STUB_ROOT/bundles/good/graph.wasm"
printf '{"name":"graph"}' > "$STUB_ROOT/bundles/good/graph.json"
printf 'graph 0000000000000000000000000000000000000000000000000000000000000000 16\n' > "$STUB_ROOT/bundles/good/components.lock"
printf '{"name":"graph"}' > "$STUB_ROOT/bundles/broken/graph.json"
printf 'graph 0000000000000000000000000000000000000000000000000000000000000000 16\n' > "$STUB_ROOT/bundles/broken/components.lock"
out="$(wa_component_fetch_assets "$ROOT" components-aaaaaaaaaaaa graph "$WORK/cgood" "http://127.0.0.1:$PORT/bundles/good" 2>&1)"; rc=$?
expect_status 0 "$rc" "a component bundle is fetched over the same transfer: $out"
[ -f "$WORK/cgood/graph.wasm" ] && [ -f "$WORK/cgood/graph.json" ] && [ -f "$WORK/cgood/components.lock" ] || fail "the component bundle did not land whole: $(ls "$WORK/cgood")"
ok
out="$(wa_component_fetch_assets "$ROOT" components-aaaaaaaaaaaa graph "$WORK/cbad" "http://127.0.0.1:$PORT/bundles/broken" 2>&1)"; rc=$?
expect_status 8 "$rc" "a component bundle missing an asset is a refusal"
contains "$out" "component_release_unreachable: graph.wasm: HTTP 404" "the component refusal names the status and the asset"
absent "$out" "http://" "the component refusal carries no URL either"

# ---- every curl exit code the refusal can print has words -------------------------------------------
for code in 6 7 18 22 28 33 35 52 56 92 999; do
  what="$(wa_download_curl_reason "$code")"
  [ -n "$what" ] || fail "curl exit $code has no words"
done
ok

# ---- the cap this change removed is gone from the code it removed it from ---------------------------
# THE CAP IS GONE FROM THE TRANSFER, and the transfer is the shared function: `wa_download_asset` is read out of
# the library (its whole body) and must carry no `-m` / `--max-time`; and the release fetcher must still go
# through it. Scoped this way on purpose - the release LIST call (node-binaries.sh, api.github.com) keeps its
# own page budget, which is a different bound (a search that stopped early) and not a body transfer.
transfer="$(sed -n '/^wa_download_asset()/,/^}/p' "$ROOT/scripts/lib/download-asset.sh")"
[ -n "$transfer" ] || fail "wa_download_asset is not in scripts/lib/download-asset.sh"
capped="$(printf '%s\n' "$transfer" | grep -nE '(--max-time|-m[[:space:]]+[0-9])')"
[ -z "$capped" ] || fail "a total-time cap is back in the shared transfer: $capped"
ok
fetch_asset="$(sed -n '/^wa_node_fetch_asset()/,/^}/p' "$ROOT/scripts/lib/node-binaries.sh")"
grep -qF 'wa_download_asset' <<< "$fetch_asset" || fail "wa_node_fetch_asset no longer fetches through the shared downloader"
ok
ok

echo "node download ok ($checks checks)"
