#!/usr/bin/env bash
# The release record for a LUA-ONLY round: which files a node loads, and one digest that names that exact set.
#
# WHY. A round that changed no compiled input does not need a cross-build, a new node release or a new
# binary - `scripts/deploy.sh` already keeps the installed binary and installs only the Lua tree beside it
# (`wa_node_binary_reuse`, docs/KERNEL.md). What such a round did NOT have is a RECORD: something a node, an
# operator or an audit can hold the installed tree against, saying "this commit loads these files, these
# bytes, and here is the signature over that list". Without it the round's evidence was a deploy log.
#
# WHAT IT WRITES (into --out, default build/lua-tree/<sha12>):
#   node-lua-tree.manifest   `schema=`, `source_commit=`, `source_tree=`, `lua_inputs=`, `built_utc=` rows and
#                            one `<sha256>  <path>` row per shipped file. The file list is NOT spelled here:
#                            scripts/lib/lua-tree.sh is the same definition scripts/deploy.sh stages from, so a
#                            record can never describe a tree a node would not install.
#   SHA256SUMS               the flat form over the record itself, which is what a signing host signs
#                            (`scripts/sign-release.sh <dir>/SHA256SUMS`) - the SAME command as a node release,
#                            because the signature is over "the bytes that name the payloads", whatever they are.
#   build-stamp.txt          the frozen identity (built_utc), for the same reason the publisher freezes it: a
#                            re-run of a round must not rewrite the file a signature was made over.
#
# WHAT IT IS NOT. It is not an installable manifest: `deploy.sh` writes `<install>/lua-core/manifest.txt` with
# the `capabilities <digest>` row of the binary it is installing, and the binary refuses a tree whose digest
# differs from its own. A record cannot invent that row - it has no binary - so a node verifies the tree it
# loads the way it always has (its own manifest at load time) and holds the RESULT against this record with
# `--verify`: same commit, same file list, same bytes, and a `lua_inputs=` digest that a checkout must
# reproduce exactly.
#
#   bash scripts/publish-lua-tree.sh --commit <sha> [--repo DIR] [--out DIR]
#   bash scripts/publish-lua-tree.sh --commit <sha> --check                # what would be written; writes nothing
#   bash scripts/publish-lua-tree.sh --commit <sha> --out DIR --sign-command "bash scripts/sign-release.sh"
#   bash scripts/publish-lua-tree.sh --verify <dir> --out DIR             # a staged lua-core tree, or a checkout
#
# Exit codes: 0 ok; 2 missing argument/commit/file; 5 the tree is not this record's (a file, a hash or the
# digest differs); 6 the signature is not over these sums; 8 signing failed.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_ROOT="$ROOT"
OUT=""
COMMIT=""
CHECK=0
VERIFY=""
SIGN_COMMAND=""
say() { printf 'publish-lua-tree: %s\n' "$*"; }
fail() { printf 'publish-lua-tree: %s\n' "$*" >&2; exit "${2:-2}"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || fail 'repo_value_required'; REPO_ROOT="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail 'out_value_required'; OUT="$2"; shift 2 ;;
    --commit) [ "$#" -ge 2 ] || fail 'commit_value_required'; COMMIT="$2"; shift 2 ;;
    --verify) [ "$#" -ge 2 ] || fail 'verify_value_required'; VERIFY="$2"; shift 2 ;;
    --sign-command) [ "$#" -ge 2 ] || fail 'sign_command_value_required'; SIGN_COMMAND="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown_option: $1" ;;
  esac
done
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || fail "not_a_checkout: $REPO_ROOT"
. "$REPO_ROOT/scripts/lib/node-binaries.sh"
. "$REPO_ROOT/scripts/lib/lua-tree.sh"

MANIFEST_NAME="node-lua-tree.manifest"

# ---- --verify: hold a tree against a record ---------------------------------------------------------
# Two shapes, because two things are worth checking and they are not the same file: a staged `lua-core`
# directory (what an installed node loads, with its own manifest.txt) and a checkout (what a build host
# stages from). Both are answered against the record's own rows, never against the tree's opinion of itself.
if [ -n "$VERIFY" ]; then
  [ -n "$OUT" ] || fail 'verify_needs_record: pass --out <the record directory>'
  RECORD="$OUT/$MANIFEST_NAME"
  [ -f "$RECORD" ] || fail "record_missing: $RECORD" 2
  COMMIT="$(wa_lua_tree_manifest_value "$RECORD" source_commit)"
  [ -n "$COMMIT" ] || fail "record_unreadable: $RECORD names no source_commit" 2
  [ -d "$VERIFY" ] || fail "verify_not_a_directory: $VERIFY" 2
  # The file rows, as the record wrote them: `<sha>  <path>`.
  rows_ok=0; rows_bad=""; rows=0
  while IFS= read -r row; do
    case "$row" in ''|*=*|'#'*) continue ;; esac
    want="$(printf '%s' "$row" | awk '{print $1}')"
    path="$(printf '%s' "$row" | sed 's/^[^ ]*  //')"
    [ -n "$path" ] && [ -n "$want" ] || continue
    rows=$((rows + 1))
    # A staged install keeps the same relative paths inside `lua-core/`; a checkout keeps them at the root.
    file="$VERIFY/$path"
    [ -f "$file" ] || file="$VERIFY/lua-core/$path"
    if [ -f "$file" ] && [ "$(wa_node_sha256 "$file")" = "$want" ]; then
      rows_ok=$((rows_ok + 1))
    else
      rows_bad="$rows_bad $path"
    fi
  done < "$RECORD"
  [ "$rows" -gt 0 ] || fail "record_empty: $RECORD names no file" 2
  [ -z "$rows_bad" ] || fail "record_mismatch: these files are not the record's bytes:$rows_bad" 5
  if [ -f "$VERIFY/manifest.txt" ]; then
    staged="$(sed -n 's/^commit //p' "$VERIFY/manifest.txt" 2>/dev/null | head -1 | tr -d '[:space:]')"
    [ "$staged" = "$COMMIT" ] || fail "record_commit_mismatch: $VERIFY/manifest.txt names commit ${staged:-none}, the record names $COMMIT" 5
  else
    want_digest="$(wa_lua_tree_manifest_value "$RECORD" lua_inputs)"
    got_digest="$(wa_lua_tree_digest "$VERIFY" "$COMMIT" 2>/dev/null)" \
      || fail "verify_tree_unreadable: $VERIFY holds no $COMMIT" 2
    [ "$want_digest" = "$got_digest" ] || fail "record_digest_mismatch: $VERIFY hashes to $got_digest, the record names $want_digest" 5
  fi
  # A signature, when one is here, is verified by the rule every node applies - a record nobody can verify is
  # not a record. An unsigned one is named, not silently accepted as signed.
  if [ -f "$OUT/SHA256SUMS.sig" ]; then
    ( . "$REPO_ROOT/scripts/lib/release-signing.sh" && wa_release_verify_sums "$OUT" ) \
      || fail "record_signature_invalid: $OUT/SHA256SUMS.sig is not a trusted signature over $OUT/SHA256SUMS" 6
    say "signature ok ($(sed -n 's/^key //p' "$OUT/SHA256SUMS.sig"))"
  else
    say "unsigned: $OUT/SHA256SUMS has no signature (the round records it as unsigned, never as signed)"
  fi
  say "record ok: $rows_ok file(s) at $COMMIT verified against $RECORD"
  exit 0
fi

[ -n "$COMMIT" ] || fail 'commit_required: --commit <sha> (the landed commit this record is about)'
COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify -q "${COMMIT}^{commit}")" || fail "commit_unknown: $COMMIT"
SHORT="${COMMIT:0:12}"
[ -n "$OUT" ] || OUT="$REPO_ROOT/build/lua-tree/$SHORT"
DIGEST="$(wa_lua_tree_digest "$REPO_ROOT" "$COMMIT")" || fail "lua_inputs_unavailable: cannot digest the Lua tree of $COMMIT" 2
[ -n "$DIGEST" ] || fail "lua_inputs_unavailable: no sha256 tool for the Lua-tree digest" 7
TREE="$(git -C "$REPO_ROOT" rev-parse "$COMMIT^{tree}" 2>/dev/null || printf 'unknown')"
COUNT="$(wa_lua_tree_files "$REPO_ROOT" | grep -c . || true)"

if [ "$CHECK" = 1 ]; then
  say "would write $OUT/$MANIFEST_NAME and $OUT/SHA256SUMS over $COUNT file(s) of $COMMIT"
  say "lua_inputs: $DIGEST"
  say "signing (when a round signs it): bash scripts/sign-release.sh $OUT/SHA256SUMS"
  say "nothing was written (--check)"
  exit 0
fi

mkdir -p "$OUT" || fail "record_unwritable: $OUT" 2
# ---- the frozen identity, exactly as the node publisher freezes it -----------------------------------
# A round may write this record more than once (a resume re-runs the artifacts step from its start, and the
# signing host signs the sums in between). A fresh `built_utc` per write would change the manifest's sha256,
# which changes SHA256SUMS, which makes the signature about other bytes - the 13/11 failure, one round later.
STAMP="$OUT/build-stamp.txt"
BUILT_UTC=""
if [ -f "$STAMP" ] && [ "$(sed -n 's/^source_commit=//p' "$STAMP" | head -1 | tr -d '[:space:]')" = "$COMMIT" ]; then
  BUILT_UTC="$(sed -n 's/^built_utc=//p' "$STAMP" | head -1 | tr -d '[:space:]')"
fi
if [ -n "$BUILT_UTC" ]; then
  say "identity frozen: built_utc=$BUILT_UTC (recorded once for $SHORT in $STAMP)"
else
  BUILT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  { printf 'source_commit=%s\nbuilt_utc=%s\n' "$COMMIT" "$BUILT_UTC"; } > "$STAMP.$$" \
    && mv -f "$STAMP.$$" "$STAMP" \
    || say "warning: $STAMP could not be written; a re-run will rewrite built_utc and invalidate a signature made over these sums"
fi

TMP="$OUT/.$MANIFEST_NAME.$$"
{
  printf 'schema=wasm-agent-lua-tree/1\n'
  printf 'source_commit=%s\n' "$COMMIT"
  printf 'source_tree=%s\n' "$TREE"
  printf 'lua_inputs=%s\n' "$DIGEST"
  printf 'built_utc=%s\n' "$BUILT_UTC"
  printf '# sha256  path   (the files scripts/deploy.sh stages into <install>/lua-core)\n'
  # From the COMMIT's blobs, never from a working tree: a record is about a landed commit, and a checkout that
  # moved while it was read would otherwise describe a tree nothing installs.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    blob="$(git -C "$REPO_ROOT" ls-tree -r --full-tree "$COMMIT" -- "$path" 2>/dev/null | awk '{print $3}' | head -1)"
    [ -n "$blob" ] || fail "file_missing: $path is not in $COMMIT" 5
    printf '%s  %s\n' "$(git -C "$REPO_ROOT" cat-file blob "$blob" | wa_node_sha256_stdin)" "$path"
  done < <(wa_lua_tree_files "$REPO_ROOT")
} > "$TMP" || fail "record_unwritable: $TMP" 2
# Written ONCE per round: an identical rewrite is still a different file to a concurrent reader and to
# anything that noted its mtime, and the sums below must name exactly the bytes that were signed.
if [ -f "$OUT/$MANIFEST_NAME" ] && cmp -s "$TMP" "$OUT/$MANIFEST_NAME"; then
  rm -f "$TMP"
  say "manifest reused $OUT/$MANIFEST_NAME (byte-identical to the one already there)"
else
  mv -f "$TMP" "$OUT/$MANIFEST_NAME" || fail "record_unwritable: $OUT/$MANIFEST_NAME" 2
  say "manifest $OUT/$MANIFEST_NAME ($COUNT file(s), lua_inputs $DIGEST)"
fi

# The sums over the record itself, reused when they already describe it (see the publisher's sums_match for
# the measurement: a signature over rewritten-but-identical bytes is still a signature over other bytes when
# the file's own hash changed).
WANT="$(wa_node_sha256 "$OUT/$MANIFEST_NAME")"
if [ -f "$OUT/SHA256SUMS" ] && [ "$(grep -c . "$OUT/SHA256SUMS" || true)" = 1 ] && grep -qx "$WANT  $MANIFEST_NAME" "$OUT/SHA256SUMS"; then
  say "checksums reused $OUT/SHA256SUMS (the same bytes a signature was made over)"
else
  ( cd "$OUT" && sha256sum "$MANIFEST_NAME" ) > "$OUT/.SHA256SUMS.$$" \
    && mv -f "$OUT/.SHA256SUMS.$$" "$OUT/SHA256SUMS" \
    || fail "record_unwritable: $OUT/SHA256SUMS" 2
  if [ -f "$OUT/SHA256SUMS.sig" ]; then
    ( . "$REPO_ROOT/scripts/lib/release-signing.sh" && wa_release_verify_sums "$OUT" ) \
      || fail "signature_stale: $OUT/SHA256SUMS.sig is not a signature over the sums just written (they changed after it was made); sign the new sums where the vault is and run this again" 6
  fi
  say "checksums $OUT/SHA256SUMS (1 asset: $MANIFEST_NAME)"
fi

if [ -n "$SIGN_COMMAND" ]; then
  say "signing $OUT/SHA256SUMS with: $SIGN_COMMAND"
  $SIGN_COMMAND "$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig" \
    || fail "record_not_signed: $SIGN_COMMAND did not sign $OUT/SHA256SUMS" 8
  ( . "$REPO_ROOT/scripts/lib/release-signing.sh" && wa_release_verify_sums "$OUT" ) \
    || fail "record_signature_invalid: the signature $SIGN_COMMAND wrote is not trusted over $OUT/SHA256SUMS (config/release-keys.txt is the anchor)" 6
  say "signature $OUT/SHA256SUMS.sig ($(sed -n 's/^key //p' "$OUT/SHA256SUMS.sig"))"
else
  say "unsigned so far: a round signs $OUT/SHA256SUMS in its own sign step (scripts/sign-release.sh), and nothing here pretends it is signed"
fi
say "record: $OUT/$MANIFEST_NAME ($COUNT file(s) at $SHORT, lua_inputs $DIGEST, no cross-build, no node release)"
