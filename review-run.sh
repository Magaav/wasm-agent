#!/usr/bin/env bash
set -u
pwd
test "$(git rev-parse --show-toplevel)" = 'C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch01a55e01-2540-41e4-941a-ae7aa565dde9' || exit 99
mkdir -p review-evidence
for c in 2f0a945 81aaba1 3c349af 66296cf; do git show --format=fuller "$c"; done > review-evidence/commits.diff
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 > review-evidence/test-ui.log 2>&1
s=$?; echo "test-ui exit=$s"; cat review-evidence/test-ui.log
