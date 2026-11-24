#!/usr/bin/env bash
# IS THIS COMMIT INSTALLABLE BY DOWNLOAD? - every URL its node release and its components lock name,
# answered by HEAD in seconds, with the one sentence a land report and releases.jsonl carry.
#
#   bash scripts/check-release-complete.sh [<40-hex commit>] [--json] [--manifest-dir DIR] [--repo DIR]
#
# WHY (24/11). Publishing is per landing and covers the node binary only; a node also needs the components
# bundle named by the sha256 of components.lock. A landing that moved the lock published a binary with no
# bundle (components-df6f97708c72: HTTP 404), so every node without a toolchain refused the update - and
# nothing in the publish path said which asset was missing. This is that check, after the publish and before
# the fleet step. It is NOT a landing gate: it reports, and the orchestrator records the report.
#
# Exit: 0 complete (every asset 200); 1 NOT installable by download, with the missing asset named; 2 a
# question that could not be answered (no network, no curl, a lock that cannot be read) - unknown is never
# reported as installable.
#
# --json prints one line for releases.jsonl and nothing else:
#   {"sha":"<40 hex>","at":"<utc>","installable":"yes|no|unknown","missing":"<asset>","verdict":"<the sentence>"}
#
# It reads GitHub (HEAD of the release URLs, read-only), publishes nothing, and starts no node.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/release-completeness.sh"

COMMIT=""
JSON=0
MANIFEST_DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --json) JSON=1; shift ;;
    --repo) ROOT="${2:-}"; [ -d "$ROOT" ] || { echo "check-release-complete: unknown: --repo $ROOT is not a directory" >&2; exit 2; }; shift 2 ;;
    --manifest-dir) MANIFEST_DIR="${2:-}"; shift 2 ;;
    -*) echo "check-release-complete: unknown_option: $1" >&2; exit 2 ;;
    *) COMMIT="$1"; shift ;;
  esac
done
[ -n "$MANIFEST_DIR" ] && export WA_RELEASE_MANIFEST_DIR="$MANIFEST_DIR"
if [ -z "$COMMIT" ]; then
  git fetch -q origin 2>/dev/null || true
  COMMIT="$(git rev-parse origin/main 2>/dev/null)" || { echo 'check-release-complete: unknown: this checkout has no origin/main' >&2; exit 2; }
fi
case "$COMMIT" in
  *[!0-9a-f]*|'') echo "check-release-complete: unknown: '$COMMIT' is not a hex commit id" >&2; exit 2 ;;
esac
[ "${#COMMIT}" = 40 ] || { echo "check-release-complete: unknown: '$COMMIT' is not a full 40-hex commit id" >&2; exit 2; }

git -C "$ROOT" cat-file -e "$COMMIT^{commit}" 2>/dev/null \
  || { echo "check-release-complete: unknown: $COMMIT is not in this checkout (fetch it first; the lock it pins is read from the commit)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-release-complete.XXXXXX")" || { echo 'check-release-complete: unknown: no scratch directory' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

rows="$(wa_release_completeness "$ROOT" "$COMMIT" "$WORK")"; rc=$?
verdict="$(printf '%s\n' "$rows" | tail -1)"
if [ "$JSON" = 1 ]; then
  case "$rc" in 0) inst=yes ;; 1) inst=no ;; *) inst=unknown ;; esac
  missing=""
  [ "$inst" = no ] && missing="$(printf '%s' "$verdict" | sed -n 's/.*NOT installable by download: //; s/ missing$//p')"
  printf '{"sha":"%s","at":"%s","installable":"%s","missing":"%s","verdict":"%s"}\n' \
    "$COMMIT" "$(date -u +%FT%TZ)" "$inst" "$missing" "$(printf '%s' "$verdict" | sed 's/"/\\"/g')"
else
  printf '%s\n' "$rows"
  case "$rc" in
    0) echo "check-release-complete: installable by download: ${COMMIT:0:12}" ;;
    # The verdict IS the sentence the land report and releases.jsonl carry, and it is the last line the rows
    # above end with: a second copy on stderr would say it twice, and a prefix would say it wrongly.
    1) : ;;
    *) echo "check-release-complete: unknown: $verdict" >&2 ;;
  esac
fi
exit "$rc"
