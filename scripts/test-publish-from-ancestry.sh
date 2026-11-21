#!/usr/bin/env bash
# A --from publish names the ancestry floor it verifies against, on a target set where this host can
# execute one architecture and not the other.
#
# MEASURED 21/11 (land250's ship step; evidence/ship.log of land-20261121T171314Z-1686339d):
#   publish-node-binaries: verified wa-aarch64-... cannot be executed on this host (aarch64-...), so it is not proved here
#   publish-node-binaries: verified wa-x86_64-unknown-linux-gnu-ed693a0bcefc: ... (elf:3e, glibc <= 2.30)
#   scripts/publish-node-binaries.sh: line 624: WINDOW_FLOOR: unbound variable
# after every artifact had already been verified. WINDOW_FLOOR was assigned only in the BUILD half and
# --from skips that half while sharing its verify loop, so a signing host that built nothing lost the
# release: land250, land251 and land253 put their code on main and made no signed release.
#
# WHAT THIS ASSERTS, in the order that failure bit:
#   1. the --from publish COMPLETES (rc 0) and never says "unbound variable";
#   2. the half that did not build names THE floor - the commit wa_ancestry_window_floor() names for this
#      commit, which is the one number both halves must read (a floor that is merely non-empty would let
#      the two halves verify against different commits);
#   3. the row this host can run is PROVED to contain that floor;
#   4. the rows it cannot run are named as NOT proved, and are never claimed as checked;
#   5. and the floor is really ASKED of the artifact, not only printed: the same set, with an artifact
#      that answers --contains with a failure, is refused (exit 5, ancestry_window_short), not published.
#
# THE RUNNABLE ARTIFACT IS A STAND-IN, compiled here: it answers exactly the two subcommands the
# publisher asks an artifact (--build-info, --contains) plus --version/--help, and its ELF shape and glibc
# floor are the real host ones because it is really built for this host. The artifact's own ancestor list
# is NOT the subject here - scripts/test-ancestry-window.sh owns it, with a real binary - and requiring a
# real wa would make this row depend on a 20-minute release build, so it could not judge a checkout.
#
# Hermetic: its own scratch HOME, its own git config, its own out directory. No network: --local keeps
# the "is this commit on a pushed branch" question (git ls-remote origin, and this repository's origin is
# a LIVE peer) out of the run, and nothing in the --from half reads that answer. Nothing publishes: the
# publisher only prints the gh command, --publish is never passed, and that is asserted.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\012' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\012' "$*"; }
refuse() { printf 'test-publish-from-ancestry: %s\012' "$*" >&2; exit 2; }

# A TEST THAT WRITES PROBES ITS OWN HOME (scripts/test.sh passes WA_TEST_SCRATCH_HOME=1 on this row).
if [ -d "${HOME:-}/.wasm-agent" ] && [ "${WA_TEST_SCRATCH_HOME:-}" != 1 ]; then
  printf 'SKIP test-publish-from-ancestry: HOME (%s) is a real node home; run it through scripts/test.sh\012' "${HOME}" >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-from-ancestry.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
for kv in user.email=t@example.invalid user.name=from-ancestry init.defaultBranch=main protocol.file.allow=always; do
  git config --global "${kv%%=*}" "${kv#*=}" >/dev/null 2>&1
done

PUBLISH="$ROOT/scripts/publish-node-binaries.sh"
[ -f "$PUBLISH" ] || refuse "no $PUBLISH"
command -v cc >/dev/null 2>&1 || refuse "no C compiler (cc) to build the runnable stand-in artifact; this row cannot be judged here"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)" || refuse "no HEAD commit in $ROOT"
SHORT="${COMMIT:0:12}"
TREE="$(git -C "$ROOT" rev-parse "$COMMIT^{tree}")"
# One definition of both numbers, read from the same lib the publisher reads.
FLOOR="$( . "$ROOT/scripts/lib/node-binaries.sh" >/dev/null 2>&1; wa_ancestry_window_floor "$ROOT" "$COMMIT" 2>/dev/null )"
[ -n "$FLOOR" ] || refuse "this checkout cannot name the ancestry floor for ${SHORT} (a shallow clone cannot), so there is nothing to compare against"
DIGEST="$( . "$ROOT/scripts/lib/node-binaries.sh" >/dev/null 2>&1; wa_compiled_inputs_digest "$ROOT" "$COMMIT" 2>/dev/null )"
[ -n "$DIGEST" ] || refuse "cannot digest the compiled inputs of ${SHORT}"

case "$(uname -m)" in
  x86_64|amd64) HOST_TRIPLE=x86_64-unknown-linux-gnu; HOST_MACHINE=3e; OTHER_TRIPLE=aarch64-unknown-linux-gnu; OTHER_MACHINE=b7 ;;
  aarch64|arm64) HOST_TRIPLE=aarch64-unknown-linux-gnu; HOST_MACHINE=b7; OTHER_TRIPLE=x86_64-unknown-linux-gnu; OTHER_MACHINE=3e ;;
  *) printf 'SKIP test-publish-from-ancestry: no cross triple for %s\012' "$(uname -m)" >&2; exit 0 ;;
esac

# ---- the fixtures: what this host runs, what it cannot, and their manifest ---------------------------
cat > "$WORK/stand-in.c" <<'CSRC'
/* The two questions publish-node-binaries.sh asks an ARTIFACT: --build-info (can this host run it) and
   --contains <commit> (does it carry that commit). WA_STUB_CONTAINS_RC makes the second one fail, which
   is what a release with a too-short ancestry window answers. Nothing else is modelled: the publisher
   asks nothing else of a wa inside its verify loop. It is deliberately NOT a real wa: the ancestor list
   those bytes carry is scripts/test-ancestry-window.sh's subject, and this row is about the plumbing. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
  const char *rc;
  if (argc > 1 && strcmp(argv[1], "--build-info") == 0) { puts("commit=stand-in"); return 0; }
  if (argc > 1 && strcmp(argv[1], "--contains") == 0) {
    rc = getenv("WA_STUB_CONTAINS_RC");
    if (argc < 3) return 2;
    puts(argv[2]);
    return rc ? atoi(rc) : 0;
  }
  if (argc > 1 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "--help") == 0)) {
    puts("wa-stand-in"); return 0;
  }
  return 0;
}
CSRC
cc -O0 -o "$WORK/wa-stand-in" "$WORK/stand-in.c" 2>"$WORK/cc.log" \
  || { cat "$WORK/cc.log" >&2; refuse "the stand-in artifact did not compile"; }

# A 25-byte ELF header of the OTHER machine: shape (od at offset 18) says elf:<machine>, and the kernel
# refuses to execute it here - exactly the cross row the ship step reports as "cannot be executed".
mkelf() { { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$2"; printf 'fixture'; } > "$1"; }
sha() { sha256sum "$1" | awk '{print $1}'; }
bytes() { wc -c < "$1" | tr -d '[:space:]'; }

# Every header field the ship's own manifest carries, with this commit's facts in it.
write_manifest() { # <dir>
  {
    echo 'schema=wasm-agent-node-binaries/1'
    echo "source_commit=$COMMIT"
    echo "source_tree=$TREE"
    echo 'pushed_branches=local-only '
    echo 'unpushed='
    echo "compiled_inputs=$DIGEST"
    echo 'rustc_version=stand-in'
    echo 'zig_version=stand-in'
    echo 'build_seconds=0'
    echo 'glibc_floor=2.31'
    echo 'codemode=embedded'
    echo 'built_utc=2026-11-21T00:00:00Z'
    echo '# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes'
    for triple in "$OTHER_TRIPLE" "$HOST_TRIPLE"; do
      printf '%s %s %s %s %s\012' "$triple" \
        "$(sha "$1/wa-$triple-$SHORT")" "$(bytes "$1/wa-$triple-$SHORT")" \
        "$(sha "$1/wa-sentinel-$triple-$SHORT")" "$(bytes "$1/wa-sentinel-$triple-$SHORT")"
    done
  } > "$1/node-$SHORT.manifest"
}

# The set is the ship step's own shape, and the architecture this host cannot run comes FIRST.
BUILT="$WORK/built"
mkdir -p "$BUILT"
cp "$WORK/wa-stand-in" "$BUILT/wa-$HOST_TRIPLE-$SHORT"
cp "$WORK/wa-stand-in" "$BUILT/wa-sentinel-$HOST_TRIPLE-$SHORT"
mkelf "$BUILT/wa-$OTHER_TRIPLE-$SHORT" "$OTHER_MACHINE"
mkelf "$BUILT/wa-sentinel-$OTHER_TRIPLE-$SHORT" "$OTHER_MACHINE"
write_manifest "$BUILT"

publish() { # <out-label> [env assignments...]; prints the publisher's output
  local label="$1"; shift
  env "$@" WA_RELEASE_SIGN_DEFER=1 bash "$PUBLISH" --from "$BUILT" --out "$WORK/out-$label" \
    --target "$OTHER_TRIPLE" --target "$HOST_TRIPLE" --glibc 2.39 --local 2>&1
}

# ---- 1..4: the set whose runnable artifact carries the floor ----------------------------------------
OUT="$(publish pass)"
rc=$?
case "$OUT" in *"unbound variable"*) bad "the verify loop died on an unbound variable" ;; *) ok "no unbound variable in the verify loop" ;; esac
if [ "$rc" = 0 ]; then ok "--from completed (rc 0): the half that built nothing still produced its set"
else bad "--from exited $rc, not 0: $(printf '%s' "$OUT" | grep -v '^  ' | tail -2 | tr '\012' '|')"; fi
case "$OUT" in
  *"ancestry window floor: $FLOOR "*) ok "the half that did not build names the floor both halves read ($FLOOR)" ;;
  *) bad "no 'ancestry window floor: $FLOOR' (named: $(printf '%s' "$OUT" | grep -m1 'ancestry window floor' || echo none))" ;;
esac
case "$OUT" in
  *"ancestry window: wa-$HOST_TRIPLE-$SHORT contains $FLOOR"*)
    ok "the row this host can run is PROVED to contain $FLOOR" ;;
  *) bad "the runnable row was not proved to contain $FLOOR" ;;
esac
case "$OUT" in
  *"cannot be executed on this host ($OTHER_TRIPLE)"*) ok "the rows this host cannot run are named as NOT proved" ;;
  *) bad "the cross rows' window was claimed or silently skipped" ;;
esac
# A literal test, not a case pattern: the message carries parentheses, which a case pattern reads as its
# own delimiter (the first version of this assertion could never match and reported a correct run red).
if printf '%s' "$OUT" | grep -Fq "wa-$OTHER_TRIPLE-$SHORT contains $FLOOR" \
  || printf '%s' "$OUT" | grep -Fq "wa-sentinel-$OTHER_TRIPLE-$SHORT contains $FLOOR"; then
  bad "an artifact this host cannot execute was CLAIMED as checked"
else
  ok "no artifact this host cannot execute was claimed as checked"
fi
case "$OUT" in *"publish-node-binaries ok: node-$SHORT"*) ok "the run reached its own end: the set is complete" ;; *) bad "the run did not reach its end" ;; esac
case "$OUT" in *"published node-"*) bad "it PUBLISHED something; this test never passes --publish" ;; *) ok "nothing was published (no --publish, no gh)" ;; esac

# ---- 5: the floor is asked, not merely printed ------------------------------------------------------
SHORT_OUT="$(publish short WA_STUB_CONTAINS_RC=1)"
rc_short=$?
if [ "$rc_short" = 5 ]; then ok "an artifact with a short window is refused with exit 5"
else bad "a short-window artifact was not refused with exit 5 (rc $rc_short): $(printf '%s' "$SHORT_OUT" | tail -2 | tr '\012' '|')"; fi
case "$SHORT_OUT" in
  *"ancestry_window_short: wa-$HOST_TRIPLE-$SHORT "*) ok "and it is refused BY NAME, on the artifact that answered" ;;
  *) bad "no ancestry_window_short naming wa-$HOST_TRIPLE-$SHORT" ;;
esac
case "$SHORT_OUT" in
  *"gh release create"*|*"publish-node-binaries ok"*) bad "a short-window set still printed an upload" ;;
  *) ok "a short-window set prints nothing for upload" ;;
esac

printf 'test-publish-from-ancestry: %s checks, %s failed\012' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
