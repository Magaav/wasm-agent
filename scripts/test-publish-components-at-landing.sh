#!/usr/bin/env bash
# The landing's SECOND publish: the components bundle, when the lock names one that does not exist.
#
# THE DEFECT (24/11). Publishing is per landing and covers the node binary only. A node also needs the
# components bundle named by the sha256 of its components.lock, so a landing that moved the lock published a
# binary whose bundle was never made - components-df6f97708c72 answered HTTP 404 - and every node without a
# toolchain refused the update. scripts/lib/landing-components-publish.sh is that step; this proves it:
#   * OFF by default (WA_PUBLISH_COMPONENTS unset): nothing is uploaded and the log says this landing is not
#     installable by download on a node without a toolchain;
#   * ON: the bundle is verified by the REAL scripts/publish-components.sh (--from, so the pinned bytes are
#     checked against the lock) and uploaded with every pinned asset plus components.lock, --latest=false,
#     under components-<sha12 of the lock>;
#   * a tag that already exists is UPLOADED OVER, never recreated (idempotent, like the node release);
#   * a channel that cannot answer is UNKNOWN, not assumed: nothing is uploaded and the line says so;
#   * a bundle whose bytes are not the pins is REFUSED by publish-components.sh and nothing is uploaded.
#
# WHAT IS A STAND-IN AND WHY: gh (an external service). It is a shim that RECORDS its arguments and answers
# `release view` with failure (so the create path is taken), and nothing here claims a release was published -
# the row is the exact command a real publisher would run. Every byte check is real: the fixture bundle is
# verified by scripts/publish-components.sh against the fixture lock.
#
# No network, no cargo, no node. Scratch HOME through scripts/lib/scratch-home.sh.
#
#   bash scripts/test-publish-components-at-landing.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"

root="$(wa_scratch_root wa-publish-components-at-landing)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
cleanup() { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
REAL_HOME="${HOME:-}"
export HOME="$W/home"
mkdir -p "$HOME"
HOME="$REAL_HOME" wa_scratch_home_guard "$W/home" || exit 2
export WASM_AGENT_HOME="$HOME"

checks=0; failed=0
ok()   { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }

# ---- a recording gh, first on PATH ----------------------------------------------------------------
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "release view") exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH"
export GH_LOG="$W/gh.log"
: > "$GH_LOG"

# ---- a fixture tree: a lock, and a bundle whose bytes ARE the pins ----------------------------------
REPO="$W/repo"
BUNDLE="$W/bundle"
mkdir -p "$REPO/scripts/lib" "$BUNDLE"
# THE FIXTURE TREE IS A LANDING HOST, so it carries the real publisher the step calls: the step runs
# bash <tree>/scripts/publish-components.sh, whose own ROOT is the tree it lives in. Nothing here is a stub
# of that verification - a bundle that is not the pins is refused by the real code (row 5).
cp "$ROOT/scripts/publish-components.sh" "$REPO/scripts/publish-components.sh"
for lib in deploy-components.sh component-build-root.sh shared-commit.sh; do cp "$ROOT/scripts/lib/$lib" "$REPO/scripts/lib/$lib"; done
# A fixture commit is on no branch the remote has; the publisher's own named exception is what a fixture uses,
# and it records the reason in the release notes it would have written.
export ALLOW_UNPUSHED_COMMIT=1 ALLOW_UNPUSHED_REASON="fixture bundle for scripts/test-publish-components-at-landing.sh"
printf 'this is not a real component\n' > "$BUNDLE/svc-alpha.wasm"
printf '{"name":"svc-alpha"}\n' > "$BUNDLE/svc-alpha.json"
SHA="$(sha256sum < "$BUNDLE/svc-alpha.wasm" | awk '{print $1}')"
BYTES="$(wc -c < "$BUNDLE/svc-alpha.wasm" | tr -d '[:space:]')"
printf 'svc-alpha %s %s\n' "$SHA" "$BYTES" > "$REPO/components.lock"
git -c init.defaultBranch=main init -q "$REPO"
( cd "$REPO" && git add components.lock && git -c user.email=t@t -c user.name=t commit -qm lock )
COMMIT="$(git -C "$REPO" rev-parse HEAD)"
SHORT="${COMMIT:0:12}"
LOCK_TAG="components-$(sha256sum < "$REPO/components.lock" | awk '{print $1}' | cut -c1-12)"

say() { printf 'landing: %s\n' "$*" >&2; }
fail() { printf 'landing: %s\n' "$*" >&2; exit "${2:-2}"; }
. "$ROOT/scripts/lib/release-completeness.sh"
. "$ROOT/scripts/lib/landing-components-publish.sh"
# The step's inputs, as publish-node-binaries.sh has them at that point in a --publish run.
OUT="$W/out"
mkdir -p "$OUT"
ROOT="$REPO"          # the step reads components.lock from the tree whose landing it is
REPO_SLUG="Magaav/wasm-agent"
# The channel stand-in: a local server over a directory tree. An empty releases/tags path means every tag
# answered 404, which is "not published" - the state a landing that moved the lock is in.
mkdir -p "$W/srv/api/repos/Magaav/wasm-agent/releases/tags"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W/srv" >"$W/srv.log" 2>&1 &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
for _ in $(seq 1 50); do
  curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/repos/Magaav/wasm-agent/releases/tags/nothing" 2>/dev/null && break
  sleep 0.1
done
export WA_RELEASE_API_BASE="http://127.0.0.1:$PORT/api"
WA_RELEASE_DOWNLOAD_BASE_LOCAL="http://127.0.0.1:$PORT"
export WA_RELEASE_DOWNLOAD_BASE_LOCAL

# ---- 1. OFF by default: nothing is uploaded, and the log says what this landing is ------------------
unset WA_PUBLISH_COMPONENTS WA_COMPONENTS_BUNDLE
out="$(components_step 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "with the flag off the step succeeds and publishes nothing" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -q "$LOCK_TAG is NOT published" && echo 1)" "it names the bundle that is missing" "$out"
ok "$(printf '%s' "$out" | grep -q 'not installable by download' && echo 1)" "and says this landing is not installable by download" "$out"
ok "$(printf '%s' "$out" | grep -q 'WA_PUBLISH_COMPONENTS=1' && echo 1)" "and names the flag that would publish it" "$out"
ok "$([ ! -s "$GH_LOG" ] && echo 1)" "gh was never called" "$(cat "$GH_LOG")"

# ---- 2. the channel cannot answer: UNKNOWN, never "missing, so publish" ------------------------------
# The prefix goes INSIDE the substitution: on the outside it is a plain assignment list, which bash applies
# to this shell and exports - every later row would then be asking the closed port (measured here).
out="$(WA_RELEASE_API_BASE="http://127.0.0.1:1/api" WA_PUBLISH_COMPONENTS=1 components_step 2>&1)"; rc=$?
ok "$([ "$rc" = 2 ] && echo 1)" "an unanswerable channel makes the step answer unknown (rc 2), not a pass" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -q 'UNKNOWN, not assumed' && echo 1)" "and says so in words" "$out"
ok "$([ ! -s "$GH_LOG" ] && echo 1)" "nothing was uploaded for an unknown state" "$(cat "$GH_LOG")"

# ---- 3. ON, with the channel answering 404: the bundle is verified and uploaded ------------------------
WA_PUBLISH_COMPONENTS=1 WA_COMPONENTS_BUNDLE="$BUNDLE" out="$(components_step 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "with the flag on the bundle is published" "rc=$rc $out"
create="$(grep '^release create ' "$GH_LOG" 2>/dev/null | head -1)"
ok "$(printf '%s' "$create" | grep -q "^release create $LOCK_TAG -R Magaav/wasm-agent" && echo 1)" "under components-<sha12 of the lock>, in the release's own repo" "$create"
ok "$(printf '%s' "$create" | grep -q -- '--latest=false' && echo 1)" "never as GitHub's latest" "$create"
ok "$(printf '%s' "$create" | grep -q 'svc-alpha.wasm' && printf '%s' "$create" | grep -q 'svc-alpha.json' && printf '%s' "$create" | grep -q 'components.lock' && echo 1)" "with every pinned asset and the lock itself" "$create"
ok "$([ -f "$OUT/components-release/svc-alpha.wasm" ] && [ -f "$OUT/components-release/components.lock" ] && echo 1)" "from a bundle directory the real publisher verified against the lock"

# ---- 4. an existing tag is COMPLETED, never replaced (Fable, 24/11; Victor: nothing overwritten) ---------
# The release exists and already holds most of the set; one asset is missing. The step must ask every asset
# for its status and upload ONLY the missing one, never --clobber.
cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 0
SH
chmod +x "$W/bin/gh"
DIST="$W/srv/Magaav/wasm-agent/releases/download/$LOCK_TAG"
API_TAG="$W/srv/api/repos/Magaav/wasm-agent/releases/tags/$LOCK_TAG"
# THE ASSET STATUSES ARE ASKED OF THE DOWNLOAD URLS, so the stand-in must serve them: without this the
# step would ask github.com about a fixture tag, get 404 for every asset, and upload all of them (measured
# here before the export: "holds 0 of 3").
export WA_RELEASE_DOWNLOAD_BASE="$WA_RELEASE_DOWNLOAD_BASE_LOCAL"
make_tag() { mkdir -p "$DIST" "$(dirname "$API_TAG")"; touch "$API_TAG"; for name in svc-alpha; do
  printf 'x' > "$DIST/$name.wasm"; printf 'x' > "$DIST/$name.json"; done; printf 'x' > "$DIST/components.lock"; }
make_tag; rm -f "$DIST/svc-alpha.json"   # exactly one asset missing
: > "$GH_LOG"
out="$(WA_PUBLISH_COMPONENTS=1 WA_COMPONENTS_BUNDLE="$BUNDLE" components_step 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "an existing tag with a missing asset is completed" "rc=$rc $out"
ok "$(grep -q '^release upload ' "$GH_LOG" && echo 1)" "by an upload" "$(head -3 "$GH_LOG")"
ok "$(! grep -q '^release create ' "$GH_LOG" && echo 1)" "and never by creating it again" "$(head -3 "$GH_LOG")"
ok "$(! grep -q -- '--clobber' "$GH_LOG" && echo 1)" "WITHOUT --clobber: a published asset is never replaced" "$(head -3 "$GH_LOG")"
ok "$(grep '^release upload ' "$GH_LOG" | grep -q 'svc-alpha.json' && echo 1)" "and the upload names the missing asset" "$(grep '^release upload ' "$GH_LOG")"
ok "$(! grep '^release upload ' "$GH_LOG" | grep -q 'svc-alpha.wasm' && echo 1)" "while the assets already there are not uploaded again" "$(grep '^release upload ' "$GH_LOG")"
ok "$(printf '%s' "$out" | grep -q 'uploading only the missing: *svc-alpha.json' && echo 1)" "and says how many it found and which it added" "$out"

# ...and a tag that already holds EVERYTHING is left alone.
make_tag
: > "$GH_LOG"
out="$(WA_PUBLISH_COMPONENTS=1 WA_COMPONENTS_BUNDLE="$BUNDLE" components_step 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "a complete tag answers 0" "rc=$rc $out"
ok "$(! grep -q '^release upload \|^release create ' "$GH_LOG" && echo 1)" "and uploads or creates nothing at all" "$(cat "$GH_LOG")"
ok "$(printf '%s' "$out" | grep -q 'already holds every asset' && echo 1)" "and says every asset is already there and nothing was replaced" "$out"

# ...and a status that cannot be read is a REFUSAL, never an upload over an asset nobody can see.
: > "$GH_LOG"
out="$(WA_PUBLISH_COMPONENTS=1 WA_COMPONENTS_BUNDLE="$BUNDLE" WA_RELEASE_DOWNLOAD_BASE="http://127.0.0.1:1" components_step 2>&1)"; rc=$?
ok "$([ "$rc" != 0 ] && echo 1)" "an asset whose status cannot be read refuses the publish" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -q 'components_publish_unanswerable' && echo 1)" "by name: components_publish_unanswerable" "$(printf '%s' "$out" | tail -2)"
ok "$(! grep -q '^release upload \|^release create ' "$GH_LOG" && echo 1)" "and nothing was uploaded" "$(cat "$GH_LOG")"
unset WA_RELEASE_DOWNLOAD_BASE
# ---- 5. a bundle that is not the pins is refused, and nothing is uploaded ------------------------------
printf 'tampered\n' > "$BUNDLE/svc-alpha.wasm"
: > "$GH_LOG"
WA_PUBLISH_COMPONENTS=1 WA_COMPONENTS_BUNDLE="$BUNDLE" out="$(components_step 2>&1)"; rc=$?
ok "$([ "$rc" != 0 ] && echo 1)" "a bundle whose bytes are not the lock's is refused" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -qE 'components_publish_failed|artifact_not_pinned' && echo 1)" "and the refusal is named (the real publisher's own line)" "$(printf '%s' "$out" | tail -3)"
ok "$([ ! -s "$GH_LOG" ] && echo 1)" "nothing was uploaded" "$(cat "$GH_LOG")"

printf 'publish components at landing ok (%d checks, %d failed)\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
