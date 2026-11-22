#!/usr/bin/env bash
# Ctrl+V in the chat's input pastes WHAT IS ON THE CLIPBOARD - the text, or an image (Victor, 22/11).
#
# The bug this holds: Ctrl+V was bound to "paste an image" only, and the reader asked the clipboard
# for an image type and nothing else, so with text copied the footer said "no image on the clipboard"
# and the draft stayed empty (measured 22/11 on this laptop: `wl-paste --list-types` for copied text
# lists text/plain;charset=utf-8, text/plain, TEXT, STRING, UTF8_STRING and no image at all).
#
# WHY A PTY AND A REAL BINARY. The key route is the whole route: the terminal's bytes reach the
# console's reader thread, the reader asks the host, the host runs a clipboard tool as a CHILD
# PROCESS, and the answer is drawn in the input box. A unit test sees none of that, and the pty is
# what makes `script(1)` necessary here: with stdin a pipe the console is the plain REPL, not the
# editor, and Ctrl+V never reaches the editor at all (measured).
#
# WHAT IT ASSERTS, case by case:
#   text  - the clipboard's two lines are drawn in the input box, the tab-separated tail with them;
#   undo  - Ctrl+Z after that leaves the LAST frame an empty draft (one paste, one undo step);
#   image - an image type on the clipboard is still `[Image #1]`, the behaviour that must not regress;
#   empty - an empty clipboard says "the clipboard is empty";
#   html  - a clipboard holding only types wa cannot use NAMES them, and never says "no image on the
#           clipboard" about a clipboard that held text.
#
#   bash scripts/test-clipboard-paste.sh        (WA_BIN names the binary; defaults to the tree's)
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${WA_BIN:-$root/rust/target/release/wa}
[ -x "$bin" ] || { echo "clipboard paste SKIP: no binary at $bin (set WA_BIN)"; exit 0; }
command -v script >/dev/null 2>&1 || { echo "clipboard paste SKIP: no script(1) here to give the console a pty"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/wa-clipboard.XXXXXX") || { echo "clipboard paste FAIL: no scratch dir"; exit 1; }
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home"

# The scratch home is this test's own, and it says so rather than discovering it after the fact.
if [ "$work/home" = "${HOME:-}" ] || [ "$work/home" = "${HOME:-}/.wasm-agent" ]; then
  echo "clipboard paste FAIL: refusing to run against the operator's own home ($work/home)"
  exit 1
fi

failures=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; failures=$((failures + 1)); }
has()  { grep -qa -- "$2" "$1"; }
lacks(){ ! grep -qa -- "$2" "$1"; }

# The clipboard, as a tool this process runs: the same two calls the reader makes. Its mode decides
# what a copy would hold here, and every mode answers `--list-types` the way wl-paste does.
cat > "$work/bin/wl-paste" <<'FAKE'
#!/bin/sh
case "$FAKE_CLIP" in
  empty)
    case "$*" in *--list-types*) echo "Nothing is copied" >&2; exit 1 ;; esac
    exit 1 ;;
  html)
    case "$*" in *--list-types*) printf 'text/html\nimage/svg+xml\n'; exit 0 ;; esac
    exit 1 ;;
  image)
    case "$*" in
      *--list-types*) printf 'image/png\ntext/plain\nTEXT\n' ;;
      *) cat "$FAKE_CLIP_IMAGE" ;;
    esac
    exit 0 ;;
esac
case "$*" in
  *--list-types*) printf 'text/plain;charset=utf-8\ntext/plain\nTEXT\nSTRING\nUTF8_STRING\n' ;;
  *) cat "$FAKE_CLIP_TEXT" ;;
esac
FAKE
chmod +x "$work/bin/wl-paste"
printf 'line one\nline two\tand a tab' > "$work/clip.txt"
# The 1x1 PNG the image round-trip test uses, decoded here rather than trusted as a file name.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' \
  | base64 -d > "$work/clip.png"

# Wait for the console to say something, rather than sleeping a fixed time: the first bytes written
# to a console that is still starting are read before its reader thread exists and are lost.
wait_log() { # wait_log <file> <literal> <tenths of a second>
  local file=$1 literal=$2 ticks=$3 n=0
  while [ "$n" -lt "$ticks" ]; do
    grep -qa -- "$literal" "$file" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
leave() { printf '\003'; sleep 0.4; printf '\003'; sleep 0.8; }

# One console, in a pty of its own (script(1)), with the fake clipboard on PATH and nothing of this
# shell's environment: no provider, no rendezvous, no relay, its own home and its own db.
console() { # console <name> <mode> <seconds the keys take at most>
  local name=$1 mode=$2
  cat > "$work/run-$name.sh" <<RUN
#!/bin/sh
stty rows 24 cols 80 2>/dev/null
exec "$bin" --db "$work/$name.db" chat
RUN
  chmod +x "$work/run-$name.sh"
  : > "$work/$name.log"
}

drive() { # drive <name> <mode> <keys-function>
  local name=$1 mode=$2 keys=$3 log="$work/$1.log"
  ( "$keys" "$log" ) | timeout 90 env -i PATH="$work/bin:/usr/bin:/bin" TERM=xterm-256color TMPDIR="${TMPDIR:-/tmp}" \
      HOME="$work/home" WASM_AGENT_HOME="$work/home" WASM_AGENT_LUA_ROOT="$root" \
      WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
      WAYLAND_DISPLAY=wayland-0 FAKE_CLIP="$mode" \
      FAKE_CLIP_TEXT="$work/clip.txt" FAKE_CLIP_IMAGE="$work/clip.png" \
      script -q -e -c "$work/run-$name.sh" /dev/null > "$log" 2>&1
}

# 1. TEXT: Ctrl+V puts the clipboard's text in the draft.
keys_paste() {
  local log=$1
  wait_log "$log" "Type a message" 400 || return 1
  printf '\026'
  wait_log "$log" "and a tab" 200 || return 1
  leave
}
console paste text
drive paste text keys_paste
has "$work/paste.log" "Type a message"   && ok "the console drew its input box"            || bad "the console never drew its input box"
has "$work/paste.log" "line one"         && ok "the clipboard's first line is in the draft"  || bad "Ctrl+V put nothing in the draft (text on the clipboard)"
has "$work/paste.log" "line two"         && ok "its second line came with it"                || bad "the paste lost its second line"
has "$work/paste.log" "and a tab"        && ok "and the text after the tab"                  || bad "the paste lost what followed its tab"
lacks "$work/paste.log" "no image on the clipboard" && ok "and it never said 'no image on the clipboard'" \
  || bad "the words of the bug are still shown for a clipboard that held text"

# 2. UNDO: one Ctrl+Z takes the whole paste back out of the draft.
keys_undo() {
  local log=$1
  wait_log "$log" "Type a message" 400 || return 1
  printf '\026'
  wait_log "$log" "and a tab" 200 || return 1
  sleep 0.5
  printf '\032'
  sleep 3
  leave
}
console undo text
drive undo text keys_undo
tail -c 1600 "$work/undo.log" > "$work/undo.frame"
has "$work/undo.log" "line one" && ok "the text was in the draft before Ctrl+Z" || bad "no paste to undo (the console never showed the text)"
has "$work/undo.frame" "Type a message" && ok "the last frame is the empty draft's placeholder" || bad "the last frame is not a drawn input box"
lacks "$work/undo.frame" "line one" && ok "one Ctrl+Z took the whole paste back out" \
  || bad "Ctrl+Z did not remove the pasted text in one step"

# 3. IMAGE: an image on the clipboard is still `[Image #1]` - the behaviour that must not regress.
keys_image() {
  local log=$1
  wait_log "$log" "Type a message" 400 || return 1
  printf '\026'
  wait_log "$log" "Image #1" 200 || return 1
  leave
}
console image image
drive image image keys_image
has "$work/image.log" 'Image #1' && ok "an image on the clipboard is attached as [Image #1]" || bad "the image paste regressed: no [Image #1] in the draft"
has "$work/image.log" 'attached' && ok "and its size is said in the notice" || bad "no attachment notice for the image"

# 4. EMPTY: nothing on the clipboard has its own notice.
keys_empty() {
  local log=$1
  wait_log "$log" "Type a message" 400 || return 1
  printf '\026'
  wait_log "$log" "the clipboard is empty" 200 || return 1
  leave
}
console empty empty
drive empty empty keys_empty
has "$work/empty.log" "the clipboard is empty" && ok "an empty clipboard says exactly that" || bad "an empty clipboard got no notice of its own"
lacks "$work/empty.log" "no image on the clipboard" && ok "and not the words of the bug" || bad "an empty clipboard says 'no image on the clipboard'"

# 5. A TYPE WA CANNOT USE: it is named.
keys_html() {
  local log=$1
  wait_log "$log" "Type a message" 400 || return 1
  printf '\026'
  wait_log "$log" "cannot paste" 200 || return 1
  leave
}
console html html
drive html html keys_html
has "$work/html.log" "the clipboard holds text/html, image/svg+xml, which wa cannot paste" \
  && ok "a type wa cannot use is named, both of them" || bad "the unusable types were not named: $(grep -ao 'the clipboard[^…]*' "$work/html.log" | tail -1)"
lacks "$work/html.log" "no image on the clipboard" && ok "and the words of the bug are gone here too" \
  || bad "a clipboard holding text/html still says 'no image on the clipboard'"

if [ "$failures" -eq 0 ]; then
  echo "clipboard paste ok (5 cases, a real console in a pty and a real clipboard tool)"
else
  echo "clipboard paste FAILED: $failures check(s); logs in $work (kept)"
  trap - EXIT
  exit 1
fi
