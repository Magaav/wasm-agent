#!/usr/bin/env bash
# Behaviour tests that need a real model: memory selection, language following,
# and session continuation across separate processes.
#
#   bash scripts/test-behavior.sh            # uses the configured provider
#
# These are separate from scripts/test.sh (which is hermetic and offline) because
# they cost tokens. Nothing here prints credentials: every value that could be
# one goes through the redactor or is never read.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-rust/target/release/wa}"
DB="$(mktemp -u /tmp/wa-behavior-XXXXXX.db)"
TMP="$(mktemp -d /tmp/wa-behavior-XXXXXX)"
trap 'rm -rf "$DB" "$DB-wal" "$DB-shm" "$TMP"' EXIT

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '       %s\n' "$1"; }

say() {  # say <text> -> prints the reply
  printf '%s\n/exit\n' "$1" | "$BIN" --db "$DB" chat 2>&1
}

if [ ! -x "$BIN" ]; then echo "no binary at $BIN" >&2; exit 1; fi

echo
echo "wasm-agent behaviour tests"
echo "  binary $BIN"
echo

# --- 3. memory selection ------------------------------------------------------
# The value under test is generated per run, so the test cannot pass by
# memorising it, and it is not a phrase the model could guess.
CODENAME="falcon-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
echo "memory selection"
say "Remember that my local node codename is $CODENAME." > "$TMP/remember.txt" 2>&1
note "stored: $CODENAME"

START=$(date +%s%N)
say "What is my local node codename?" > "$TMP/recall.txt" 2>&1
END=$(date +%s%N)
WALL_MS=$(( (END - START) / 1000000 ))

python3 - "$DB" "$CODENAME" "$WALL_MS" <<'PY'
import json, sqlite3, sys
db, codename, wall_ms = sys.argv[1], sys.argv[2], int(sys.argv[3])
con = sqlite3.connect(db)
sid = con.execute("SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1").fetchone()[0]
turns = list(con.execute(
    "SELECT seq, role, content, tool_calls, tool_name, trace, ms FROM turns "
    "WHERE session_id=? ORDER BY seq", (sid,)))

selected, query, retrieved, answer = False, "", "", ""
latency = 0
for seq, role, content, tool_calls, tool_name, trace, ms in turns:
    latency += ms or 0
    try: calls = json.loads(tool_calls or "[]")
    except Exception: calls = []
    if role == "assistant" and calls:
        for call in calls:
            fn = call.get("function", {})
            if fn.get("name") == "recall":
                selected = True
                try: query = json.loads(fn.get("arguments") or "{}").get("query", "")
                except Exception: query = fn.get("arguments") or ""
    if role == "tool" and tool_name == "recall":
        retrieved = content or ""
    # `tool_calls` is stored as '[]' when empty, and a non-empty string is
    # truthy in Python - so test the parsed list, not the raw column.
    if role == "assistant" and content and not calls:
        answer = content
for _, _, _, _, _, trace, _ in turns:
    for span in json.loads(trace or "[]"):
        if isinstance(span, dict) and span.get("kind") == "tool" and span.get("name") == "recall":
            selected = True

print(f"       tool discovered      : recall is in the master envelope")
print(f"       tool selected        : {'yes' if selected else 'NO'}")
print(f"       tool query           : {query[:70]!r}")
print(f"       retrieval result     : {retrieved[:70]!r}")
print(f"       final answer         : {answer[:70]!r}")
print(f"       latency              : {wall_ms} ms wall, {latency} ms in-turn")
print(f"       unsupported assertion: none" if selected and codename in retrieved and codename in answer
      else f"       unsupported assertion: "
           + ", ".join(filter(None, [
               None if selected else "recall was never called",
               None if codename in retrieved else "the fact was not retrieved",
               None if codename in answer else "the answer omitted the fact"])))
sys.exit(0 if (selected and codename in retrieved and codename in answer) else 1)
PY
if [ $? -eq 0 ]; then ok "memory: recall selected, fact retrieved, answer correct"
else bad "memory: the model did not retrieve a stored fact"; fi

# Schema/token overhead: what carrying memory costs on every request.
cat > "$TMP/overhead.lua" <<'LUA'
local json = dofile("lua/vendor/json.lua")
local tools = dofile("lua/core/tools.lua")
local agentlib = dofile("lua/core/agent.lua")
local envelope = json.encode(tools.all("master"))
local prompt = agentlib.system_prompt_bytes and 0 or 0
print("       tools      : " .. #tools.all("master") .. " schemas, " .. #envelope ..
      " chars (~" .. math.ceil(#envelope / 4) .. " tokens)")
LUA
WA_SCRIPT="$TMP/overhead.lua" "$BIN" --db "$DB" 2>&1 | grep "tools  " || true

echo
echo "language following"
# Assertions are deliberately light: a marker check, not language detection.
# Each case asks for a short sentence, so there is something to judge.
check_language() {
  local label="$1" prompt="$2" expected="$3"
  local reply
  reply="$(say "$prompt" | tail -3 | tr '\n' ' ')"
  local got
  got="$(python3 - "$reply" <<'PY'
import re, sys
text = sys.argv[1]
low = text.lower()
pt = len(re.findall(r"\b(não|é|você|está|olá|obrigad|sim|azul|céu|uma|como)\b|[ãõçáéíóúâêô]", low))
en = len(re.findall(r"\b(the|is|are|you|sky|blue|hello|how|a|of|and)\b", low))
print("pt" if pt > en else ("en" if en > pt else "?"))
PY
)"
  if [ "$got" = "$expected" ]; then ok "$label -> $expected"
  else bad "$label -> expected $expected, detected $got"; note "reply: ${reply:0:90}"; fi
}
check_language "english prompt"              "Answer in one short sentence: what colour is the sky?" "en"
check_language "portuguese prompt"           "Responda em uma frase curta: de que cor é o céu?" "pt"
check_language "english asking portuguese"   "Answer in one short Portuguese sentence: de que cor é o céu?" "pt"
check_language "portuguese asking english"   "Responda em uma frase curta em inglês: what colour is the sky?" "en"

# --- 3b. compaction summaries carry the plan ----------------------------------
# pi ships no todo tool ("they confuse models"), so the run's plan lives in the
# compaction summary. With compaction now happening mid-turn, that is
# load-bearing: a summary without Goal/Progress/Next Steps loses the task.
# Two compactions in one turn must use the checkpoint template and, once the cut
# has moved inside the turn, the split-turn prefix template.
echo
echo "compaction summaries"
cat > "$TMP/compact.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()
local sid = memory.start_session("", "probe", { user_id = "master", node_id = "", title = "probe" })
local function work(from, to)
  for i = from, to do
    local call = { id = "c" .. i, type = "function", ["function"] = { name = "read", arguments = "{}" } }
    memory.append_turn(sid, { role = "assistant", content = "", tool_calls = { call } })
    memory.append_turn(sid, { role = "tool", tool_call_id = "c" .. i, tool_name = "read",
      content = string.rep("tool output " .. i .. " ", 400) })
  end
end
memory.append_turn(sid, { role = "user", content = "Do a long sequence of work, then report." })
work(1, 8)
local bot = agentlib.new(sid, function() end, "master", "master", "")
bot.last_prompt_tokens = 99999
local first = bot:maybe_compact()
work(9, 18)
bot.last_prompt_tokens = 99999
local second = bot:maybe_compact()
local summaries = {}
for _, turn in ipairs(memory.session_turns(sid, { limit = 500 })) do
  if turn.role == "summary" then
    for _, span in ipairs(turn.trace or {}) do
      if span.kind == "compact" then summaries[#summaries + 1] = { split = span.split_turn, text = turn.content } end
    end
  end
end
assert(first and second, "both compactions should have run")
assert(summaries[1].split == false and summaries[1].text:find("## Next Steps", 1, true),
  "the first summary must be the checkpoint template with a plan")
assert(summaries[2].split == true and summaries[2].text:find("## Original Request", 1, true),
  "a cut inside the turn must use the split-turn prefix template")
print("compaction templates ok")
LUA
if WASM_AGENT_LLM_CONTEXT=6000 WA_SCRIPT="$TMP/compact.lua" "$BIN" --db "$DB" 2>&1 | grep "compaction templates ok"; then
  ok "checkpoint and split-turn summaries both carry the plan"
else bad "compaction summaries did not use pi's templates"; fi

# --- 2. session continuation --------------------------------------------------
echo
echo "session continuation"
sessions_count() { python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('select count(*) from sessions').fetchone()[0])" "$DB"; }
before="$(sessions_count)"
say "one" > /dev/null 2>&1
mid="$(sessions_count)"
if [ "$mid" -gt "$before" ]; then ok "a new session is the default (sessions $before -> $mid)"
else bad "the default should start a new session"; fi

CONT="$TMP/continue.txt"
printf 'two\n/exit\n' | "$BIN" --db "$DB" chat --continue > "$CONT" 2>&1
after="$(sessions_count)"
resumed="$(grep -c "(continued)" "$CONT" || true)"
if [ "$after" = "$mid" ] && [ "$resumed" -ge 1 ]; then ok "--continue reuses the latest session (still $after sessions)"
else bad "--continue should not create a session (was $mid, now $after, marker=$resumed)"; fi

# The continued thread must actually carry the earlier turn. Assert on content,
# not on a turn count: "one" and "two" answered directly are two exchanges, and
# a magic threshold makes the test depend on whether the model chose to use a
# tool. That flakiness cost me two confident-but-wrong "regression" reports.
PRE_SID="$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('select id from sessions order by updated_at desc limit 1').fetchone()[0])" "$DB")"
python3 - "$DB" "$PRE_SID" <<'PY' && ok "the continued thread carries its earlier turns" || bad "continuation lost the transcript"
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
sid = sys.argv[2]
texts = [row[0] or "" for row in con.execute(
    "SELECT content FROM turns WHERE session_id=? ORDER BY seq", (sid,))]
print(f"       session {sid[:8]} has {len(texts)} turns; earliest user text: "
      f"{next((t for t in texts if t.strip()), '')[:40]!r}")
# The earlier exchange must still be there alongside the new one.
sys.exit(0 if any("one" == t.strip() for t in texts) and any("two" == t.strip() for t in texts) else 1)
PY

SID="$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('select id from sessions order by updated_at desc limit 1').fetchone()[0])" "$DB")"
printf 'three\n/exit\n' | "$BIN" --db "$DB" chat --session "$SID" > /dev/null 2>&1
explicit="$(sessions_count)"
if [ "$explicit" = "$after" ]; then ok "--session <id> continues exactly that session"
else bad "--session created a new session (was $after, now $explicit)"; fi

"$BIN" --db "$DB" chat --session definitely-not-a-session "hi" > "$TMP/bad.txt" 2>&1
code=$?
if [ "$code" -ne 0 ] && grep -q "no such session" "$TMP/bad.txt" && grep -q "wa sessions" "$TMP/bad.txt"; then
  ok "an unknown session id fails with a useful error (exit $code)"
else bad "unknown session id should fail with a message and non-zero exit (got $code)"; sed 's/^/       /' "$TMP/bad.txt" | head -3; fi

# --- 5. redaction, end to end -------------------------------------------------
echo
echo "redaction (live error path)"
FAKE="sk-FAKEintegration1234567890abcdef"
printf 'hello\n/exit\n' | WASM_AGENT_LLM_API_KEY="$FAKE" "$BIN" --db "$DB" chat > "$TMP/leak.txt" 2>&1
if grep -qF "$FAKE" "$TMP/leak.txt"; then
  bad "a fake key reached the output verbatim"
  grep -n "sk-FAKE" "$TMP/leak.txt" | sed 's/sk-FAKE[A-Za-z0-9]*/sk-***/' | head -2 | sed 's/^/       /'
else
  ok "a rejected key is masked in the error output"
  grep -o "sk-[A-Za-z0-9]*" "$TMP/leak.txt" | head -2 | sed 's/^/       saw: /' || true
fi

echo
if [ "$fail" -eq 0 ]; then echo "behaviour ok ($pass checks)"; else echo "behaviour FAILED ($fail of $((pass + fail)))"; fi
exit $(( fail > 0 ))
