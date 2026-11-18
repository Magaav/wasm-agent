#!/usr/bin/env bash
# Does linux/bootstrap.sh honour an override it is given, and refuse an install nothing can identify?
#
# WHAT THIS EXISTS FOR. Two holes measured in round 3 of the deploy-ancestry review, both on the release-install
# path (the one a node with no compiler uses):
#
#   1. "a first install" was decided from "nothing here NAMES a commit", not from "nothing is installed". A node
#      whose binary predates --build-info, or whose record says commit= and carries no sha256=, was therefore
#      announced as "a first install, not a downgrade" and replaced with no ancestry question at all.
#   2. the pin override could never happen: the gate tested the LITERAL strings ("[ force = 1 ]" is always
#      false) and printed a variable that does not exist. So --force --reason on a pinned node refused every
#      time, with a message that could not say why - an operator had no way to move such a node with this script.
#
# HOW IT IS PROVEN. The real bootstrap core is run against a signed fixture release on the local filesystem
# (file: URLs, the opt-in the script documents), with a bundle whose wa is a real ELF built here, so every gate
# in front of the ancestry question passes for the right reason: index, signature, size, sha256, ELF machine,
# --version, --build-info. Nothing is downloaded and nothing outside the scratch tree is touched.
#
# Usage:  bash scripts/test-bootstrap-gate.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CORE="$ROOT/scripts/linux/bootstrap.sh"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found in: $(printf '%s' "$2" | tail -3)" ;; esac; }
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok "$1" ;; esac; }

if ! command -v cc >/dev/null 2>&1; then
  printf 'SKIP test-bootstrap-gate: no C compiler (the fixture bundle needs a real ELF binary)\n'
  exit 0
fi
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-bootstrap-gate.XXXXXX") || { printf 'FAIL tmpdir_unavailable\n' >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
if ! ( cp /bin/true "$T/.exec-probe" && "$T/.exec-probe" ) >/dev/null 2>&1; then
  printf 'FAIL tmpdir_noexec: %s cannot execute a file; set TMPDIR to a normal filesystem\n' "$T" >&2
  exit 1
fi
rm -f "$T/.exec-probe"

case "$(uname -m)" in aarch64|arm64) TARGET=aarch64-unknown-linux-gnu ;; *) TARGET=x86_64-unknown-linux-gnu ;; esac
NODEV=24.22.1
COMMIT1=1111111111111111111111111111111111111111
COMMIT2=2222222222222222222222222222222222222222
mkdir -p "$T/home" "$T/bin" "$T/agent-home/.wasm-agent"
printf 'fixture-node\n' > "$T/agent-home/.wasm-agent/node.name"
# The release fixture keys: TEST keys, committed on purpose (tests/fixtures/release-sign/).
export WA_RELEASE_KEYS="$ROOT/tests/fixtures/release-sign/keys.txt"
export WASM_AGENT_HOME="$T/agent-home"

# ---- the fixture bundle's binary ---------------------------------------------------------------------
# A real ELF for this machine's architecture (the core reads byte 18 and refuses anything else), whose identity is
# compiled in: which commit it is, how many ancestors it has, and which commits it contains.
build_stub() { # <out> <commit> <ancestors> [contained commits...]
  local out="$1" commit="$2" ancestors="$3"; shift 3
  {
    printf '#include <stdio.h>\n#include <string.h>\n'
    printf '#define COMMIT "%s"\n#define ANCESTORS "%s"\n#define CONTAINS "%s"\n' "$commit" "$ancestors" "$*"
    cat <<'C'
int main(int argc, char **argv) {
  const char *tree = "9b7d1c3e5f709254b1a8c6d4e2f0a1b3c5d7e9f11";
  if (argc > 1 && strcmp(argv[1], "--version") == 0) { printf("wasm-agent fixture %s\n", COMMIT); return 0; }
  if (argc > 1 && strcmp(argv[1], "--build-info") == 0) {
    printf("version=fixture\ncommit=%s\ntree=%s\ndirty=false\nsource=git\nbuilt_epoch=1700000000\nancestors=%s\nancestors_complete=true\n", COMMIT, tree, ANCESTORS);
    return 0;
  }
  if (argc > 2 && strcmp(argv[1], "--contains") == 0) {
    char list[] = CONTAINS;
    for (char *part = strtok(list, " "); part; part = strtok(NULL, " "))
      if (strcmp(part, argv[2]) == 0) return 0;
    return 1;
  }
  return 0;
}
C
  } > "$T/stub.c"
  cc -O0 -o "$out" "$T/stub.c" >/dev/null 2>&1
}

sign_release() { python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$1" --key A >/dev/null 2>&1; }
fakenode() { mkdir -p "$1/node/bin"; printf '#!/bin/sh\nprintf v%s\n' "$NODEV" > "$1/node/bin/node"; chmod +x "$1/node/bin/node"; }

mkbundle() { # NAME TAG COMMIT [contained commits...] -> manifest sha256; archive at $T/rel-NAME/NAME.tar.gz
  local name="$1" tag="$2" commit="$3"; shift 3
  local dir="$T/src/$name"
  rm -rf "$dir"; mkdir -p "$dir/ui" "$dir/scripts/linux"
  build_stub "$dir/wa" "$commit" "$#" "$@" || { printf 'FAIL cannot compile the fixture binary\n' >&2; exit 1; }
  cp "$dir/wa" "$dir/wa-sentinel"
  printf '<html>\n' > "$dir/ui/index.html"
  printf '//\n' > "$dir/scripts/mcp-web.mjs"
  cp "$ROOT/scripts/install.sh" "$dir/scripts/install.sh"
  ( cd "$dir" && find . -type f ! -name files.sha256 ! -name bundle.manifest -printf '%P\n' | LC_ALL=C sort \
      | while IFS= read -r f; do sha256sum -- "$f"; done ) > "$dir/files.sha256"
  printf 'schema=wa-linux-bundle/1\nsource_commit=%s\ntarget_triple=%s\nnode_version=%s\nwa_version=fixture-%s\nfiles_sha256=%s\n' \
    "$commit" "$TARGET" "$NODEV" "$tag" "$(sha256sum "$dir/files.sha256" | cut -d' ' -f1)" > "$dir/bundle.manifest"
  mkdir -p "$T/rel-$name"
  tar -C "$T/src" -czf "$T/rel-$name/$name.tar.gz" "$name"
  sign_release "$T/rel-$name"
  sha256sum "$dir/bundle.manifest" | cut -d' ' -f1
}

entry() { # NAME TAG COMMIT SHA
  local name="$1" tag="$2" commit="$3" sha="$4"
  printf '{"tag":"%s","commit":"%s","target":"%s","manifest_sha256":"%s","url":"file://%s/rel-%s/%s.tar.gz","size":%s,"node_version":"%s"}' \
    "$tag" "$commit" "$TARGET" "$sha" "$T" "$name" "$name" "$(wc -c < "$T/rel-$name/$name.tar.gz" | tr -d ' ')" "$NODEV"
}
mkindex() { local file="$1"; shift; printf '{"schema":"wasm-agent-linux-release-index","schema_version":1,"releases":[%s]}\n' "$(IFS=,; printf '%s' "$*")" > "$file"; }

rec() { sed -n "s/^$2=//p" "$1/installed.txt" 2>/dev/null | head -1; }

run_core() { # <prefix> <index-url> [args...] -> sets OUT, RC
  local prefix="$1" index="$2"; shift 2
  OUT=$( env HOME="$T/home" WASM_AGENT_HOME="$T/agent-home" \
        WA_LINUX_RELEASE_ALLOW_LOCAL=1 WA_RELEASE_KEYS="$WA_RELEASE_KEYS" \
        WA_LINUX_RELEASE_INDEX_URL="$index" \
        bash "$CORE" --prefix "$prefix" --no-service --rendezvous none \
        --port 18997 --client-port 18998 "$@" 2>&1 ); RC=$?
}

SHA1=$(mkbundle rel1 v1.0.0-fixture "$COMMIT1")
mkindex "$T/i1.json" "$(entry rel1 v1.0.0-fixture "$COMMIT1" "$SHA1")"
# Release 2 contains release 1's commit: the ordinary, non-downgrade move.
SHA2=$(mkbundle rel2 v2.0.0-fixture "$COMMIT2" "$COMMIT1")
mkindex "$T/i2.json" "$(entry rel2 v2.0.0-fixture "$COMMIT2" "$SHA2")"
# A third release for the pinned-node cases: a node already on the newest release is "current", and a current
# install never reaches the gate - so the pin needs a release to move TO.
COMMIT3=3333333333333333333333333333333333333333
SHA3=$(mkbundle rel3 v3.0.0-fixture "$COMMIT3" "$COMMIT2" "$COMMIT1")
mkindex "$T/i3.json" "$(entry rel3 v3.0.0-fixture "$COMMIT3" "$SHA3")"

echo "test-bootstrap-gate: a fresh install, then the two overrides the review found unreachable"
P="$T/prefix"
fakenode "$P"
run_core "$P" "file://$T/i1.json"
[ "$RC" = 0 ] && ok "a fresh install lands (exit 0)" || bad "fresh install refused: $(printf '%s' "$OUT" | tail -3)"
same "the record says how it arrived" "$(rec "$P" via)" linux-bootstrap
same "...and that there was nothing to compare" "$(rec "$P" ancestry_checked)" first_install
same "...naming the bundle's own commit" "$(rec "$P" commit)" "$COMMIT1"

echo "test-bootstrap-gate: an install that cannot name its commit is not a first install (item 1)"
grep -v '^sha256=' "$P/installed.txt" > "$P/installed.txt.nosha" && mv "$P/installed.txt.nosha" "$P/installed.txt"
printf '#!/bin/sh\nexit 1\n' > "$P/wa"; chmod +x "$P/wa"
BEFORE="$(cat "$P/installed.txt")"
run_core "$P" "file://$T/i2.json"
[ "$RC" != 0 ] && ok "it refused (exit $RC)" || bad "an install nothing can identify was replaced as if empty"
shows "the refusal is by name" "$OUT" "refused(running_commit_unprovable)"
shows "it says something IS installed" "$OUT" "A binary IS installed here"
shows "it names what makes it unanswerable" "$OUT" "no sha256="
same "nothing was replaced" "$(cat "$P/installed.txt")" "$BEFORE"
same "the binary is still the one that was there" "$(head -1 "$P/wa")" '#!/bin/sh'

echo "test-bootstrap-gate: --force --reason overrides it, and the override is recorded (items 1 and 4)"
run_core "$P" "file://$T/i2.json" --force --reason "the node's rebuild is not here yet"
[ "$RC" = 0 ] && ok "the override is honoured (exit 0)" || bad "the override was refused: $(printf '%s' "$OUT" | tail -3)"
shows "it said the override out loud" "$OUT" "OVERRIDE, recorded"
shows "...with the rule it overrode" "$OUT" "force_requested rule=running_commit_unprovable"
shows "...and the reason" "$OUT" "reason=the node's rebuild is not here yet"
same "the record names the override" "$(rec "$P" ancestry_checked)" override
same "the new release is installed" "$(rec "$P" release)" v2.0.0-fixture

echo "test-bootstrap-gate: a pinned node refuses, and --force --reason moves it (item 4)"
# The node's own pin store, exactly as a rollback writes it: one key=value block, state=active, no awaited commit.
cat > "$T/agent-home/.wasm-agent/pins.txt" <<'PINS'
schema=wasm-agent-pins/1
id=aaaa1111
node=fixture-node
kind=rollback
state=active
commit=1111111111111111111111111111111111111111
rolled_back_from=9999999999999999999999999999999999999999
reason=held on the build the operator wants
by=operator
at=2026-11-18T10:00:00Z
PINS
WABEFORE="$(sha256sum < "$P/wa" | cut -d' ' -f1)"
run_core "$P" "file://$T/i3.json" --reason "an ordinary update"
OUT_PIN="$OUT"
[ "$RC" != 0 ] && ok "an ordinary update is refused (exit $RC)" || bad "an ordinary update walked over a pin"
shows "the refusal is by name" "$OUT_PIN" "node_pinned"
shows "it quotes the pin" "$OUT_PIN" "held on the build the operator wants"
shows "it says nothing was replaced" "$OUT_PIN" "Nothing was replaced"
same "the running bytes are the same" "$(sha256sum < "$P/wa" | cut -d' ' -f1)" "$WABEFORE"

echo "test-bootstrap-gate: a pin that names no awaited commit is described exactly (item 6)"
shows "the refusal names --unpin" "$OUT_PIN" "--unpin --reason"
hides "...it does not promise a deploy releases it" "$OUT_PIN" "contains the awaited commit"
hides "...and never an undefined variable" "$OUT_PIN" "reasonVar"

run_core "$P" "file://$T/i3.json" --force --reason "the operator released this pin by hand"
[ "$RC" = 0 ] && ok "the pin override is honoured (exit 0)" || bad "the pin override was refused: $(printf '%s' "$OUT" | tail -3)"
shows "it said the override out loud" "$OUT" "OVERRIDE, recorded"
shows "it recorded the pin force" "$OUT" "force_requested rule=node_pinned"
shows "...with its reason" "$OUT" "reason=the operator released this pin by hand"
shows "...and who" "$OUT" "by="
same "the record names the override" "$(rec "$P" ancestry_checked)" override
hides "the force line never prints an undefined variable" "$OUT" "reasonVar"
same "the third release is installed" "$(rec "$P" release)" v3.0.0-fixture

echo "test-bootstrap-gate: --check prints the answer, not a shell expression (item 4)"
printf '#!/bin/sh\nexit 1\n' > "$P/wa"; chmod +x "$P/wa"
run_core "$P" "file://$T/i3.json" --check
shows "check-only talks about what it found" "$OUT" "check only: the ancestry question needs the install"
if printf '%s' "$OUT" | grep -q 'RUNNING_COMMIT'; then bad "the check-only line prints the expression"
else ok "the check-only line expands its variables"; fi
if printf '%s' "$OUT" | grep -Eq 'other bytes|no sha256=|cannot name'; then ok "and says why nothing names a commit"
else bad "the check-only line does not say why: $(printf '%s' "$OUT" | tail -2)"; fi

printf 'test-bootstrap-gate: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
