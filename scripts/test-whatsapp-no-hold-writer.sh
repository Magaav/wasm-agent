#!/usr/bin/env bash
# NO CHAT HOLD EXISTS (the owner's decision of 23/11), and no code path may create one again.
#
# WHY. A revoke whose chat scope or author could not be proven put the whole CHAT on a hold, and every
# post into that chat was refused for good (`posting_held_chat`), with no door for the operator to lift
# it. On 23/11 Victor ended that design in one line: "we never should get hold from a chat". The rule is
# per MESSAGE: a deletion flags the message it names and keeps its content, the one not-yet-posted reply
# to it is skipped, a notice that names no message this store holds leaves a tombstone by id, and
# nothing about a deletion can block a chat.
#
# WHAT THIS REFUSES, in the component's own source (`rust/components/wa-whatsapp/src`):
#   * the three reason words of a derived chat hold, and the refusal code they produced;
#   * the module and the writer that created them (`holds.rs`, \`struct Holds\`, the re-proof);
#   * any write of the `holds` kv key. Reading and DELETING it is the migration, not a hold: the first
#     start of the new build lifts what the previous one left and counts it in one line.
#
# WHAT IT MUST NOT REFUSE: the history. Docs, comments and this script itself may name the old reasons -
# a record of what was removed is not a path back. The scan therefore reads the component's code only.
#
# The scan is proved on a fixture, so this row is a gate and not a grep nobody tested.
set -u

cd "$(dirname "$0")/.." || exit 1
SRC="rust/components/wa-whatsapp/src"

fail=0
note() { printf '%s\n' "$*" >&2; fail=1; }

# One scan: rg when it is here (the tree's own preference), grep otherwise. Both are the same expression.
scan() {
  local pattern="$1" root="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -n --no-heading -e "$pattern" "$root" 2>/dev/null
  else
    grep -REn -e "$pattern" "$root" 2>/dev/null
  fi
}

# A COMMENT may name the old reasons: the record of what was removed is not a path back. So the
# judgement reads CODE lines only - a hit whose text starts with `//`, `/*`, `*` or `#` is prose.
code_only() {
  awk -F: '{ line = $0; sub(/^[^:]*:[0-9]+:/, "", line); if (line !~ /^[[:space:]]*(\/\/|\/\*|\*|#)/) print }'
}

refuse_pattern() {
  local pattern="$1" what="$2" hits
  hits="$(scan "$pattern" "$SRC" | code_only)"
  if [ -n "$hits" ]; then
    note "REFUSED: $what"
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ---- the negative checks -------------------------------------------------------------------------
[ -d "$SRC" ] || { note "REFUSED: $SRC is not here; this row cannot judge a tree it cannot read"; exit 1; }
[ -f "$SRC/notices.rs" ] || note "REFUSED: $SRC/notices.rs is gone, so the per-message rule is gone"
[ -f "$SRC/holds.rs" ] && note "REFUSED: $SRC/holds.rs is back: the module that held whole chats was removed on 23/11"
refuse_pattern 'unproven_mutation_chat_hold|untargeted_mutation_chat_hold|owner_chat_clear_hold' "a derived chat-hold reason word is back"
refuse_pattern 'posting_held_chat' "the refusal code of a held chat is back"
refuse_pattern 'struct Holds|mod holds;|fn reprove' "the hold writer (or its re-proof) is back"
refuse_pattern 'kkv::set\(b\"holds\"' "the component writes the holds kv key again"
refuse_pattern 'Gate::Held' "the posting gate can report a hold again (it is Gate::Blocked, configuration only)"

# ---- the positive checks: the per-message rule is the one that is here ----------------------------
grep -q 'pub mod notices;' "$SRC/lib.rs" || note "REFUSED: lib.rs does not export notices"
grep -q 'pub fn mark_deleted' "$SRC/index.rs" || note "REFUSED: index.rs has no mark_deleted: a deletion would forget its content"
grep -q 'fn key_tombstone' "$SRC/index.rs" || note "REFUSED: index.rs has no tombstone by message id"
grep -q 'fn apply_notice' "$SRC/guest.rs" || note "REFUSED: guest.rs has no notice handler"
grep -q 'notices matched=' "$SRC/health.rs" || note "REFUSED: the health line carries no notice counters"
grep -q 'holds were removed by the owner' "$SRC/guest.rs" || note "REFUSED: the migration that lifts the old holds is gone"

# ---- the fixture: the scan is a gate, and it fails when a hold writer exists ----------------------
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/clean" "$fixture/held"
printf 'pub fn apply() { let reason = "unproven_mutation_chat_hold"; }\n' > "$fixture/held/holds.rs"
printf 'pub fn apply() { let reason = "source_deleted"; }\n' > "$fixture/clean/notices.rs"
if [ -z "$(scan 'unproven_mutation_chat_hold' "$fixture/held")" ]; then
  note "REFUSED: the scan misses a hold writer on a fixture, so a clean answer above proves nothing"
fi
if [ -n "$(scan 'unproven_mutation_chat_hold' "$fixture/clean")" ]; then
  note "REFUSED: the scan reports a notice writer as a hold writer"
fi

if [ "$fail" -ne 0 ]; then
  note "whatsapp-hold-not-silent: the per-message rule of 23/11 is not what this tree implements (docs/WHATSAPP-TRANSCRIPTION.md)"
  exit 1
fi
echo "whatsapp-no-hold-writer: ok: no code path creates a chat hold; the deletion path is index::mark_deleted + notices.rs"
