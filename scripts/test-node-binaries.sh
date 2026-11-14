#!/usr/bin/env bash
# Proof for scripts/publish-node-binaries.sh - the build/publish half of "a node installs a published
# binary" (docs/COMPONENTS.md "The node binary itself", job p3x). No cargo, no zig, no network, no gh:
# the artifacts are fixtures and `gh` is a shim that records being called, so "this script never
# publishes" is checked rather than promised.
#
# What is checked, and why each case earns its line:
#   * --check prints the plan (commit, triples, tag, assets, whether the code-mode assets are embedded)
#     and writes nothing - the dry run an operator reads before paying for two cross builds;
#   * --from verifies artifacts built elsewhere against the manifest that travelled with them, and
#     refuses every way that manifest can be wrong: another commit, a tampered binary, a wrong size, a
#     wrong ELF machine, a glibc newer than the pin claims, a missing asset, an empty-code-mode artifact
#     that nobody named as development;
#   * a dirty tree, a commit that is not on origin/main, and a target this channel does not publish are
#     refusals, by name;
#   * the printed command is a `gh release create node-<sha12>` line and nothing ran it.
#
#   bash scripts/test-node-binaries.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PUBLISH="$ROOT/scripts/publish-node-binaries.sh"
. "$ROOT/scripts/lib/node-binaries.sh"

WORK="$(mktemp -d)"
trap 'test_release_vault_stop; chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# The publisher signs every release with wa-vault's `release-signing` key and refuses to publish without a
# signature, so this suite runs a SCRATCH vault and signs with it (never the operator's running vault).
. "$ROOT/scripts/lib/test-release-vault.sh"
test_release_vault_start || { echo "SKIP test-node-binaries: python3/curl or vault/wa_vault.py is missing, so nothing can be signed"; exit 0; }
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "node binaries (publish) FAILED: $*" >&2; exit 1; }
expect_status() { # <want> <got> <what>
  [ "$2" = "$1" ] || fail "$3: expected status $1, got $2"
  ok
}
contains() { # <text> <needle> <what>
  # No pipe, on purpose. `printf '%s' "$1" | grep -qF -- "$2"` under `set -o pipefail` reports the pipeline
  # as failed when `grep -q` finds its match and exits while `printf` is still writing: printf dies of
  # SIGPIPE (141), pipefail makes 141 the pipeline's status, and a TRUE assertion fails. Measured 13/11 on
  # this file after the publisher grew past ~43 KB - the same assertions passed and failed on alternate
  # runs, which is the worst possible evidence. Here-strings keep one process, so the answer is the grep's.
  grep -qF -- "$2" <<< "$1" || fail "$3: '$2' not in: $1"
  ok
}
absent() { # <text> <needle> <what>
  grep -qF -- "$2" <<< "$1" && fail "$3: '$2' unexpectedly in: $1"
  ok
}

# `gh` exists, is first on PATH, and records what it was asked to do. `release view` fails (no release),
# `release create`/`release upload` succeed - so --publish is proved without a network or a token, and every
# default path still proves it never called gh at all.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh-called"
case "\$1 \$2" in
  "release create"|"release upload") exit 0 ;;
esac
exit 1
SHIM
chmod +x "$WORK/bin/gh" 2>/dev/null || true
PATH="$WORK/bin:$PATH"
export PATH
# A fixture is an ELF header and a few bytes: it cannot be executed, and the publisher PROVES a candidate
# by running it. Its own --runner knob (WA_PUBLISH_RUNNER) names a prefix it trusts for that step, so the
# artifact cases below are host-independent; `true` answers for the fixture. The run gate's own decision
# (run what this host can, SKIP what it cannot) is proved separately, on a real ELF, further down.
WA_PUBLISH_RUNNER=true
export WA_PUBLISH_RUNNER

mkelf() { # FILE MACHINE_HEX [EXTRA]
  { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$2"; printf 'fixture-binary%s' "${3:-}"; } > "$1"
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
bytes() { wc -c < "$1" | tr -d '[:space:]'; }

HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
SHORT="${HEAD_SHA:0:12}"
TRIPLE=x86_64-unknown-linux-gnu
OTHER_TRIPLE=aarch64-unknown-linux-gnu

# ---- a git fixture: a clean repo on "main", and one behind main --------------------------------------
fixture="$WORK/fixture"
mkdir -p "$fixture/scripts/lib"
cp "$ROOT/scripts/lib/node-binaries.sh" "$ROOT/scripts/lib/build-requirements.sh" "$fixture/scripts/lib/"
# The signature gate lives beside it, and the fixture stands in for a checkout: both files, or a release
# could not be verified at all (which the lib refuses by name, correctly).
cp "$ROOT/scripts/lib/release-signing.sh" "$fixture/scripts/lib/"
mkdir -p "$fixture/scripts/lib" "$fixture/config"
cp "$ROOT/scripts/lib/release_verify.py" "$fixture/scripts/lib/"
cp "$ROOT/config/release-keys.txt" "$fixture/config/"
cp "$ROOT/scripts/check-disk-floor.sh" "$fixture/scripts/"
( cd "$fixture" && git init -q && git config core.autocrlf false && git config user.email t@t && git config user.name t \
  && git add -A && git commit -qm one && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1 \
  || fail "could not build the git fixture"
FIXTURE_SHA="$(git -C "$fixture" rev-parse HEAD)"
FIXTURE_SHORT="${FIXTURE_SHA:0:12}"

plan_out="$(bash "$PUBLISH" --repo "$fixture" --out "$WORK/never" --check --local --allow-empty-codemode 2>&1)"
expect_status 0 "$?" "--check on a clean fixture tree"
contains "$plan_out" "would build $FIXTURE_SHA" "the plan names the commit"
contains "$plan_out" "release tag: node-$FIXTURE_SHORT" "the plan names the release tag"
contains "$plan_out" "node-$FIXTURE_SHORT.manifest" "the plan names the pins file"
contains "$plan_out" "compiled inputs: $(wa_compiled_inputs_digest "$fixture" "$FIXTURE_SHA")" \
  "the plan names the compiled-inputs digest a later commit can match"
contains "$plan_out" "nothing was built" "the dry run says nothing was built"
[ ! -d "$WORK/never" ] || fail "--check created its output directory"
ok
[ ! -f "$WORK/gh-called" ] || fail "gh was run"
ok

# A tracked file: an untracked one is not what "dirty" means here (`git status --untracked-files=no`).
echo dirty >> "$fixture/scripts/check-disk-floor.sh"
out="$(bash "$PUBLISH" --repo "$fixture" --out "$WORK/never" --check --local --allow-empty-codemode 2>&1)"
expect_status 2 "$?" "a dirty tree"
contains "$out" "source_dirty:" "the dirty refusal is named"
git -C "$fixture" checkout -q -- . 2>/dev/null || true

# A commit that is ahead of origin/main is refused unless --local says this is a test artifact.
echo two > "$fixture/README.md" && git -C "$fixture" add -A && git -C "$fixture" commit -qm two
out="$(bash "$PUBLISH" --repo "$fixture" --out "$WORK/never" --check --allow-empty-codemode 2>&1)"
expect_status 2 "$?" "a commit that is not on origin/main"
contains "$out" "not_on_main:" "the main refusal is named"
out="$(bash "$PUBLISH" --repo "$fixture" --out "$WORK/never" --check --local --allow-empty-codemode 2>&1)"
expect_status 0 "$?" "the same commit with --local"
git -C "$fixture" reset -q --hard "$FIXTURE_SHA"

# ---- --from: verify artifacts built elsewhere, then print (never run) the publish command -------------
built="$WORK/built"
mkdir -p "$built"
mkelf "$built/wa-$TRIPLE-$SHORT" 3e
mkelf "$built/wa-sentinel-$TRIPLE-$SHORT" 3e
cat > "$built/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$HEAD_SHA
source_tree=$(git -C "$ROOT" rev-parse "$HEAD_SHA^{tree}")
rustc_version=fixture
zig_version=fixture
glibc_floor=2.31
codemode=embedded
built_utc=2026-11-06T00:00:00Z
# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes
$TRIPLE $(sha "$built/wa-$TRIPLE-$SHORT") $(bytes "$built/wa-$TRIPLE-$SHORT") $(sha "$built/wa-sentinel-$TRIPLE-$SHORT") $(bytes "$built/wa-sentinel-$TRIPLE-$SHORT")
MANIFEST

out="$(bash "$PUBLISH" --from "$built" --out "$WORK/bundle-good" --target "$TRIPLE" 2>&1)"
expect_status 0 "$?" "--from a matching artifact set"
contains "$out" "verified wa-$TRIPLE-$SHORT:" "every member is verified"
contains "$out" "gh release create node-$SHORT -R" "the publish command is printed"
contains "$out" "wa-$TRIPLE-$SHORT" "the command names the binary asset"
contains "$out" "node-$SHORT.manifest" "the command names the pins"
[ -f "$WORK/bundle-good/node-$SHORT.manifest" ] || fail "the manifest was not carried into the bundle"
ok
cmp -s "$WORK/bundle-good/wa-$TRIPLE-$SHORT" "$built/wa-$TRIPLE-$SHORT" || fail "the bundled binary differs from the verified one"
ok
[ ! -f "$WORK/gh-called" ] || fail "gh was run: $(cat "$WORK/gh-called")"
ok
# The compiled-inputs digest travels in the manifest that ships: a deploy of a later commit whose compiled
# inputs hash to this value installs THIS release instead of compiling (job relmatch). The incoming fixture
# manifest had no such row, so this is also the "an older artifact is given one" case.
contains "$(cat "$WORK/bundle-good/node-$SHORT.manifest")" \
  "compiled_inputs=$(wa_compiled_inputs_digest "$ROOT" "$HEAD_SHA")" \
  "the bundled manifest records the commit's compiled-inputs digest"

# --from with a tampered binary: the bytes that claim to be this build are not.
bad="$WORK/built-tampered"; cp -r "$built" "$bad"
printf 'tampered' >> "$bad/wa-$TRIPLE-$SHORT"
out="$(bash "$PUBLISH" --from "$bad" --out "$WORK/bundle-bad" --target "$TRIPLE" 2>&1)"
expect_status 5 "$?" "--from a tampered binary"
contains "$out" "artifact_not_pinned: wa-$TRIPLE-$SHORT" "the hash refusal names the asset"

# --from with a size that does not match the pin. Re-pin the tampered bytes' hash so only the size is wrong.
sized="$WORK/built-sized"; cp -r "$built" "$sized"
printf 'x' >> "$sized/wa-$TRIPLE-$SHORT"
sed -i.bak "s/^$TRIPLE [0-9a-f]* [0-9]* /$TRIPLE $(sha "$sized/wa-$TRIPLE-$SHORT") 1 /" "$sized/node-$SHORT.manifest" 2>/dev/null \
  || sed -i '' "s/^$TRIPLE [0-9a-f]* [0-9]* /$TRIPLE $(sha "$sized/wa-$TRIPLE-$SHORT") 1 /" "$sized/node-$SHORT.manifest"
out="$(bash "$PUBLISH" --from "$sized" --out "$WORK/bundle-sized" --target "$TRIPLE" 2>&1)"
expect_status 6 "$?" "--from a binary of the wrong size"
contains "$out" "artifact_not_pinned:" "the size refusal is named"

# --from with another commit's manifest.
foreign="$WORK/built-foreign"; cp -r "$built" "$foreign"
sed -i.bak "s/^source_commit=.*/source_commit=$(printf '2%.0s' $(seq 40))/" "$foreign/node-$SHORT.manifest" 2>/dev/null \
  || sed -i '' "s/^source_commit=.*/source_commit=$(printf '2%.0s' $(seq 40))/" "$foreign/node-$SHORT.manifest"
out="$(bash "$PUBLISH" --from "$foreign" --out "$WORK/bundle-foreign" --target "$TRIPLE" 2>&1)"
expect_status 2 "$?" "--from a manifest that names another commit"
contains "$out" "manifest_commit_mismatch:" "the commit refusal is named"

# --from with a missing asset.
missing="$WORK/built-missing"; cp -r "$built" "$missing"; rm -f "$missing/wa-sentinel-$TRIPLE-$SHORT"
out="$(bash "$PUBLISH" --from "$missing" --out "$WORK/bundle-missing" --target "$TRIPLE" 2>&1)"
expect_status 2 "$?" "--from a set that is missing an asset"
contains "$out" "binary_missing:" "the missing asset is named"

# --from with a compiled-inputs row that is not this commit's tree: the digest is a fact about the commit,
# so a manifest that disagrees would be installed by every docs-only descendant of a commit it is not the
# build of. Refused by name, before anything is printed for upload.
wrongdigest="$WORK/built-wrongdigest"; cp -r "$built" "$wrongdigest"
printf 'compiled_inputs=%s\n' "$(printf '0%.0s' $(seq 64))" >> "$wrongdigest/node-$SHORT.manifest"
out="$(bash "$PUBLISH" --from "$wrongdigest" --out "$WORK/bundle-wrongdigest" --target "$TRIPLE" 2>&1)"
expect_status 5 "$?" "--from a manifest whose compiled_inputs is another tree's"
contains "$out" "compiled_inputs_mismatch:" "the digest refusal is named"

# --from with an ELF machine that does not match the row.
machine="$WORK/built-machine"; mkdir -p "$machine"
mkelf "$machine/wa-$OTHER_TRIPLE-$SHORT" 3e   # the aarch64 row, an x86_64 binary
mkelf "$machine/wa-sentinel-$OTHER_TRIPLE-$SHORT" 3e
sed "s/^$TRIPLE /$OTHER_TRIPLE /; s/wa-$TRIPLE-/wa-$OTHER_TRIPLE-/g" "$built/node-$SHORT.manifest" > /dev/null
cat > "$machine/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$HEAD_SHA
glibc_floor=2.31
codemode=embedded
$OTHER_TRIPLE $(sha "$machine/wa-$OTHER_TRIPLE-$SHORT") $(bytes "$machine/wa-$OTHER_TRIPLE-$SHORT") $(sha "$machine/wa-sentinel-$OTHER_TRIPLE-$SHORT") $(bytes "$machine/wa-sentinel-$OTHER_TRIPLE-$SHORT")
MANIFEST
out="$(bash "$PUBLISH" --from "$machine" --out "$WORK/bundle-machine" --target "$OTHER_TRIPLE" 2>&1)"
expect_status 5 "$?" "--from a binary built for another architecture"
contains "$out" "machine_mismatch:" "the machine refusal is named"

# --from with a binary that needs a newer glibc than the pin promises.
glibc="$WORK/built-glibc"; mkdir -p "$glibc"
mkelf "$glibc/wa-$TRIPLE-$SHORT" 3e 'GLIBC_2.39'
mkelf "$glibc/wa-sentinel-$TRIPLE-$SHORT" 3e
cat > "$glibc/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$HEAD_SHA
glibc_floor=2.31
codemode=embedded
$TRIPLE $(sha "$glibc/wa-$TRIPLE-$SHORT") $(bytes "$glibc/wa-$TRIPLE-$SHORT") $(sha "$glibc/wa-sentinel-$TRIPLE-$SHORT") $(bytes "$glibc/wa-sentinel-$TRIPLE-$SHORT")
MANIFEST
out="$(bash "$PUBLISH" --from "$glibc" --out "$WORK/bundle-glibc" --target "$TRIPLE" 2>&1)"
expect_status 5 "$?" "--from a binary newer than the glibc floor it claims"
contains "$out" "glibc_floor_exceeded:" "the glibc refusal is named"

# --from a cross build that could not embed the code-mode assets: refused unless an operator names it.
emptycm="$WORK/built-empty"; cp -r "$built" "$emptycm"
sed -i.bak 's/^codemode=embedded/codemode=empty/' "$emptycm/node-$SHORT.manifest" 2>/dev/null \
  || sed -i '' 's/^codemode=embedded/codemode=empty/' "$emptycm/node-$SHORT.manifest"
out="$(bash "$PUBLISH" --from "$emptycm" --out "$WORK/bundle-empty" --target "$TRIPLE" 2>&1)"
expect_status 2 "$?" "--from a binary without the code-mode assets"
contains "$out" "codemode_assets_absent:" "the empty-code-mode refusal is named"
out="$(bash "$PUBLISH" --from "$emptycm" --out "$WORK/bundle-empty-ok" --target "$TRIPLE" --allow-empty-codemode 2>&1)"
expect_status 0 "$?" "the same artifact when the exemption is named"
contains "$out" "code-mode empty" "the release notes record that it has no code mode"

# A target this channel does not publish.
out="$(bash "$PUBLISH" --from "$built" --out "$WORK/bundle-x" --target riscv64-unknown-linux-gnu 2>&1)"
expect_status 2 "$?" "an unsupported target"
contains "$out" "target_unsupported:" "the target refusal is named"

# --check with no --target: the plan names both Linux triples and the exact build command it would run.
# Against the fixture tree, not this checkout: a test that needs the working tree to be clean fails while
# the change it is testing is still uncommitted, which is exactly when it is run.
out="$(bash "$PUBLISH" --repo "$fixture" --out "$WORK/never2" --check --local --allow-empty-codemode 2>&1)"
expect_status 0 "$?" "--check planning both targets"
contains "$out" "aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu" "both published targets are planned"
contains "$out" "cargo zigbuild --release --offline --locked" "the exact build command is printed"
[ ! -d "$WORK/never2" ] || fail "--check created the bundle directory"
ok
[ ! -f "$WORK/gh-called" ] || fail "gh was run during --check: $(cat "$WORK/gh-called")"
ok

# ---- --ensure: a commit whose compiled inputs a published release already covers builds nothing ------
# The landing's cheap answer, on the same digest rule the deploy's fallback uses. A stub release (a local
# directory: no network, no gh) holds this fixture commit's manifest and pins.
releases="$WORK/releases"
mkdir -p "$releases"
printf 'node-%s\n' "$FIXTURE_SHORT" > "$releases/releases.txt"
mkelf "$releases/wa-$TRIPLE-$FIXTURE_SHORT" 3e
mkelf "$releases/wa-sentinel-$TRIPLE-$FIXTURE_SHORT" 3e
cat > "$releases/node-$FIXTURE_SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$FIXTURE_SHA
compiled_inputs=$(wa_compiled_inputs_digest "$fixture" "$FIXTURE_SHA")
codemode=embedded
$TRIPLE $(sha "$releases/wa-$TRIPLE-$FIXTURE_SHORT") $(bytes "$releases/wa-$TRIPLE-$FIXTURE_SHORT") $(sha "$releases/wa-sentinel-$TRIPLE-$FIXTURE_SHORT") $(bytes "$releases/wa-sentinel-$TRIPLE-$FIXTURE_SHORT")
MANIFEST
# Signed, because every release asset a node accepts now carries `SHA256SUMS` + its signature; the tag
# directory IS this release's base (it holds releases.txt and the payloads flat), so they live there.
test_release_sign_dir "$releases" || fail "could not sign the fixture release"
rm -f "$WORK/gh-called"
out="$(WA_NODE_BINARIES_URL="$releases" bash "$PUBLISH" --repo "$fixture" --out "$WORK/ensure" --ensure --target "$TRIPLE" --allow-empty-codemode 2>&1)"
expect_status 0 "$?" "--ensure where a release covers the commit"
contains "$out" "covered: node-$FIXTURE_SHORT covers the compiled inputs of $FIXTURE_SHA" "the covering release is named"
contains "$out" "nothing to build or publish" "a covered commit builds nothing"
[ ! -f "$WORK/ensure/node-$FIXTURE_SHORT.manifest" ] || fail "--ensure built when it was already covered"
ok
[ ! -f "$WORK/gh-called" ] || fail "--ensure called gh: $(cat "$WORK/gh-called")"
ok

# A release whose manifest matches the digest but whose bytes do not is a refusal, not a rebuild: the
# bytes that claim to be this commit's build are not, exactly as in a deploy.
badrelease="$WORK/releases-tampered"; cp -r "$releases" "$badrelease"
printf 'tampered' >> "$badrelease/wa-$TRIPLE-$FIXTURE_SHORT"
out="$(WA_NODE_BINARIES_URL="$badrelease" bash "$PUBLISH" --repo "$fixture" --out "$WORK/ensure-bad" --ensure --target "$TRIPLE" --allow-empty-codemode 2>&1)"
expect_status 5 "$?" "--ensure against a matching release whose bytes were tampered with"
contains "$out" "ensure_refused:" "the tampered-release refusal is named"
contains "$out" "node_hash_mismatch:" "the hash refusal is the deploy's own"

# Nothing published for this commit's digest: --ensure says so and lets the caller continue. --from keeps
# this hermetic: the artifact set is verified, no compiler runs.
empty="$WORK/releases-empty"; mkdir -p "$empty"; : > "$empty/releases.txt"
out="$(WA_NODE_BINARIES_URL="$empty" bash "$PUBLISH" --from "$built" --out "$WORK/ensure-none" --ensure --target "$TRIPLE" 2>&1)"
expect_status 0 "$?" "--ensure on a commit nothing covers"
contains "$out" "not covered for $TRIPLE" "the uncovered target is named"
contains "$out" "verified wa-$TRIPLE-$SHORT:" "the caller continues with the artifact it has"

# ---- --publish: the release is created by the landing step, not pasted by hand ----------------------
rm -f "$WORK/gh-called"
out="$(bash "$PUBLISH" --from "$built" --out "$WORK/bundle-pub" --target "$TRIPLE" --publish 2>&1)"
expect_status 0 "$?" "--publish creates the release"
contains "$out" "published node-$SHORT:" "the published release is named"
grep -q "release create node-$SHORT -R .* --target $HEAD_SHA " "$WORK/gh-called" \
  || fail "the publish did not create node-$SHORT against $HEAD_SHA: $(cat "$WORK/gh-called")"
ok
out="$(bash "$PUBLISH" --from "$built" --out "$WORK/bundle-pub-local" --target "$TRIPLE" --local --publish 2>&1)"
expect_status 2 "$?" "--publish with --local"
contains "$out" "publish_local_refused:" "a test artifact is never published"

# ---- the run gate asks about THIS triple, not about the target set -------------------------------
# Measured 2026-11-11 on wa-desktop (Ubuntu x86_64), the first Linux host to publish BOTH rows: the
# publisher read its "can this host execute it" answer off the SET of targets, which holds x86_64
# somewhere, so it executed the aarch64 binary too and a 481s verified build ended in
# `run_failed: wa-aarch64-unknown-linux-gnu-<sha12> --version did not answer on this host`. The gate has to
# answer for the row in front of it: the native one is RUN and proved, the other is SKIPPED and said so.
native_triple=""
case "$(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)" in
  Linux/x86_64|Linux/amd64) native_triple=x86_64-unknown-linux-gnu ;;
  Linux/aarch64|Linux/arm64) native_triple=aarch64-unknown-linux-gnu ;;
esac
if [ -z "$native_triple" ] || [ ! -x /bin/true ]; then
  # The case needs a REAL ELF of this machine (a fixture cannot be executed, and a host that can execute
  # neither Linux row is the case the gate already handled). Reported, never counted as a pass.
  echo "run gate (per triple): SKIPPED (this host $(uname -s)/$(uname -m) cannot execute a Linux ELF)"
else
  case "$native_triple" in
    x86_64-*) other_triple=aarch64-unknown-linux-gnu; other_hex=b7 ;;
    *) other_triple=x86_64-unknown-linux-gnu; other_hex=3e ;;
  esac
  built_n="$WORK/built-native"; mkdir -p "$built_n"
  cp /bin/true "$built_n/wa-$native_triple-$SHORT"
  cp /bin/true "$built_n/wa-sentinel-$native_triple-$SHORT"
  mkelf "$built_n/wa-$other_triple-$SHORT" "$other_hex"
  mkelf "$built_n/wa-sentinel-$other_triple-$SHORT" "$other_hex"
  # The host's own /bin/true needs this host's glibc, so the floor is named as the value the check is given
  # (a fixture is not a release: a release's floor is 2.31, linked by zig).
  floor="$(grep -a -o 'GLIBC_2\.[0-9]\+' /bin/true 2>/dev/null | sed 's/^GLIBC_//' | sort -uV | tail -1)"
  [ -n "$floor" ] || floor=2.31
  cat > "$built_n/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$HEAD_SHA
source_tree=$(git -C "$ROOT" rev-parse "$HEAD_SHA^{tree}")
rustc_version=fixture
zig_version=fixture
glibc_floor=$floor
codemode=embedded
built_utc=2026-11-11T00:00:00Z
# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes
$native_triple $(sha "$built_n/wa-$native_triple-$SHORT") $(bytes "$built_n/wa-$native_triple-$SHORT") $(sha "$built_n/wa-sentinel-$native_triple-$SHORT") $(bytes "$built_n/wa-sentinel-$native_triple-$SHORT")
$other_triple $(sha "$built_n/wa-$other_triple-$SHORT") $(bytes "$built_n/wa-$other_triple-$SHORT") $(sha "$built_n/wa-sentinel-$other_triple-$SHORT") $(bytes "$built_n/wa-sentinel-$other_triple-$SHORT")
MANIFEST
  out="$(env -u WA_PUBLISH_RUNNER bash "$PUBLISH" --from "$built_n" --out "$WORK/bundle-native" \
    --glibc "$floor" --target "$native_triple" --target "$other_triple" 2>&1)"
  expect_status 0 "$?" "a run publishing one row this host can execute and one it cannot"
  contains "$out" "ran $native_triple natively" "the row this host can execute is RUN and proved"
  contains "$out" "run: SKIPPED for $other_triple" "the row it cannot execute is SKIPPED, and the build is not refused"
  absent "$out" "run_failed" "and neither row reports a failed run"
  contains "$out" "gh release create node-$SHORT -R" "the release command is still printed for both rows"
fi

echo "node binaries (publish) ok ($checks checks)"

# ---- the toolchain is the script's own, not the caller's --------------------------------------------
# Measured 2026-11-10 (the aarch64 publisher): `zig` lives in the pip package `ziglang` and was not on
# PATH, and `CARGO_TARGET_DIR` was whatever the caller's shell exported - so `wa-sentinel`, whose Cargo
# workspace is its own, wrote its binary under rust/wa-sentinel/target while the publisher looked under
# rust/target. Both are the script's business: a landing must be able to run it with no environment.
# A PATH with git and the shell utilities but WITHOUT the directory zig was found in (when there is
# one): that is the caller environment the bug was measured in.
GIT_DIR_ON_PATH="$(dirname "$(command -v git)")"
ZIG_DIR_ON_PATH="$(dirname "$(command -v zig 2>/dev/null || echo /nonexistent/zig)")"
BARE_PATH=""
for part in /usr/bin /bin "$GIT_DIR_ON_PATH" "$ZIG_DIR_ON_PATH"; do
  [ "$part" = "$ZIG_DIR_ON_PATH" ] && continue
  case ":$BARE_PATH:" in *":$part:"*) continue ;; esac
  BARE_PATH="${BARE_PATH:+$BARE_PATH:}$part"
done
out="$(env -u CARGO_TARGET_DIR -u WA_ZIG PATH="$BARE_PATH" bash "$PUBLISH" --repo "$fixture"   --out "$WORK/never" --check --local --allow-empty-codemode 2>&1)"
expect_status 0 "$?" "--check with zig off PATH and no CARGO_TARGET_DIR"
contains "$out" "zig: " "the plan names the zig it would use (or says none was found)"
contains "$out" "cargo target dir: $fixture/rust/target" "the plan names the one target directory"
contains "$out" "--target-dir overrides" "and the supported override"
# The two crates are built from two workspaces; one exported target directory is what makes the second
# one visible to the lookup that copies the artifacts out.
grep -q 'export CARGO_TARGET_DIR="$TARGET_DIR"' "$PUBLISH" \
  || fail "the publisher does not export one CARGO_TARGET_DIR for both workspaces"
ok
# The discovery covers the pip package on every host that has one, and an operator can always name the
# binary explicitly.
contains "$(cat "$PUBLISH")" 'import ziglang,os' "the publisher looks inside the pip ziglang package"
contains "$(cat "$PUBLISH")" 'WA_ZIG' "and an operator can name zig explicitly"
# PATH alone is not enough (measured: cargo-zigbuild 0.24.1 could not find a zig its own PATH held), so
# the binary is named through the crate's supported variable instead of being searched for.
contains "$(cat "$PUBLISH")" 'CARGO_ZIGBUILD_ZIG_COMMAND' "the publisher names the zig binary for cargo-zigbuild"
out="$(WA_ZIG=/nonexistent/zig bash "$PUBLISH" --repo "$fixture" --out "$WORK/never" \
  --check --local --allow-empty-codemode 2>&1)"
expect_status 0 "$?" "a bad WA_ZIG does not break the plan (the build refuses, not the plan)"
contains "$out" "cargo zigbuild uses: CARGO_ZIGBUILD_ZIG_COMMAND=" "and the plan names the binary cargo-zigbuild will use, not only a PATH"
