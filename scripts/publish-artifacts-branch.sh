#!/usr/bin/env bash
# Ship a built release artifact set to the machine that can publish it, through git: one orphan commit
# that holds exactly the release files plus the `gh` command to publish them.
#
# WHY. `scripts/publish-node-binaries.sh` builds and verifies the release, and deliberately never runs
# `gh` - publishing stays a reviewed action on a host with credentials. But the host that can BUILD (a
# Linux box with zig and 16 threads) is not always the host with a GitHub credential: measured
# 2026-11-11 on wa-desktop, whose only key is a git drop box. So the two halves need a transport, and the
# cheapest one is the transport that already exists: git.
#
#   ref      artifacts/node-<sha12>            (an orphan commit: no parent, no tree of the project)
#   contents node-<sha12>.manifest             the pins the publisher wrote
#            SHA256SUMS                        the same pins in the flat form `sha256sum -c` reads
#            wa-<triple>-<sha12>               one payload per published triple
#            wa-sentinel-<triple>-<sha12>
#            PUBLISH.sh                        the exact `gh release create` line, paths relative to the
#                                              commit's own root, so it runs from a plain `git archive`
#                                              or a checkout of that ref
#
# The commit is created in a scratch repository, never in this checkout: the worktree's index, HEAD and
# branch are untouched, so shipping artifacts can never disturb the tree that built them.
#
#   bash scripts/publish-artifacts-branch.sh --remote oc-in                 # build both targets, ship the ref
#   bash scripts/publish-artifacts-branch.sh --remote oc-in --dry-run        # everything but the push
#   bash scripts/publish-artifacts-branch.sh --remote oc-in --from DIR       # ship artifacts built elsewhere
#   bash scripts/publish-artifacts-branch.sh --remote oc-in --commit <sha> --targets "aarch64-unknown-linux-gnu"
#
# Every payload is verified against the manifest before the commit exists (the publisher's own check, run
# on what will actually ship), and the printed block is what a coordinator pastes back:
#
#   PUBLISHREADY artifacts/node-<sha12> <artifacts commit> source=<main sha>
#   <sha256>  <bytes>  <asset>        one line per release file
#   build aarch64-unknown-linux-gnu in 373s      (from the publisher's own lines)
#
# Exit codes: 0 shipped (or --dry-run printed); 2 a missing argument, tool or artifact; 5 a payload does
# not match its pin; 8 the build or the push failed.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/node-binaries.sh"
say() { printf 'publish-artifacts-branch: %s\n' "$*"; }
fail() { printf 'publish-artifacts-branch: %s\n' "$*" >&2; exit "${2:-2}"; }

REMOTE=""
COMMIT=""
FROM=""
OUT=""
TARGETS=""
PREFIX="artifacts/"
DRY=0
KEEP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote) [ "$#" -ge 2 ] || fail 'remote_value_required'; REMOTE="$2"; shift 2 ;;
    --commit) [ "$#" -ge 2 ] || fail 'commit_value_required'; COMMIT="$2"; shift 2 ;;
    --from) [ "$#" -ge 2 ] || fail 'from_value_required'; FROM="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail 'out_value_required'; OUT="$2"; shift 2 ;;
    --targets) [ "$#" -ge 2 ] || fail 'targets_value_required'; TARGETS="$2"; shift 2 ;;
    --prefix) [ "$#" -ge 2 ] || fail 'prefix_value_required'; PREFIX="$2"; shift 2 ;;
    --keep) [ "$#" -ge 2 ] || fail 'keep_value_required'; KEEP="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown_option: $1" ;;
  esac
done
[ -n "$REMOTE" ] || fail 'remote_required: name the git remote (or URL) that is the drop box, e.g. --remote oc-in'
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || fail "not_a_checkout: $ROOT"
COMMIT="$(git -C "$ROOT" rev-parse --verify -q "${COMMIT:-HEAD}^{commit}")" || fail "commit_unknown: ${COMMIT:-HEAD}"
COMMIT="$(git -C "$ROOT" rev-parse "$COMMIT")"
TAG="$(wa_node_release_tag "$COMMIT")" || fail "commit_invalid: $COMMIT"
SHORT="${TAG#node-}"
BRANCH="$PREFIX$TAG"
OUT="${OUT:-$ROOT/build/node-binaries}"
command -v git >/dev/null 2>&1 || fail 'git_missing'

# ---- 1. the artifact set: built here, verified here, or verified elsewhere ---------------------------
# A target this channel does not publish is refused HERE, before a publisher run: the refusal costs
# nothing and names the option, instead of arriving as a failed build further down.
for t in $TARGETS; do
  case "$t" in
    aarch64-unknown-linux-gnu|x86_64-unknown-linux-gnu|aarch64-unknown-linux-musl|x86_64-unknown-linux-musl) ;;
    *) fail "target_unsupported: $t (aarch64|x86_64-unknown-linux-gnu|musl)" ;;
  esac
done
publish_args=(--commit "$COMMIT" --out "$OUT")
[ -z "$TARGETS" ] || for t in $TARGETS; do publish_args+=(--target "$t"); done
[ -z "$FROM" ] || publish_args+=(--from "$FROM")
say "publisher: bash scripts/publish-node-binaries.sh ${publish_args[*]}"
published="$( cd "$ROOT" && bash scripts/publish-node-binaries.sh "${publish_args[@]}" 2>&1 )" || {
  printf '%s\n' "$published" >&2
  fail "publisher_failed: bash scripts/publish-node-binaries.sh ${publish_args[*]}" 8
}
MANIFEST="$OUT/node-$SHORT.manifest"
[ -f "$MANIFEST" ] || fail "manifest_missing: $MANIFEST" 2
[ "$(wa_node_manifest_value "$MANIFEST" source_commit)" = "$COMMIT" ] \
  || fail "manifest_commit_mismatch: $MANIFEST names $(wa_node_manifest_value "$MANIFEST" source_commit), asked for $COMMIT" 5

# The triples are the manifest's own rows; the payload names come from the manifest, not from a guess.
TRIPLES="$(awk '!/^#/ && !/^[a-z_]+=/ { print $1 }' "$MANIFEST")"
[ -n "$TRIPLES" ] || fail "manifest_incomplete: no target rows in $MANIFEST" 2
ASSETS=""
ROWS=""
for triple in $TRIPLES; do
  pin="$(wa_node_manifest_pin "$MANIFEST" "$triple")" || fail "manifest_incomplete: no row for $triple" 2
  set -- $pin
  [ "$#" = 4 ] || fail "manifest_incomplete: row for $triple is '$pin'" 2
  for pair in "wa-$triple-$SHORT:$1:$2" "wa-sentinel-$triple-$SHORT:$3:$4"; do
    name="${pair%%:*}"; rest="${pair#*:}"; want_sha="${rest%%:*}"; want_bytes="${rest##*:}"
    file="$OUT/$name"
    [ -f "$file" ] || fail "binary_missing: $file" 2
    actual="$(wa_node_sha256 "$file")" || fail 'sha256_tool_missing' 7
    [ "$actual" = "$want_sha" ] || fail "artifact_not_pinned: $name is $actual, the manifest pins $want_sha" 5
    [ "$(wc -c < "$file" | tr -d '[:space:]')" = "$want_bytes" ] || fail "artifact_not_pinned: $name is not $want_bytes bytes" 5
    ASSETS="$ASSETS $name"
    ROWS="$ROWS$want_sha  $want_bytes  $name"$'\n'
  done
done
ASSETS="$ASSETS node-$SHORT.manifest"
[ -f "$MANIFEST" ] || fail "manifest_missing: $MANIFEST" 2
ROWS="$ROWS$(wa_node_sha256 "$MANIFEST")  $(wc -c < "$MANIFEST" | tr -d '[:space:]')  node-$SHORT.manifest"$'\n'
# The signed sums ship WITH the binaries they name. Both are release files like any other: the publisher
# wrote them beside the payloads (scripts/publish-node-binaries.sh signs SHA256SUMS with wa-vault's
# `release-signing` key), and a set without them is not a release this project will publish.
for signed in SHA256SUMS SHA256SUMS.sig; do
  [ -f "$OUT/$signed" ] || fail \
    "release_not_signed: $OUT/$signed is missing - a node refuses a release without its signed sums, so it is not published" 6
  ASSETS="$ASSETS $signed"
  ROWS="$ROWS$(wa_node_sha256 "$OUT/$signed")  $(wc -c < "$OUT/$signed" | tr -d '[:space:]')  $signed"$'\n'
done
say "verified $MANIFEST against every payload (source_commit $COMMIT)"

# ---- 1b. SHA256SUMS belongs INSIDE the ref -----------------------------------------------------------
# The publisher writes SHA256SUMS beside the manifest and names it in the `gh release create` line it
# prints, so the PUBLISH.sh shipped here asks for that file - and this script did not carry it. Measured
# 13/11 on `artifacts/node-0d4ccca2213d`: the ref held PUBLISH.sh, the manifest and four payloads, no
# SHA256SUMS, while PUBLISH.sh's last argument was `SHA256SUMS`. Publishing it would have failed on a
# missing file, after the human was told to paste exactly that line.
#
# Two checks, both before the commit exists: the file is there, and every pin in it is the pin in the
# manifest. Then it becomes an asset like the others - copied into the commit and verified again out of
# git - so `sha256sum -c SHA256SUMS` works from a `git archive` of the ref, with no knowledge of the
# manifest's shape.
SUMS="$OUT/SHA256SUMS"
[ -f "$SUMS" ] \
  || fail "checksums_missing: $SUMS (scripts/publish-node-binaries.sh writes it beside the manifest, and the shipped PUBLISH.sh names it; a ref without it publishes to a missing file)" 2
unpinned=""
while IFS=$' \t' read -r want_sha want_bytes name; do
  [ -n "${name:-}" ] || continue
  grep -qx "$want_sha  $name" "$SUMS" || unpinned="$unpinned $name"
done <<< "$ROWS"
[ -z "$unpinned" ] || fail "checksums_mismatch: SHA256SUMS does not carry the manifest's pin for:$unpinned" 5
SUMS_SHA="$(wa_node_sha256 "$SUMS")" || fail 'sha256_tool_missing' 7
ASSETS="$ASSETS SHA256SUMS"
ROWS="$ROWS$SUMS_SHA  $(wc -c < "$SUMS" | tr -d '[:space:]')  SHA256SUMS"$'\n'
say "checksums verified: $SUMS ($(wc -l < "$SUMS" | tr -d '[:space:]') row(s), every pin the manifest's)"

# ---- 2. PUBLISH.sh: the publisher's own gh line, with the paths made relative to the commit root -----
# The publisher prints both forms (create, then the clobber upload). They are taken from ITS output rather
# than retyped, so a change in the script's command line cannot leave the shipped file behind - and the
# absolute build directory is stripped, which is what makes the file usable from a checkout of the ref.
gh_lines="$(printf '%s\n' "$published" | grep -E '^gh release (create|upload) ' || true)"
[ -n "$gh_lines" ] || { printf '%s\n' "$published" >&2; fail "publish_command_missing: the publisher printed no gh line" 8; }
gh_lines="$(printf '%s\n' "$gh_lines" | sed "s#$OUT/##g")"
# `|| true` INSIDE the substitution: a command line that ends with `|| true` after the closing quote
# would put `|| true` into the shipped PUBLISH.sh and swallow a failed publish (measured while writing
# this script - the line shipped as `gh release create ... || true`, which never fails).
create_line="$(printf '%s\n' "$gh_lines" | grep -m1 '^gh release create ' || true)"
upload_line="$(printf '%s\n' "$gh_lines" | grep -m1 '^gh release upload ' || true)"
[ -n "$create_line" ] || fail "publish_command_missing: no 'gh release create' line" 8

# Per-target build seconds, straight from the publisher's lines ("built <triple> in 42s").
BUILD_TIMES="$(printf '%s\n' "$published" | sed -n 's/^publish-node-binaries: built \(.*\) in \([0-9]*\)s$/build \1 in \2s/p')"
TOTAL="$(printf '%s\n' "$published" | sed -n 's/^publish-node-binaries: total build: \([0-9]*s\).*$/total build: \1/p')"

[ -z "$KEEP" ] || mkdir -p "$KEEP" || fail "keep_unwritable: $KEEP" 2
STAGE="$(mktemp -d "${KEEP:-${TMPDIR:-/tmp}}/wasm-agent-artifacts.XXXXXX")" || fail "scratch_unwritable: no scratch directory under ${KEEP:-${TMPDIR:-/tmp}}" 2
[ -n "$KEEP" ] || trap 'rm -rf "$STAGE"' EXIT
{
  echo '#!/usr/bin/env bash'
  echo "# Publish the release $TAG: the exact command scripts/publish-node-binaries.sh printed on the host"
  echo "# that built these bytes, with every path made relative to THIS commit's root, so it runs from a"
  echo "# checkout of the ref or from a plain \`git archive\` of it:"
  echo '#'
  echo '#   git fetch <remote> refs/heads/'"$BRANCH"':refs/heads/'"$BRANCH"
  echo '#   git worktree add /tmp/'$BRANCH' '"$BRANCH"'   # or: git archive '"$BRANCH"' | tar -x -C /tmp/'"$TAG"
  echo '#   cd /tmp/'$BRANCH' && bash PUBLISH.sh'
  echo '#'
  echo "# source commit: $COMMIT"
  echo "# pins:          node-$SHORT.manifest (compile inputs $(wa_node_manifest_value "$MANIFEST" compiled_inputs))"
  [ -z "$BUILD_TIMES" ] || while IFS= read -r line; do echo "# $line"; done <<< "$BUILD_TIMES"
  [ -z "$TOTAL" ] || echo "# $TOTAL"
  printf '%s' "$ROWS" | while IFS= read -r row; do [ -n "$row" ] && echo "# sha256/bytes: $row"; done
  echo '#'
  echo "# The commented line is the publisher's own alternative for a tag that already exists (a"
  echo "# re-publish of the same commit): the release is replaced, never duplicated."
  echo 'set -euo pipefail'
  echo 'cd "$(dirname "$0")"'
  echo "$create_line"
  echo "# $upload_line"
} > "$STAGE/PUBLISH.sh" || fail "stage_unwritable: $STAGE/PUBLISH.sh" 2
chmod +x "$STAGE/PUBLISH.sh"

# ---- 3. the orphan commit: the release files and nothing else --------------------------------------
# The scratch repository pushes to the drop box by URL, resolved from THIS checkout's remote, so the
# remote configuration stays in one place (and `--remote` may be a URL already).
REMOTE_URL="$(git -C "$ROOT" remote get-url "$REMOTE" 2>/dev/null || printf '%s' "$REMOTE")"
[ -n "$REMOTE_URL" ] || fail "remote_unknown: $REMOTE" 2
for asset in $ASSETS; do
  cp -f "$OUT/$asset" "$STAGE/$asset" || fail "stage_unwritable: $STAGE/$asset" 2
done
say "staged: $(printf '%s ' $ASSETS)PUBLISH.sh"
if [ "$DRY" = 1 ]; then
  say "dry run: nothing committed or pushed. The ref that would carry it: $BRANCH (remote $REMOTE)"
else
  REPO="$STAGE/.commit-repo"
  mkdir -p "$REPO" || fail "scratch_unwritable: $REPO" 2
  git -C "$REPO" init -q || fail 'git_init_failed' 8
  git -C "$REPO" config core.autocrlf false
  # The commit is authored by the identity this checkout uses, read from it (a scratch repository has no
  # identity of its own, and git would otherwise refuse the commit with "Author identity unknown").
  ident_name="$(git -C "$ROOT" config user.name 2>/dev/null || true)"
  ident_email="$(git -C "$ROOT" config user.email 2>/dev/null || true)"
  [ -z "$ident_name" ] || git -C "$REPO" config user.name "$ident_name"
  [ -z "$ident_email" ] || git -C "$REPO" config user.email "$ident_email"
  for asset in $ASSETS; do cp -f "$STAGE/$asset" "$REPO/$asset" || fail "stage_unwritable: $REPO/$asset" 2; done
  cp -f "$STAGE/PUBLISH.sh" "$REPO/PUBLISH.sh"
  commit_msg="Built and verified by scripts/publish-node-binaries.sh on $(uname -s)/$(uname -m) and shipped by
scripts/publish-artifacts-branch.sh, because the machine that can build is not the machine with a
GitHub credential. PUBLISH.sh holds the exact gh command, paths relative to this commit's root.

source_commit=$COMMIT
compiled_inputs=$(wa_node_manifest_value "$MANIFEST" compiled_inputs)"
  ( cd "$REPO" && git add -A && git commit -q --no-verify \
      -m "artifacts($TAG): prebuilt node binaries for $COMMIT" -m "$commit_msg" ) \
    || fail 'artifacts_commit_failed' 8
  ARTIFACT_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
  # The bytes that ship are the bytes that were verified: the orphan tree is compared to the pins once
  # more after `git add`, because a checkout's filters (CRLF, clean/smudge) can otherwise alter a payload
  # on its way into the object database.
  for asset in $ASSETS; do
    in_git="$(git -C "$REPO" show "HEAD:$asset" | wa_node_sha256_stdin)" || fail 'sha256_tool_missing' 7
    want="$(printf '%s' "$ROWS" | awk -v a="$asset" '$3==a {print $1}')"
    [ "$in_git" = "$want" ] || fail "artifact_altered_in_git: $asset is $in_git in the commit, the pin is $want" 5
  done
  say "artifacts commit $ARTIFACT_COMMIT (orphan, $(git -C "$REPO" ls-tree -r --name-only HEAD | wc -l | tr -d ' ') files)"
  git -C "$REPO" push --quiet "$REMOTE_URL" "HEAD:refs/heads/$BRANCH" \
    || fail "push_failed: git push $REMOTE_URL HEAD:refs/heads/$BRANCH" 8
  # Read back from the remote: a push that returns 0 is not evidence the ref is there.
  readback="$(git ls-remote "$REMOTE_URL" "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')"
  [ "$readback" = "$ARTIFACT_COMMIT" ] \
    || fail "push_not_readback: $REMOTE refs/heads/$BRANCH is '${readback:-absent}', pushed $ARTIFACT_COMMIT" 8
  say "pushed and read back: $REMOTE $BRANCH = $ARTIFACT_COMMIT"
fi

# ---- 4. what a coordinator pastes back ---------------------------------------------------------------
printf '\n'
if [ "$DRY" = 1 ]; then
  printf 'PUBLISHREADY(unpushed) %s - source=%s\n' "$BRANCH" "$COMMIT"
else
  printf 'PUBLISHREADY %s %s source=%s\n' "$BRANCH" "$ARTIFACT_COMMIT" "$COMMIT"
fi
printf '%s' "$ROWS"
[ -z "$BUILD_TIMES" ] || printf '%s\n' "$BUILD_TIMES"
[ -z "$TOTAL" ] || printf '%s\n' "$TOTAL"
printf 'publish with: git fetch %s refs/heads/%s:refs/heads/%s && git worktree add /tmp/%s %s && bash /tmp/%s/PUBLISH.sh\n' \
  "$REMOTE" "$BRANCH" "$BRANCH" "$TAG" "$BRANCH" "$TAG"
