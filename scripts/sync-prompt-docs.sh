#!/usr/bin/env bash
# Check (default) or rewrite (--write) the generated prompt-doc blocks from the live Lua source.
# The generator is scripts/sync-prompt-docs.lua; it runs inside the wa binary with this checkout as
# the Lua root, so it reads the code being committed, not the copy embedded in the binary.
#
# The binary: $WA_BIN, else `wa` on PATH, else ~/.local/bin/wa, else this checkout's release build,
# else the `wa` installed in the sandbox container's home volume, run through Docker
# (WA_DOCKER_IMAGE, default wasm-agent-sandbox:local; WA_DOCKER_HOME_VOLUME, default
# wasm-agent-sandbox_agent-home; DOCKER_HOST defaults to the rootless socket when it exists).
# Exit 0 = current (or written), 1 = stale, 2 = no wa binary to run the generator.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode=check
[ "${1:-}" = "--write" ] && mode=write

bin="${WA_BIN:-}"
if [ -z "$bin" ]; then
  for candidate in "$(command -v wa 2>/dev/null || true)" "$HOME/.local/bin/wa" \
      "$root/rust/target/release/wa" "$root/rust/target/release/wa.exe"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then bin="$candidate"; break; fi
  done
fi
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  # Docker fallback: the sandbox's installed wa, with this checkout mounted as the Lua root.
  if [ -z "${DOCKER_HOST:-}" ] && [ -S "/run/user/$(id -u)/docker.sock" ]; then
    export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
  fi
  image="${WA_DOCKER_IMAGE:-wasm-agent-sandbox:local}"
  volume="${WA_DOCKER_HOME_VOLUME:-wasm-agent-sandbox_agent-home}"
  if command -v docker >/dev/null 2>&1 && docker image inspect "$image" >/dev/null 2>&1 \
      && docker volume inspect "$volume" >/dev/null 2>&1; then
    docker run --rm --user 0 -v "$volume":/wa-home:ro -v "$root":/t -w /t --tmpfs /data \
      -e HOME=/data -e WASM_AGENT_LUA_ROOT=/t -e WA_SCRIPT=scripts/sync-prompt-docs.lua \
      -e WA_PROMPT_DOCS_MODE="$mode" --entrypoint /wa-home/.local/bin/wa "$image" --db /data/docs.db
    exit $?
  fi
  echo "sync-prompt-docs: no wa binary found (set WA_BIN, put wa on PATH, build rust/, or provide" >&2
  echo "  the sandbox image $image and volume $volume); generated docs were NOT checked" >&2
  exit 2
fi

db="$(mktemp -d)"
trap 'rm -rf "$db"' EXIT
cd "$root" && WASM_AGENT_LUA_ROOT="$root" WA_SCRIPT=scripts/sync-prompt-docs.lua \
  WA_PROMPT_DOCS_MODE="$mode" "$bin" --db "$db/docs.db"
