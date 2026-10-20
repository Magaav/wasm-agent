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
#
# Files that are not members of the closure it describes: the manifest itself, and anything
# named in RL_MANIFEST_EXCLUDE. The cross-build bundle needs the second one - it ships
# `bundle.manifest`, the envelope that describes the closure, next to the closure - and a
# phone-built or updater-built release sets nothing here, so it hashes exactly as before.
RL_MANIFEST_EXCLUDE=

rl_manifest() { # <release_dir> <outfile>
  _rl_d=$1
  _rl_o=$2
  (
    cd "$_rl_d" || exit 1
    set -- -type f ! -name installed.sha256
    for _rl_x in $RL_MANIFEST_EXCLUDE; do
      set -- "$@" ! -name "$_rl_x"
    done
    find . "$@" -print | sed 's|^\./||' | LC_ALL=C sort |
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

rl_write_installed() { # <dest_file> <commit> <remote> <previous_sha|-> <installed_by> [build_profile] [source_provenance] [release_key]
  {
    printf 'source_commit=%s\n' "$2"
    printf 'source_remote=%s\n' "$3"
    printf 'installed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'previous_commit=%s\n' "${4:--}"
    printf 'installed_by=%s\n' "$5"
    # Where the bytes came from. `source-built-termux` is a build on this phone; a prebuilt
    # bundle built on a desktop records `cross-built-android` instead, because "this runtime
    # was not compiled here" is a fact the operator needs later.
    printf 'source_provenance=%s\n' "${7:-source-built-termux}"
    # Which rung of the build ladder produced the runtime that is in this release: a phone
    # whose optimized build would not finish ends up running the debug/unoptimized one, and
    # that has to be readable later (`wa doctor` reads exactly this line). Absent in a
    # release from before this line existed, which is not an error.
    if [ -n "${6:-}" ]; then printf 'build_profile=%s\n' "$6"; fi
    # The name this release is switched in under, when it is not simply its commit: a
    # prebuilt bundle records it so that two releases of one commit stay distinguishable.
    if [ -n "${8:-}" ]; then printf 'release_key=%s\n' "$8"; fi
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

# Everything a PREBUILT bundle must prove before its bytes may be treated as a release.
# The hash the operator pasted is checked by the caller (it names this bundle's
# `bundle.manifest`); this function walks the rest of the chain and refuses on the first
# broken link, naming it:
#
#   --manifest-sha256  ==  sha256(bundle.manifest)          (checked by the installer)
#   bundle.manifest's `release_manifest_sha256` == sha256(installed.sha256)
#   installed.sha256   ==  every file in the bundle, and nothing else
#   every `artefact <sha256> <path>` line == the bytes of that file
#   `wa` reads as an aarch64 ELF, and the manifest agrees about its machine and triple
#
# The Android/arm64 triple is required here on purpose: the phone can only run that, so a
# bundle for another triple is not a candidate, whatever its filename says.
rl_bundle_verify() { # <bundle_dir>
  _rl_b=$1
  [ -d "$_rl_b" ] || { rl_warn "bundle_missing: $_rl_b is not a directory"; return 1; }
  for _rl_f in bundle.manifest installed.sha256 wa bin/wa bin/wa-update bin/release-lib.sh \
                installed.txt LICENSE ui/index.html; do
    [ -e "$_rl_b/$_rl_f" ] || { rl_warn "bundle_incomplete: missing $_rl_b/$_rl_f"; return 1; }
  done
  for _rl_a in $RL_UI_ASSETS; do
    [ -e "$_rl_b/ui/$_rl_a" ] || { rl_warn "bundle_incomplete: missing $_rl_b/ui/$_rl_a"; return 1; }
  done
  _rl_claim_triple=$(rl_get "$_rl_b/bundle.manifest" target_triple)
  [ -n "$_rl_claim_triple" ] ||
    { rl_warn "bundle_manifest_incomplete: $_rl_b/bundle.manifest records no target_triple"; return 1; }
  [ "$_rl_claim_triple" = aarch64-linux-android ] ||
    { rl_warn "wrong_target_triple: the bundle was built for $_rl_claim_triple, this node needs aarch64-linux-android"; return 1; }
  _rl_rm=$(rl_get "$_rl_b/bundle.manifest" release_manifest_sha256)
  [ -n "$_rl_rm" ] ||
    { rl_warn "bundle_manifest_incomplete: $_rl_b/bundle.manifest records no release_manifest_sha256"; return 1; }
  _rl_actual=$(rl_sha256 "$_rl_b/installed.sha256")
  [ "$_rl_rm" = "$_rl_actual" ] ||
    { rl_warn "bundle_manifest_mismatch: bundle.manifest records release_manifest_sha256=$_rl_rm but installed.sha256 is $_rl_actual"; return 1; }
  if ! rl_manifest_verify "$_rl_b"; then
    rl_warn "bundle_modified: $_rl_b/installed.sha256 does not describe the files in this bundle (a member was changed, added or is missing)"
    return 1
  fi
  _rl_seen=0
  while read -r _rl_tag _rl_hash _rl_path; do
    [ "$_rl_tag" = artefact ] || continue
    _rl_seen=$((_rl_seen + 1))
    if [ ! -f "$_rl_b/$_rl_path" ]; then
      rl_warn "bundle_incomplete: bundle.manifest lists artefact $_rl_path but it is missing from $_rl_b"
      return 1
    fi
    _rl_h=$(rl_sha256 "$_rl_b/$_rl_path")
    [ "$_rl_h" = "$_rl_hash" ] ||
      { rl_warn "bundle_member_mismatch: $_rl_path hashes to $_rl_h, bundle.manifest records $_rl_hash"; return 1; }
  done < "$_rl_b/bundle.manifest"
  [ "$_rl_seen" -gt 0 ] ||
    { rl_warn "bundle_manifest_incomplete: $_rl_b/bundle.manifest lists no artefacts"; return 1; }
  _rl_abi=$(rl_elf_abi "$_rl_b/wa")
  [ "$_rl_abi" = aarch64 ] ||
    { rl_warn "wrong_abi: $_rl_b/wa is $_rl_abi, this node needs an aarch64 ELF"; return 1; }
  _rl_claim=$(rl_get "$_rl_b/bundle.manifest" elf_machine)
  if [ -n "$_rl_claim" ] && [ "$_rl_claim" != "$_rl_abi" ]; then
    rl_warn "bundle_manifest_mismatch: bundle.manifest claims elf_machine=$_rl_claim but $_rl_b/wa is $_rl_abi"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The published release channel: an index on main, and one asset per release
# ---------------------------------------------------------------------------
#
# WHY. The device cannot compile this workspace any more: every rung of the build ladder
# above died inside rustc with `(signal: 11, SIGSEGV)` while compiling `cranelift_codegen`
# (the measurements are in that section, and in scripts/termux/cross-build-android.sh). So
# the channel `wa update` uses is a PUBLISHED RELEASE, not a compile on the phone:
# `releases/index.json` on main is the index, one entry per published bundle, newest first.
# This section resolves it, picks one entry and refuses unless the bytes match that entry.
#
# THE TRUST CHAIN, link by link (docs/release/RELEASE_INDEX.md is the document):
#   1. the index is fetched over HTTPS from the public repository. No token, ever: the
#      repository is public, and a phone that needed a credential to read a release would
#      be a phone that cannot update itself after a credential is lost.
#   2. one entry pins ONE bundle by sha256(bundle.manifest). That single 64-hex value is
#      what the operator used to paste in by hand (`--manifest-sha256`), now read from the
#      index, so the channel is exactly as strong as the manual install it replaces.
#   3. the asset is downloaded to a private temp directory and its size must equal the
#      entry's `size` - a truncated transfer is refused, not retried forever.
#   4. sha256(downloaded bundle.manifest) must equal the entry's `manifest_sha256`. If it
#      does not, that is `hash_mismatch`: nothing is installed, and there is NO fallback to
#      building. A hash mismatch is never a reason to try the other path.
#   5. only then is the bundle handed to rl_bundle_install below, which walks the rest of
#      the chain exactly as a hand-installed bundle does: bundle.manifest describes
#      installed.sha256, installed.sha256 describes every member, every `artefact` line is
#      checked against the bytes, the ELF machine is read from the header, the triple must
#      be aarch64-linux-android, and the candidate is run once before it is switched in.
#
# The index is machine-written and line-oriented on purpose: one `"key": value` pair per
# line, so a POSIX sh phone can validate it with sed and `case`, with no JSON library and no
# new dependency. Anything that does not match that shape is refused as `index_invalid`,
# which is a refusal and not a parse to be guessed at.

RL_RELEASE_INDEX_URL='https://raw.githubusercontent.com/Magaav/wasm-agent/main/releases/index.json'
RL_RELEASE_INDEX_SCHEMA='wasm-agent-release-index'
RL_RELEASE_INDEX_VERSION=1
RL_RELEASE_TARGET='aarch64-linux-android'
RL_RELEASE_ASSET_NAME='wa-android-bundle-<commit_short>.tar.gz'
RL_HTTP_TIMEOUT_INDEX=60
RL_HTTP_TIMEOUT_ASSET=900
RL_TAB=$(printf '\t')

# The index URL: --index wins, then the documented override, then the published default.
rl_release_index_url() {
  printf '%s' "${WA_TERMUX_RELEASE_INDEX_URL:-$RL_RELEASE_INDEX_URL}"
}

# curl OR wget, never both required. A node with neither cannot use the channel at all, and
# that is a named refusal (`http_client_missing`), not a crash.
rl_http_client() {
  if command -v curl >/dev/null 2>&1; then printf 'curl'; return 0; fi
  if command -v wget >/dev/null 2>&1; then printf 'wget'; return 0; fi
  return 1
}

# Fetch <url> into <outfile>. Returns 0, or 1 with RL_FETCH_CLASS naming why:
#   http_client_missing  neither curl nor wget is installed on this node
#   unreachable          the transfer failed (DNS, TLS, 404, a dead local file)
#   local_url_refused    a file: URL outside the fixture suite
# RL_FETCH_DETAIL is for the operator; the caller maps the class to its own refusal name so
# that the index and the asset can name different failures with the same transport code.
rl_http_fetch() { # <url> <outfile> <timeout_seconds>
  _rl_u=$1
  _rl_o=$2
  _rl_t=$3
  RL_FETCH_CLASS=ok
  RL_FETCH_DETAIL=
  case "$_rl_u" in
    file://*)
      # A local asset is how the fixture suite serves a real bundle without a network. It is
      # never a normal channel: an attacker who can write that path could point the index
      # somewhere else, so a file: URL needs an explicit opt-in, and it is announced.
      if [ "${WA_TERMUX_RELEASE_ALLOW_LOCAL:-0}" != 1 ]; then
        RL_FETCH_CLASS=local_url_refused
        RL_FETCH_DETAIL="$_rl_u is a file: URL; only WA_TERMUX_RELEASE_ALLOW_LOCAL=1 accepts one"
        return 1
      fi
      _rl_p=${_rl_u#file://}
      if [ ! -f "$_rl_p" ]; then
        RL_FETCH_CLASS=unreachable
        RL_FETCH_DETAIL="$_rl_p does not exist"
        return 1
      fi
      if ! cp -- "$_rl_p" "$_rl_o" 2>/dev/null; then
        RL_FETCH_CLASS=unreachable
        RL_FETCH_DETAIL="could not copy $_rl_p"
        return 1
      fi
      return 0
      ;;
  esac
  _rl_client=$(rl_http_client) || {
    RL_FETCH_CLASS=http_client_missing
    RL_FETCH_DETAIL='this node has neither curl nor wget'
    return 1
  }
  if [ "$_rl_client" = curl ]; then
    if ! curl -fsSL --connect-timeout 20 --max-time "$_rl_t" -o "$_rl_o" "$_rl_u"; then
      RL_FETCH_CLASS=unreachable
      RL_FETCH_DETAIL="curl could not fetch $_rl_u"
      return 1
    fi
  else
    if ! wget -q -T 20 -t 1 -O "$_rl_o" "$_rl_u"; then
      RL_FETCH_CLASS=unreachable
      RL_FETCH_DETAIL="wget could not fetch $_rl_u"
      return 1
    fi
  fi
  return 0
}

# The index, as bytes. An empty body is a broken fetch, not an index with no releases.
rl_release_index_fetch() { # <dest_file>
  if ! rl_http_fetch "$(rl_release_index_url)" "$1" "$RL_HTTP_TIMEOUT_INDEX"; then
    return 1
  fi
  if [ ! -s "$1" ]; then
    RL_FETCH_CLASS=unreachable
    RL_FETCH_DETAIL='the index came back empty'
    return 1
  fi
  return 0
}

_rl_index_bad() { # <detail>
  RL_INDEX_ERROR=index_invalid
  RL_INDEX_DETAIL=$1
  return 1
}

_rl_index_hex() { # <value> <length>
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq "$2" ] || return 1
  return 0
}

# Validate the entry collected so far and append it to the flat file. One record, tab
# separated, in the fixed field order above. Everything the installer later needs is
# validated here, so a selected record is complete by construction.
_rl_index_entry_done() { # <flat_out>
  _rl_missing=
  [ -n "$_rl_e_commit" ] || _rl_missing="$_rl_missing commit"
  [ -n "$_rl_e_short" ] || _rl_missing="$_rl_missing commit_short"
  [ -n "$_rl_e_msha" ] || _rl_missing="$_rl_missing manifest_sha256"
  [ -n "$_rl_e_url" ] || _rl_missing="$_rl_missing url"
  [ -n "$_rl_e_size" ] || _rl_missing="$_rl_missing size"
  [ -n "$_rl_e_target" ] || _rl_missing="$_rl_missing target"
  [ -n "$_rl_e_ndk" ] || _rl_missing="$_rl_missing ndk"
  [ -n "$_rl_e_rustc" ] || _rl_missing="$_rl_missing rustc"
  [ -n "$_rl_e_built" ] || _rl_missing="$_rl_missing built_utc"
  if [ -n "$_rl_missing" ]; then
    _rl_index_bad "a release entry is missing:$_rl_missing"
    return 1
  fi
  _rl_e_commit=$(printf '%s' "$_rl_e_commit" | tr 'A-F' 'a-f')
  _rl_e_short=$(printf '%s' "$_rl_e_short" | tr 'A-F' 'a-f')
  _rl_e_msha=$(printf '%s' "$_rl_e_msha" | tr 'A-F' 'a-f')
  _rl_index_hex "$_rl_e_commit" 40 || {
    _rl_index_bad "commit '$_rl_e_commit' is not a 40-character SHA-1"; return 1; }
  _rl_index_hex "$_rl_e_short" 12 || {
    _rl_index_bad "commit_short '$_rl_e_short' is not 12 hex characters"; return 1; }
  case "$_rl_e_commit" in
    "$_rl_e_short"*) : ;;
    *) _rl_index_bad "commit_short '$_rl_e_short' is not the first 12 characters of commit '$_rl_e_commit'"; return 1 ;;
  esac
  _rl_index_hex "$_rl_e_msha" 64 || {
    _rl_index_bad "manifest_sha256 '$_rl_e_msha' is not a 64-character sha256"; return 1; }
  case "$_rl_e_size" in
    ''|*[!0-9]*) _rl_index_bad "size '$_rl_e_size' is not a byte count"; return 1 ;;
  esac
  case "$_rl_e_url" in
    https://*|http://*) : ;;
    file://*)
      if [ "${WA_TERMUX_RELEASE_ALLOW_LOCAL:-0}" != 1 ]; then
        _rl_index_bad "url '$_rl_e_url' is a file: URL; a published index must name an http(s) asset"
        return 1
      fi
      ;;
    *) _rl_index_bad "url '$_rl_e_url' is neither https nor http"; return 1 ;;
  esac
  case "$_rl_e_url" in *"$RL_TAB"*) _rl_index_bad 'url contains a tab'; return 1 ;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_rl_e_commit" "$_rl_e_short" "$_rl_e_msha" "$_rl_e_url" "$_rl_e_size" \
    "$_rl_e_target" "$_rl_e_ndk" "$_rl_e_rustc" "$_rl_e_built" >> "$1"
  return 0
}

_rl_index_entry_reset() {
  _rl_e_commit=
  _rl_e_short=
  _rl_e_msha=
  _rl_e_url=
  _rl_e_size=
  _rl_e_target=
  _rl_e_ndk=
  _rl_e_rustc=
  _rl_e_built=
}

# Parse and validate the index into a flat file, newest entry first, in the order the index
# lists them. Returns non-zero with RL_INDEX_ERROR=index_invalid and RL_INDEX_DETAIL naming
# the line that broke, and writes nothing usable.
rl_release_index_parse() { # <index_file> <flat_out>
  RL_INDEX_ERROR=
  RL_INDEX_DETAIL=
  : > "$2" || {
    RL_INDEX_ERROR=index_invalid
    RL_INDEX_DETAIL="cannot write $2"
    return 1
  }
  _rl_norm="$2.norm"
  # Canonical form: no CR (an index committed on Windows is still valid), no surrounding
  # whitespace, no blank lines. Everything below is a `case` on that shape.
  if ! tr -d '\r' < "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' > "$_rl_norm"; then
    rm -f -- "$_rl_norm"
    _rl_index_bad 'the index could not be read'
    return 1
  fi
  _rl_schema=
  _rl_version=
  _rl_seen_releases=0
  _rl_in_releases=0
  _rl_open=0
  _rl_index_entry_reset
  while IFS= read -r _rl_line || [ -n "$_rl_line" ]; do
    case $_rl_line in
      '{')
        if [ "$_rl_in_releases" = 1 ]; then
          [ "$_rl_open" = 0 ] || { rm -f -- "$_rl_norm"; _rl_index_bad 'a release entry was opened inside another'; return 1; }
          _rl_open=1
          _rl_index_entry_reset
        fi
        ;;
      '}'|'},')
        if [ "$_rl_open" = 1 ]; then
          _rl_index_entry_done "$2" || { rm -f -- "$_rl_norm"; return 1; }
          _rl_open=0
        fi
        ;;
      '['|']'|'],'|'[]')
        ;;
      '"'*)
        case $_rl_line in
          *'":'*) : ;;
          *)
            # A bare JSON string element: the `trust_chain` list is written this way. It is
            # documentation, never a field, so it is allowed only outside a release entry.
            if [ "$_rl_open" = 1 ]; then
              rm -f -- "$_rl_norm"
              _rl_index_bad "unexpected string inside a release entry: $_rl_line"
              return 1
            fi
            continue
            ;;
        esac
        _rl_key=${_rl_line#\"}
        _rl_key=${_rl_key%%\"*}
        _rl_after=${_rl_line#\"$_rl_key\"}
        _rl_after=${_rl_after#:}
        while [ "${_rl_after# }" != "$_rl_after" ]; do _rl_after=${_rl_after# }; done
        _rl_after=${_rl_after%,}
        while [ "${_rl_after% }" != "$_rl_after" ]; do _rl_after=${_rl_after% }; done
        case $_rl_after in
          '"'*'"') _rl_val=${_rl_after#\"}; _rl_val=${_rl_val%\"} ;;
          *[!0-9]*) _rl_val= ;;
          '') _rl_val= ;;
          *) _rl_val=$_rl_after ;;
        esac
        if [ "$_rl_open" = 1 ]; then
          case $_rl_key in
            commit) _rl_e_commit=$_rl_val ;;
            commit_short) _rl_e_short=$_rl_val ;;
            manifest_sha256) _rl_e_msha=$_rl_val ;;
            url) _rl_e_url=$_rl_val ;;
            size) _rl_e_size=$_rl_val ;;
            target) _rl_e_target=$_rl_val ;;
            ndk) _rl_e_ndk=$_rl_val ;;
            rustc) _rl_e_rustc=$_rl_val ;;
            built_utc) _rl_e_built=$_rl_val ;;
            *)
              rm -f -- "$_rl_norm"
              _rl_index_bad "release entry has an unknown field '$_rl_key'"
              return 1
              ;;
          esac
        else
          case $_rl_key in
            schema) _rl_schema=$_rl_val ;;
            schema_version) _rl_version=$_rl_val ;;
            releases)
              _rl_seen_releases=1
              case $_rl_after in
                '['|'[]') _rl_in_releases=1 ;;
                *) rm -f -- "$_rl_norm"; _rl_index_bad "'releases' is not an array"; return 1 ;;
              esac
              ;;
            doc|trust_chain|generated_utc|notes) : ;;
            *)
              rm -f -- "$_rl_norm"
              _rl_index_bad "unknown top-level field '$_rl_key'"
              return 1
              ;;
          esac
        fi
        ;;
      *) rm -f -- "$_rl_norm"; _rl_index_bad "unparsed index line: $_rl_line"; return 1 ;;
    esac
  done < "$_rl_norm"
  rm -f -- "$_rl_norm"
  if [ "$_rl_schema" != "$RL_RELEASE_INDEX_SCHEMA" ]; then
    _rl_index_bad "schema is '$_rl_schema', expected '$RL_RELEASE_INDEX_SCHEMA'"
    return 1
  fi
  if [ "$_rl_version" != "$RL_RELEASE_INDEX_VERSION" ]; then
    _rl_index_bad "schema_version is '$_rl_version', this phone understands $RL_RELEASE_INDEX_VERSION"
    return 1
  fi
  if [ "$_rl_seen_releases" != 1 ]; then
    _rl_index_bad 'the index has no releases array'
    return 1
  fi
  RL_INDEX_COUNT=$(wc -l < "$2" | tr -d ' ')
  return 0
}

# The record for one commit, or nothing. Entries are newest first, so "the latest release"
# is the first record.
rl_release_entry_for() { # <flat_file> <commit>
  _rl_want=$(printf '%s' "$2" | tr 'A-F' 'a-f')
  while IFS=$RL_TAB read -r _rl_c _rl_cs _rl_ms _rl_u _rl_sz _rl_tg _rl_ndk _rl_rc _rl_bt; do
    if [ "$_rl_c" = "$_rl_want" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_rl_c" "$_rl_cs" "$_rl_ms" "$_rl_u" "$_rl_sz" "$_rl_tg" "$_rl_ndk" "$_rl_rc" "$_rl_bt"
      return 0
    fi
  done < "$1"
  return 1
}

rl_release_latest_commit() { # <flat_file>
  [ -s "$1" ] || return 1
  IFS=$RL_TAB read -r _rl_c _rl_rest < "$1" || return 1
  [ -n "$_rl_c" ] || return 1
  printf '%s' "$_rl_c"
}

# Download ONE published release and prove the one hash the index pins. Prints the bundle
# directory (the directory that holds bundle.manifest and installed.sha256) and the pinned
# manifest hash on stdout, separated by a space; refuses with a named message otherwise.
#
# The archive is a tar.gz of the bundle directory (scripts/termux/cross-build-android.sh
# writes `wa-android-bundle/bundle`). It is unpacked only after every member path has been
# checked, so a crafted archive cannot write outside the temp directory.
rl_release_fetch() { # <flat_file> <commit> <workdir>; sets RL_RELEASE_BUNDLE, RL_RELEASE_MANIFEST_SHA
  RL_RELEASE_BUNDLE=
  RL_RELEASE_MANIFEST_SHA=
  RL_RELEASE_ERROR=
  _rl_rec=$(rl_release_entry_for "$1" "$2") || {
    rl_fail "release_missing_for_commit: no release is published for $2 in $(rl_release_index_url)"
  }
  IFS=$RL_TAB read -r _rl_commit _rl_short _rl_msha _rl_url _rl_size _rl_target _rl_ndk _rl_rustc _rl_built <<EOF
$_rl_rec
EOF
  if [ "$_rl_target" != "$RL_RELEASE_TARGET" ]; then
    rl_fail "release_target_mismatch: the release for $_rl_short is built for $_rl_target, this node needs $RL_RELEASE_TARGET"
  fi
  mkdir -p -- "$3/asset" "$3/unpacked" || rl_fail "download_failed: cannot create a temporary directory in $3"
  _rl_archive=$3/asset/$(basename -- "$_rl_url")
  if ! rl_http_fetch "$_rl_url" "$_rl_archive" "$RL_HTTP_TIMEOUT_ASSET"; then
    case $RL_FETCH_CLASS in
      http_client_missing)
        rl_fail "http_client_missing: this node has neither curl nor wget, so the release for $_rl_short cannot be downloaded (install one: pkg install curl)"
        ;;
      local_url_refused)
        rl_fail "index_invalid: $RL_FETCH_DETAIL"
        ;;
      *) rl_fail "download_failed: $_rl_url: $RL_FETCH_DETAIL" ;;
    esac
  fi
  _rl_bytes=$(wc -c < "$_rl_archive" | tr -d ' ')
  if [ "$_rl_bytes" -lt "$_rl_size" ]; then
    rl_fail "download_truncated: $_rl_url is $_rl_bytes bytes, the index records $_rl_size (a partial or interrupted transfer); nothing was unpacked and nothing was installed"
  fi
  if [ "$_rl_bytes" -gt "$_rl_size" ]; then
    rl_fail "download_size_mismatch: $_rl_url is $_rl_bytes bytes, the index records $_rl_size; nothing was unpacked and nothing was installed"
  fi
  if ! tar -tzf "$_rl_archive" > "$3/asset/members" 2>/dev/null; then
    rl_fail "archive_invalid: $_rl_url is not a readable tar.gz; nothing was unpacked and nothing was installed"
  fi
  _rl_members=$(wc -l < "$3/asset/members" | tr -d ' ')
  [ "$_rl_members" -gt 0 ] || rl_fail "archive_invalid: $_rl_url declares no members"
  while IFS= read -r _rl_m; do
    case $_rl_m in
      /*|..|../*|*/../*|*/..)
        rl_fail "archive_unsafe: $_rl_url contains the member '$_rl_m' which escapes the archive; nothing was unpacked and nothing was installed"
        ;;
    esac
  done < "$3/asset/members"
  if ! tar -xzf "$_rl_archive" -C "$3/unpacked" 2>/dev/null; then
    rl_fail "archive_invalid: $_rl_url did not unpack; nothing was installed"
  fi
  _rl_found=$(find "$3/unpacked" -type f -name bundle.manifest -print 2>/dev/null)
  _rl_count=$(printf '%s\n' "$_rl_found" | grep -c . || true)
  if [ -z "$_rl_found" ]; then
    rl_fail "bundle_manifest_missing: $_rl_url unpacks to no bundle.manifest; this is not a prebuilt bundle"
  fi
  if [ "$_rl_count" -ne 1 ]; then
    rl_fail "bundle_manifest_ambiguous: $_rl_url unpacks to $_rl_count bundle.manifest files; refusing to guess which one is the release"
  fi
  RL_RELEASE_BUNDLE=$(dirname -- "$_rl_found")
  _rl_actual=$(rl_sha256 "$RL_RELEASE_BUNDLE/bundle.manifest")
  if [ "$_rl_actual" != "$_rl_msha" ]; then
    rl_fail "hash_mismatch: the bundle in $_rl_url has bundle.manifest sha256 $_rl_actual, the index for $_rl_short records $_rl_msha; nothing was installed and there is no fallback from a hash mismatch"
  fi
  _rl_claim_commit=$(rl_get "$RL_RELEASE_BUNDLE/bundle.manifest" source_commit)
  if [ -n "$_rl_claim_commit" ] && [ "$_rl_claim_commit" != "$_rl_commit" ]; then
    rl_fail "release_commit_mismatch: the index entry for $_rl_short points at a bundle built from $_rl_claim_commit; nothing was installed"
  fi
  RL_RELEASE_MANIFEST_SHA=$_rl_msha
  return 0
}

# ---------------------------------------------------------------------------
# Installing a verified prebuilt bundle
# ---------------------------------------------------------------------------
#
# This is the body `install-termux.sh --bundle` runs, lifted into one function so that the
# published-release channel in `wa update` and a hand-installed bundle are the SAME code:
# there is one implementation of "verify the bundle, keep the old release, switch". The
# caller owns the staging directory (it must be on the same filesystem as $RL_INSTALL) and
# cleans it up; this function never deletes a directory it did not create files in.
#
# `RL_BUNDLE_TAG` is the message prefix, so install-bundle.sh keeps printing
# `termux-bundle:` and `wa update` prints `termux-update:`. `RL_BUNDLE_RESULT` is
# `installed` or `already-installed` afterwards.
rbi_note() { printf '%s: %s\n' "${RL_BUNDLE_TAG:-termux-bundle}" "$*"; }
rbi_fail() { printf '%s: %s\n' "${RL_BUNDLE_TAG:-termux-bundle}" "$*" >&2; exit 1; }

rl_bundle_install() { # <bundle_dir> <manifest_sha256> <stage_dir>
  _rbi_bundle=$1
  _rbi_msha=$2
  _rbi_stage=$3
  RL_BUNDLE_RESULT=
  case "$_rbi_msha" in
    *[!0-9a-fA-F]*)
      rbi_fail "manifest_sha256_invalid: '$_rbi_msha' is not a hexadecimal sha256 (64 hex characters)"
      ;;
  esac
  if [ "${#_rbi_msha}" -ne 64 ]; then
    rbi_fail "manifest_sha256_invalid: '$_rbi_msha' is ${#_rbi_msha} characters; a sha256 is 64"
  fi
  _rbi_msha=$(printf '%s' "$_rbi_msha" | tr 'A-F' 'a-f')
  [ -d "$_rbi_bundle" ] ||
    rbi_fail "bundle_missing: $_rbi_bundle is not a directory (copy the bundle out of shared storage first)"
  [ -f "$_rbi_bundle/bundle.manifest" ] ||
    rbi_fail "bundle_incomplete: $_rbi_bundle/bundle.manifest is missing; this is not a prebuilt bundle"
  _rbi_actual=$(rl_sha256 "$_rbi_bundle/bundle.manifest")
  if [ "$_rbi_actual" != "$_rbi_msha" ]; then
    rbi_fail "bundle_manifest_sha256_mismatch: you passed $_rbi_msha but $_rbi_bundle/bundle.manifest is $_rbi_actual (a partial copy, a modified bundle, or the wrong hash; nothing was changed)"
  fi
  # From here the manifest, every member, the per-artefact hashes and the ELF machine are
  # checked. `bundle.manifest` is the envelope, not a member, so the release manifest written
  # at build time excludes it - the same exclusion this verification uses.
  RL_MANIFEST_EXCLUDE=bundle.manifest
  rl_bundle_verify "$_rbi_bundle" ||
    rbi_fail "bundle_refused: $_rbi_bundle did not verify (see above); nothing was switched, installed or changed"
  _rbi_commit=$(rl_get "$_rbi_bundle/bundle.manifest" source_commit)
  _rbi_tree=$(rl_get "$_rbi_bundle/bundle.manifest" source_tree_sha256)
  _rbi_ndk=$(rl_get "$_rbi_bundle/bundle.manifest" ndk_version)
  _rbi_rustc=$(rl_get "$_rbi_bundle/bundle.manifest" rustc_version)
  _rbi_target=$(rl_get "$_rbi_bundle/bundle.manifest" target_triple)
  [ -n "$_rbi_commit" ] ||
    rbi_fail "bundle_manifest_incomplete: $_rbi_bundle/bundle.manifest records no source_commit; cannot record what is installed"
  _rbi_remote=$(rl_get "$_rbi_bundle/installed.txt" source_remote)
  [ -n "$_rbi_remote" ] || _rbi_remote='-'
  _rbi_recorded=$(rl_get "$_rbi_bundle/installed.txt" source_commit)
  if [ "$_rbi_recorded" != "$_rbi_commit" ]; then
    rbi_fail "bundle_manifest_mismatch: installed.txt records source_commit='$_rbi_recorded' but bundle.manifest records '$_rbi_commit'"
  fi
  if _rbi_offending=$(rl_state_inside "$_rbi_bundle"); then
    rbi_fail "state_in_bundle: $_rbi_offending is inside the bundle; that is node state, not runtime bytes - do not install this bundle"
  fi
  # ---- what is installed right now, and the rollback release ----------------
  _rbi_existing=
  if [ -e "$RL_INSTALL" ] || [ -L "$RL_INSTALL" ]; then
    if [ -L "$RL_INSTALL" ]; then
      rbi_fail "install_is_a_link: $RL_INSTALL is a symbolic link; this installer replaces a directory (use 'wa update')"
    fi
    [ -d "$RL_INSTALL" ] || rbi_fail "not_a_directory: $RL_INSTALL"
    [ -f "$RL_INSTALL/installed.txt" ] ||
      rbi_fail "installed_metadata_missing: $RL_INSTALL/installed.txt (cannot tell which revision is installed, so it cannot be the rollback release)"
    _rbi_existing=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
    [ -n "$_rbi_existing" ] ||
      rbi_fail "installed_revision_unknown: $RL_INSTALL/installed.txt has no source_commit"
    if _rbi_offending=$(rl_state_inside "$RL_INSTALL"); then
      rbi_fail "state_inside_install: $_rbi_offending (node state must live in ~/.wasm-agent, not in the runtime directory; move it before installing)"
    fi
    rl_manifest_verify "$RL_INSTALL" ||
      rbi_fail "installed_release_modified: $RL_INSTALL no longer matches its installed.sha256; refusing to take it as the rollback release"
    if [ -e "$RL_PREFIX/bin/wa" ] && [ ! -L "$RL_PREFIX/bin/wa" ]; then
      # On the phone this is fatal: a plain file at $PREFIX/bin/wa would keep running an
      # older launcher after the switch. The published fixture suite says it is standing in
      # for the phone and announces the skip; a Windows host cannot represent a symlink at
      # all, so pretending otherwise would only make the suite lie.
      if [ "${WA_TERMUX_TEST:-0}" = 1 ]; then
        rbi_note "WA_TERMUX_TEST=1: $RL_PREFIX/bin/wa is not a symlink on this host (no symlinks here); the launcher guard is skipped for the fixture suite"
      else
        rbi_fail "launcher_not_symlink: $RL_PREFIX/bin/wa is not the expected symlink to $RL_INSTALL/bin/wa"
      fi
    fi
    # Already exactly this bundle? Then there is nothing to do, and nothing to move. This is
    # the common repeat case - the operator ran the install twice, or the same bundle was
    # rebuilt byte-identically - and the check matters: without it the second run would try to
    # take the ACTIVE release as the rollback copy under a name this bundle itself already
    # put there (the case where the same revision was installed from source first), and refuse
    # over a conflict that is not one. The active release has just been verified against its
    # own manifest above, and the bundle hash it records is what it was switched in from.
    if [ "$(rl_get "$RL_INSTALL/installed.txt" bundle_manifest_sha256)" = "$_rbi_msha" ]; then
      rbi_note "this bundle is already installed ($_rbi_commit); nothing to do"
      if [ "$(rl_get "$RL_INSTALL/installed.txt" previous_commit)" != '-' ]; then
        rbi_note 'roll back with: wa update --rollback'
      fi
      RL_BUNDLE_RESULT=already-installed
      return 0
    fi
  else
    if [ -e "$RL_PREFIX/bin/wa" ] || [ -L "$RL_PREFIX/bin/wa" ]; then
      rbi_fail "launcher_exists: $RL_PREFIX/bin/wa exists but no installation is at $RL_INSTALL"
    fi
  fi
  mkdir -p -- "$RL_RELEASES" "$RL_UPDATE" || rbi_fail "cannot create $RL_RELEASES"
  chmod 700 "$RL_UPDATE" 2>/dev/null || true
  if [ -n "$_rbi_existing" ]; then
    _rbi_backup="$RL_RELEASES/$_rbi_existing"
    if [ -d "$_rbi_backup" ]; then
      _rbi_before=$(mktemp)
      _rbi_after=$(mktemp)
      rl_manifest "$RL_INSTALL" "$_rbi_before"
      rl_manifest "$_rbi_backup" "$_rbi_after"
      if cmp -s "$_rbi_before" "$_rbi_after"; then
        rbi_note "backup already present and identical: $_rbi_backup"
      else
        rm -f "$_rbi_before" "$_rbi_after"
        rbi_fail "backup_conflict: $_rbi_backup exists and is not identical to $RL_INSTALL; move it aside"
      fi
      rm -f "$_rbi_before" "$_rbi_after"
      rl_manifest "$RL_INSTALL" "$_rbi_backup/installed.sha256"
    else
      _rbi_before=$(mktemp)
      rl_manifest "$RL_INSTALL" "$_rbi_before"
      rbi_note "backing up the current installation to $_rbi_backup"
      cp -a "$RL_INSTALL" "$_rbi_backup" || rbi_fail "backup_failed: could not copy $RL_INSTALL to $_rbi_backup"
      _rbi_after=$(mktemp)
      rl_manifest "$_rbi_backup" "$_rbi_after"
      if ! cmp -s "$_rbi_before" "$_rbi_after"; then
        rm -f "$_rbi_before" "$_rbi_after"
        rbi_fail "backup_mismatch: the copy in $_rbi_backup does not match $RL_INSTALL file by file"
      fi
      rm -f "$_rbi_before" "$_rbi_after"
      rl_manifest "$_rbi_backup" "$_rbi_backup/installed.sha256"
      rbi_note 'backup verified: every file and byte of the current installation is preserved'
    fi
  fi
  # ---- name the release, keeping anything already at that name ----------------
  # The release directory is named by the commit the bundle was built from. A different
  # directory can legitimately hold that name - the rollback copy taken above is exactly that
  # when the same revision is installed from source first and then from a cross-built bundle -
  # so on any clash this release is named by its bundle hash instead of overwriting what is
  # there. The name is decided BEFORE the release is written, because the release records it:
  # `release_key` is what makes two releases of the same commit - one built on the phone, one
  # cross-built here - distinguishable to the switch and to `wa update --rollback`.
  _rbi_key=$_rbi_commit
  _rbi_reuse=0
  if [ -e "$RL_RELEASES/$_rbi_key" ]; then
    if [ "$(rl_get "$RL_RELEASES/$_rbi_key/installed.txt" bundle_manifest_sha256)" = "$_rbi_msha" ] &&
       rl_manifest_verify "$RL_RELEASES/$_rbi_key"; then
      _rbi_reuse=1
    else
      _rbi_key="$_rbi_commit+bundle.$(printf '%.12s' "$_rbi_msha")"
    fi
  fi
  # ---- stage the bundle as a release directory --------------------------------
  rm -rf -- "$_rbi_stage"
  mkdir -p -- "$_rbi_stage/bin" "$_rbi_stage/ui"
  install -m 755 "$_rbi_bundle/wa" "$_rbi_stage/wa" || rbi_fail 'assemble_failed: wa'
  install -m 755 "$_rbi_bundle/bin/wa" "$_rbi_stage/bin/wa" || rbi_fail 'assemble_failed: bin/wa'
  install -m 755 "$_rbi_bundle/bin/wa-update" "$_rbi_stage/bin/wa-update" ||
    rbi_fail 'assemble_failed: bin/wa-update'
  install -m 644 "$_rbi_bundle/bin/release-lib.sh" "$_rbi_stage/bin/release-lib.sh" ||
    rbi_fail 'assemble_failed: bin/release-lib.sh'
  for _rbi_a in $RL_UI_ASSETS; do
    install -m 644 "$_rbi_bundle/ui/$_rbi_a" "$_rbi_stage/ui/$_rbi_a" || rbi_fail "assemble_failed: ui/$_rbi_a"
  done
  install -m 644 "$_rbi_bundle/LICENSE" "$_rbi_stage/LICENSE" || rbi_fail 'assemble_failed: LICENSE'
  rl_write_installed "$_rbi_stage/installed.txt" "$_rbi_commit" "$_rbi_remote" \
    "${_rbi_existing:--}" 'bundle-install' 'cross-android' 'cross-built-android' "$_rbi_key"
  # The build facts, kept where `wa doctor`, an operator and a later update can all read them.
  {
    printf 'bundle_manifest_sha256=%s\n' "$_rbi_msha"
    printf 'target_triple=%s\n' "$_rbi_target"
    printf 'source_tree_sha256=%s\n' "$_rbi_tree"
    printf 'ndk_version=%s\n' "$_rbi_ndk"
    printf 'rustc_version=%s\n' "$_rbi_rustc"
  } >> "$_rbi_stage/installed.txt"
  rl_manifest "$_rbi_stage" "$_rbi_stage/installed.sha256"
  rl_verify_release "$_rbi_stage" ||
    rbi_fail 'candidate_refused: the staged release did not verify (see above); nothing was switched'
  if [ "$_rbi_reuse" = 1 ]; then
    rm -rf -- "$_rbi_stage"
    rbi_note "reusing the verified release already at $RL_RELEASES/$_rbi_key"
  fi
  if [ -z "$_rbi_existing" ]; then
    mv -- "$_rbi_stage" "$RL_INSTALL" || rbi_fail "install_failed: cannot place $RL_INSTALL"
  else
    if [ "$_rbi_reuse" = 0 ]; then
      mv -- "$_rbi_stage" "$RL_RELEASES/$_rbi_key" ||
        rbi_fail "install_failed: cannot place the release in $RL_RELEASES"
    fi
    rl_activate "$_rbi_key"
  fi
  if [ ! -e "$RL_PREFIX/bin/wa" ] && [ ! -L "$RL_PREFIX/bin/wa" ]; then
    ln -s "$RL_INSTALL/bin/wa" "$RL_PREFIX/bin/wa" ||
      rbi_fail "launcher_failed: cannot link $RL_PREFIX/bin/wa"
  fi
  # ---- what was installed, and what is still unproven -------------------------
  rbi_note "installed $_rbi_commit, cross-built for $_rbi_target (NDK ${_rbi_ndk:-unknown}, rustc ${_rbi_rustc:-unknown})"
  rbi_note "bundle manifest sha256: $_rbi_msha"
  if [ -n "$_rbi_existing" ]; then
    rbi_note "previous release kept at $RL_RELEASES/$_rbi_existing; roll back with: wa update --rollback"
  fi
  rbi_note 'this runtime was NOT compiled on this phone: "wa doctor" reports build_profile=cross-android'
  rbi_note 'node state under ~/.wasm-agent was not read, copied or written, and wa setup was not run.'
  rbi_note 'restart the UI to run the new runtime: Ctrl-C, then wa ui'
  RL_BUNDLE_RESULT=installed
  return 0
}

# Put a release at the active path. Two same-filesystem renames with a recorded intent:
# a crash between them is recoverable (see rl_recover), and the previous release is kept
# under its own name in $RL_RELEASES, which is the rollback.
#
# WHICH RELEASE IS ACTIVE is the NAME it was switched in under, not just its source commit.
# Two releases can carry the same commit and still be different bytes - one built on the
# phone, one cross-built on a desktop and installed from a prebuilt bundle - and those must
# be able to replace each other, and roll back to each other, without either being silently
# thrown away as "already active". A prebuilt bundle records that name as `release_key` in
# installed.txt; every other path records no key, and then the commit IS the key, so a
# phone-built release behaves exactly as it did before this line existed.
rl_activate() { # <release_key>
  _rl_target=$1
  [ -d "$RL_RELEASES/$_rl_target" ] || rl_fail "release_missing: $RL_RELEASES/$_rl_target"
  _rl_cur=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
  [ -n "$_rl_cur" ] || rl_fail "installed_revision_unknown: $RL_INSTALL/installed.txt has no source_commit"
  _rl_cur_key=$(rl_get "$RL_INSTALL/installed.txt" release_key)
  [ -n "$_rl_cur_key" ] || _rl_cur_key=$_rl_cur
  if [ "$_rl_cur_key" = "$_rl_target" ]; then
    rl_note "termux-update: $_rl_target is already active"
    return 0
  fi
  mkdir -p -- "$RL_RELEASES" "$RL_UPDATE" || rl_fail "activate_failed: cannot create $RL_RELEASES"
  chmod 700 "$RL_UPDATE" 2>/dev/null || true
  if [ -d "$RL_RELEASES/$_rl_cur_key" ]; then
    _rl_retire="$RL_UPDATE/.trash.$$"
  else
    # The release being replaced is not in $RL_RELEASES under its own key - it was switched
    # in from there, or it is a bundle release whose key is not its commit. Keep it under
    # that key, so a rollback can be rolled forward again instead of destroying it.
    _rl_retire="$RL_RELEASES/$_rl_cur_key"
  fi
  printf '%s %s\n' "$_rl_cur_key" "$_rl_target" > "$RL_UPDATE/switch.intent"
  mv -- "$RL_INSTALL" "$_rl_retire" || rl_fail "switch_failed: could not set aside $_rl_cur_key"
  if ! mv -- "$RL_RELEASES/$_rl_target" "$RL_INSTALL"; then
    mv -- "$_rl_retire" "$RL_INSTALL"
    rl_fail "switch_failed: could not install $_rl_target; the previous release is back in place"
  fi
  if [ "$_rl_retire" = "$RL_UPDATE/.trash.$$" ]; then rm -rf -- "$_rl_retire"; fi
  rm -f -- "$RL_UPDATE/switch.intent"
  rl_note "termux-update: active release $_rl_cur_key -> $_rl_target"
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
