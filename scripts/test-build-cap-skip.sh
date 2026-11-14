#!/usr/bin/env bash
# The build cap keeps evicting past a candidate it cannot delete (14/11: a dangling symlink, always "the
# oldest", stopped the loop at its first refusal and the cap evicted nothing for a day - 261 GB).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
export HOME="$root/home"; mkdir -p "$HOME/.wasm-agent/build/target"
T="$HOME/.wasm-agent/build/target"
fail=0; check(){ if eval "$1"; then :; else echo "FAIL: $2"; fail=1; fi; }
mk(){ mkdir -p "$T/$1/release"; head -c "$2" /dev/zero > "$T/$1/release/blob"; touch -d "$3" "$T/$1"; }
mk old-aaaaaaaaaaaa 3000000 '3 days ago'
mk mid-bbbbbbbbbbbb 3000000 '2 days ago'
mk new-cccccccccccc 3000000 '1 day ago'
# The 13/11 shape: a link to a directory outside the root that still existed, older than every build.
mkdir -p "$root/elsewhere"; touch -d '9 days ago' "$root/elsewhere"; ln -s "$root/elsewhere" "$T/ghost-dddddddddddd"; touch -h -d "9 days ago" "$T/ghost-dddddddddddd"
out=$(WASM_AGENT_BUILD_CAP_BYTES=7000000 WASM_AGENT_BUILD_GRACE=0 bash -c ". '$here/scripts/lib/build-target.sh'; wa_build_cap_enforce '$T/new-cccccccccccc'" 2>&1)
check '[ ! -L "$T/ghost-dddddddddddd" ]' "the link in the build root is unlinked: $out"
check '[ ! -e "$T/old-aaaaaaaaaaaa" ]' "the oldest real build output is evicted despite the link: $out"
check '[ -d "$T/new-cccccccccccc" ]' "the build this call is about is kept"
check '[ -d "$root/elsewhere" ]' "what the link named is never touched"
[ $fail -eq 0 ] && echo "build cap ok (4 checks)" || exit 1
