#!/usr/bin/env bash
# A ROW BUILDS ITS ENVIRONMENT ONCE, NEVER ACROSS A LINE CONTINUATION
# (installer-refuses-a-target, item 10 - the 09:48Z incident)
#
# MEASURED 25/11 09:48Z-10:00Z: a comment inserted inside a line continuation cut a row's `env ... \` prefix off, so
# `setsid --wait bash scripts/deploy.sh` ran with the CHAT's environment against the LIVE install directory - five deploys, one
# accepted, the install lock held for ten minutes, two sessions paused and a false deploy-result.json. A line continuation
# is a statement whose meaning depends on nothing but its own bytes, and one stray line removes the very prefix that made it
# safe.
#
# THE RULE: a statement in a row (or a harness) that starts an installer must not carry a backslash-newline continuation.
# One line, or an env FILE, or an ARRAY - never a `\` at end of line inside such a statement.
#
# What this row is NOT: a ban on line continuations. They are fine everywhere else, and this checks only statements that
# run an installer, because only those can act on the operator's home by accident.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }

INSTALLER='(deploy\.sh|upgrade\.sh|bootstrap\.sh|install-local\.sh|install\.sh)'
offenders=0
scanned=0
while IFS= read -r file; do
  scanned=$((scanned+1))
  # a statement that runs an installer AND ends a line with a backslash
  hits=$(awk -v pat="$INSTALLER" '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        # THE SHAPE OF THE 09:48Z INCIDENT, and only it: a statement that builds an environment with env (the prefix a
        # stray line cut off), names an installer, and continues on a backslash. A bare bash scripts/deploy.sh is fine.
        if (line ~ /^[[:space:]]*#/) continue
        if (line !~ /(^|[;&|()[:space:]])env[[:space:]]/) continue
        if (line ~ pat && line ~ /\\[[:space:]]*$/) { print FILENAME ":" i ": " line }
      }
    }' "$file")
  if [ -n "$hits" ]; then
    offenders=$((offenders+1))
    while IFS= read -r hit; do
      [ -n "$hit" ] && printf '  offending statement: %s\n' "$hit" >&2
    done <<< "$hits"
  fi
done < <(ls scripts/test-*.sh scripts/*.sh 2>/dev/null | sort -u)

if [ "$offenders" -eq 0 ]; then
  ok "no row or harness runs an installer through a line continuation ($scanned file(s) scanned)"
else
  bad "$offenders file(s) run an installer through a line continuation: a stray line above it removes the env prefix (the 09:48Z incident)"
fi

# And the half that makes the rule usable: the shared helper a row should use when it needs many variables.
if grep -q 'wa_installer_run' scripts/lib/scratch-installer.sh 2>/dev/null; then
  ok "scripts/lib/scratch-installer.sh offers wa_installer_run, so a row needs no continuation at all"
else
  bad "scripts/lib/scratch-installer.sh does not offer wa_installer_run"
fi

if [ "$failed" -gt 0 ]; then echo "rows-build-one-environment: FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "rows-build-one-environment ok ($checks checks)"
