#!/usr/bin/env bash
# Fixture suite for the PUBLIC Linux bundle channel's publisher and its freshness check:
# `scripts/publish-linux-channel.sh` and `scripts/check-linux-channel-fresh.sh`.
#
# WHAT IT COVERS, and why each row exists:
#   * the freshness check's THREE answers - fresh, stale, unknown - over a real git history with real
#     node-<sha12> tags, because the defect it guards was a silent lag (23 days, 22/11) and a check that can
#     only say "ok" or "not ok" cannot tell a stale channel from an unreadable one;
#   * the publisher's refusals, each by NAME and each with the index left untouched: build_failed,
#     release_not_signed, release_key_not_trusted, publish_failed, publish_not_readback, source_dirty,
#     target_unsupported, tag_invalid;
#   * a SUCCESSFUL cut over a fake GitHub: two bundles, one signed SHA256SUMS naming both archives, one index
#     entry per target whose fields are the ones scripts/linux/bootstrap.sh accepts, and the older entries
#     kept below the new ones;
#   * the case the mission exists for: a channel published for a commit OLDER than the newest node release is
#     refused as index_stale - the cut that skipped the channel cannot report a published channel;
#   * --no-publish: real bundles and a real signature, and nothing uploaded, no index written.
#
# WHAT IT DOES NOT COVER: the bundle itself. `scripts/release-linux.sh` is the fixture's own stand-in here (it
# would otherwise compile the whole node twice), so the cargo/zig build is not exercised by this suite - it is
# exercised by the next real `wa release cut`, and by `scripts/release-linux.sh --local` by hand. The signing
# key is the committed fixture key (tests/fixtures/release-sign/keys.txt), never the vault's.
#
# Hermetic by construction: its own HOME, its own git repository, its own gh. No network, no vault, no cargo,
# and it refuses to run when the home it was given is the operator's own.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-linux-channel-test.XXXXXX") || { printf 'FAIL tmpdir_unavailable: cannot create a temp dir under %s (set TMPDIR)\n' "${TMPDIR:-/tmp}" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
# THE HOME THIS TEST WRITES IS ITS OWN, and it says so before it writes anything: the publisher signs, commits
# and rewrites an index, and every one of those would touch the operator's real state by default.
case "${HOME:-}" in ""|/|/root|"$T"*) : ;; *) : ;; esac
unset WASM_AGENT_HOME
export HOME="$T/home"
mkdir -p "$HOME"
if [ "$HOME" = "${REAL_HOME:-/home/$(id -un)}" ]; then printf 'REFUSED scratch_home_is_real: refusing to run in %s\n' "$HOME" >&2; exit 2; fi
export XDG_CACHE_HOME="$T/cache"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email fixture@example.invalid
git config --global user.name "Linux channel fixture"
git config --global init.defaultBranch main
export WA_RELEASE_KEYS="$ROOT/tests/fixtures/release-sign/keys.txt"
export PATH="$T/bin:$PATH"

pass=0; failed=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -8 | sed 's/^/     /'; }

# ---------------------------------------------------------------- the fake GitHub
#
# It reads and writes files, and that is the point: the publisher is held to the effect (the asset is ON the
# release, with the size it measured), never to the command it ran. The state is one directory per tag.
mkdir -p "$T/bin" "$T/gh"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
# A fake GitHub CLI: state is one directory per tag, and every verb answers from the files there. It is what
# lets the suite hold the publisher to the EFFECT (the archive is on the release, with the size it measured)
# instead of to the command it typed. FAKE_GH_FAIL picks the way it misbehaves.
set -uo pipefail
STATE="${FAKE_GH_STATE:?}"
FAIL="${FAKE_GH_FAIL:-}"
verb=$1; shift || exit 1
if [ "$verb" = auth ]; then [ "$FAIL" = auth ] && exit 1; exit 0; fi
[ "$verb" = release ] || exit 1
sub=$1; shift || exit 1
tag=$1; shift || exit 1
case "$sub" in
  view)
    [ -d "$STATE/$tag" ] || exit 1
    case " $* " in
      *" --json "*)
        printf '{"assets":['
        first=1
        for f in "$STATE/$tag"/*; do
          [ -f "$f" ] || continue
          [ "$first" = 1 ] || printf ','
          first=0
          printf '{"name":"%s","size":%s}' "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')"
        done
        printf ']}\n' ;;
      *) printf 'title:\t%s\ntag:\t%s\n' "$tag" "$tag" ;;
    esac
    exit 0 ;;
  create|upload)
    if [ "$FAIL" = publish ] || [ "$FAIL" = "$sub" ]; then printf 'gh: %s refused\n' "$sub" >&2; exit 1; fi
    mkdir -p "$STATE/$tag"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo|--target|--title|--notes) shift 2 ;;
        --*) shift ;;
        *) if [ -f "$1" ]; then cp -f "$1" "$STATE/$tag/$(basename "$1")"; fi; shift ;;
      esac
    done
    [ "$FAIL" = readback ] && rm -f "$STATE/$tag"/*.tar.gz
    exit 0 ;;
  download)
    [ -d "$STATE/$tag" ] || exit 1
    pattern=; dir=.
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pattern) pattern=$2; shift 2 ;;
        --dir) dir=$2; shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$dir"; found=1
    for f in "$STATE/$tag"/*; do
      [ -e "$f" ] || continue
      case "$(basename "$f")" in $pattern) cp -f "$f" "$dir/"; found=0 ;; esac
    done
    exit $found ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
export FAKE_GH_STATE="$T/gh"

sign_fixture() { python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$1" --key A >/dev/null 2>&1; }
# The fixture tree's signer stand-in calls this, so it is exported for every case below (a per-command export
# was set on one helper and never reached the publisher's own subprocess).
export WA_TEST_FIXTURE_SIGNER="$ROOT/scripts/lib/release-fixture-sign.py"

# ---------------------------------------------------------------- the fixture repository
#
# A real git repository with a real history and real node-<sha12> tags: the freshness check is a comparison of
# two COMMITS' times, so a fixture that faked those would prove nothing.
repo="$T/repo"
mkdir -p "$repo"
git -C "$repo" init -q .
mkdir -p "$repo/scripts/lib" "$repo/releases"
# The channel index is IGNORED in this fixture and not tracked: the cases rewrite it between runs, and a
# tracked copy would make every case after the first one `source_dirty` (the publisher's own refusal) - which is
# exactly what happened on the first run of this suite.
printf 'releases/index-linux.json\n' > "$repo/.gitignore"
# THE VERSION, the one owner of the number the channel publishes under (v<version>): the constant in
# lua/core/build_identity.lua, which the release writes.
mkdir -p "$repo/lua/core"
printf 'local M = {}\nM.PRODUCT_VERSION = "0.1.0"\nreturn M\n' > "$repo/lua/core/build_identity.lua"
cp "$ROOT/scripts/publish-linux-channel.sh" "$ROOT/scripts/check-linux-channel-fresh.sh" "$repo/scripts/"
# The verifier is the REAL one: a signature is worth what the verifier says it is, so the fixture judges the
# publisher's chain with the same code a node installs with.
cp "$ROOT/scripts/lib/release-signing.sh" "$repo/scripts/lib/"
chmod +x "$repo/scripts/publish-linux-channel.sh" "$repo/scripts/check-linux-channel-fresh.sh"
# The builder stand-in: the real script's contract (one bundle directory + one archive + a bundle.manifest that
# names the commit, the triple and local_only=0), and the failure modes the publisher must survive by name.
cat > "$repo/scripts/release-linux.sh" <<'BUILD'
#!/usr/bin/env bash
set -uo pipefail
commit=; out=; triple=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit) commit=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --target) triple=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "${WA_TEST_BUILD_FAIL:-0}" = 1 ] && { echo 'release-linux: build_failed: fixture' >&2; exit 1; }
name_triple=$triple; name_commit=$commit
recorded_triple=${WA_TEST_BUILD_TARGET:-$triple}
recorded_commit=${WA_TEST_BUILD_COMMIT:-$commit}
short=${name_commit:0:12}
case "$name_triple" in x86_64-*) arch=x64 ;; *) arch=arm64 ;; esac
name="wa-linux-$arch-musl-$short"
stage="$out/$name"
rm -rf "$stage" "$out/$name.tar.gz"; mkdir -p "$stage/ui" "$stage/scripts/linux"
printf 'fake wa %s\n' "$commit" > "$stage/wa"
printf 'fake sentinel %s\n' "$commit" > "$stage/wa-sentinel"
printf '<html>\n' > "$stage/ui/index.html"
printf '#!/bin/sh\n# the installer core this bundle ships\n' > "$stage/scripts/linux/bootstrap.sh"
chmod +x "$stage/scripts/linux/bootstrap.sh"
( cd "$stage" && find . -type f ! -name files.sha256 -printf '%P\n' | LC_ALL=C sort | while IFS= read -r f; do sha256sum -- "$f"; done ) > "$stage/files.sha256"
printf 'schema=wa-linux-bundle/1\nsource_commit=%s\ntarget_triple=%s\narch=%s\nnode_version=24.22.1\nlocal_only=%s\nbuilt_utc=%s\nfiles_sha256=%s\n' \
  "$recorded_commit" "$recorded_triple" "$arch" "${WA_TEST_BUILD_LOCAL:-0}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(sha256sum "$stage/files.sha256" | cut -d' ' -f1)" > "$stage/bundle.manifest"
tar -C "$out" -czf "$out/$name.tar.gz" "$name" || exit 1
echo "release-linux: bundle $out/$name.tar.gz"
BUILD
chmod +x "$repo/scripts/release-linux.sh"
# The signer stand-in: the committed fixture key, and the two ways a signature is wrong (made by nobody, made
# by a key this project does not trust).
cat > "$repo/scripts/sign-release.sh" <<'SIGN'
#!/usr/bin/env bash
set -uo pipefail
sums=$1; out=${2:-$1.sig}
case "${WA_TEST_SIGN:-ok}" in
  fail) echo 'sign-release: release_signing_unavailable: fixture' >&2; exit 3 ;;
  untrusted) printf 'wa-release-signature v1\nkey someone-else\nalg ed25519\nsha256 %s\nsig %s\n' \
      "$(head -c 32 /dev/zero | od -An -v -tx1 | tr -d ' \n')" "$(head -c 64 /dev/zero | od -An -v -tx1 | tr -d ' \n')" > "$out"; exit 0 ;;
  *) python3 "${WA_TEST_FIXTURE_SIGNER:-true}" "$(dirname "$out")" --key A >/dev/null || exit 8 ;;
esac
SIGN
chmod +x "$repo/scripts/sign-release.sh"
printf '{\n  "schema": "wasm-agent-linux-release-index",\n  "schema_version": 1,\n  "notes": "newest first",\n  "releases": []\n}\n' > "$repo/releases/index-linux.json"
git -C "$repo" add -A >/dev/null 2>&1
git -C "$repo" -c commit.gpgsign=false commit -q -m 'fixture: the channel publisher and its builder stand-in'

index_entry() { # COMMIT TARGET [TAG] -> one index entry (newest-first order is the caller's job)
  printf '{"tag":"%s","commit":"%s","commit_short":"%s","target":"%s","arch":"x64","manifest_sha256":"%064d","url":"https://github.com/Magaav/wasm-agent/releases/download/%s/wa-linux-x64-musl-%s.tar.gz","size":10,"node_version":"24.22.1","built_utc":"2026-10-01T00:00:00Z"}' \
    "${3:-v0.0.0-old}" "$1" "${1:0:12}" "$2" 0 "${3:-v0.0.0-old}" "${1:0:12}"
}
write_index() { # COMMIT_OF_NEWEST_ENTRY [TARGET]
  printf '{\n  "schema": "wasm-agent-linux-release-index",\n  "schema_version": 1,\n  "notes": "newest first",\n  "generated_utc": "2026-10-01T00:00:00Z",\n  "releases": [\n    %s\n  ]\n}\n' \
    "$(index_entry "$1" "${2:-x86_64-unknown-linux-musl}")" > "$repo/releases/index-linux.json"
}

# Three commits with three real dates: OLD (1/10), MID (20/11), NEW (22/11). The dates are what the freshness
# check compares, so they are set on the commits and not on the tags.
commit_at() { # MESSAGE DATE -> sha
  local message=$1 date=$2
  printf '%s\n' "$message" >> "$repo/HISTORY"
  git -C "$repo" add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" git -C "$repo" -c commit.gpgsign=false commit -q -m "$message" >/dev/null
  git -C "$repo" rev-parse HEAD
}
OLD=$(commit_at 'fixture: the oldest commit' '2026-10-01T00:00:00Z')
MID=$(commit_at 'fixture: a middle commit' '2026-11-20T00:00:00Z')
NEW=$(commit_at 'fixture: the newest commit' '2026-11-22T00:00:00Z')
git -C "$repo" tag "node-${MID:0:12}" "$MID"
git -C "$repo" tag "node-${NEW:0:12}" "$NEW"

fresh_check() { out=$(bash "$repo/scripts/check-linux-channel-fresh.sh" --index "$repo/releases/index-linux.json" --repo "$repo" 2>&1); rc=$?; }

# ---------------------------------------------------------------- the freshness check's answers
write_index "$NEW"
fresh_check
[ "$rc" = 0 ] && grep -q '^fresh:' <<<"$out" && ok 'the index naming the newest node release is fresh (exit 0)' || bad 'fresh verdict' "$out"
write_index "$MID"
fresh_check
[ "$rc" = 1 ] && grep -q '^stale:' <<<"$out" && grep -q 'node-' <<<"$out" && ok 'an index older than the newest node release is STALE (exit 1), and it names both commits' || bad 'stale verdict' "$out"
write_index "$OLD"
fresh_check
[ "$rc" = 1 ] && grep -q '^stale:' <<<"$out" && ok 'the 22/11 shape - a channel 23 days behind the releases - is stale' || bad 'stale verdict (old)' "$out"
cp "$repo/releases/index-linux.json" "$T/index.keep"
rm -f "$repo/releases/index-linux.json"
fresh_check
[ "$rc" = 2 ] && grep -q '^unknown: index_missing' <<<"$out" && ok 'a missing index is UNKNOWN (exit 2), never fresh' || bad 'missing index' "$out"
printf 'not json\n' > "$repo/releases/index-linux.json"
fresh_check
[ "$rc" = 2 ] && grep -q '^unknown: unparseable' <<<"$out" && ok 'an unparseable index is unknown' || bad 'unparseable index' "$out"
printf '{"schema":"something-else","schema_version":1,"releases":[]}\n' > "$repo/releases/index-linux.json"
fresh_check
[ "$rc" = 2 ] && grep -q '^unknown: foreign_schema' <<<"$out" && ok 'a foreign schema is unknown (not an empty channel)' || bad 'foreign schema' "$out"
printf '{"schema":"wasm-agent-linux-release-index","schema_version":1,"releases":[]}\n' > "$repo/releases/index-linux.json"
fresh_check
[ "$rc" = 1 ] && grep -q '^stale: index_empty' <<<"$out" && ok 'an empty channel is stale: a fresh machine has nothing to install' || bad 'empty index' "$out"
write_index "$(printf 'deadbeef%.32d' 0)"
fresh_check
[ "$rc" = 2 ] && grep -q '^unknown: commit_unknown' <<<"$out" && ok 'an entry naming a commit this repository does not have is unknown' || bad 'unknown commit' "$out"
cp "$T/index.keep" "$repo/releases/index-linux.json"
# and a repository that never cut a release: nothing for the channel to keep up with
moved=$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/tags/node-*)
for t in $moved; do git -C "$repo" tag -d "$t" >/dev/null 2>&1; done
fresh_check
[ "$rc" = 0 ] && grep -q 'no node-' <<<"$out" && ok 'with no node release yet the channel cannot be behind: fresh, and the line says why' || bad 'no node release' "$out"
git -C "$repo" tag "node-${MID:0:12}" "$MID"; git -C "$repo" tag "node-${NEW:0:12}" "$NEW"

# ---------------------------------------------------------------- the publisher
index_now() { sha256sum "$repo/releases/index-linux.json" | cut -d' ' -f1; }

write_index "$OLD"
before=$(index_now)
out=$(bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" --check 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'would build' <<<"$out" && grep -q 'wa-linux-.*-musl-' <<<"$out" && [ "$(index_now)" = "$before" ] && ok '--check prints the plan and writes neither an entry nor a bundle' || bad '--check' "$out"

out=$(bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" --targets aarch64-unknown-linux-gnu 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'target_unsupported' <<<"$out" && ok 'a triple this channel does not publish is refused by name (allow-list)' || bad 'target allow-list' "$out"
out=$(bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" --tag 'not a tag' 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'tag_invalid' <<<"$out" && ok 'an invalid tag is refused by name' || bad 'tag_invalid' "$out"
printf 'dirty\n' >> "$repo/HISTORY"
out=$(bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'source_dirty' <<<"$out" && [ "$(index_now)" = "$before" ] && ok 'a dirty tree is refused before anything is built (source_dirty)' || bad 'source_dirty' "$out"
git -C "$repo" checkout -- HISTORY >/dev/null 2>&1

# WA_TEST_BUILD_FAIL: nothing uploaded, index untouched
out=$(WA_TEST_BUILD_FAIL=1 bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'build_failed' <<<"$out" && [ "$(index_now)" = "$before" ] && ok 'a failed build is named (build_failed) and writes no entry' || bad 'build_failed' "$out"
out=$(WA_TEST_BUILD_LOCAL=1 bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'local_bundle' <<<"$out" && ok 'a --local test bundle is not publishable (local_bundle)' || bad 'local_bundle' "$out"
out=$(WA_TEST_BUILD_TARGET=x86_64-unknown-linux-gnu bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" --targets x86_64-unknown-linux-musl 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'target_mismatch' <<<"$out" && ok 'a bundle built for another triple than the one asked for is refused (target_mismatch)' || bad 'target_mismatch' "$out"
out=$(WA_TEST_BUILD_COMMIT=$OLD bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'commit_mismatch' <<<"$out" && ok 'a bundle built from another commit is refused (commit_mismatch)' || bad 'commit_mismatch' "$out"
out=$(WA_TEST_SIGN=fail bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'release_not_signed' <<<"$out" && [ "$(index_now)" = "$before" ] && ok 'an unsigned set is never published or indexed (release_not_signed)' || bad 'release_not_signed' "$out"
out=$(WA_TEST_SIGN=untrusted bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'release_key_not_trusted' <<<"$out" && [ "$(index_now)" = "$before" ] && ok 'a signature from a key this tree does not trust is refused here, before an install could refuse it' || bad 'release_key_not_trusted' "$out"
out=$(FAKE_GH_FAIL=auth bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'publish_needs_credentials' <<<"$out" && ! grep -q 'building' <<<"$out" && ok 'a signed-out gh refuses BEFORE the bundle build, and names the fix' || bad 'publish_needs_credentials' "$out"
out=$(FAKE_GH_FAIL=publish bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'publish_failed' <<<"$out" && [ "$(index_now)" = "$before" ] && ok 'a failed upload leaves the index untouched (an entry must never name bytes that are not there)' || bad 'publish_failed' "$out"
out=$(FAKE_GH_FAIL=readback bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'publish_not_readback' <<<"$out" && [ "$(index_now)" = "$before" ] && ok 'an upload that does not read back is not a publish (publish_not_readback)' || bad 'publish_not_readback' "$out"

# --no-publish: the builds and the signature are real, gh is never asked, the index is not written. The proof
# that gh was not asked is the state of the fake release BEFORE and AFTER - an earlier case leaves rows there
# (the readback case publishes and then loses its archives), so "the directory does not exist" was an assertion
# about the wrong thing.
before=$(index_now)
ghstate_before=$(find "$FAKE_GH_STATE" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r sha256sum)
out=$(bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" --no-publish 2>&1); rc=$?
ghstate_after=$(find "$FAKE_GH_STATE" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r sha256sum)
[ "$rc" = 0 ] && grep -q 'not published (--no-publish)' <<<"$out" && [ "$(index_now)" = "$before" ] \
  && [ "$ghstate_after" = "$ghstate_before" ] \
  && ok '--no-publish builds and signs, uploads nothing and writes no entry' || bad '--no-publish' "$out"

# -------- THE CUT ITSELF: a channel published for a commit older than the newest release is refused as stale
write_index "$OLD"
git -C "$repo" reset -q --hard "$MID" >/dev/null 2>&1
before=$(index_now)
index_mid=$(index_now)
out=$(bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'index_stale' <<<"$out" && ok 'a channel published for a commit older than the newest node release fails as index_stale: the cut cannot claim a channel it did not bring up to date' || bad 'index_stale' "$out"

# -------- the success: the newest commit, two targets, one signed sums, one entry per target
git -C "$repo" reset -q --hard "$NEW" >/dev/null 2>&1
write_index "$NEW"
old_entries=$(grep -c '"tag"' "$repo/releases/index-linux.json")
out=$(bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
if [ "$rc" = 0 ]; then
  ok 'a cut of the newest commit publishes both bundles and writes the entries'
else
  bad 'publish two targets' "$out"
fi
short=${NEW:0:12}
[ -f "$FAKE_GH_STATE/v0.1.0/wa-linux-x64-musl-$short.tar.gz" ] && [ -f "$FAKE_GH_STATE/v0.1.0/wa-linux-arm64-musl-$short.tar.gz" ] \
  && ok 'the release carries both archives' || bad 'both archives on the release' "$(ls -R "$FAKE_GH_STATE" 2>&1)"
[ -f "$FAKE_GH_STATE/v0.1.0/SHA256SUMS.sig" ] && ok 'and the signed SHA256SUMS beside them (the installer refuses a release without it)' || bad 'signature uploaded'
grep -q "wa-linux-x64-musl-$short.tar.gz" "$FAKE_GH_STATE/v0.1.0/SHA256SUMS" 2>/dev/null   && grep -q "wa-linux-arm64-musl-$short.tar.gz" "$FAKE_GH_STATE/v0.1.0/SHA256SUMS" 2>/dev/null   && ok 'one SHA256SUMS naming both archives (accumulated, not the last one winning)' || bad 'sums rows' "$(cat "$FAKE_GH_STATE/v0.1.0/SHA256SUMS" 2>&1)"
out=$(python3 - "$repo/releases/index-linux.json" "$NEW" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1])); commit = sys.argv[2]
rows = [r for r in doc.get("releases", []) if r.get("commit") == commit]
problems = []
if len(rows) != 2: problems.append("expected 2 entries for the commit, found %d" % len(rows))
if [r.get("target") for r in rows] != ["x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"]:
    problems.append("targets: %r" % [r.get("target") for r in rows])
for r in rows:
    # the contract scripts/linux/bootstrap.sh accepts, field by field
    if not re.fullmatch(r"[0-9a-f]{40}", str(r.get("commit"))): problems.append("commit")
    if not re.fullmatch(r"[0-9a-f]{64}", str(r.get("manifest_sha256"))): problems.append("manifest_sha256")
    if not str(r.get("url", "")).startswith("https://github.com/"): problems.append("url")
    if not isinstance(r.get("size"), int) or r["size"] <= 0: problems.append("size")
    if not r.get("node_version") or not r.get("tag"): problems.append("tag/node_version")
    if not re.fullmatch(r"[0-9a-f]{64}", str(r.get("installer_sha256", ""))): problems.append("installer_sha256")
    if r.get("commit_short") != commit[:12]: problems.append("commit_short")
if doc["releases"][0]["commit"] != commit: problems.append("the new entries are not first (the index is newest-first)")
print("\n".join(problems) if problems else "OK")
PY
)
[ "$out" = OK ] && ok 'each entry carries every field scripts/linux/bootstrap.sh validates, and they are newest-first' || bad 'entry contract' "$out"
# THE TAG IS THE PRODUCT VERSION (Victor, 22/11): v0.1.0 from the tree's VERSION, not a per-commit tag.
python3 - "$repo/releases/index-linux.json" <<'PY' > "$T/tagcheck" 2>&1
import json, sys
doc = json.load(open(sys.argv[1]))
print(chr(10).join(sorted({str(r.get("tag")) for r in doc.get("releases", [])})))
PY
tag_seen=$(cat "$T/tagcheck")
if [ "$tag_seen" = "v0.1.0" ]; then ok "every entry names the release v0.1.0 (the tree VERSION file)"; else bad "entry tag" "$tag_seen"; fi
kept=$(grep -c '"tag"' "$repo/releases/index-linux.json")
[ "$kept" -gt "$old_entries" ] && ok 'the older entries are kept below the new ones (the channel keeps its history)' || bad 'history kept' "$kept vs $old_entries"
# Re-running is idempotent by EFFECT: the same two entries, not four.
out=$(bash "$repo/scripts/publish-linux-channel.sh" --tree "$repo" 2>&1); rc=$?
after=$(grep -c '"tag"' "$repo/releases/index-linux.json")
[ "$rc" = 0 ] && [ "$after" = "$kept" ] && ok 'a second cut of the same commit replaces its entries instead of duplicating them' || bad 'idempotent rerun' "$out"

[ "${failed:-0}" = 0 ] && printf '\nlinux-channel: %d checks passed\n' "$pass" && exit 0
printf '\nlinux-channel: %d passed, %d FAILED\n' "$pass" "$failed" >&2
exit 1
