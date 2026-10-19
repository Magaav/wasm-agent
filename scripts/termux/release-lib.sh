# The Termux release closure: how one build of this source tree becomes a release
# directory, how that directory is hashed, verified and switched onto the phone.
#
# Sourced by three callers, so there is exactly one implementation of each rule:
#   scripts/install-termux.sh          a fresh install
#   scripts/termux/adopt-existing.sh   the one-time bootstrap of a preview installed
#                                      before `wa update` existed
#   scripts/termux/wa-update.sh        the installed updater (shipped as bin/wa-update,
#                                      which sources its own copy as bin/release-lib.sh)
#   scripts/termux/bootstrap.sh        the one command: clone if needed, then whichever
#                                      of the three above this node actually needs
#
# POSIX sh: the installed copy is read by `sh`, which on Termux is bash, and the same
# functions are read by the bash installer and the bash bootstrap. Nothing here uses
# bash-only syntax on purpose.
#
# What a release directory holds, and nothing else:
#   wa                      the Android-native runtime
#   bin/wa                  the launcher
#   bin/wa-update           this updater, so the next update needs no checkout on the phone
#   bin/release-lib.sh      this file, for the updater above
#   ui/<assets>             the matching UI closure, from the same commit as the runtime
#   LICENSE
#   installed.txt           source_commit, source_remote, previous_commit, build_profile
#                           (which rung of the build ladder produced the runtime), ...
#   installed.sha256        manifest of every file above except itself
#
# Private state is NEVER part of a release: `~/.wasm-agent` is not read, copied or written
# by anything in this file, and it must never appear under a release, a staging area or
# $RL_UPDATE. Both the bootstrap and the updater check for it.

# The UI files the launcher serves and the release claims to carry. Kept as a list, not a
# directory copy, so an unreviewed file cannot ride into a release unnoticed.
RL_UI_ASSETS='index.html style.css app.js components.js render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png'

rl_fail() { printf 'termux-update: %s\n' "$*" >&2; exit 1; }
rl_note() { printf '%s\n' "$*"; }
rl_warn() { printf 'termux-update: %s\n' "$*" >&2; }

# Resolve every path from PREFIX (and the documented overrides), once.
rl_paths() {
  RL_PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
  RL_INSTALL=${WA_TERMUX_INSTALL:-$RL_PREFIX/opt/wasm-agent-preview}
  RL_BASE=$(dirname "$RL_INSTALL")
  RL_RELEASES=${WA_TERMUX_RELEASES:-$RL_BASE/wasm-agent-releases}
  RL_UPDATE=${WA_TERMUX_UPDATE_DIR:-$RL_BASE/wasm-agent-update}
}

# Print the value of one `key=value` line, or nothing. Missing files are not an error:
# every caller asks "is this fact recorded?" and a refusal is the caller's decision.
rl_get() { # <file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

rl_sha256() { sha256sum "$1" | cut -d' ' -f1; }

# The manifest is the file list and hashes of a release, sorted for stability. It is what
# makes "the installed release is unmodified" and "the candidate is exactly the built
# closure" checkable at all: without it a switcher compares a path, not bytes.
rl_manifest() { # <release_dir> <outfile>
  _rl_d=$1
  _rl_o=$2
  (
    cd "$_rl_d" || exit 1
    find . -type f ! -name installed.sha256 -print | sed 's|^\./||' | LC_ALL=C sort |
      while IFS= read -r _rl_f; do
        printf '%s  %s\n' "$(sha256sum "$_rl_f" | cut -d' ' -f1)" "$_rl_f"
      done
  ) > "$_rl_o"
}

rl_manifest_verify() { # <release_dir>; 0 when installed.sha256 still describes the tree
  _rl_d=$1
  [ -f "$_rl_d/installed.sha256" ] || return 1
  _rl_t=$(mktemp) || return 1
  if rl_manifest "$_rl_d" "$_rl_t" && cmp -s "$_rl_t" "$_rl_d/installed.sha256"; then
    rm -f "$_rl_t"
    return 0
  fi
  rm -f "$_rl_t"
  return 1
}

# The ELF machine of a candidate, read from the file header. Termux has no `file`, and a
# build that produced the wrong architecture must be refused before it is switched in -
# not discovered when the launcher execs it.
rl_elf_abi() { # <file>
  if [ ! -f "$1" ]; then printf 'missing'; return 0; fi
  _rl_magic=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
  if [ "$_rl_magic" != 7f454c46 ]; then printf 'not-elf'; return 0; fi
  _rl_m=$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')
  case "$_rl_m" in
    b700) printf 'aarch64' ;;
    3e00) printf 'x86-64' ;;
    0300) printf 'x86' ;;
    2800) printf 'arm' ;;
    *) printf 'unknown-%s' "$_rl_m" ;;
  esac
}

rl_write_installed() { # <dest_file> <commit> <remote> <previous_sha|-> <installed_by> [build_profile]
  {
    printf 'source_commit=%s\n' "$2"
    printf 'source_remote=%s\n' "$3"
    printf 'installed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'previous_commit=%s\n' "${4:--}"
    printf 'installed_by=%s\n' "$5"
    printf 'source_provenance=source-built-termux\n'
    # Which rung of the build ladder produced the runtime that is in this release: a phone
    # whose optimized build would not finish ends up running the debug/unoptimized one, and
    # that has to be readable later (`wa doctor` reads exactly this line). Absent in a
    # release from before this line existed, which is not an error.
    if [ -n "${6:-}" ]; then printf 'build_profile=%s\n' "$6"; fi
  } > "$1"
}

# ---------------------------------------------------------------------------
# Building the runtime, on a phone
#
# A phone is not a CI runner, and that is the whole reason this section is not two lines.
# Several rustc processes at once, on a device that is also running Android, Termux and
# the UI, is more memory than the device can give. The observed failure on the operator's
# device was rustc killed by a signal - `signal: 11, SIGSEGV`, reported by cargo as
# `process didn't exit successfully` - which is a crash, not a Rust diagnostic and not a
# build error. The crate rustc died on, both times, was the Wasmtime engine
# `cranelift_codegen`, and the device reported ~2.7 GB available on 8 cores with a swap
# file already half used.
#
# So the levers are the ones that decide how many rustc processes exist at once and how
# much memory ONE of them holds, and each one below is kept or dropped for a stated reason:
#   CARGO_BUILD_JOBS=1     one rustc at a time: peak memory stops scaling with the core
#                          count. On a device this size, eight concurrent rustc processes
#                          are the largest single claim on memory in the build, and this is
#                          the one lever worth paying build time for. Every rung sets it.
#   (no RUSTFLAGS)         `-C codegen-units=1` is deliberately NOT set any more. It puts a
#                          whole crate into ONE LLVM codegen unit, which *raises* peak
#                          memory inside that rustc - the opposite of what a memory-starved
#                          compiler needs - and the crashing build was already running it.
#                          Default codegen units let LLVM split a crate the size of
#                          cranelift_codegen into several units, each finished and released
#                          in turn. Slower in wall-clock terms is the accepted cost.
#   RUST_MIN_STACK=33554432  32 MiB per compiler thread against the 8 MiB default, from the
#                          second rung on. A SIGSEGV is as much the signature of a
#                          guard-page stack overflow as of a wild pointer, and rustc's
#                          query, trait-layout and const-eval recursion is legitimately deep
#                          in exactly the crates that die here; a raised stack is the only
#                          knob that addresses that shape. It costs address space, not
#                          resident memory - thread stacks are mapped lazily and an
#                          untouched page is never committed - so on a memory-starved device
#                          it is close to free. It is a hypothesis about this crash and not a
#                          claim about its cause; the third rung tests the other hypothesis
#                          (optimizer and codegen work) directly.
#   CARGO_INCREMENTAL=0    the third rung only, where it does something. A `--release` build
#                          already has incremental off (cargo's default), so setting it
#                          there would be a knob kept for the look of caution; the `dev`
#                          profile turns incremental ON, and on a fresh build there is
#                          nothing to reuse and a cache of compiler state to hold and write.
#
# The ladder. A memory-starved compiler gets three chances, and the third is a way through
# rather than another mitigation:
#   attempt 1  profile default       one job; everything else cargo's own default
#   attempt 2  profile conservative  one job, 32 MiB compiler stack
#   attempt 3  profile debug         `cargo build --profile dev`, one job, no incremental
# A debug build does the type checking and borrow checking but almost none of the optimizer
# work, so it can build a crate that `--release` cannot, and an unoptimized runtime that
# starts is a better outcome on a phone than no install at all. It is slower at runtime, and
# it IS the installed runtime: the rung that succeeds decides which binary is installed, and
# installed.txt records which rung it was.
#
# Authorship of a setting. An explicit operator setting always wins and is never overridden,
# and the origin of every value is recorded: a build that silently ignores CARGO_BUILD_JOBS=4
# is a build nobody can explain afterwards. The origin is captured BEFORE any rung runs,
# because after rung 1 this script's own export is indistinguishable from an operator's value
# by inspection alone - which is exactly what this file used to misreport as "yours, kept".
#
# A host that is not a phone is untouched: there the ladder is one rung, with the host's own
# defaults and no profile variables at all. WA_TERMUX_BUILD_PROFILE=default|conservative|
# debug forces one rung on any host - which is how the fixture suite drives a phone rung off
# a phone - and WA_TERMUX_TEST=1 (the fixture suite saying "pretend this is the phone")
# selects the whole three-rung ladder. That is announced, never silent.
RL_BUILD_JOBS=1
RL_BUILD_MIN_STACK=33554432
RL_BUILD_INCREMENTAL_DEBUG=0
RL_BUILD_LADDER_PHONE='default conservative debug'

# Android/Termux, detected the way the installers already guard on it.
rl_build_host_is_android() {
  [ "${PREFIX:-}" = /data/data/com.termux/files/usr ] || return 1
  [ "$(uname -o 2>/dev/null || true)" = Android ] || return 1
  return 0
}

# Is the phone build path in play: the device itself, or the fixture suite standing in for
# it. RL_BUILD_TEST_HOST records the second case so the caller can announce it.
rl_build_on_phone() {
  RL_BUILD_TEST_HOST=0
  if rl_build_host_is_android; then return 0; fi
  [ "${WA_TERMUX_TEST:-0}" = 1 ] || return 1
  RL_BUILD_TEST_HOST=1
  return 0
}

# The rungs this build will try, in order. Sets RL_BUILD_LADDER, RL_BUILD_PHONE_KNOBS (the
# rungs' knobs are in play), RL_BUILD_LADDER_FORCED and RL_BUILD_PROFILE (the first rung,
# descriptive until one is applied). Refuses by name on an unknown WA_TERMUX_BUILD_PROFILE
# value - here, and not in a command substitution, where `exit 1` would only end the subshell
# and leave the caller building with no profile chosen at all.
rl_build_ladder() {
  RL_BUILD_LADDER_FORCED=0
  RL_BUILD_PHONE_KNOBS=0
  case "${WA_TERMUX_BUILD_PROFILE:-}" in
    default|conservative|debug)
      RL_BUILD_LADDER=$WA_TERMUX_BUILD_PROFILE
      RL_BUILD_LADDER_FORCED=1
      RL_BUILD_PHONE_KNOBS=1
      ;;
    '')
      if rl_build_on_phone; then
        RL_BUILD_LADDER=$RL_BUILD_LADDER_PHONE
        RL_BUILD_PHONE_KNOBS=1
      else
        RL_BUILD_LADDER=default
      fi
      ;;
    *)
      rl_fail "build_profile_unknown: WA_TERMUX_BUILD_PROFILE=$WA_TERMUX_BUILD_PROFILE (use 'default', 'conservative' or 'debug')"
      ;;
  esac
  RL_BUILD_PROFILE=${RL_BUILD_LADDER%% *}
}

rl_build_rung_count() {
  _rl_n=0
  for _rl_r in $RL_BUILD_LADDER; do _rl_n=$((_rl_n + 1)); done
  printf '%s' "$_rl_n"
}

# The operator's own settings, captured ONCE and before any rung can change the environment.
# This is the fix for the misreport: after rung 1 exported CARGO_BUILD_JOBS=1, the next rung
# found a value in the environment and called it the operator's.
rl_build_capture_operator_knobs() {
  RL_BUILD_OP_JOBS=
  RL_BUILD_OP_STACK=
  RL_BUILD_OP_FLAGS=
  RL_BUILD_OP_INCREMENTAL=
  if [ -n "${CARGO_BUILD_JOBS:-}" ]; then RL_BUILD_OP_JOBS=$CARGO_BUILD_JOBS; fi
  if [ -n "${RUST_MIN_STACK:-}" ]; then RL_BUILD_OP_STACK=$RUST_MIN_STACK; fi
  if [ -n "${RUSTFLAGS:-}" ]; then RL_BUILD_OP_FLAGS=$RUSTFLAGS; fi
  if [ -n "${CARGO_INCREMENTAL:-}" ]; then RL_BUILD_OP_INCREMENTAL=$CARGO_INCREMENTAL; fi
  RL_BUILD_OPERATOR_LINES=
  if [ -n "$RL_BUILD_OP_JOBS" ]; then
    RL_BUILD_OPERATOR_LINES="CARGO_BUILD_JOBS=$RL_BUILD_OP_JOBS"
  fi
  if [ -n "$RL_BUILD_OP_STACK" ]; then
    RL_BUILD_OPERATOR_LINES="${RL_BUILD_OPERATOR_LINES}${RL_BUILD_OPERATOR_LINES:+
}RUST_MIN_STACK=$RL_BUILD_OP_STACK"
  fi
  if [ -n "$RL_BUILD_OP_FLAGS" ]; then
    RL_BUILD_OPERATOR_LINES="${RL_BUILD_OPERATOR_LINES}${RL_BUILD_OPERATOR_LINES:+
}RUSTFLAGS='$RL_BUILD_OP_FLAGS'"
  fi
  if [ -n "$RL_BUILD_OP_INCREMENTAL" ]; then
    RL_BUILD_OPERATOR_LINES="${RL_BUILD_OPERATOR_LINES}${RL_BUILD_OPERATOR_LINES:+
}CARGO_INCREMENTAL=$RL_BUILD_OP_INCREMENTAL"
  fi
}

rl_build_operator_value() { # <NAME>; empty when the operator did not set it
  case "$1" in
    CARGO_BUILD_JOBS) printf '%s' "$RL_BUILD_OP_JOBS" ;;
    RUST_MIN_STACK) printf '%s' "$RL_BUILD_OP_STACK" ;;
    RUSTFLAGS) printf '%s' "$RL_BUILD_OP_FLAGS" ;;
    CARGO_INCREMENTAL) printf '%s' "$RL_BUILD_OP_INCREMENTAL" ;;
  esac
}

rl_build_knob_value() { # <NAME>; what this environment holds right now
  case "$1" in
    CARGO_BUILD_JOBS) printf '%s' "${CARGO_BUILD_JOBS:-}" ;;
    RUST_MIN_STACK) printf '%s' "${RUST_MIN_STACK:-}" ;;
    RUSTFLAGS) printf '%s' "${RUSTFLAGS:-}" ;;
    CARGO_INCREMENTAL) printf '%s' "${CARGO_INCREMENTAL:-}" ;;
  esac
}

rl_build_knob_set() { # <NAME> <value>; only ever called with this script's own values
  case "$1" in
    CARGO_BUILD_JOBS) CARGO_BUILD_JOBS=$2; export CARGO_BUILD_JOBS ;;
    RUST_MIN_STACK) RUST_MIN_STACK=$2; export RUST_MIN_STACK ;;
    RUSTFLAGS) RUSTFLAGS=$2; export RUSTFLAGS ;;
    CARGO_INCREMENTAL) CARGO_INCREMENTAL=$2; export CARGO_INCREMENTAL ;;
  esac
}

rl_build_desc_add() { # <line>
  if [ -n "$RL_BUILD_PROFILE_DESC" ]; then
    RL_BUILD_PROFILE_DESC="$RL_BUILD_PROFILE_DESC
$1"
  else
    RL_BUILD_PROFILE_DESC=$1
  fi
}

# One knob for one rung. A value the operator set is kept and labelled theirs; this script's
# own value is labelled as this script's, for the rung that set it. Nothing is ever
# overridden without saying so.
rl_build_knob() { # <NAME> <script_value> <rung>
  _rl_name=$1
  _rl_current=$(rl_build_knob_value "$_rl_name")
  if [ -n "$_rl_current" ]; then
    if [ -n "$(rl_build_operator_value "$_rl_name")" ]; then
      rl_build_desc_add "$_rl_name=$_rl_current (yours, kept)"
    else
      rl_build_desc_add "$_rl_name=$_rl_current (this script, rung $3)"
    fi
    return 0
  fi
  rl_build_knob_set "$_rl_name" "$2"
  rl_build_desc_add "$_rl_name=$2 (this script, rung $3)"
}

# Apply one rung to the environment the compiler will inherit: records exactly what was
# applied in RL_BUILD_PROFILE_DESC (one knob per line) and which cargo profile the rung
# builds with in RL_BUILD_CARGO_MODE. Never on stdout: rl_build_wa's stdout is the built
# binary path, because every caller reads it with $(...).
rl_build_apply_profile() { # <default|conservative|debug>
  RL_BUILD_PROFILE=$1
  RL_BUILD_PROFILE_DESC=
  RL_BUILD_CARGO_MODE=release
  if [ "$1" = debug ]; then RL_BUILD_CARGO_MODE=dev; fi
  if [ "${RL_BUILD_PHONE_KNOBS:-0}" != 1 ]; then
    # Not a phone: the host's own defaults, and not one variable of ours in the environment.
    RL_BUILD_PROFILE_DESC='unchanged (host defaults)'
    return 0
  fi
  rl_build_knob CARGO_BUILD_JOBS "$RL_BUILD_JOBS" "$1"
  case "$1" in
    conservative|debug) rl_build_knob RUST_MIN_STACK "$RL_BUILD_MIN_STACK" "$1" ;;
  esac
  if [ "$1" = debug ]; then
    rl_build_knob CARGO_INCREMENTAL "$RL_BUILD_INCREMENTAL_DEBUG" "$1"
  fi
}

# Which rung produced a built binary, for the release record. The rung that succeeds decides
# the target subdirectory cargo wrote to, so the path says which one it was.
rl_build_profile_of_bin() { # <binary path>
  case "$1" in
    */target/debug/*) printf 'dev' ;;
    *) printf 'release' ;;
  esac
}

# The one cargo invocation this file makes, for one rung. The lockfile is fixed (`--locked`)
# and it is the same invocation as the installer's, so a release is the tree, not the tree
# plus whatever resolution felt like that day. `dev` is the debug rung: cargo's `dev`
# profile, which does almost none of the optimizer and codegen work that `--release` does.
rl_build_cargo() { # <src_root> <release|dev>
  if [ "$2" = dev ]; then
    if [ "${WA_TERMUX_OFFLINE:-0}" = 1 ]; then
      "$_rl_cargo" build --profile dev --locked --offline --manifest-path "$1/rust/Cargo.toml"
    else
      "$_rl_cargo" build --profile dev --locked --manifest-path "$1/rust/Cargo.toml"
    fi
  elif [ "${WA_TERMUX_OFFLINE:-0}" = 1 ]; then
    "$_rl_cargo" build --release --locked --offline --manifest-path "$1/rust/Cargo.toml"
  else
    "$_rl_cargo" build --release --locked --manifest-path "$1/rust/Cargo.toml"
  fi
}

# One attempt, showing the output live and keeping it for the crash check. POSIX sh has no
# pipefail, so the status of a pipeline is tee's status and not the build's: the subshell
# that ran cargo writes the real status to a file instead. Each subshell ends in `:`, so a
# tee that dies (a closed stderr) cannot abort the caller under `set -e`.
rl_build_run() { # <src_root> <logfile>; sets RL_BUILD_RC
  _rl_status=$(mktemp) 2>/dev/null || rl_fail 'build_log_failed: cannot create a temporary status file'
  if command -v tee >/dev/null 2>&1; then
    ( set +e
      ( rl_build_cargo "$1" "$RL_BUILD_CARGO_MODE" 2>&1; printf '%s\n' "$?" > "$_rl_status" ) | tee "$2" >&2
      : )
  else
    # No tee: the log is still written and the live output is lost. A phone without
    # coreutils is unusual, and losing the live output beats losing the crash record.
    ( set +e
      rl_build_cargo "$1" "$RL_BUILD_CARGO_MODE" > "$2" 2>&1
      printf '%s\n' "$?" > "$_rl_status"
      : )
    cat "$2" >&2
  fi
  RL_BUILD_RC=$(cat "$_rl_status" 2>/dev/null || true)
  rm -f -- "$_rl_status"
  case "$RL_BUILD_RC" in ''|*[!0-9]*) RL_BUILD_RC=1 ;; esac
}

# A build that died because the compiler died. cargo reports that as
#   process didn't exit successfully: `rustc ...` (signal: 11, SIGSEGV)
# with a non-zero (usually 101) status, so these markers are a crash and not a Rust error
# message. Sets RL_BUILD_CRASH_LINE to the first matching line.
rl_build_log_crashed() { # <logfile>
  RL_BUILD_CRASH_LINE=
  [ -f "$1" ] || return 1
  RL_BUILD_CRASH_LINE=$(grep -m 1 -e 'signal: 11' -e 'SIGSEGV' \
    -e "process didn't exit successfully" "$1" 2>/dev/null || true)
  [ -n "$RL_BUILD_CRASH_LINE" ] || return 1
  return 0
}

# Where a retained build log goes. Under $RL_UPDATE, which is already this node's private
# (mode 700) update state, and never inside a release.
rl_build_log_dir() {
  [ -n "${RL_UPDATE:-}" ] || rl_paths
  RL_BUILD_LOG_DIR=${WA_TERMUX_BUILD_LOG_DIR:-$RL_UPDATE/build-logs}
}

# Keep the log of a failed attempt where the operator can find and paste it, and echo where
# it is now. One file per attempt, overwritten by the next build, so it cannot grow on a
# phone; on a successful build no log is written at all. The caller must not delete the
# temporary log afterwards: it has either moved or is the returned path.
rl_build_retain_log() { # <tmp_log> <attempt>
  rl_build_log_dir
  if mkdir -p -- "$RL_BUILD_LOG_DIR" 2>/dev/null; then
    chmod 700 "$RL_BUILD_LOG_DIR" 2>/dev/null || true
    if mv -- "$1" "$RL_BUILD_LOG_DIR/build-attempt$2.log" 2>/dev/null; then
      printf '%s' "$RL_BUILD_LOG_DIR/build-attempt$2.log"
      return 0
    fi
  fi
  rl_warn "build_log_dir_unwritable: could not place the log in $RL_BUILD_LOG_DIR"
  printf '%s' "$1"
}

# The crate a crash log names, if it names one cheaply. On the operator's phone this is the
# line that identified `cranelift_codegen`: cargo prints the rustc command line it ran and
# `crate-name <n>` is on it, and with one job at a time the LAST crate in the log is the one
# rustc was compiling when it died.
rl_build_log_crate() { # <logfile>
  RL_BUILD_CRATE=
  [ -f "$1" ] || return 1
  RL_BUILD_CRATE=$(grep -o 'crate-name [A-Za-z0-9_-]*' "$1" 2>/dev/null | tail -n 1 |
    sed 's/^crate-name //')
  [ -n "$RL_BUILD_CRATE" ] || return 1
  return 0
}

# Print a block of already-formatted lines to stderr, one per line and indented.
rl_build_lines() { # <text> <indent>
  printf '%s\n' "$1" | while IFS= read -r _rl_l; do
    [ -n "$_rl_l" ] || continue
    printf '%s%s\n' "$2" "$_rl_l" >&2
  done
}

# The refusal after the ladder is exhausted: named, with every attempt, every retained log,
# the crate if a log names one, the environment the last attempt ran with and where each value
# in it came from, and the three diagnostics worth pasting. It changes nothing and claims
# nothing.
rl_build_refuse() { # <crashed 0|1> <last_status>
  if [ "$1" = 1 ]; then
    rl_warn 'compiler_crash_build_refused: the compiler crashed on every attempt of the build ladder'
  else
    rl_warn "build_failed_after_a_crash: cargo exited $2 after the compiler had crashed once"
  fi
  rl_warn '  attempts:'
  rl_build_lines "$RL_BUILD_REPORT" 'termux-update:     '
  rl_warn "  environment of the last attempt (profile $RL_BUILD_PROFILE):"
  rl_build_lines "$RL_BUILD_PROFILE_DESC" 'termux-update:     '
  if [ -n "$RL_BUILD_OPERATOR_LINES" ]; then
    rl_warn '  you had set these yourself, and they were kept:'
    rl_build_lines "$RL_BUILD_OPERATOR_LINES" 'termux-update:     '
  else
    rl_warn '  you had set none of these variables yourself, so no value above is yours'
  fi
  rl_warn '  paste these three lines when reporting this:'
  rl_warn '    rustc -V'
  rl_warn '    free -m | head -3'
  rl_warn '    nproc'
  rl_warn '  no release was assembled, switched or installed, and node state was not read or written'
  exit 1
}

# Build the runtime from a source tree, walking the ladder above. Echoes the built binary
# path on stdout and nothing else; `rl_build_profile_of_bin` says which rung produced it.
rl_build_wa() { # <src_root>
  _rl_src=$1
  [ -f "$_rl_src/rust/Cargo.toml" ] || rl_fail "source_checkout_required: $_rl_src/rust/Cargo.toml"
  _rl_cargo=${WA_TERMUX_CARGO:-cargo}
  if ! command -v "$_rl_cargo" >/dev/null 2>&1 && [ ! -x "$_rl_cargo" ]; then
    rl_fail "cargo_required: install rust through Termux (pkg install rust)"
  fi
  rl_build_ladder
  rl_build_capture_operator_knobs
  RL_BUILD_ATTEMPT_TOTAL=$(rl_build_rung_count)
  RL_BUILD_ATTEMPT_COUNT=0
  RL_BUILD_REPORT=
  printf 'termux-update: building with %s... the first build can take several minutes\n' \
    "$_rl_cargo" >&2
  if [ "${RL_BUILD_TEST_HOST:-0}" = 1 ]; then
    printf '%s\n' 'termux-update: WA_TERMUX_TEST=1: this host is not an Android device; driving the phone build ladder (one job at a time) for the fixture suite' >&2
  fi
  if [ "$RL_BUILD_LADDER_FORCED" = 1 ]; then
    printf 'termux-update: build profile forced by WA_TERMUX_BUILD_PROFILE=%s: one attempt, no ladder\n' \
      "$RL_BUILD_LADDER" >&2
  else
    printf 'termux-update: build ladder: %s (%s attempt(s); the last rung installs a debug/unoptimized runtime if it is reached)\n' \
      "$RL_BUILD_LADDER" "$RL_BUILD_ATTEMPT_TOTAL" >&2
  fi
  for _rl_rung in $RL_BUILD_LADDER; do
    RL_BUILD_ATTEMPT_COUNT=$((RL_BUILD_ATTEMPT_COUNT + 1))
    rl_build_apply_profile "$_rl_rung"
    if [ "$RL_BUILD_LADDER_FORCED" = 1 ]; then
      printf 'termux-update: attempt %s/%s, profile %s:\n' \
        "$RL_BUILD_ATTEMPT_COUNT" "$RL_BUILD_ATTEMPT_TOTAL" "$_rl_rung" >&2
    else
      printf 'termux-update: attempt %s/%s of the ladder, profile %s:\n' \
        "$RL_BUILD_ATTEMPT_COUNT" "$RL_BUILD_ATTEMPT_TOTAL" "$_rl_rung" >&2
    fi
    rl_build_lines "$RL_BUILD_PROFILE_DESC" 'termux-update:     '
    if [ "$RL_BUILD_CARGO_MODE" = dev ]; then
      printf 'termux-update: this attempt builds with %s build --profile dev (debug, unoptimized)\n' \
        "$_rl_cargo" >&2
    fi
    _rl_log=$(mktemp) 2>/dev/null || rl_fail 'build_log_failed: cannot create a temporary build log'
    rl_build_run "$_rl_src" "$_rl_log"
    if [ "$RL_BUILD_RC" -eq 0 ]; then
      case "$RL_BUILD_CARGO_MODE" in
        dev) _rl_bin="$_rl_src/rust/target/debug/wa" ;;
        *) _rl_bin="$_rl_src/rust/target/release/wa" ;;
      esac
      rm -f -- "$_rl_log"
      [ -f "$_rl_bin" ] || rl_fail "build_output_missing: $_rl_bin"
      printf 'termux-update: profile %s finished: %s\n' "$_rl_rung" "$_rl_bin" >&2
      printf '%s' "$_rl_bin"
      return 0
    fi
    _rl_crashed=0
    if rl_build_log_crashed "$_rl_log"; then _rl_crashed=1; fi
    _rl_crate=
    if [ "$_rl_crashed" = 1 ]; then
      if rl_build_log_crate "$_rl_log"; then _rl_crate=$RL_BUILD_CRATE; fi
    fi
    _rl_kept=$(rl_build_retain_log "$_rl_log" "$RL_BUILD_ATTEMPT_COUNT")
    if [ "$_rl_crashed" = 0 ]; then
      # A real build error is not a memory problem, and another rung would only make the
      # message harder to read. Keep the log, say which rung it was, refuse.
      rl_warn "cargo exited $RL_BUILD_RC at attempt $RL_BUILD_ATTEMPT_COUNT/$RL_BUILD_ATTEMPT_TOTAL (profile $_rl_rung) and that is not a compiler crash, so the ladder stops here"
      if [ "$RL_BUILD_ATTEMPT_COUNT" -gt 1 ]; then
        RL_BUILD_REPORT="$RL_BUILD_REPORT${RL_BUILD_REPORT:+
}attempt $RL_BUILD_ATTEMPT_COUNT/$RL_BUILD_ATTEMPT_TOTAL, profile $_rl_rung: cargo exited $RL_BUILD_RC, not a compiler crash
  log: $_rl_kept"
        rl_build_refuse 0 "$RL_BUILD_RC"
      fi
      if [ "${WA_TERMUX_OFFLINE:-0}" = 1 ]; then
        rl_warn 'build_failed: cargo build --locked --offline exited non-zero'
      else
        rl_warn 'build_failed: cargo build --locked exited non-zero'
      fi
      rl_warn "  build log: $_rl_kept"
      rl_warn '  no release was assembled, switched or installed, and node state was not read or written'
      exit 1
    fi
    RL_BUILD_REPORT="$RL_BUILD_REPORT${RL_BUILD_REPORT:+
}attempt $RL_BUILD_ATTEMPT_COUNT/$RL_BUILD_ATTEMPT_TOTAL, profile $_rl_rung: THE COMPILER CRASHED (cargo exited $RL_BUILD_RC)
  log: $_rl_kept"
    if [ -n "$_rl_crate" ]; then
      RL_BUILD_REPORT="$RL_BUILD_REPORT
  last crate in the log: $_rl_crate"
    fi
    printf 'termux-update: THE COMPILER CRASHED (status %s), this is not a build error: %s\n' \
      "$RL_BUILD_RC" "$RL_BUILD_CRASH_LINE" >&2
    if [ -n "$_rl_crate" ]; then
      printf 'termux-update: the last crate in that log is %s\n' "$_rl_crate" >&2
    fi
    printf 'termux-update: its log is kept at %s\n' "$_rl_kept" >&2
    if [ "$RL_BUILD_ATTEMPT_COUNT" -lt "$RL_BUILD_ATTEMPT_TOTAL" ]; then
      printf 'termux-update: trying the next rung of the ladder\n' >&2
    fi
  done
  rl_build_refuse 1 "$RL_BUILD_RC"
}

# Assemble one release directory from a source tree. The launcher, the updater and the UI
# all come from the SAME source tree as the runtime, which is what keeps a release's parts
# from being different revisions of each other.
rl_assemble() { # <src_root> <bin> <dest> <commit> <remote> <previous> <installed_by> [build_profile]
  _rl_src=$1
  _rl_bin=$2
  _rl_dest=$3
  rm -rf -- "$_rl_dest"
  mkdir -p -- "$_rl_dest/bin" "$_rl_dest/ui"
  install -m 755 "$_rl_bin" "$_rl_dest/wa" || rl_fail "assemble_failed: $_rl_bin"
  install -m 755 "$_rl_src/scripts/termux/wa" "$_rl_dest/bin/wa" || rl_fail 'assemble_failed: bin/wa'
  install -m 755 "$_rl_src/scripts/termux/wa-update.sh" "$_rl_dest/bin/wa-update" ||
    rl_fail 'assemble_failed: bin/wa-update'
  install -m 644 "$_rl_src/scripts/termux/release-lib.sh" "$_rl_dest/bin/release-lib.sh" ||
    rl_fail 'assemble_failed: bin/release-lib.sh'
  for _rl_a in $RL_UI_ASSETS; do
    install -m 644 "$_rl_src/ui/$_rl_a" "$_rl_dest/ui/$_rl_a" ||
      rl_fail "ui_asset_missing: $_rl_src/ui/$_rl_a"
  done
  install -m 644 "$_rl_src/LICENSE" "$_rl_dest/LICENSE" || rl_fail "license_missing: $_rl_src/LICENSE"
  rl_write_installed "$_rl_dest/installed.txt" "$4" "$5" "$6" "$7" "${8:-}"
  rl_manifest "$_rl_dest" "$_rl_dest/installed.sha256"
}

# Everything that must hold before a release may be used. Prints the specific missing fact
# and returns non-zero; the caller decides whether that is fatal.
#
# `strict` (default 1) is for a CANDIDATE about to be switched in: its architecture is
# exactly the question, so a non-aarch64 ELF is fatal. The rollback target is verified
# with strict=0 - it is the release that has already been running on this node, and the
# manifest plus the file list are what can have gone wrong since. Neither mode skips the
# manifest, which is what catches tampering either way.
rl_verify_release() { # <release_dir> [strict]
  _rl_d=$1
  _rl_strict=${2:-1}
  for _rl_f in wa bin/wa bin/wa-update bin/release-lib.sh ui/index.html ui/render.wasm \
                LICENSE installed.txt installed.sha256; do
    if [ ! -e "$_rl_d/$_rl_f" ]; then rl_warn "candidate_incomplete: missing $_rl_d/$_rl_f"; return 1; fi
  done
  if ! rl_manifest_verify "$_rl_d"; then
    rl_warn "candidate_manifest_mismatch: $_rl_d/installed.sha256 does not describe the tree"
    return 1
  fi
  if [ "$_rl_strict" != 1 ]; then return 0; fi
  _rl_abi=$(rl_elf_abi "$_rl_d/wa")
  if [ "$_rl_abi" != aarch64 ]; then
    rl_warn "wrong_abi: $_rl_d/wa is $_rl_abi, this node needs an aarch64 ELF"
    return 1
  fi
  # Two probes only mean anything on the target host: the POSIX executable bit (which a
  # non-POSIX filesystem cannot represent) and running the candidate (which a host of
  # another architecture cannot do). WA_TERMUX_HOST_PROBES=0 is the fixture suite saying
  # it is not the target host; it is announced, never silent.
  if [ "${WA_TERMUX_HOST_PROBES:-1}" = 1 ]; then
    [ -x "$_rl_d/wa" ] || { rl_warn "candidate_not_executable: $_rl_d/wa"; return 1; }
    # Run the candidate against a scratch home, never the operator's: a proof must not be
    # the thing that touches state.
    _rl_home=$(mktemp -d) || return 1
    if "$_rl_d/wa" init > "$_rl_home/out" 2>/dev/null &&
       head -n 1 "$_rl_home/out" | grep -q '"schema"'; then
      rm -rf -- "$_rl_home"
    else
      rm -rf -- "$_rl_home"
      rl_warn "candidate_does_not_run: $_rl_d/wa init failed"
      return 1
    fi
  elif [ "${_rl_host_warned:-0}" = 0 ]; then
    _rl_host_warned=1
    rl_warn 'WA_TERMUX_HOST_PROBES=0: skipping the executable-bit check and the candidate run probe (this is not the target host)'
  fi
  return 0
}

# Put a release at the active path. Two same-filesystem renames with a recorded intent:
# a crash between them is recoverable (see rl_recover), and the previous release is kept
# under its own commit in $RL_RELEASES, which is the rollback.
rl_activate() { # <target_sha>
  _rl_target=$1
  [ -d "$RL_RELEASES/$_rl_target" ] || rl_fail "release_missing: $RL_RELEASES/$_rl_target"
  _rl_cur=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
  [ -n "$_rl_cur" ] || rl_fail "installed_revision_unknown: $RL_INSTALL/installed.txt has no source_commit"
  if [ "$_rl_cur" = "$_rl_target" ]; then rl_note "termux-update: $_rl_target is already active"; return 0; fi
  mkdir -p -- "$RL_RELEASES" "$RL_UPDATE" || rl_fail "activate_failed: cannot create $RL_RELEASES"
  chmod 700 "$RL_UPDATE" 2>/dev/null || true
  if [ -d "$RL_RELEASES/$_rl_cur" ]; then
    _rl_retire="$RL_UPDATE/.trash.$$"
  else
    _rl_retire="$RL_RELEASES/$_rl_cur"
  fi
  printf '%s %s\n' "$_rl_cur" "$_rl_target" > "$RL_UPDATE/switch.intent"
  mv -- "$RL_INSTALL" "$_rl_retire" || rl_fail "switch_failed: could not set aside $_rl_cur"
  if ! mv -- "$RL_RELEASES/$_rl_target" "$RL_INSTALL"; then
    mv -- "$_rl_retire" "$RL_INSTALL"
    rl_fail "switch_failed: could not install $_rl_target; the previous release is back in place"
  fi
  if [ "$_rl_retire" = "$RL_UPDATE/.trash.$$" ]; then rm -rf -- "$_rl_retire"; fi
  rm -f -- "$RL_UPDATE/switch.intent"
  rl_note "termux-update: active release $_rl_cur -> $_rl_target"
}

# A switch that was interrupted leaves the intent behind and the active path empty. Put the
# previous release back rather than guessing, and say so.
rl_recover() {
  [ -f "$RL_UPDATE/switch.intent" ] || return 0
  if [ -e "$RL_INSTALL" ]; then rm -f -- "$RL_UPDATE/switch.intent"; return 0; fi
  _rl_prev=$(cut -d' ' -f1 "$RL_UPDATE/switch.intent")
  for _rl_c in "$RL_RELEASES/$_rl_prev" "$RL_UPDATE"/.trash.*; do
    if [ -d "$_rl_c" ]; then
      if mv -- "$_rl_c" "$RL_INSTALL"; then
        rm -rf -- "$RL_UPDATE"/.trash.*
        rm -f -- "$RL_UPDATE/switch.intent"
        rl_note "termux-update: recovered an interrupted switch, active release $_rl_prev"
        return 0
      fi
    fi
  done
  rl_fail "interrupted_switch_unrecoverable: $RL_UPDATE/switch.intent names $_rl_prev but no copy of it exists"
}

# State that must never be inside an install directory. If it is, the layout on this phone
# is not the documented one and moving the directory would move state with it.
rl_state_inside() { # <dir>; prints the offending path, returns 0 when one is found
  for _rl_p in .wasm-agent memory.db history.db sessions env .env; do
    if [ -e "$1/$_rl_p" ]; then printf '%s' "$1/$_rl_p"; return 0; fi
  done
  return 1
}
