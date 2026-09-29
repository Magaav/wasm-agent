#!/usr/bin/env bash
# One machine, one answer to "where does the deployed node live".
#
# Sourced, never executed, and side-effect free: it defines functions only, so a caller that sets `-e` is
# not disturbed and nothing runs just because this file was read.
#
# Why it exists. On 2026-09-29 a cloud node looped 61,117 times. The systemd unit ran
# `/home/ubuntu/.local/share/wasm-agent/wa` - a ten-day-old install - while the deploy, and the process
# actually serving, were at `/home/ubuntu/.local/bin/wa`. The unit's process started, failed to bind
# (`Address already in use (os error 98)`), exited 0, and systemd restarted it three seconds later,
# forever; the deploy in the meantime reported success. Nothing was broken in either script: there were
# simply *two* answers to "where does the node live" - `deploy.sh` defaulted to `~/.local/share/wasm-agent`,
# `upgrade.sh` defaults to `~/.local/bin` on Linux, and the unit named a third of its own - and no one was
# asked which one the machine runs.
#
# So this file holds the one expression for that question, and it answers with what the machine *does*,
# in this order:
#
#   1. `WA_INSTALL_DIR`, when the caller has said where - an override, not a discovery (see below);
#   2. the service definition's `ExecStart`: the binary the service actually executes. On Linux that is
#      systemd's own effective value (`systemctl show -p ExecStart`), which is the only thing that knows
#      about drop-ins, and the unit file plus its `.d/*.conf` when systemd cannot be asked;
#   3. the node process holding the node's port: on a machine with no unit (Windows runs the node as a
#      detached child, not a service) the running process is the only witness that exists;
#   4. the historical default, unchanged, for a first install on a machine that has neither.
#
# Steps 2 and 3 are *claims the machine makes*, and `wa_service_install_dir` hands them to the caller with
# the sentence that says where the answer came from, so a refusal can name both paths and their source
# instead of saying "mismatch". `wa_install_target` is the target for a deploy; a caller that passed
# `WA_INSTALL_DIR` and gets back a different `wa_service_install_dir` has a disagreement to refuse, not to
# resolve on the operator's behalf.
#
# Every probe is read-only. Nothing here writes, starts, stops or deploys anything.

# --- the node's own directories ----------------------------------------------------------------
# `WASM_AGENT_HOME` is the *home*, and the config lives under it - this is what the node itself uses
# (rust/wa-host/src/main.rs resolve_home, lua/core/paths.lua paths.config()). `upgrade.sh` reads the same
# variable as if it were the config directory itself (`HOME_DIR="${WASM_AGENT_HOME:-$HOME/.wasm-agent}"`),
# which is the other half of this class: two expressions, one place. This function is the one expression.
wa_home_dir() {
  if [ -n "${WASM_AGENT_HOME:-}" ]; then printf '%s' "$WASM_AGENT_HOME"; return 0; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) if [ -n "${USERPROFILE:-}" ]; then wa_posix_path "$USERPROFILE"; return 0; fi ;;
  esac
  printf '%s' "${HOME:-.}"
}

wa_config_dir() { printf '%s/.wasm-agent' "$(wa_home_dir)"; }

# A native path (`C:\Users\x`) and a shell path (`/c/Users/x`) are the same directory and different strings,
# which is exactly how a string comparison of two paths becomes a false verdict. Everything this file returns
# is in the shell's own form.
wa_posix_path() {
  local value="$1"
  case "$value" in
    [A-Za-z]:[\\/]*|*\\*)
      if command -v cygpath >/dev/null 2>&1; then cygpath -u "$value" 2>/dev/null || printf '%s' "$value"; return 0; fi ;;
  esac
  printf '%s' "$value"
}

# Same directory? A trailing slash, a `..`, a symlinked directory or a native-vs-POSIX spelling are not
# disagreements, and `pwd -P` is the only cheap way to say so.
wa_same_dir() {
  local a b
  a="$(wa_posix_path "$1")"; b="$(wa_posix_path "$2")"
  a="${a%/}"; b="${b%/}"
  if [ -d "$a" ] && [ -d "$b" ]; then
    a="$(cd "$a" 2>/dev/null && pwd -P)" || true
    b="$(cd "$b" 2>/dev/null && pwd -P)" || true
  fi
  [ "$a" = "$b" ]
}

# --- the service definition ---------------------------------------------------------------------
wa_service_unit() { printf '%s' "${1:-${WA_SERVICE_UNIT:-wa-serve.service}}"; }

# Where the unit lives on this machine, or empty. `WA_SERVICE_UNIT_FILE` is the seam a fixture uses (and an
# operator on a machine whose units live somewhere else): one file, read the same way as a real one.
wa_service_unit_file() {
  local unit file
  if [ -n "${WA_SERVICE_UNIT_FILE:-}" ]; then printf '%s' "$WA_SERVICE_UNIT_FILE"; return 0; fi
  unit="$(wa_service_unit "${1:-}")"
  case "$unit" in /*) [ -f "$unit" ] && printf '%s' "$unit"; return 0 ;; esac
  for file in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system \
              /lib/systemd/system /usr/lib/systemd/system; do
    if [ -f "$file/$unit" ]; then printf '%s' "$file/$unit"; return 0; fi
  done
  printf ''
}

# The effective `ExecStart`, drop-ins applied, from a unit file.
#
# systemd's rule: an empty assignment resets the list, and a later one replaces what came before. So the last
# non-empty assignment wins - which is what an operator who wrote `ExecStart=` then `ExecStart=/new/path`
# meant, and what a drop-in that only appends would still be read as. Where systemd itself can be asked,
# `wa_service_exec_start` asks it instead and this parser is only the fallback.
wa_service_exec_line() {
  local file="$1" line="" drop value
  [ -f "$file" ] || { printf ''; return 0; }
  line="$(sed -n 's/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*//p' "$file" 2>/dev/null | tail -1)"
  for drop in "$file".d/*.conf; do
    [ -f "$drop" ] || continue
    if grep -qE '^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*$' "$drop" 2>/dev/null; then line=""; fi
    value="$(sed -n 's/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*//p' "$drop" 2>/dev/null | tail -1)"
    [ -n "$value" ] && line="$value"
  done
  printf '%s' "$line"
}

wa_service_exec_start() {
  local unit value file
  if [ -n "${WA_SERVICE_UNIT_FILE:-}" ]; then wa_service_exec_line "${WA_SERVICE_UNIT_FILE}"; return 0; fi
  unit="$(wa_service_unit "${1:-}")"
  if command -v systemctl >/dev/null 2>&1; then
    # systemd's own answer, drop-ins and all: `{ path=/home/ubuntu/.local/bin/wa ; argv[]=... ; ... }`.
    value="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null | tr -d '\r')"
    case "$value" in *path=*) printf '%s' "$value"; return 0 ;; esac
  fi
  file="$(wa_service_unit_file "$unit")"
  [ -n "$file" ] && wa_service_exec_line "$file"
}

# The binary out of an ExecStart line, whether it is a systemd property dump or a plain command line.
#
# One rule for both shapes: turning `=` and brackets into spaces makes the tokens uniform, and the first
# absolute path that is not an interpreter is the binary. Flags, `path=`, `argv[]=` and relative tokens are
# skipped rather than guessed at; a line with nothing absolute in it returns empty on purpose, because a
# check that invents a directory is worse than one that says it cannot tell. `bash -lc '/opt/wa serve'` is
# read as /opt/wa, which is what it runs.
wa_exec_binary() {
  local line="$1" token bin=""
  for token in $(printf '%s' "$line" | tr '[]=' '   ' | tr '\042\047\015' ' '); do
    case "$token" in /*|[A-Za-z]:[\\/]*) ;; *) continue ;; esac
    case "${token##*/}" in
      env|nice|nohup|setsid|stdbuf|sh|bash|dash|zsh|python|python3) continue ;;
    esac
    bin="$token"
    break
  done
  printf '%s' "$bin"
}

# The pid systemd says the unit is running, empty when it is not (0 means "not running").
wa_service_pid() {
  local unit value
  if [ -n "${WA_SERVICE_PID:-}" ]; then printf '%s' "$WA_SERVICE_PID"; return 0; fi
  command -v systemctl >/dev/null 2>&1 || return 0
  unit="$(wa_service_unit "${1:-}")"
  value="$(systemctl show "$unit" -p MainPID --value 2>/dev/null | tr -d '\r')"
  case "$value" in ''|0) printf '' ;; *) printf '%s' "$value" ;; esac
}

# --- the running node --------------------------------------------------------------------------
# The pid listening on a TCP port, empty when nothing is or when this machine cannot be asked. `ss` first
# because it names the pid directly; `netstat -ano` on Windows, matching the *local* address only.
wa_port_pid() {
  local port="$1" pid=""
  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" { if (match($0,/pid=[0-9]+/)) { print substr($0,RSTART+4,RLENGTH-4); exit } }')"
  fi
  if [ -z "$pid" ] && command -v netstat >/dev/null 2>&1; then
    pid="$(netstat -ano -p TCP 2>/dev/null | awk -v p=":$port" '$1=="TCP" && $2 ~ p"$" && $4=="LISTENING" { print $5; exit }' | tr -d '\r')"
  fi
  printf '%s' "$pid"
}

# The executable a pid is running. `/proc` on Linux (a symlink); `WA_PROC_ROOT` is the seam a fixture on a
# machine without /proc points at a synthetic tree, which holds the same three files the kernel does. On
# Windows there is no /proc at all, so the answer comes from PowerShell (or wmic) - a pid nobody can name is
# still worth reporting, and the caller does that.
wa_pid_image() {
  local pid="$1" root="${WA_PROC_ROOT:-/proc}" link
  if [ -n "$pid" ] && [ -e "$root/$pid" ]; then
    if [ -L "$root/$pid/exe" ]; then link="$(readlink "$root/$pid/exe" 2>/dev/null)"
    elif [ -f "$root/$pid/exe" ]; then link="$(tr -d '\r\n' < "$root/$pid/exe" 2>/dev/null)"
    fi
    [ -n "$link" ] && { printf '%s' "$link"; return 0; }
    link="$(tr '\0' ' ' < "$root/$pid/cmdline" 2>/dev/null | awk '{print $1}')"
    [ -n "$link" ] && { printf '%s' "$link"; return 0; }
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    link="$(powershell.exe -NoProfile -Command "(Get-Process -Id $pid -ErrorAction SilentlyContinue).Path" 2>/dev/null | tr -d '\r\n')"
  fi
  if [ -z "${link:-}" ] && command -v wmic >/dev/null 2>&1; then
    link="$(wmic process where "processid=$pid" get ExecutablePath 2>/dev/null | tr -d '\r' | sed -n '2p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  case "${link:-}" in
    /*|[A-Za-z]:[\\/]*) printf '%s' "$link" ;;
    *) printf '' ;;
  esac
}

# The parent pid, for the sentence that names a stray. The `/proc/<pid>/stat` shape is
# `pid (comm) state ppid ...`, and `comm` may contain spaces and parentheses, so the fields are taken from
# after the last ')' rather than by column.
wa_pid_ppid() {
  local pid="$1" root="${WA_PROC_ROOT:-/proc}" rest ppid=""
  if [ -n "$pid" ] && [ -f "$root/$pid/stat" ]; then
    rest="$(cat "$root/$pid/stat" 2>/dev/null)"
    rest="${rest##*)}"
    ppid="$(printf '%s' "$rest" | awk '{print $2}')"
    [ "$ppid" = "0" ] && ppid=""   # pid 1's parent is the kernel; "0" is not a pid to look up
  fi
  if [ -z "$ppid" ] && command -v powershell.exe >/dev/null 2>&1; then
    ppid="$(powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \"ProcessId=$pid\" -ErrorAction SilentlyContinue).ParentProcessId" 2>/dev/null | tr -d '\r\n')"
  fi
  printf '%s' "$ppid"
}

# A one-line description of a pid for a refusal: `pid 644564 (ppid 1, running /home/ubuntu/.local/bin/wa)`.
wa_pid_label() {
  local pid="$1" image ppid
  [ -n "$pid" ] || { printf 'no process'; return 0; }
  image="$(wa_pid_image "$pid")"
  ppid="$(wa_pid_ppid "$pid")"
  printf 'pid %s (ppid %s%s)' "$pid" "${ppid:-unknown}" "${image:+, running $image}"
}

# --- the machine's claim, and the deploy's target -----------------------------------------------
# Prints two lines: the directory the machine says its node lives in, then the sentence that says which
# source answered. Both can be empty, and empty means the machine made no claim this could read - which is
# a fact the caller must report, not an answer it may assume.
#
# Two lines rather than one plus a variable, because a caller captures this in `$(...)` - a subshell - and
# an assignment made in here would not survive it. `wa_read_service_claim` is the reader callers should use;
# it fills WA_SERVICE_DIR and WA_SERVICE_CLAIM in the caller's own shell.
wa_service_install_dir() {
  local unit="$1" line bin dir pid image
  line="$(wa_service_exec_start "$unit")"
  if [ -n "$line" ]; then
    bin="$(wa_exec_binary "$line")"
    if [ -n "$bin" ]; then
      bin="$(wa_posix_path "$bin")"
      dir="${bin%/*}"
      if [ -n "$dir" ] && [ "$dir" != "$bin" ]; then
        printf '%s\n' "$dir"
        printf '%s\n' "the service $(wa_service_unit "$unit") runs $bin"
        return 0
      fi
    fi
  fi
  # No unit this can read. The process holding the node's port is the other statement the machine makes;
  # a witness is only a claim when the path is absolute and its directory is really there. Nothing is printed
  # when there is no witness: `wa_read_service_claim` reads line one as the directory and line two as the
  # sentence that came with it, so an answer and its source are never emitted apart.
  pid="$(wa_port_pid "${WA_PORT:-8799}")"
  [ -n "$pid" ] || return 0
  image="$(wa_pid_image "$pid")"
  [ -n "$image" ] || return 0
  image="$(wa_posix_path "$image")"
  dir="${image%/*}"
  [ -n "$dir" ] && [ "$dir" != "$image" ] && [ -d "$dir" ] || return 0
  printf '%s\n' "$dir"
  printf '%s\n' "the node on port ${WA_PORT:-8799} runs $image"
}

# Where a deploy should install. `WA_INSTALL_DIR` when set - the caller has spoken, and whether it disagrees
# with the machine is the caller's check to make - else the machine's claim, else the historical default.
wa_install_target() {
  local claimed
  if [ -n "${WA_INSTALL_DIR:-}" ]; then printf '%s' "$WA_INSTALL_DIR"; return 0; fi
  claimed="$(wa_service_install_dir "${WA_SERVICE_UNIT:-}" | sed -n 1p)"
  if [ -n "$claimed" ]; then printf '%s' "$claimed"; return 0; fi
  wa_default_install_dir
}

# Fills WA_SERVICE_DIR / WA_SERVICE_CLAIM in the caller's shell, from one probe.
wa_read_service_claim() {
  local out
  out="$(wa_service_install_dir "${1:-}")"
  WA_SERVICE_DIR="$(printf '%s' "$out" | sed -n 1p)"
  WA_SERVICE_CLAIM="$(printf '%s' "$out" | sed -n 2p)"
}

# The same question about the supervisor's unit, for an installer that has just placed a sentinel somewhere.
wa_sentinel_service_dir() { wa_service_install_dir "${WA_SENTINEL_UNIT:-wa-sentinel.service}" | sed -n 1p; }

# The default this project has always used, kept as the last resort rather than the first answer. On Windows
# the same directory was spelled `$HOME/AppData/Local/wasm-agent` and `$LOCALAPPDATA/wasm-agent` in two
# scripts; `LOCALAPPDATA` is the one both mean, and it is returned in shell form.
wa_default_install_dir() {
  local first second
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      first="$(wa_posix_path "${LOCALAPPDATA:-$(wa_home_dir)/AppData/Local}")/wasm-agent" ;;
    *) first="$(wa_home_dir)/AppData/Local/wasm-agent" ;;
  esac
  second="$(wa_home_dir)/.local/share/wasm-agent"
  if [ -d "$second" ] && [ ! -d "$first" ]; then printf '%s' "$second"; else printf '%s' "$first"; fi
}
