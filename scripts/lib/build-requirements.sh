# What a build needs on this machine, checked in a blink and provisioned when it is missing (29/10).
#
# Sourced by deploy.sh (the one rebuild path; the sentinel runs it) and runnable on its own:
#   bash scripts/lib/build-requirements.sh check [ROOT]   # one line per requirement, exit 1 if any is missing
#
# THE CHECK IS STATS, NOT RUNS. No cargo invocation, no network: a toolchain's version is read from the file
# rustup writes beside it, node's from one `--version`, the assets from their receipt, the disk from `df`.
# Measured in the sandbox: ~40 ms for all of it when everything is present - so it runs on every deploy and
# a missing piece is named before anything is built, instead of surfacing as a build error that names no cause.
#
# PROVISIONING IS OPT-IN (WA_BUILD_PROVISION=1, e.g. from <home>/.wasm-agent/build.env). A deploy on a node
# nobody asked to download toolchains refuses by name, exactly as before (`refused(cargo_unavailable)`);
# the sandbox, which wants the sentinel to fetch what it lacks, says so in its build.env. Everything fetched
# is pinned or checksum-verified: rustup-init against the .sha256 published beside it (rustup then verifies
# each component), Node against the release's SHASUMS256.txt at the version scripts/install.sh pins, the
# code-mode assets by scripts/provision-codemode-assets.mjs (integrity-pinned) - which deploy.sh did already.
# A C compiler, ripgrep and git are system packages: no user-level install, so they are refused by name.
#
# <home>/.wasm-agent/build.env carries a node build record, KEY=VALUE, and ONLY the keys named in
# WA_BUILD_ENV_KEYS are read (it is data, never sourced). Item 3 of the node-ops round: the record is the
# ONE place a toolchain directory, zig, the target-dir policy, the code-mode assets and the wasi-sdk are
# written down, and every build entry point - scripts/fast.sh, wa land, scripts/deploy.sh and
# scripts/mission.sh - reads it here instead of each guessing from its own ambient environment.
#   WA_BUILD_PATH          extra tool directories, colon-separated, searched last
#   WA_BUILD_PROVISION     fetch a missing toolchain instead of refusing
#   WA_BUILD_ZIG           the zig binary a cross build links with
#   WASI_SDK_PATH          the wasi-sdk whose sysroot the components build against
#   WA_BUILD_CARGO_TARGET  the target-directory policy (oneroot is the default; docs/ONEROOT.md)
#   CARGO_BUILD_JOBS, CARGO_INCREMENTAL, CARGO_PROFILE_RELEASE_OPT_LEVEL, WA_UPGRADE_IDLE_POLL
# A key that is not in that list is IGNORED and said so by wa_build_env_audit: a setting that looks
# applied and is not is worse than no record at all.
# The allow-list, in one place, as data: every entry a build may read from the record. A name is added
# here with the face that consumes it, never read ad hoc at the point of use.
WA_BUILD_ENV_KEYS="WA_BUILD_PATH WA_BUILD_PROVISION WA_BUILD_ZIG WASI_SDK_PATH WA_BUILD_CARGO_TARGET CARGO_BUILD_JOBS CARGO_INCREMENTAL CARGO_PROFILE_RELEASE_OPT_LEVEL WA_UPGRADE_IDLE_POLL"

# What each entry means and, when it is missing or unusable, the ONE line that fixes it.
wa_build_env_help() { # <key> -> "meaning<TAB>fix"
  case "$1" in
    WA_BUILD_PATH) printf 'extra tool directories, colon-separated, searched last\tadd the directory: WA_BUILD_PATH=/opt/zig:/opt/wasi-sdk/bin' ;;
    WA_BUILD_PROVISION) printf 'fetch a missing toolchain instead of refusing\tset WA_BUILD_PROVISION=1 when this node may download rustup/node' ;;
    WA_BUILD_ZIG) printf 'the zig binary a cross build links with\tset WA_BUILD_ZIG=/path/to/zig (scripts/provision-publish-toolchain.sh installs a pinned one)' ;;
    WASI_SDK_PATH) printf 'the wasi-sdk whose sysroot the components build against\tset WASI_SDK_PATH=/opt/wasi-sdk-24' ;;
    WA_BUILD_CARGO_TARGET) printf 'the target-directory policy a build uses: oneroot is the default (docs/ONEROOT.md)\tset WA_BUILD_CARGO_TARGET=oneroot, or leave it unset for the default' ;;
    *) printf 'unknown build.env key\tremove it: only WA_BUILD_ENV_KEYS are read' ;;
  esac
}

# Does the record exist, and is every line in it one a build reads?
#
# A key nobody reads is a REFUSAL: it looks applied and is not, and a machine can spend a day believing it
# set a toolchain directory that no build ever looked at. A MISSING record is not a refusal: a node that
# never needed one builds from its ambient environment exactly as before.
wa_build_env_audit() { # [ROOT] -> prints one line per fact; WA_BUILD_ENV_PROBLEM names the first refusal
  local root=${1:-${WASM_AGENT_HOME:-$HOME}} file key value known entry
  WA_BUILD_ENV_PROBLEM=""
  file="$root/.wasm-agent/build.env"
  if [ ! -f "$file" ]; then
    printf 'record  absent  %s (a node with no record builds from its ambient environment; nothing to check)\n' "$file"
    return 0
  fi
  printf 'record  %s\n' "$file"
  while IFS='=' read -r key value; do
    case "$key" in ''|'#'*) continue ;; esac
    known=0
    for entry in $WA_BUILD_ENV_KEYS; do [ "$entry" = "$key" ] && known=1 && break; done
    if [ "$known" = 1 ]; then
      printf 'entry   %-30s %s\n' "$key" "${value:-(empty)}"
    else
      printf 'unknown %-30s not read by any build: remove it, or add it to WA_BUILD_ENV_KEYS with the face that consumes it\n' "$key"
      [ -n "$WA_BUILD_ENV_PROBLEM" ] || WA_BUILD_ENV_PROBLEM="build_env_key_unknown:$key"
    fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null)
  # The problem line is part of the AUDIT OUTPUT, not only a variable: an audit read through a command
  # substitution runs in a subshell, so a caller that captured the text would lose the variable and be
  # left with a refusal that names nothing.
  if [ -n "$WA_BUILD_ENV_PROBLEM" ]; then
    printf 'problem %s\n' "$WA_BUILD_ENV_PROBLEM"
    return 1
  fi
  return 0
}

# One requirement's named refusal with its remedy.
#   refused(<code>): <what>. Fix: <the one line>
wa_build_env_refuse() { # <code> <what>
  local code=$1 what=$2 help
  help="$(wa_build_env_help "$code")"
  printf 'refused(%s): %s. Fix: %s\n' "$code" "$what" "${help#*$(printf '\t')}" >&2
}
WA_RUST_MIN_DEFAULT="1.89"   # std File::lock (wa-sentinel) is the newest std API the tree needs
WA_BUILD_MISSING=""

wa_build_env() { # reads build.env: EXPORTS every key it audits, puts tool directories on PATH
  local file="${WASM_AGENT_HOME:-$HOME}/.wasm-agent/build.env" key value dir entry known
  if [ -f "$file" ]; then
    while IFS='=' read -r key value; do
      case "$key" in ''|'#'*) continue ;; esac
      # AN ENTRY THE AUDIT ACCEPTS IS AN ENTRY THIS FUNCTION APPLIES (item 3/6 of the node-ops round).
      # Measured 19/11: the audit listed WA_BUILD_ZIG, WASI_SDK_PATH and WA_BUILD_CARGO_TARGET as read
      # entries, and this function exported none of them - a node set a toolchain directory nothing
      # looked at, which is the exact defect the audit exists to catch, one level deeper. The allow-list
      # is the same list: nobody edits two places to add a key.
      known=0
      for entry in $WA_BUILD_ENV_KEYS; do [ "$entry" = "$key" ] && known=1 && break; done
      [ "$known" = 1 ] || continue
      # A QUOTED VALUE IS UNQUOTED (item 8 of the node-ops round): an operator who writes
      # WASI_SDK_PATH='/opt/wasi-sdk' in the record meant that directory, and a shell that exported the
      # quotes as part of the value named a path that does not exist - the audit then refused a record
      # that was in fact correct. One pair of matching single or double quotes is removed; anything else
      # is handed over exactly as written, because a path may legitimately contain a quote.
      value="$(printf '%s' "$value" | sed -e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/')"
      # A key that is there and EMPTY is reported by the audit and applied as empty, never silently kept
      # from the ambient environment: 'I set it' and 'it is set' would then differ with nothing saying so.
      export "$key=$value"
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null)
  fi
  # A NAMED DIRECTORY THAT IS NOT THERE IS A REFUSAL, not a silent fallback: the record said where the
  # tool is, and a build that quietly used another one is the confusion WA_BUILD_ENV_KEYS exists to end.
  # wa_build_env_refuse is the ONE printer of that refusal, so fast.sh, deploy.sh and wa land say the
  # same thing with the same one-line fix (item 6 of the node-ops round: a missing entry is refused by
  # name, never discovered later as a build error that names no cause).
  if [ -n "${WA_BUILD_ZIG:-}" ] && [ ! -x "${WA_BUILD_ZIG}" ]; then
    wa_build_env_refuse WA_BUILD_ZIG "${WA_BUILD_ZIG} is named by $file and is not an executable file"
    return 2
  fi
  if [ -n "${WASI_SDK_PATH:-}" ] && [ ! -d "${WASI_SDK_PATH}/share/wasi-sysroot" ]; then
    wa_build_env_refuse WASI_SDK_PATH "${WASI_SDK_PATH} is named by $file and holds no share/wasi-sysroot, so no component can build against it"
    return 2
  fi
  # WA_BUILD_ZIG is a FILE, and the directories a build searches come from its directory and from the
  # wasi-sdk root: a record that names them is enough, the caller does not also have to name a PATH.
  [ -n "${WA_BUILD_ZIG:-}" ] && [ -d "$(dirname "$WA_BUILD_ZIG")" ] && WA_BUILD_PATH="${WA_BUILD_PATH:+$WA_BUILD_PATH:}$(dirname "$WA_BUILD_ZIG")"
  [ -n "${WASI_SDK_PATH:-}" ] && [ -d "$WASI_SDK_PATH/bin" ] && WA_BUILD_PATH="${WA_BUILD_PATH:+$WA_BUILD_PATH:}$WASI_SDK_PATH/bin"
  # WA_BUILD_CARGO_TARGET is a POLICY name, not a path: `oneroot` is the default (docs/ONEROOT.md) and a
  # build reads it through scripts/lib/build-target.sh. It is exported above like every other key, and
  # nothing here turns it into CARGO_TARGET_DIR - a record may say which policy, not which directory a
  # caller's own target dir is.
  local IFS=:
  # `.../.wasm-agent/bin` is the node's own tool directory (`host.paths().bin`), where it stages the
  # ripgrep it runs with. Without it here, a deploy started by the sentinel cannot see the rg the node
  # already provisioned and refuses `rg_unavailable` - measured 2026-11-03 on this node, whose
  # ~/.wasm-agent/bin/rg had been there since July while the deploy's PATH never named it.
  for dir in "${CARGO_HOME:-$HOME/.cargo}/bin" "${WASM_AGENT_HOME:-$HOME}/.wasm-agent/node/bin" "${WASM_AGENT_HOME:-$HOME}/.wasm-agent/bin" ${WA_BUILD_PATH:-}; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    case ":$PATH:" in *":$dir:"*) ;; *) PATH="$PATH:$dir" ;; esac
  done
  export PATH WA_BUILD_PATH
}
wa_version_ge() { # A B: is version A >= B (dotted numbers)
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

wa_rust_min() { # ROOT: the newest rust-version a manifest declares, else the default
  local min="$WA_RUST_MIN_DEFAULT" v
  for v in $(sed -n 's/^rust-version *= *"\([0-9.]*\)".*/\1/p' "$1"/rust/Cargo.toml "$1"/rust/*/Cargo.toml 2>/dev/null); do
    wa_version_ge "$v" "$min" && min="$v"
  done
  printf '%s' "$min"
}

wa_rust_toolchain() { # ROOT: the toolchain rustup would pick here (pinned file, else the default)
  local pin="" file
  for file in "$1/rust-toolchain.toml" "$1/rust-toolchain" "$1/rust/rust-toolchain.toml" "$1/rust/rust-toolchain"; do
    [ -f "$file" ] || continue
    pin="$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$file" | head -1)"
    [ -n "$pin" ] || pin="$(head -1 "$file" | tr -d '[:space:]')"
    break
  done
  if [ -z "$pin" ]; then
    pin="$(sed -n 's/^default_toolchain *= *"\([^"]*\)".*/\1/p' "${RUSTUP_HOME:-$HOME/.rustup}/settings.toml" 2>/dev/null | head -1)"
  fi
  printf '%s' "$pin"
}

wa_rust_version() { # ROOT: the rustc version that would build here, from rustup's manifest when it has one
  local tc dir manifest
  tc="$(wa_rust_toolchain "$1")"
  if [ -n "$tc" ]; then
    for dir in "${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$tc" "${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$tc-$(uname -m)-unknown-linux-gnu"; do
      manifest="$dir/lib/rustlib/multirust-channel-manifest.toml"
      [ -f "$manifest" ] || continue
      grep -m1 -A1 '^\[pkg\.rustc\]' "$manifest" | sed -n 's/^version *= *"\([0-9.]*\).*/\1/p'
      return 0
    done
    # A pinned toolchain rustup has not installed is missing, whatever else is on PATH.
    command -v rustup >/dev/null 2>&1 && return 0
  fi
  rustc --version 2>/dev/null | sed -n 's/^rustc \([0-9.]*\).*/\1/p'
}

wa_codemode_assets_dir() { # ROOT
  printf '%s/codemode-assets/pi-1.2.0-quickjs-3.6.2' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
}

# wa_build_check ROOT: prints `ok|missing <what> <detail>` per requirement; WA_BUILD_MISSING lists the ids.
wa_build_check() {
  local root="$1" have min node_v floor
  WA_BUILD_MISSING=""
  _req() { # id ok? detail
    if [ "$2" = 1 ]; then printf 'ok      %-9s %s\n' "$1" "$3"; else printf 'missing %-9s %s\n' "$1" "$3"; WA_BUILD_MISSING="$WA_BUILD_MISSING $1"; fi
  }
  command -v git >/dev/null 2>&1 && _req git 1 "$(command -v git)" || _req git 0 "git is not on PATH (a system package)"
  min="$(wa_rust_min "$root")"
  if ! command -v cargo >/dev/null 2>&1; then
    _req cargo 0 "cargo is not on PATH (PATH=$PATH)"
  else
    have="$(wa_rust_version "$root")"
    if [ -z "$have" ]; then _req cargo 0 "toolchain $(wa_rust_toolchain "$root") is not installed"
    elif wa_version_ge "$have" "$min"; then _req cargo 1 "rustc $have (needs >= $min)"
    else _req cargo 0 "rustc $have is older than $min"
    fi
  fi
  # Windows builds with MSVC, whose cl.exe is deliberately not on PATH (lua/core/toolchain.lua): not probed.
  if command -v cygpath >/dev/null 2>&1; then _req cc 1 "msvc (not probed here)"
  elif command -v cc >/dev/null 2>&1; then _req cc 1 "$(command -v cc)"
  else _req cc 0 "no C compiler (cc) for the native crates (sqlite, ring): install gcc/libc6-dev in the image, or name its directory in WA_BUILD_PATH"
  fi
  if command -v node >/dev/null 2>&1; then
    node_v="$(node --version 2>/dev/null | sed 's/^v//')"
    if wa_version_ge "${node_v:-0}" 18; then _req node 1 "node $node_v"; else _req node 0 "node ${node_v:-unreadable} is older than 18"; fi
  else
    _req node 0 "node is not on PATH"
  fi
  command -v rg >/dev/null 2>&1 && _req rg 1 "$(command -v rg)" || _req rg 0 "ripgrep (rg) is not on PATH; the shipping build stages it (a system package)"
  [ -f "$(wa_codemode_assets_dir "$root")/receipt.json" ] && _req assets 1 "$(wa_codemode_assets_dir "$root")" \
    || _req assets 0 "code-mode assets not prepared at $(wa_codemode_assets_dir "$root")"
  floor="$(dirname "${BASH_SOURCE[0]}")/../check-disk-floor.sh"
  # Below the measured floor is said, not refused: the floor is one gate run with its test binaries, and an
  # incremental build into an existing target needs far less. `low` is not in WA_BUILD_MISSING.
  if [ -f "$floor" ] && ! bash "$floor" --path "$root" >/dev/null 2>&1; then
    printf 'low     %-9s %s\n' disk "below the measured floor: $(bash "$floor" --path "$root" 2>&1 | sed -n 's/^ *free: *//p' | head -1)"
  else
    _req disk 1 "$(df -Pk "$root" 2>/dev/null | awk 'END { printf "%.1f GiB free", $(NF-2) / 1048576 }')"
  fi
  unset -f _req
  [ -z "$WA_BUILD_MISSING" ]
}

wa_build_fetch() { # URL FILE
  curl -fsSL --retry 2 --connect-timeout 15 "$1" -o "$2"
}
wa_build_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# wa_build_provision ROOT ID: fetch one missing requirement. Prints what it does; non-zero when it cannot.
wa_build_provision() {
  local root="$1" id="$2" tmp tc arch os version archive expected
  case "$id" in
    cargo)
      tc="$(wa_rust_toolchain "$root")"; tc="${tc:-stable}"
      if command -v rustup >/dev/null 2>&1; then
        echo "provision: rustup toolchain install $tc --profile minimal"
        rustup toolchain install "$tc" --profile minimal >/dev/null 2>&1 || rustup update "$tc" >/dev/null 2>&1 || return 1
      else
        arch="$(uname -m)"; case "$(uname -s)" in Linux) os=unknown-linux-gnu ;; Darwin) os=apple-darwin ;; *) return 1 ;; esac
        tmp="$(mktemp -d)" || return 1
        echo "provision: rustup-init ($arch-$os), checksum-verified, default toolchain $tc"
        if wa_build_fetch "https://static.rust-lang.org/rustup/dist/$arch-$os/rustup-init" "$tmp/rustup-init" \
          && wa_build_fetch "https://static.rust-lang.org/rustup/dist/$arch-$os/rustup-init.sha256" "$tmp/rustup-init.sha256" \
          && [ "$(awk '{print $1}' "$tmp/rustup-init.sha256")" = "$(wa_build_sha256 "$tmp/rustup-init")" ]; then
          chmod +x "$tmp/rustup-init" && "$tmp/rustup-init" -y --no-modify-path --profile minimal --default-toolchain "$tc" >/dev/null 2>&1 \
            || { rm -rf "$tmp"; return 1; }
        else
          echo "provision: rustup-init download or checksum failed"; rm -rf "$tmp"; return 1
        fi
        rm -rf "$tmp"
      fi
      wa_build_env ;;
    node)
      # The version scripts/install.sh pins, read from it: one pin for the installer and the build.
      version="$(sed -n 's/^NODE_VERSION="\([0-9.]*\)"/\1/p' "$root/scripts/install.sh" | head -1)"
      [ -n "$version" ] || return 1
      case "$(uname -m)" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac
      case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) return 1 ;; esac
      archive="node-v$version-$os-$arch.tar.gz"; tmp="$(mktemp -d)" || return 1
      echo "provision: node v$version ($archive), SHASUMS256-verified"
      if wa_build_fetch "https://nodejs.org/dist/v$version/$archive" "$tmp/$archive" \
        && wa_build_fetch "https://nodejs.org/dist/v$version/SHASUMS256.txt" "$tmp/SHASUMS256.txt"; then
        expected="$(awk -v f="$archive" '$2==f {print $1}' "$tmp/SHASUMS256.txt")"
        if [ -z "$expected" ] || [ "$expected" != "$(wa_build_sha256 "$tmp/$archive")" ]; then
          echo "provision: node checksum mismatch - not installing"; rm -rf "$tmp"; return 1
        fi
        local dest="${WASM_AGENT_HOME:-$HOME}/.wasm-agent/node"
        rm -rf "$dest.new" && mkdir -p "$dest.new" && tar -xzf "$tmp/$archive" -C "$dest.new" --strip-components=1 \
          && rm -rf "$dest" && mv "$dest.new" "$dest" || { rm -rf "$tmp" "$dest.new"; return 1; }
      else
        rm -rf "$tmp"; return 1
      fi
      rm -rf "$tmp"; wa_build_env ;;
    assets)
      local dir; dir="$(wa_codemode_assets_dir "$root")"
      command -v node >/dev/null 2>&1 || return 1
      echo "provision: code-mode assets (pinned, checksum-verified) into $dir"
      local arg="$dir"; command -v cygpath >/dev/null 2>&1 && arg="$(cygpath -w "$dir")"
      mkdir -p "$(dirname "$dir")" && node "$root/scripts/provision-codemode-assets.mjs" "$arg" >/dev/null ;;
    *) return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    check)
      root="${2:-$(cd "$(dirname "$0")/../.." && pwd)}"
      wa_build_env
      wa_build_check "$root" ;;
    record)
      # `wa build-env` and this command: what the record says, and whether every line in it is read.
      wa_build_env_audit "${2:-}" ;;
    help)
      for key in $WA_BUILD_ENV_KEYS; do wa_build_env_help "$key"; printf "\n"; done ;;
    *) echo "usage: build-requirements.sh check [ROOT] | record [HOME-ROOT] | help" >&2; exit 2 ;;
  esac
fi
