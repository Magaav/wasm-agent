#!/usr/bin/env bash
# Execute only the real privilege helper in private fixtures, never install/restart anything.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
awk '/^sentinel_restart\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$ROOT/scripts/deploy.sh" > "$WORK/function.sh"
grep -q 'WA_DEPLOY_SENTINEL_SUDO' "$WORK/function.sh"
INSTALL_DIR="$WORK/install with space"; SENTINEL_NAME=wa-sentinel
mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/$SENTINEL_NAME" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TRACE"
SH
chmod +x "$INSTALL_DIR/$SENTINEL_NAME"
export TRACE="$WORK/effects"
export INSTALL_DIR SENTINEL_NAME
wa_home_dir(){ printf '/private home'; }
uname(){ printf Linux; }
sudo(){
  printf '%s\n' "$@" > "$WORK/sudo-args"
  [ "${DENY:-0}" = 0 ] || return 1
  [ "$1" = -n ] && [ "$2" = env ] && [ "$3" = 'WASM_AGENT_HOME=/private home' ]
  [ "$4" = "WA_INSTALL_DIR=$INSTALL_DIR" ] && [ "$5" = 'WA_SENTINEL_SUPERVISOR=wa-sentinel.service' ]
  [ "$6" = "$INSTALL_DIR/$SENTINEL_NAME" ] && [ "$7" = restart ] && [ "$#" = 7 ]
  "$6" "$7"
}
source "$WORK/function.sh"
WA_DEPLOY_SENTINEL_SUDO=0 sentinel_restart
[ "$(cat "$TRACE")" = restart ] && [ ! -e "$WORK/sudo-args" ]
WA_SENTINEL_SUPERVISOR=wa-sentinel.service WA_DEPLOY_SENTINEL_SUDO=1 sentinel_restart
[ "$(wc -l < "$TRACE")" = 2 ] && [ "$(wc -l < "$WORK/sudo-args")" = 7 ]
DENY=1 WA_SENTINEL_SUPERVISOR=wa-sentinel.service WA_DEPLOY_SENTINEL_SUDO=1 sentinel_restart && exit 1
[ "$(wc -l < "$TRACE")" = 2 ] # no fallback, service state unchanged
WA_DEPLOY_SENTINEL_SUDO=typo sentinel_restart && exit 1
[ "$(wc -l < "$TRACE")" = 2 ]
uname(){ printf MINGW64_NT; }
WA_DEPLOY_SENTINEL_SUDO=1 sentinel_restart && exit 1
[ "$(wc -l < "$TRACE")" = 2 ]
printf 'deploy sentinel sudo ok (5 checks, 0 skipped; private commands only)\n'
