#!/usr/bin/env bash
# IS A PUBLISHED COMMIT ACTUALLY INSTALLABLE BY DOWNLOAD? - every URL the release and its components lock
# name, asked for HEAD, in seconds.
#
# WHY (24/11). Publishing is per landing and covers the node binary only, while a node also needs the
# components bundle named by the sha256 of its components.lock (scripts/lib/deploy-components.sh,
# wa_component_release_tag). A landing that changed the lock therefore published a binary whose components
# bundle was never made - components-df6f97708c72 answered HTTP 404 - and every node without a toolchain
# refused the update, twice a day, with nothing anywhere saying which asset was missing. This file is the
# question that was never asked, in the one place it is cheap: after a publish, before the fleet step.
#
# THREE ANSWERS, NEVER TWO. `published` is an HTTP 200 for the asset; `missing` is a 404; anything else -
# no network, a rate-limited API, a redirect that never resolves, no curl - is `unknown`, and unknown is a
# REFUSAL about the question, not a pass (the row that says `unknown` never claims installable).
#
# ENDPOINTS. Defaults are GitHub's own: the API at https://api.github.com and assets under
# https://github.com/<slug>/releases/download/<tag>/<asset>. Both are overridable (WA_RELEASE_API_BASE,
# WA_RELEASE_DOWNLOAD_BASE) so a fixture can hold a local stand-in - the only way to prove the checks
# without asking the real channel, and how scripts/test-release-completeness.sh runs.
#
# Sourced by scripts/check-release-complete.sh, scripts/publish-node-binaries.sh and scripts/deploy.sh.

# THE BOUND EVERY REQUEST HERE RUNS TO, in seconds. A question this file asks is worth seconds, not a
# hang: `wa update --check` asks it while a person waits (24/11 - its refresh runs to 10 s,
# M.REFRESH_SECONDS in lua/core/update_banner.lua), and a channel that accepts a connection and then says
# nothing must become `unknown` inside that bound rather than hold the command open. WA_RELEASE_SECONDS
# is how a caller states its own; the check's --components mode asks for 10.
wa_release_seconds() {
  local seconds="${WA_RELEASE_SECONDS:-20}"
  case "$seconds" in ''|*[!0-9]*) seconds=20 ;; esac
  [ "$seconds" -ge 1 ] || seconds=1
  printf '%s\n' "$seconds"
}

wa_release_api_base() { printf '%s\n' "${WA_RELEASE_API_BASE:-https://api.github.com}"; }
wa_release_download_base() { printf '%s\n' "${WA_RELEASE_DOWNLOAD_BASE:-https://github.com}"; }

# <slug> <tag> <asset> -> the canonical download URL (the one a node's fetch uses).
wa_release_asset_url() { # <slug> <tag> <asset>
  printf '%s/%s/releases/download/%s/%s\n' "$(wa_release_download_base)" "$1" "$2" "$3"
}

# <url> -> "200", a three-digit status, or "unknown (<why>)". -I first (a HEAD: no body to pay for), and a
# range GET for a host that answers a HEAD with 501/403 (some CDNs do) - the status of the GET's first byte
# is the same answer. Never a redirect followed silently into another host's 200 for another asset: -L is
# used because GitHub's download URLs redirect to a canonical asset host, and the status of the FINAL hop is
# what a node's fetch sees.
wa_release_http_status() { # <url>
  local url="$1" code rc
  command -v curl >/dev/null 2>&1 || { printf 'unknown (no curl)\n'; return 2; }
  code="$(curl -s -o /dev/null -I -L -m "$(wa_release_seconds)" -w '%{http_code}' "$url" 2>/dev/null)"; rc=$?
  # A TRANSFER THAT DID NOT COMPLETE IS NOT AN ANSWER (measured 24/11): a host that accepts the connection
  # and then sends nothing makes curl PRINT the 200 it read from the headers and EXIT 28 when -m cuts the
  # transfer - so the status code alone would call an asset published that the host never sent. The exit
  # status is asked first, and a cut request is `unknown`, never a 200.
  [ "$rc" = 0 ] || { printf 'unknown (the request did not complete: curl %s)\n' "$rc"; return 2; }
  case "$code" in
    200) printf '200\n'; return 0 ;;
  esac
  if [ "$code" = 000 ] || [ -z "$code" ] || [ "$code" = 405 ] || [ "$code" = 501 ] || [ "$code" = 403 ]; then
    code="$(curl -s -o /dev/null -L -m "$(wa_release_seconds)" -r 0-0 -w '%{http_code}' "$url" 2>/dev/null)"; rc=$?
    [ "$rc" = 0 ] || { printf 'unknown (the request did not complete: curl %s)\n' "$rc"; return 2; }
  fi
  case "$code" in
    200|206) printf '200\n'; return 0 ;;
    ''|000) printf 'unknown (no answer from the host)\n'; return 2 ;;
    *) printf '%s\n' "$code"; return 1 ;;
  esac
}

# <slug> <tag> -> "published" (0), "missing" (1, the tag does not exist: HTTP 404) or "unknown (<why>)" (2).
# gh is asked FIRST only when no API base was named: an authenticated view is one request and no rate limit.
# A gh that FAILS is not an answer (a token can be missing while the release exists), so the API is asked
# next - and gh is never asked when the caller pointed the lib somewhere else.
wa_release_tag_state() { # <slug> <tag>
  local slug="$1" tag="$2" code rc
  if [ -z "${WA_RELEASE_API_BASE:-}" ] && command -v gh >/dev/null 2>&1; then
    if gh release view "$tag" -R "$slug" >/dev/null 2>&1; then printf 'published\n'; return 0; fi
  fi
  command -v curl >/dev/null 2>&1 || { printf 'unknown (no curl, and gh could not answer)\n'; return 2; }
  code="$(curl -s -o /dev/null -m "$(wa_release_seconds)" -w '%{http_code}' "$(wa_release_api_base)/repos/$slug/releases/tags/$tag" 2>/dev/null)"; rc=$?
  # The exit status first, for the same reason as the asset check: a request cut by the bound is not a 200.
  [ "$rc" = 0 ] || { printf 'unknown (the release API did not answer: curl %s)\n' "$rc"; return 2; }
  case "$code" in
    200) printf 'published\n'; return 0 ;;
    404) printf 'missing\n'; return 1 ;;
    ''|000) printf 'unknown (the release API did not answer)\n'; return 2 ;;
    *) printf 'unknown (the release API answered HTTP %s)\n' "$code"; return 2 ;;
  esac
}

# <text on stdin> -> its sha256, or 7 without a sha tool (the identity of a lock, read from a commit).
wa_release_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else return 7; fi
}

# <repo> <commit> -> the release tag that publishes the components THIS COMMIT's lock pins. 2 when the lock
# cannot be read from the commit (a shallow clone): an unknown tag is refused, never guessed from the
# publisher's own checkout, which is a different commit the moment a landing moves.
wa_release_components_tag() { # <repo> <commit>
  local repo="$1" commit="$2" sha
  sha="$(git -C "$repo" show "$commit:components.lock" 2>/dev/null | wa_release_sha256_stdin)" || return 2
  [ -n "$sha" ] || return 2
  printf 'components-%s\n' "${sha:0:12}"
}

# <manifest file> -> the asset names a node's fetch reads for the triples the manifest publishes, one per
# line, plus the manifest itself, the sums and the signature. Only rows the manifest really carries: a
# release that publishes one triple is complete with one triple's assets.
wa_release_manifest_assets() { # <manifest>
  local manifest="$1" short triple rows
  short="$(sed -n 's/^source_commit=//p' "$manifest" 2>/dev/null | head -1)"
  short="${short:0:12}"
  [ -n "$short" ] || return 2
  rows="$(awk '!/=/ && NF >= 5 && $1 !~ /^#/ {print $1}' "$manifest")"
  [ -n "$rows" ] || return 2
  printf 'node-%s.manifest\nSHA256SUMS\nSHA256SUMS.sig\n' "$short"
  for triple in $rows; do
    printf 'wa-%s-%s\nwa-sentinel-%s-%s\n' "$triple" "$short" "$triple" "$short"
  done
  return 0
}

# <repo> <commit> [workdir] -> every asset name this commit's node release must carry, on stdout, one per
# line. The manifest is read from <workdir> when it is already there, else fetched (WA_RELEASE_MANIFEST_DIR
# names a directory to read it from). 2 when the manifest itself cannot be read: an unreadable manifest is
# an unanswerable question, never a short list.
wa_release_node_assets() { # <repo> <commit> [workdir]
  local repo="$1" commit="$2" work="${3:-}" short manifest slug file
  short="${commit:0:12}"
  manifest=""
  if [ -n "${WA_RELEASE_MANIFEST_DIR:-}" ] && [ -f "$WA_RELEASE_MANIFEST_DIR/node-$short.manifest" ]; then
    manifest="$WA_RELEASE_MANIFEST_DIR/node-$short.manifest"
  elif [ -n "$work" ] && [ -f "$work/node-$short.manifest" ]; then
    manifest="$work/node-$short.manifest"
  fi
  if [ -z "$manifest" ]; then
    [ -n "$work" ] || return 2
    slug="$(wa_release_repo_slug "$repo")" || return 2
    file="$(wa_release_asset_url "$slug" "node-$short" "node-$short.manifest")"
    mkdir -p "$work" 2>/dev/null || return 2
    curl -fsSL -m "$(wa_release_seconds)" "$file" -o "$work/node-$short.manifest" 2>/dev/null || return 2
    manifest="$work/node-$short.manifest"
  fi
  wa_release_manifest_assets "$manifest"
}

# <repo> -> the owner/repo a release lives in: WA_RELEASE_REPO wins, else origin's GitHub slug, else the one
# source of truth every tree in this fleet is a worktree of (the same rule the component fetch uses).
wa_release_repo_slug() { # <repo>
  local repo="$1" url
  if [ -n "${WA_RELEASE_REPO:-}" ]; then printf '%s\n' "$WA_RELEASE_REPO"; return 0; fi
  url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null)"
  case "$url" in
    *github.com[:/]*)
      url="${url##*github.com[:/]}"; url="${url%.git}"
      case "$url" in */*) printf '%s\n' "$url"; return 0 ;; esac ;;
  esac
  printf '%s\n' 'Magaav/wasm-agent'
}

# <repo> <commit> <workdir> -> the completeness verdict for ONE commit, in the format the land report and
# releases.jsonl carry (item 2). One `<status> <asset> <url>` line per asset on stdout, then:
#   complete      0
#   INCOMPLETE    1  and the last line is "<sha12> is NOT installable by download: <asset> missing"
#   unknown       2  when a question could not be answered (never reported as complete)
wa_release_completeness() { # <repo> <commit> <workdir>
  local repo="$1" commit="$2" work="$3" short slug lock_tag names name asset url status rc=0 missing="" unknown=""
  short="${commit:0:12}"
  slug="$(wa_release_repo_slug "$repo")" || { printf 'unknown\n'; return 2; }
  if ! names="$(wa_release_node_assets "$repo" "$commit" "$work")"; then
    printf 'unknown node-%s.manifest could not be read from %s\n' "$short" "$slug"
    printf '%s is NOT installable by download: node-%s.manifest missing (or unreadable)\n' "$short" "$short"
    return 1
  fi
  for asset in $names; do
    url="$(wa_release_asset_url "$slug" "node-$short" "$asset")"
    status="$(wa_release_http_status "$url")" || true
    case "$status" in
      200) printf '200 %s %s\n' "$asset" "$url" ;;
      unknown*) printf '%s %s %s\n' "$status" "$asset" "$url"; unknown="$asset"; rc=2 ;;
      *) printf '%s %s %s\n' "$status" "$asset" "$url"; [ -n "$missing" ] || missing="$asset"; rc=1 ;;
    esac
  done
  # THE COMPONENTS BUNDLE, named by the sha256 of the lock AT THAT COMMIT (not the publisher's checkout: the
  # question is what a node deploying THIS commit asks for).
  lock_tag="$(wa_release_components_tag "$repo" "$commit" 2>/dev/null)"
  if [ -z "$lock_tag" ]; then
    printf 'unknown components.lock could not be read at %s\n' "$commit"
    rc=2
  else
    names="$(git -C "$repo" show "$commit:components.lock" 2>/dev/null | awk '/^[[:space:]]*(#|$)/ {next}; $1 != "" && $2 ~ /^[0-9a-f]+$/ {print $1}')"
    if [ -z "$names" ]; then
      printf 'unknown components.lock at %s pins no component\n' "$commit"
      rc=2
    else
      for name in $names; do
        for asset in "$name.wasm" "$name.json"; do
          url="$(wa_release_asset_url "$slug" "$lock_tag" "$asset")"
          status="$(wa_release_http_status "$url")" || true
          case "$status" in
            200) printf '200 %s %s\n' "$asset" "$url" ;;
            unknown*) printf '%s %s %s\n' "$status" "$asset" "$url"; unknown="$asset"; [ "$rc" = 0 ] && rc=2 ;;
            *) printf '%s %s %s\n' "$status" "$asset" "$url"; [ -n "$missing" ] || missing="$lock_tag/$asset"; rc=1 ;;
          esac
        done
      done
      url="$(wa_release_asset_url "$slug" "$lock_tag" components.lock)"
      status="$(wa_release_http_status "$url")" || true
      case "$status" in
        200) printf '200 components.lock %s\n' "$url" ;;
        unknown*) printf '%s components.lock %s\n' "$status" "$url"; unknown="components.lock"; [ "$rc" = 0 ] && rc=2 ;;
        *) printf '%s components.lock %s\n' "$status" "$url"; [ -n "$missing" ] || missing="$lock_tag/components.lock"; rc=1 ;;
      esac
    fi
  fi
  case "$rc" in
    0) printf 'complete node-%s and %s answer 200 for every asset\n' "$short" "${lock_tag:-the components bundle}" ;;
    1) printf '%s is NOT installable by download: %s missing\n' "$short" "$missing" ;;
    *) printf '%s: what this commit needs could not be asked (%s); that is not the same as installable\n' "$short" "${unknown:-an unanswerable question}" ;;
  esac
  return "$rc"
}
