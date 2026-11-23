#!/usr/bin/env bash
# A fake GitHub CLI, for the rows that publish into a release: one directory per tag, and every verb answers
# from the files there. It is what lets a row hold a publisher to the EFFECT (the archive is ON the release,
# with the size it measured) instead of to the command it typed, with no token and no network on the machine
# that runs it.
#
# WHY A SHARED FILE (Fable, 23/11). Two rows now drive the release upload - the channel publisher's own row
# (scripts/test-linux-channel.sh) and the channel STEP's end-to-end row (scripts/test-release-channel-e2e.sh) -
# and a fake copied into each of them drifts: the second copy would answer a verb the first one refuses, and a
# row would then be green against a GitHub that does not exist. One implementation, judged by both.
#
#   . scripts/lib/fake-gh.sh
#   wa_fake_gh_install "$T/bin"          # writes $T/bin/gh
#   export FAKE_GH_STATE="$T/gh"        # one directory per tag, holding the uploaded assets
#
# FAKE_GH_FAIL picks the way it misbehaves: `auth` (signed out), `publish`/`create`/`upload` (the upload is
# refused), `readback` (the archive is dropped after a "successful" upload, so the effect is not there).
wa_fake_gh_install() { # <bin-dir>
  local bin=${1:?wa_fake_gh_install needs the directory to write the fake into}
  mkdir -p "$bin" || return 1
  cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
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
  chmod +x "$bin/gh"
}
