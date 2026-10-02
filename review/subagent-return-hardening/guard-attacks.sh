#!/usr/bin/env bash
# The drift-guard attack set of review/subagent-return-hardening/VERDICT.md, sections 1-3.
#
#   bash review/subagent-return-hardening/guard-attacks.sh [/path/to/a68dfed-clone]
#
# Runs in a copy of the reviewed tree (default: this repository) and never writes to it beyond a
# scratch directory under the OS temp dir. Every case prints GREEN(exit 0) or RED(exit n) plus the
# first line the guard said about it, so a hole (GREEN on a case that should be red) is visible.
set -u
TREE="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK="$(mktemp -d)"
cd "$TREE" || exit 4

report() { if [ "$2" -eq 0 ]; then echo "GREEN(exit 0) :: $1"; else echo "RED(exit $2) :: $1"; fi; }

mutate_manifest() { # kind entry out
  node -e 'const fs=require("fs");const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));m[process.argv[3]]=m[process.argv[3]].filter(e=>e!==process.argv[4]);fs.writeFileSync(process.argv[2],JSON.stringify(m));' \
    scripts/deploy-shipped.json "$3" "$1" "$2"
}

echo "=== baseline ==="
node scripts/check-deploy-shipped.mjs >/dev/null 2>&1; report "the reviewed tree as delivered" $?

echo "=== A. manifest holes (each must be RED) ==="
for spec in directories:jobs/ globs:scripts/whatsapp-* globs:scripts/subagent-return-* files:scripts/upgrade.sh directories:deploy/; do
  kind="${spec%%:*}"; entry="${spec#*:}"
  mutate_manifest "$kind" "$entry" "$WORK/m.json"
  err=$(node scripts/check-deploy-shipped.mjs "$WORK/m.json" 2>&1); code=$?
  report "manifest drops $kind=$entry" $code
  printf '    %s\n' "$(printf '%s\n' "$err" | grep FAIL | head -1)"
done

echo "=== B. installer copy forms (each must be RED) ==="
run_copy() { # label line
  local dir="$WORK/inst"; rm -rf "$dir"; mkdir -p "$dir"
  cp scripts/deploy.sh scripts/upgrade.sh "$dir"/
  printf '\n%s\n' "$2" >> "$dir/deploy.sh"
  local err; err=$(node scripts/check-deploy-shipped.mjs --installers "$dir" 2>&1); local code=$?
  report "$1" $code
  printf '    %s\n' "$(printf '%s\n' "$err" | grep -E 'FAIL|^deploy shipped ok' | head -1)"
}
run_copy "plain cp"          'cp "$ROOT/scripts/gate-lane.mjs" "$INSTALL_DIR/scripts/"'
run_copy "install -m"        'install -m 644 "$ROOT/scripts/check-naming.sh" "$INSTALL_DIR/scripts/"'
run_copy "mv"                'mv "$ROOT/scripts/gate-lane.mjs" "$INSTALL_DIR/scripts/"'
run_copy 'quote-then-slash'  'cp -f "$ROOT"/scripts/gate-lane.mjs "$INSTALL_DIR/scripts/"'
run_copy 'plain $ROOT/'      'cp -f $ROOT/scripts/gate-lane.mjs "$INSTALL_DIR/scripts/"'
run_copy "continuation cp"   'cp -f \
  "$ROOT/scripts/gate-lane.mjs" \
  "$INSTALL_DIR/scripts/"'
run_copy "path behind a variable" 'SHIP="$ROOT/scripts/gate-lane.mjs"
cp -f "$SHIP" "$INSTALL_DIR/scripts/"'
run_copy 'braced ${ROOT}'    'cp -f "${ROOT}/scripts/gate-lane.mjs" "$INSTALL_DIR/scripts/"'

echo "=== C. build derivation (each must be RED) ==="
dir="$WORK/nobuild"; rm -rf "$dir"; mkdir -p "$dir"; cp scripts/deploy.sh scripts/upgrade.sh "$dir"/
node -e 'const fs=require("fs"),p=process.argv[1];const t=fs.readFileSync(p,"utf8");const b="cargo build --manifest-path \"$ROOT/rust/plugins/whatsapp-transcript/Cargo.toml\"";if(!t.includes(b)){console.error("anchor missing");process.exit(9)}fs.writeFileSync(p,t.replace(b,"true # was: "+b));' "$dir/deploy.sh" || exit 9
err=$(node scripts/check-deploy-shipped.mjs --installers "$dir" 2>&1); report "commented-out cargo build" $?
printf '    %s\n' "$(printf '%s\n' "$err" | grep FAIL | head -1)"

dir="$WORK/foreign"; rm -rf "$dir"; mkdir -p "$dir"; cp scripts/deploy.sh scripts/upgrade.sh "$dir"/
printf '\n  cp -f "$ROOT/rust/plugins/nobody-builds-this/target/release/ghost.wasm" "$INSTALL_DIR/plugins/"\n' >> "$dir/deploy.sh"
err=$(node scripts/check-deploy-shipped.mjs --installers "$dir" 2>&1); report "target/ nobody builds" $?
printf '    %s\n' "$(printf '%s\n' "$err" | grep FAIL | head -1)"

dir="$WORK/crosscrate"; rm -rf "$dir"; mkdir -p "$dir"; cp scripts/deploy.sh scripts/upgrade.sh "$dir"/
printf '\n  cp -f "$ROOT/rust/only-upgrade-builds/target/release/thing.bin" "$INSTALL_DIR/"\n' >> "$dir/deploy.sh"
printf '\n  cargo build --manifest-path "$SOURCE_ROOT/rust/only-upgrade-builds/Cargo.toml" --release --offline >/dev/null\n' >> "$dir/upgrade.sh"
err=$(node scripts/check-deploy-shipped.mjs --installers "$dir" 2>&1); report "target/ from a crate only the OTHER installer builds (should be RED, is the hole)" $?

echo "=== D. legitimate trees (each must be GREEN) ==="
dir="$WORK/braced"; rm -rf "$dir"; mkdir -p "$dir"; cp scripts/deploy.sh scripts/upgrade.sh "$dir"/
node -e 'const fs=require("fs"),p=process.argv[1];const t=fs.readFileSync(p,"utf8");const a="for skill_source in \"$SOURCE_ROOT\"/skills/*; do";if(!t.includes(a)){console.error("anchor missing");process.exit(9)}fs.writeFileSync(p,t.replace(a,"for skill_source in \"${SOURCE_ROOT}\"/skills/*; do"));' "$dir/upgrade.sh" || exit 9
err=$(node scripts/check-deploy-shipped.mjs --installers "$dir" 2>&1); report 'braced ${SOURCE_ROOT} in the skills loop' $?
printf '    %s\n' "$(printf '%s\n' "$err" | grep -E 'FAIL|^deploy shipped ok' | head -1)"

dir="$WORK/selfinstall"; rm -rf "$dir"; mkdir -p "$dir"; cp scripts/deploy.sh scripts/upgrade.sh "$dir"/
node -e 'const fs=require("fs"),p=process.argv[1];const t=fs.readFileSync(p,"utf8");const a="cp -f \"$0\" \"$INSTALL_DIR/scripts/upgrade.sh.new.$$\"",b="install -m 755 \"$0\" \"$INSTALL_DIR/scripts/upgrade.sh.new.$$\" ";if(!t.includes(a)){console.error("anchor missing");process.exit(9)}fs.writeFileSync(p,t.replace(a,b));' "$dir/upgrade.sh" || exit 9
err=$(node scripts/check-deploy-shipped.mjs --installers "$dir" 2>&1); report 'install -m instead of cp -f for upgrade.sh itself' $?
printf '    %s\n' "$(printf '%s\n' "$err" | grep -E 'FAIL|^deploy shipped ok' | head -1)"

run_copy "a commented-out copy (must not be read)" '# cp -f "$ROOT/scripts/ghost.mjs" "$INSTALL_DIR/scripts/"'
run_copy "prose inside a string that names install + a path (must not be read)" 'say "please install $ROOT/scripts/build-release.mjs by hand"'

rm -rf "$WORK"
