#!/usr/bin/env bash
# Claim 2(a): does bash really drop a simple command's `VAR=value \` prefix when a comment
# line sits inside the continuation - and does the tip's invocation still deliver the
# variables? Run from the repository root:  bash review/deploy-unbound/probe-prefix-loss.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$ROOT" || exit 1

cat > "$W/stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "--- environment upgrade.sh actually received ---"
for v in WA_INSTALL_DIR WA_PORT WA_CLIENT_PORT WA_UPGRADE_REASON WA_UPGRADE_VIA; do
  eval "val=\${$v:-unset}"; echo "  $v=$val"
done
echo "  ARG=$1"
EOF

echo "===== (1) the language rule, on its own ====="
cat > "$W/control.sh" <<EOF
set -uo pipefail
FOO=1 BAR=two \\
  bash -c 'echo "  control: FOO=[\$FOO] BAR=[\$BAR]"'
EOF
cat > "$W/oldshape.sh" <<EOF
set -uo pipefail
FOO=1 BAR=two \\
  # the comment that used to sit between the assignments and the command
  bash -c 'echo "  comment inside the continuation: FOO=[\$FOO] BAR=[\$BAR]"'
EOF
bash "$W/control.sh"; echo "  control exit=$?"
bash "$W/oldshape.sh"; echo "  oldshape exit=$?"

echo "===== (2) the same rule on the REAL invocation, before and after the fix ====="
mkdir -p "$W/install" "$W/tree"; touch "$W/tree/wa"
mk() { # file, block
  { echo 'set -uo pipefail'
    echo "INSTALL_DIR=\"$W/install\""; echo 'PORT="8877"'; echo 'CLIENT_PORT="8878"'
    echo 'REASON="a reason with spaces"'; echo "UPGRADE=\"$W/stub.sh\""; echo "NEW=\"$W/tree/wa\""
    printf '%s\n' "$2"; } > "$1"
}
git show 2f02b4c:scripts/deploy.sh > "$W/deploy-old.sh"
mk "$W/old-invocation.sh" "$(sed -n '432,438p' "$W/deploy-old.sh")"
mk "$W/new-invocation.sh" "$(awk '/^# wa-deploy-upgrade-invocation: begin$/{on=1} on{print} on && /^# wa-deploy-upgrade-invocation: end$/{exit}' scripts/deploy.sh)"
echo "----- the invocation as it was at origin/main 2f02b4c -----"
bash "$W/old-invocation.sh"; cat "$W/install/deploy-upgrade.log"
echo "----- the invocation as it is at the reviewed tip -----"
bash "$W/new-invocation.sh"; cat "$W/install/deploy-upgrade.log"
