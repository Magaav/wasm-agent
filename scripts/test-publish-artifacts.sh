#!/usr/bin/env bash
# Proof for the two halves that make a Linux node a publisher:
#   scripts/provision-publish-toolchain.sh   the pinned toolchain (zig, cargo-zigbuild, rust-std)
#   scripts/publish-artifacts-branch.sh      the transport: release files -> orphan git ref a host with gh
#                                            can publish from
#
# No network, no cargo, no gh, no zig build: the artifacts are ELF fixtures and the tools are shims that
# answer `--version`, so "it found the right tool" and "it installed nothing" are checked, not promised.
#
# What each case earns:
#   * --check on a host with no toolchain names EVERY missing requirement (zig, cargo-zigbuild, the
#     rust-std of each target), exits 1, and creates no directory - the row an operator reads before
#     paying for an install;
#   * --check with the pinned tools answers ok, and a zig of another version is a `warn` (reported, left
#     alone) rather than a silent swap of a toolchain behind the user's back;
#   * a rust-std that is not installed is named per triple, because that is the failure ("can't find crate
#     for `std`") a cross build dies with;
#   * the transport refuses without a remote, writes a PUBLISH.sh whose gh line is the publisher's own and
#     whose paths are relative to the commit root, and pushes an ORPHAN commit of exactly the release
#     files - read back from the remote, with each payload's sha256 still the pin;
#   * --dry-run commits and pushes nothing, and no `gh` is ever executed.
#
#   bash scripts/test-publish-artifacts.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PROVISION="$ROOT/scripts/provision-publish-toolchain.sh"
SHIP="$ROOT/scripts/publish-artifacts-branch.sh"

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "publish artifacts FAILED: $*" >&2; exit 1; }
expect_status() { # <want> <got> <what>
  [ "$2" = "$1" ] || fail "$3: expected status $1, got $2"
  ok
}
contains() { # <text> <needle> <what>
  printf '%s' "$1" | grep -qF -- "$2" || fail "$3: '$2' not in: $1"
  ok
}
absent() { # <text> <needle> <what>
  printf '%s' "$1" | grep -qF -- "$2" && fail "$3: '$2' unexpectedly in: $1"
  ok
}
not_dir() { [ ! -e "$1" ] || fail "$2: $1 was created"; ok; }

syspath="/usr/bin:/bin"
# The publisher PROVES a candidate by running it, and a fixture is not executable. Its own --runner knob
# (WA_PUBLISH_RUNNER) names a prefix it trusts for that step, so the transport can be exercised here
# without pretending a fixture binary runs: `true` answers for it. The run gate itself is proved by
# scripts/test-node-binaries.sh.
export WA_PUBLISH_RUNNER=true
# ---- tool shims: `zig`, `cargo-zigbuild`, `rustup`, and a `gh` that records being called -----------
mkdir -p "$WORK/bin" "$WORK/nozig/bin"
cat > "$WORK/bin/zig" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_ZIG_VERSION:-0.17.1}"
SHIM
cat > "$WORK/bin/cargo-zigbuild" <<'SHIM'
#!/usr/bin/env bash
printf 'cargo-zigbuild %s\n' "${FAKE_ZIGBUILD_VERSION:-0.24.1}"
SHIM
cat > "$WORK/bin/rustup" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-} ${2:-} ${3:-}" = "target list --installed" ]; then printf '%s\n' ${FAKE_RUST_TARGETS:-aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu}; fi
exit 0
SHIM
cat > "$WORK/bin/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh-called"
exit 1
SHIM
chmod +x "$WORK/bin/"* 2>/dev/null || true

# ---- 1. a host with no toolchain: every requirement named, nothing installed ------------------------
mkdir -p "$WORK/home1"
out="$(env -i HOME="$WORK/home1" PATH="$syspath" bash "$PROVISION" --check 2>&1)"; rc=$?
expect_status 1 "$rc" "--check refuses a host with no toolchain"
contains "$out" "missing zig" "the missing C compiler/linker is named"
contains "$out" "missing cargo-zigbuild" "the missing cargo subcommand is named"
contains "$out" "no zig on PATH" "the zig row says where it looked"
contains "$out" "installs 0.17.1" "the zig row names the pinned version it would install"
contains "$out" "installs 0.24.1" "the cargo-zigbuild row names the pinned version"
not_dir "$WORK/home1/.local" "--check must not install anything"

# ---- 2. the pinned tools: ok; another zig: warn; a missing rust-std: named per triple ---------------
mkdir -p "$WORK/home2"
out="$(env -i HOME="$WORK/home2" PATH="$WORK/bin:$syspath" bash "$PROVISION" --check 2>&1)"; rc=$?
expect_status 0 "$rc" "--check passes with the pinned toolchain"
contains "$out" "ok      zig" "the pinned zig is ok"
contains "$out" "ok      cargo-zigbuild" "the pinned cargo-zigbuild is ok"
contains "$out" "ok      rust-target  aarch64-unknown-linux-gnu" "the aarch64 rust-std is ok"
contains "$out" "ok      rust-target  x86_64-unknown-linux-gnu" "the x86_64 rust-std is ok"
out="$(env -i HOME="$WORK/home2" PATH="$WORK/bin:$syspath" FAKE_ZIG_VERSION=0.16.0 bash "$PROVISION" --check 2>&1)"; rc=$?
expect_status 0 "$rc" "another zig version does not fail the check"
contains "$out" "warn    zig" "another zig version is reported, not swapped"
contains "$out" "0.16.0; the publisher was measured with 0.17.1" "the warn says which version it found and which was measured"
out="$(env -i HOME="$WORK/home2" PATH="$WORK/bin:$syspath" FAKE_RUST_TARGETS="aarch64-unknown-linux-gnu" bash "$PROVISION" --check 2>&1)"; rc=$?
expect_status 1 "$rc" "an uninstalled rust-std is a missing requirement"
contains "$out" "missing rust-target  x86_64-unknown-linux-gnu" "the missing triple is named"
contains "$out" "rustup target add x86_64-unknown-linux-gnu" "and the command that fixes it"

# ---- 3. the transport: refusals by name -------------------------------------------------------------
out="$(bash "$SHIP" --dry-run 2>&1)"; rc=$?
expect_status 2 "$rc" "a transport without a remote is refused"
contains "$out" "remote_required" "the refusal is named"
out="$(bash "$SHIP" --remote "$WORK/dropbox.git" --targets mosarch-unknown-linux-gnu --dry-run 2>&1)"; rc=$?
expect_status 2 "$rc" "an unsupported target is refused before any publisher run"
contains "$out" "target_unsupported" "an unsupported target is refused by name"

# ---- 4. a fixture release: the publisher verifies it, the transport ships an orphan ref ------------
COMMIT="$(git rev-parse HEAD)"
SHORT="${COMMIT:0:12}"
TRIPLE=x86_64-unknown-linux-gnu
FIX="$WORK/fixture"; mkdir -p "$FIX"
mkelf() { # FILE MACHINE_HEX [EXTRA]
  { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$2"; printf 'fixture-binary%s' "${3:-}"; } > "$1"
}
mkelf "$FIX/wa-$TRIPLE-$SHORT" 3e
mkelf "$FIX/wa-sentinel-$TRIPLE-$SHORT" 3e
wa_sha="$(sha256sum "$FIX/wa-$TRIPLE-$SHORT" | awk '{print $1}')"
wa_bytes="$(wc -c < "$FIX/wa-$TRIPLE-$SHORT" | tr -d '[:space:]')"
sen_sha="$(sha256sum "$FIX/wa-sentinel-$TRIPLE-$SHORT" | awk '{print $1}')"
sen_bytes="$(wc -c < "$FIX/wa-sentinel-$TRIPLE-$SHORT" | tr -d '[:space:]')"
cat > "$FIX/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$COMMIT
source_tree=$(git rev-parse HEAD^{tree})
rustc_version=fixture
zig_version=fixture
glibc_floor=2.31
codemode=embedded
built_utc=2026-11-11T00:00:00Z
# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes
$TRIPLE $wa_sha $wa_bytes $sen_sha $sen_bytes
MANIFEST
git init -q --bare "$WORK/dropbox.git"
STAGE="$WORK/stage"; mkdir -p "$STAGE"
out="$(PATH="$WORK/bin:$PATH" bash "$SHIP" --remote "$WORK/dropbox.git" --from "$FIX" --out "$WORK/out" \
        --targets "$TRIPLE" --keep "$STAGE" 2>&1)"; rc=$?
expect_status 0 "$rc" "the transport ships a verified fixture release: $out"
contains "$out" "PUBLISHREADY artifacts/node-$SHORT " "the READY line names the ref"
contains "$out" " source=$COMMIT" "the READY line names the source commit"
contains "$out" "$wa_sha  $wa_bytes  wa-$TRIPLE-$SHORT" "the report carries the payload's sha256 and size"
absent "$out" "gh release" "the transport never runs gh (the command is only written into PUBLISH.sh)"
[ -s "$WORK/gh-called" ] && fail "gh was executed: $(cat "$WORK/gh-called")"
ok

# PUBLISH.sh: the publisher's own command, with paths relative to the commit root.
# --keep names the PARENT the staged release is left under (so a failed run can be inspected).
P="$(ls "$STAGE"/wasm-agent-artifacts.*/PUBLISH.sh 2>/dev/null | head -1)"
[ -n "$P" ] || fail "--keep $STAGE holds no staged release"
ok
[ -f "$P" ] || fail "PUBLISH.sh was not written into the staged release"
contains "$(cat "$P")" "gh release create node-$SHORT" "PUBLISH.sh carries the gh release create line"
contains "$(cat "$P")" "wa-$TRIPLE-$SHORT" "PUBLISH.sh names the relative payload path"
contains "$(cat "$P")" "--target $COMMIT" "PUBLISH.sh pins the release target to the source commit"
absent "$(cat "$P")" "$WORK" "PUBLISH.sh has no absolute build path from this machine"
# A published command that cannot fail is not a command: `gh release create ... || true` swallows a
# failed publish, and it was shipped that way once while this script was being written.
absent "$(cat "$P")" "|| true" "PUBLISH.sh does not swallow a failed gh call"
contains "$(grep -v '^#' "$P")" 'set -euo pipefail' "and the file fails loudly (set -euo pipefail)"
contains "$(cat "$P")" "source commit: $COMMIT" "PUBLISH.sh records the source commit"

# The pushed ref: an orphan commit of exactly the release files, read back from the remote itself.
readback="$(git ls-remote "$WORK/dropbox.git" "refs/heads/artifacts/node-$SHORT" | awk '{print $1}')"
[ -n "$readback" ] || fail "the ref was not pushed to the drop box"
ok
contains "$out" "pushed and read back:" "the transport says it read the ref back"
contains "$out" "PUBLISHREADY artifacts/node-$SHORT $readback source=$COMMIT" "the READY line carries the artifacts commit"
parents="$(git --git-dir="$WORK/dropbox.git" rev-list --parents -n1 "$readback" | wc -w | tr -d '[:space:]')"
[ "$parents" = 1 ] || fail "the artifacts commit is not an orphan (rev-list --parents lists $parents ids)"
ok
files="$(git --git-dir="$WORK/dropbox.git" ls-tree -r --name-only "$readback" | sort | tr '\n' ' ')"
# SHA256SUMS is part of the set, not beside it: the shipped PUBLISH.sh names it (the publisher does), and
# measured 13/11 the ref carried PUBLISH.sh, the manifest and the payloads while that line asked for a file
# the commit did not hold - a publish that fails on a missing file, after a human was told to paste it.
want="PUBLISH.sh SHA256SUMS node-$SHORT.manifest wa-sentinel-$TRIPLE-$SHORT wa-$TRIPLE-$SHORT "
[ "$files" = "$want" ] || fail "the commit holds '$files', expected exactly '$want'"
ok
contains "$(cat "$P")" "SHA256SUMS" "PUBLISH.sh names SHA256SUMS (which is why the commit must carry it)"
sums="$(git --git-dir="$WORK/dropbox.git" cat-file -p "$readback:SHA256SUMS")"
contains "$sums" "$wa_sha  wa-$TRIPLE-$SHORT" "SHA256SUMS pins the payload the manifest pins"
contains "$sums" "$sen_sha  wa-sentinel-$TRIPLE-$SHORT" "SHA256SUMS pins the supervisor too"
contains "$(git --git-dir="$WORK/dropbox.git" cat-file -p "$readback:SHA256SUMS" | grep -c .)" "3" \
  "SHA256SUMS holds one row per payload and the manifest"
shipped_sha="$(git --git-dir="$WORK/dropbox.git" cat-file -p "$readback:wa-$TRIPLE-$SHORT" | sha256sum | awk '{print $1}')"
[ "$shipped_sha" = "$wa_sha" ] || fail "the shipped payload is $shipped_sha, the pin is $wa_sha"
ok

# ---- 5. a tampered payload never becomes a commit ---------------------------------------------------
mkdir -p "$WORK/tampered"
cp "$FIX"/* "$WORK/tampered/"
printf 'tampered' >> "$WORK/tampered/wa-$TRIPLE-$SHORT"
git init -q --bare "$WORK/dropbox2.git"
out="$(bash "$SHIP" --remote "$WORK/dropbox2.git" --from "$WORK/tampered" --out "$WORK/out2" --targets "$TRIPLE" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok || fail "a tampered payload must not ship: $out"
contains "$out" "artifact_not_pinned" "the tampered payload is refused by name"
absent "$(git ls-remote "$WORK/dropbox2.git" 2>/dev/null)" "artifacts/node-$SHORT" "nothing was pushed for the refused release"

# ---- 6. --dry-run: everything but the commit and the push ------------------------------------------
out="$(bash "$SHIP" --remote "$WORK/dropbox.git" --from "$FIX" --out "$WORK/out3" --targets "$TRIPLE" --dry-run 2>&1)"; rc=$?
expect_status 0 "$rc" "--dry-run succeeds without pushing"
contains "$out" "PUBLISHREADY(unpushed) artifacts/node-$SHORT" "the dry run says the ref is not pushed"
contains "$out" "dry run: nothing committed or pushed" "and says so in a line of its own"

echo "publish artifacts: ok ($checks checks)"
