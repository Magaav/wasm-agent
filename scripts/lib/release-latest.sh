#!/bin/bash
# WHEN A RELEASE MAY BECOME THE LATEST (Fable 26/11).
#
# A release has two or more targets and one asset per target, and `gh release create --latest` marks it Latest at
# CREATE time - so a node of the other target sees a Latest that has no asset for it, and a failed later upload
# leaves a half release wearing the badge. The rule is therefore a DECISION taken at the END, after every asset is
# uploaded, and it is written here (not inline in release-linux.sh) so a row can run it:
#
#   create  ->  upload every target + sums + signature  ->  verify the asset list  ->  edit --latest
#
# and only when the tag is a FULL version (v<d>.<d>.<d>), every expected target has its asset, and the version is
# GREATER than the release that currently holds Latest (a patch of an older line must not take the badge).
#
# Contract: every function prints its answer on stdout and nothing else; callers pass values in, never paths.

# The substring an asset name must carry for a target. Measured against the published names
# (wa-linux-x64-musl-<sha12>.tar.gz) and scripts/release-linux.sh line 112 ($name.tar.gz).
wa_release_expected_asset() {
  case "${1:-}" in
    x86_64-unknown-linux-musl) echo 'x64-musl' ;;
    aarch64-unknown-linux-musl) echo 'arm64-musl' ;;
    x86_64-unknown-linux-gnu) echo 'x64-gnu' ;;
    aarch64-unknown-linux-gnu) echo 'arm64-gnu' ;;
    *) return 1 ;;
  esac
}

# A FULL version is v<digits>.<digits>.<digits>, nothing else. A suffix (v0.2.0-rc1, a rehearsal) never takes Latest.
wa_release_full_tag() {
  printf '%s' "${1:-}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
}

# Semver precedence on the numeric core only: prints gt, eq or lt. Both sides must be full versions.
wa_release_compare() {
  local a b x y z p q r
  wa_release_full_tag "${1:-}" || { echo 'unparsable'; return 1; }
  wa_release_full_tag "${2:-}" || { echo 'unparsable'; return 1; }
  a="${1#v}"; b="${2#v}"
  x="${a%%.*}"; a="${a#*.}"; y="${a%%.*}"; z="${a#*.}"
  p="${b%%.*}"; b="${b#*.}"; q="${b%%.*}"; r="${b#*.}"
  for pair in "$x $p" "$y $q" "$z $r"; do
    set -- $pair
    if [ "$1" -gt "$2" ]; then echo gt; return 0; fi
    if [ "$1" -lt "$2" ]; then echo lt; return 0; fi
  done
  echo eq
}

# The decision. Args: tag current_latest_tag expected_targets(space separated) assets(newline separated).
# stdout: `take` or `skip:<code> <detail>`. The detail NAMES the thing that stopped it - a missing target is named
# by its triple, never summarised as 'incomplete'.
wa_release_latest_decision() {
  local tag="${1:-}" current="${2:-}" targets="${3:-}" assets="${4:-}"
  if ! wa_release_full_tag "$tag"; then
    echo "skip:not_full_version $tag is not v<digits>.<digits>.<digits>, so it stays a prerelease"
    return 0
  fi
  local target token missing=''
  for target in $targets; do
    token=$(wa_release_expected_asset "$target") || { echo "skip:unknown_target $target has no known asset token"; return 0; }
    if ! printf '%s\n' "$assets" | grep -q -- "$token"; then
      missing="${missing:+$missing, }$target"
    fi
  done
  if [ -n "$missing" ]; then
    echo "skip:missing_target the release has no asset for $missing"
    return 0
  fi
  if wa_release_full_tag "$current"; then
    case "$(wa_release_compare "$tag" "$current")" in
      gt) echo "take $tag is newer than the Latest $current" ; return 0 ;;
      eq) echo "skip:not_newer $tag is already the Latest $current" ; return 0 ;;
      *)  echo "skip:not_newer $tag is older than the Latest $current, so a patch of an older line does not take the badge" ; return 0 ;;
    esac
  fi
  echo "take $tag is newer than the current Latest (${current:-none})"
}
