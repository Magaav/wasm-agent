#!/usr/bin/env bash
# The copilot pipeline's first step: read the store, diff it against the cursor, and print one JSON object -
# the new eligible *text* messages for a child to answer, the ones nobody here can read (an image, a voice
# note) reported to the operator's own inbox instead of being guessed at, and the ones that were handed on
# as often as the reader is willing to try without anybody deciding them.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for candidate in \
  "${WA_BIN:-}" \
  "$LOCALAPPDATA/wasm-agent/wa.exe" \
  "$HOME/.local/bin/wa" \
  "$ROOT/rust/target/release/wa" \
  "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && WA="$candidate" && break
done
if [ -z "${WA:-}" ]; then
  echo '{"events":[],"unanswerable":[],"error":"no_binary"}'
  exit 0
fi

lua_script="$ROOT/scripts/whatsapp-ingest.lua"
if command -v cygpath >/dev/null 2>&1; then
  lua_script="$(cygpath -m "$lua_script")"
fi

read_out="$(WA_WHATSAPP_JSON_EVENTS=1 WA_SCRIPT="$lua_script" "$WA" "$@")"

# Report the unreadable ones to the operator, never to the sender, and the ones nobody managed to decide
# before the reader's attempt bound. Bounded to three of each per run so a noisy run cannot flood the chat,
# and every failure is ignored: a report must not break the step's contract, which is exit 0 and one JSON
# object on stdout.
rows="$(printf '%s' "$read_out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);(j.unanswerable||[]).slice(0,3).forEach(u=>console.log("media|"+u.message_id+"|"+u.conversation_id+"|"+u.media));(j.exhausted||[]).slice(0,3).forEach(e=>console.log("exhausted|"+e.message_id+"|"+e.conversation_id+"|"+e.attempts))}catch(e){}})')"
if [ -n "$rows" ]; then
  while IFS='|' read -r kind mid conv detail; do
    [ -z "$mid" ] && continue
    case "$kind" in
      media) body="wasm-agent: could not reply - the message in $conv is a $detail, not text (id $mid). Nothing was sent to the sender." ;;
      exhausted) body="wasm-agent: gave up on the message in $conv (id $mid) after $detail attempts to decide it; nothing was sent to the sender. The reader will not hand it on again." ;;
      *) continue ;;
    esac
    node "$ROOT/scripts/whatsapp-reply.mjs" --to-self \
      --body "$body" \
      --send >/dev/null 2>&1 || true
  done <<< "$rows"
fi

# The result, at the path the runner chose and passed in. A step that writes nothing where it was asked to
# is indistinguishable from a step that found nothing - and that ambiguity is what hid the bug that left a
# child unstarted while the delivery still said "completed".
if [ -n "${WA_JOB_RESULT_FILE:-}" ]; then
  printf '%s' "$read_out" > "$WA_JOB_RESULT_FILE" 2>/dev/null || true
fi

printf '%s' "$read_out"
