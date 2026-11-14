#!/usr/bin/env bash
# The Go WhatsApp connector is gone, and it must not come back (Phase 4, 11/11).
#
# WHY. The operator's 11/11 decision retired Go outright ("i do not want go anymore... we want our own
# mcp"). WhatsApp runs on the `wa-whatsapp` WASI component; the `whatsmeow` connector was a second client
# on the same linked device, and running both races the Signal ratchet. What Phase 4 removed:
# `connectors/whatsapp/` (57 files: Go source, its tests, go.mod/go.sum, a Windows build artifact), the
# three entry points that built/installed/started it (`scripts/whatsapp-build.py`,
# `scripts/build-whatsapp.sh`, `scripts/whatsapp-install.py`) and the tests that drove that binary.
#
# WHAT THIS REFUSES, and why each one is a *path* rather than a mention:
#   * `connectors/whatsapp/`, a `*whatsapp*.go` file, a `go.mod` naming the connector module - the source;
#   * the three entry-point file names - the build, the install, and the `wa-whatsapp.service` unit
#     template the installer wrote, which was this connector's start path;
#   * `whatsmeow`, `GOTOOLCHAIN`, `cd connectors/whatsapp`, `go build|test|run|install ... whatsapp` in
#     code: those exist only to build or run the Go client;
#   * in documentation, the same commands plus `systemctl ... wa-whatsapp` and `go version`: a doc that
#     tells an operator how to build, install or start it is a path even when no file remains.
#
# WHAT IT MUST NOT REFUSE (and therefore does not): the Rust component. `mcp-whatsapp` is the *Rust*
# component's own name, `wa-whatsapp` is the *Rust* WASI component, and both stay. A comment that cites a
# ported source file - `rust/components/wa-whatsapp/src/queue.rs` says "as in
# connectors/whatsapp/audio_queue.go" - is history, not a path, so a bare citation is allowed, and so is
# the Rust component's own `wa-whatsapp.service.log`. The positive checks below fail loudly if an
# over-eager cleanup ever takes the Rust path instead.
#
# The structural scan reads the tree under test ($WA_GO_RETIRED_ROOT, else this script's own tree) and is
# proved on fixtures at the end: a planted Go module, build script, systemctl line and whatsmeow import
# must each be found, or the scan is not a gate.
set -uo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-go-retired-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
checks=0
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
check() { # <name> <condition...>
  local name="$1"; shift
  "$@" || fail "$name"
  checks=$((checks + 1)); printf 'ok - %s\n' "$name"
}

# ---- the marker sets -------------------------------------------------------------------------------
# Code: a string that can only be there to build, install or start the Go client.
# `go.mau.fi/whatsmeow` is the Go client's import path; the SQLite table `whatsmeow_device` that the
# read-only adoption exporter reads is data, not a path, so it is deliberately not a marker. The
# `go <verb>` forms carry a leading non-word guard because `cargo build` contains "go build".
CODE_MARKERS='whatsapp-install\.py|whatsapp-build\.py|build-whatsapp\.sh|go\.mau\.fi/whatsmeow|GOTOOLCHAIN|wa-whatsapp\.service([^.]|$)|cd[[:space:]]+connectors/whatsapp|(^|[^[:alnum:]_.-])go[[:space:]]+(build|test|run|install)[[:space:]][^|]*whatsapp'
# Docs: the same as a command line, plus the unit and the SDK-binding variables. A prose citation of
# `connectors/whatsapp/operator.go` is allowed; a command that would run it is not.
# A doc is a path when it gives the command, not when it mentions the setting in prose: a historical
# receipt that says the build ran with "GOTOOLCHAIN local" is evidence, while `export GOTOOLCHAIN=local`
# is an instruction to rebuild the Go client.
# A doc may still NAME the unit to remove it (the operator's cleanup does), so the unit name alone is not
# a marker here; starting or enabling it is. `is-enabled` is a check and does not match.
DOC_MARKERS='whatsapp-install\.py|whatsapp-build\.py|build-whatsapp\.sh|GOTOOLCHAIN=|(^|[^[:alnum:]_.-])go[[:space:]]+(build|test|run|install|version)([[:space:]]|$)|systemctl[^|]*(start|enable)[[:space:]][^|]*wa-whatsapp|systemctl[^|]*wa-whatsapp[^|]*(start|enable)[[:space:]]'
CODE_PATHS=(scripts lua rust jobs config policies deploy ui components.lock package.json lane-policy.json)
DOC_PATHS=(docs skills README.md ARCHITECTURE.md DESIGN.md AGENTS.md ROADMAP.md)

scan() { # <root> <regex> <path...> -- one "<path>:<line>:<text>" per hit, paths relative to the root
  local root="$1" pattern="$2"; shift 2
  local path
  for path in "$@"; do
    [ -e "$root/$path" ] || continue
    grep -rInE --binary-files=without-match \
      --exclude-dir=.git --exclude-dir=target --exclude-dir=node_modules --exclude-dir=build \
      --exclude=test-whatsapp-go-retired.sh \
      "$pattern" "$root/$path" 2>/dev/null | sed "s|^$root/||"
  done
  return 0
}

source_findings() { # <root> -- the Go module directory, a whatsapp*.go file, a go.mod naming it
  local root="$1"
  [ -d "$root/connectors/whatsapp" ] && printf 'connectors/whatsapp/: the Go module directory is back\n'
  find "$root" -path "$root/.git" -prune -o -type f -name '*.go' -print 2>/dev/null \
    | grep -i whatsapp | sed 's|^|Go source: |'
  find "$root" -path "$root/.git" -prune -o -type f -name 'go.mod' -print 2>/dev/null \
    | xargs -r grep -Il 'connectors/whatsapp' 2>/dev/null | sed 's|^|go.mod naming the connector: |'
  return 0
}

code_findings() { local root="$1"; source_findings "$root"; scan "$root" "$CODE_MARKERS" "${CODE_PATHS[@]}"; }
doc_findings() { scan "$1" "$DOC_MARKERS" "${DOC_PATHS[@]}"; }

quiet() { # <name> <producer> <root> -- the producer prints nothing
  local out
  out="$("$2" "$3")"
  [ -z "$out" ] || { printf '%s\n' "$out" >&2; return 1; }
}

runs() { # <root> <finder: code_findings|doc_findings> <needle> -- the finder reports the needle
  "$2" "$1" | grep -qF -- "$3"
}

silent() { # <root> <finder> -- the finder reports nothing at all
  [ -z "$("$2" "$1")" ]
}

# ---- the tree under test ---------------------------------------------------------------------------
ROOT="${WA_GO_RETIRED_ROOT:-$HERE}"
[ -d "$ROOT" ] || fail "the tree under test does not exist: $ROOT"

check 'no Go WhatsApp source file and no go.mod naming the connector' silent "$ROOT" source_findings
check 'no code that builds, installs or starts the Go client' silent "$ROOT" code_findings
check 'no doc that gives a command to build, install or start it' silent "$ROOT" doc_findings
for gone in scripts/whatsapp-build.py scripts/build-whatsapp.sh scripts/whatsapp-install.py; do
  check "removed: $gone" test ! -e "$ROOT/$gone"
done

# ---- the Rust path it must never have taken with it -------------------------------------------------
rust_path() { # <root>
  local root="$1" missing=0 entry
  for entry in \
    rust/components/wa-whatsapp/Cargo.toml rust/components/wa-whatsapp/manifest.json \
    rust/components/mcp-whatsapp/Cargo.toml rust/components/mcp-whatsapp/manifest.json \
    rust/wa-whatsapp-index/src/lib.rs rust/wa-whatsapp-outbox/src/lib.rs \
    scripts/whatsapp-stt-local.py scripts/whatsapp-ocr-local.py \
    scripts/whatsapp-connector-http.mjs scripts/whatsapp-readiness.mjs \
    stt/python-stt-dependency.json stt/python-stt-linux-arm64.requirements.txt \
    docs/WHATSAPP-OPERATOR-MANAGEMENT.md; do
    [ -e "$root/$entry" ] || { printf 'missing, and the Rust path needs it: %s\n' "$entry"; missing=1; }
  done
  grep -q '^wa-whatsapp ' "$root/components.lock" 2>/dev/null \
    || { printf 'missing: the wa-whatsapp pin in components.lock\n'; missing=1; }
  grep -q '"wa-whatsapp"' "$root/policies/default.json" 2>/dev/null \
    || { printf 'missing: the wa-whatsapp rule in policies/default.json\n'; missing=1; }
  return "$missing"
}
check 'the Rust component, its MCP, the workers, the connector client and their pins all survive' rust_path "$ROOT"

# ---- the scan is a gate: it finds each path on a fixture that has one ------------------------------
FIX="$WORK/fixture"
mkdir -p "$FIX/connectors/whatsapp" "$FIX/scripts" "$FIX/docs" "$FIX/lua"
printf 'module github.com/Magaav/wasm-agent/connectors/whatsapp\n' > "$FIX/connectors/whatsapp/go.mod"
printf 'package main\n' > "$FIX/connectors/whatsapp/main.go"
check 'proof: a planted Go module is found' runs "$FIX" source_findings 'the Go module directory is back'
check 'proof: a planted connector go.mod is found' runs "$FIX" source_findings 'go.mod naming the connector'
rm -rf "$FIX/connectors"
printf 'import "go.mau.fi/whatsmeow"\n' > "$FIX/scripts/whatsapp-thing.go"
check 'proof: a planted whatsmeow import is found' runs "$FIX" code_findings 'whatsmeow'
check 'proof: a planted whatsapp*.go file is found' runs "$FIX" source_findings 'Go source: '
printf '#!/bin/sh\npython3 scripts/whatsapp-install.py --apply\n' > "$FIX/scripts/deploy-whatsapp.sh"
check 'proof: a planted installer call is found' runs "$FIX" code_findings 'whatsapp-install.py'
rm -f "$FIX/scripts"/*.go "$FIX/scripts"/*.sh
printf 'systemctl --user enable --now wa-whatsapp.service\n' > "$FIX/docs/RUN.md"
check 'proof: a planted systemctl line is found in a doc' runs "$FIX" doc_findings 'wa-whatsapp.service'
printf 'GOTOOLCHAIN=local go build -o conn.exe .\n' > "$FIX/docs/BUILD.md"
check 'proof: a planted Go build line is found in a doc' runs "$FIX" doc_findings 'GOTOOLCHAIN'
rm -f "$FIX/docs"/*.md
printf 'systemctl --user start wa-whatsapp\n' > "$FIX/docs/OTRO.md"
check 'proof: a planted systemctl start line is found in a doc' runs "$FIX" doc_findings 'systemctl --user start wa-whatsapp'
rm -f "$FIX/docs"/*.md
printf 'systemctl --user disable --now wa-whatsapp.service\nrm -rf "$HOME/.local/lib/wa-whatsapp"\n' > "$FIX/docs/CLEANUP.md"
check 'proof: a removal of the unit and its files is not refused' silent "$FIX" doc_findings
rm -f "$FIX/docs"/*.md
printf -- '-- Ported from the Go connector (connectors/whatsapp/operator.go).\n' > "$FIX/lua/port.lua"
printf -- 'The component log was wa-whatsapp.service.log in the release.\n' > "$FIX/docs/NOTE.md"
printf 'wa-whatsapp 3568b2d5a8260c9021902679fb8758e7f5f281e92af26efbcdf3262e11947760 8554548\n' > "$FIX/components.lock"
check 'proof: a port citation is not refused' silent "$FIX" code_findings
check 'proof: the Rust component log name is not refused' silent "$FIX" doc_findings

printf '%d checks passed: no Go WhatsApp build or start path, the Rust path intact\n' "$checks"
