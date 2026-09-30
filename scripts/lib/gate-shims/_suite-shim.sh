#!/bin/sh
# ONE GATE SUITE'S WRAPPER, shared by the `bash`, `node` and `powershell` shims. Measurement only:
# the real program is exec'd with the suite's own argv, environment, stdio and exit code, and one record
# is appended to $GATE_SUITES_JSONL (see scripts/lib/gate-suite.mjs for the shape and the lower-bound
# caveat). The shim knows which program it stands for by its OWN NAME ($0), which is what a PATH lookup
# gives it - not by $1, which is the suite's first argument.
#
# TWO THINGS IT MUST NOT DO, both learned by running it:
#   * `#!/usr/bin/env bash` as the shebang: this directory is FIRST on the gate's PATH, so `env` would
#     find THIS shim again and re-exec it, which nested until the run had to be killed. /bin/sh is an
#     absolute path, so the interpreter cannot be the shim.
#   * `exec node ...` by name: same trap, for the same reason. The real `node` is resolved out of the
#     filtered PATH (the one with this directory removed) and exec'd by absolute path.
set -u
here=$(cd "$(dirname "$0")" && pwd)
name=$(basename "$0")
filtered=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/gate-shims$' | paste -sd: -)
target=$(PATH="$filtered" command -v "$name" 2>/dev/null || true)
runner=$(PATH="$filtered" command -v node 2>/dev/null || true)
if [ -z "$target" ] || [ -z "$runner" ]; then
  echo "gate shim: $name or node is not on PATH outside $here" >&2
  exit 127
fi
# The wrapper is a native `node` process: give it a path that node's own spawn can open (a Git-Bash
# /c/... path is not one, and this shim's call is not the MSYS conversion boundary that would fix it).
if command -v cygpath >/dev/null 2>&1; then
  case "$target" in /*) target=$(cygpath -w "$target") ;; esac
  case "$runner" in /*) runner=$(cygpath -w "$runner") ;; esac
fi
# The suite's label: the first non-option argument is the suite file (*.cjs, *.mjs, *.sh, *.ps1); an
# inline program has no file, so it is named by its first word instead of by its first line.
label=""
prev=""
for arg in "$@"; do
  case "$prev" in
    -File|-CommandWithArgs) label=$(basename "$arg"); break ;;
    -c|-f) label=$(basename "$arg"); break ;;
    -e|--eval|-Command) label=$(printf '%s' "$arg" | awk '{print $1}' | tr -d '\r'); label="inline:${label:-eval}"; break ;;
  esac
  case "$arg" in
    -e|--eval|-Command|-File|-CommandWithArgs|-c|-f) prev="$arg" ;;
    -*) ;;
    '') ;;
    *) label=$(basename "$arg"); break ;;
  esac
  prev="$arg"
done
exec "$runner" "$here/../gate-suite.mjs" --name "${label:-$name}" -- "$target" "$@"
