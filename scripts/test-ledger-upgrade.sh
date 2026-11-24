#!/usr/bin/env bash
# THE UPGRADE FROM THE LAST RELEASE (Fable 24/11, from the live stall).
#
# MEASURED on the live node: `run_id` was declared inside `CREATE TABLE IF NOT EXISTS self_wakes` only, so a ledger
# created by an older build kept its old columns - and the tick's first call raised "no such column: run_id"
# before the claim loop. Zero wakes were dispatched for 2.5 hours on a node that was idle for long stretches.
#
# This row is the general form of that bug, and it is the "upgrade from the last release" proof the fleet update
# depends on:
#   1. a ledger is created by THE LAST RELEASE'S OWN SETUP - the published v0.1.1 lua core (tag v0.1.1, whose
#      selfloop.lua has no run_id and no resume_chain), run under this binary; WA_RELEASED_BIN lets a caller use
#      the published BINARY instead, which is the artifact itself;
#   2. THIS tree's setup() runs on that same ledger;
#   3. for EVERY self_* table, the upgraded column set must equal a fresh ledger's (created by this tree);
#   4. and the upgraded ledger must WORK: a wake scheduled on it is claimed and dispatched by one tick - which is
#      the line that was dead on the live node.
#
# RED on any tree whose setup() adds a column the code reads but the CREATE list forgot.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "ledger-upgrade: SKIP (no wa binary: set WA_BIN)" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "ledger-upgrade: SKIP (no git on PATH)" >&2; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/ledger-upgrade-XXXXXX")"
cleanup() { local s=$?; rm -rf "$HELP"; [ "$s" != 0 ] && echo "  fixture kept at $W" >&2; [ "$s" = 0 ] && rm -rf "$W"; return "$s"; }
trap cleanup EXIT
mkdir -p "$W/old" "$W/fresh" "$ROOT/.ledger-upgrade-$$"
HELP_REL=".ledger-upgrade-$$"
HELP="$ROOT/$HELP_REL"

# 1. THE RELEASED LEDGER. Two ways, both the release's own code: the published binary when a caller names one,
#    otherwise the lua core of tag v0.1.1 (the file the released binary carries), run under this binary.
OLD_SOURCE=""
# THE RELEASED ARTIFACT FIRST (Fable, 24/11): the published v0.1.1 / node-2104a4d88a37 binary's own setup is the
# gate's default, because the artifact - not the tag's source - is what a node actually runs. The source at the
# tag is the fallback for a machine that has no asset, and the row PRINTS which of the two it used.
RELEASED_ASSET=""
for candidate in "${WA_RELEASED_BIN:-}" \
                 "${WA_RELEASES_DIR:-}/v0.1.1/wa" "${WA_RELEASES_DIR:-}/node-2104a4d88a37/wa" \
                 "$HOME/.wasm-agent/releases/v0.1.1/wa" "$HOME/.wasm-agent/releases/node-2104a4d88a37/wa" \
                 "$ROOT/build/release/v0.1.1/wa" "$ROOT/build/release/node-2104a4d88a37/wa"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { RELEASED_ASSET="$candidate"; break; }
done
if [ -n "$RELEASED_ASSET" ]; then
  WA_RELEASED_BIN="$RELEASED_ASSET"
fi
if [ -n "${WA_RELEASED_BIN:-}" ] && [ -x "${WA_RELEASED_BIN}" ]; then
  RELEASED="$WA_RELEASED_BIN"; OLD_HOW="the published binary $RELEASED"
  cat > "$HELP/make-old.lua" <<'LUA'
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()
print("released ledger created")
LUA
else
  RELEASED="$BIN"; OLD_HOW="tag v0.1.1's own lua core, run under this binary"
  OLD_SOURCE="$W/v0.1.1-selfloop.lua"
  git -C "$ROOT" show v0.1.1:lua/core/selfloop.lua > "$OLD_SOURCE" 2>/dev/null || {
    echo "ledger-upgrade: SKIP (tag v0.1.1 is not in this checkout and WA_RELEASED_BIN was not given)" >&2; exit 0; }
  cat > "$HELP/make-old.lua" <<LUA
local path = "$OLD_SOURCE"
local text = host.read_file(path)
if type(text) ~= "string" or text == "" then error("the released selfloop.lua could not be read: " .. path) end
local chunk = assert(load(text, path))
local selfloop = chunk()
selfloop.setup()
print("released ledger created")
LUA
fi
echo "ledger-upgrade (released ledger from: $OLD_HOW)"
WASM_AGENT_HOME="$W/old" WA_SCRIPT="$HELP_REL/make-old.lua" \
  env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL \
  "$RELEASED" --db "$W/old/memory.db" > "$W/old.log" 2>&1 || {
    echo "  FAIL: the released setup did not create a ledger"; tail -5 "$W/old.log"; exit 1; }

# 2/3/4. THIS tree's setup on it, the column comparison, and a wake that must be dispatched.
cat > "$HELP/upgrade.lua" <<'LUA'
local json = dofile("lua/vendor/json.lua")
local function decode(raw) if type(raw) == "string" then return json.decode(raw) end return raw end
local function rows(sql) return decode(host.sql_query(sql, "[]")) end
local SETUPS = { "selfloop", "enrollment", "agent_control", "done_gate", "event_ledger", "provider", "turn_journal" }
local function setup_all()
  local done = {}
  for _, name in ipairs(SETUPS) do
    local ok, module = pcall(dofile, "lua/core/" .. name .. ".lua")
    if ok and type(module) == "table" and type(module.setup) == "function" then
      local called, err = pcall(module.setup)
      if not called then print("SETUP_FAILED " .. name .. ": " .. tostring(err)); os.exit(1) end
      done[#done + 1] = name
    end
  end
  return done
end
local selfloop = dofile("lua/core/selfloop.lua")
-- THE LAZILY CREATED TABLES ARE THE UPGRADE TOO (Fable, 24/11): a serve does not create access_events,
-- access_requests, agent_control, done_checks, done_gates, ledger_events, provider_serving or turn_notes, so a row
-- that only calls selfloop.setup() never looks at them - and a missing column there is the same stall one table over.
-- Every module's setup is called here, exactly as the subsystems call them on a real node.
local created = setup_all()
print("SETUPS " .. table.concat(created, ","))
local tables = {}
for _, row in ipairs(rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) do
  tables[#tables + 1] = tostring(row.name)
end
local function sorted(list)
  for i = 2, #list do
    local value, j = list[i], i - 1
    while j >= 1 and list[j] > value do list[j + 1] = list[j]; j = j - 1 end
    list[j + 1] = value
  end
  return list
end
local function columns(table)
  local out = {}
  for _, row in ipairs(rows("PRAGMA table_info(" .. table .. ")")) do out[#out + 1] = tostring(row.name) end
  return sorted(out)
end
local report = {}
for _, table in ipairs(tables) do report[table] = columns(table) end
print("UPGRADED " .. json.encode(report))
-- AND IT MUST WORK: one wake, one tick.
local memory = dofile("lua/core/memory.lua")
memory.setup()
local session = memory.start_session("local", "chat", { id = "ledger-upgrade", user_id = "master", title = "upgrade" })
local made = selfloop.schedule({ in_seconds = 0, reason = "ledger upgrade: a due wake", prompt = "x" },
  { session_id = session, user_id = "master" })
if not (type(made) == "table" and made.wake) then print("SCHEDULE_FAILED " .. json.encode(made)); os.exit(1) end
local sent = 0
local called, out = pcall(selfloop.tick, { now = os.time() + 5, dispatch = function() sent = sent + 1; return { accepted = true, run_id = sent } end })
print("TICK called=" .. tostring(called) .. " dispatched=" .. tostring(sent) .. " out=" .. tostring(called and json.encode(out) or out))
local after = rows("SELECT status, attempts FROM self_wakes WHERE id='" .. tostring(made.wake.id) .. "'")[1]
print("ROW " .. json.encode(after))
LUA
cat > "$HELP/fresh.lua" <<'LUA'
local json = dofile("lua/vendor/json.lua")
local function decode(raw) if type(raw) == "string" then return json.decode(raw) end return raw end
local SETUPS = { "selfloop", "enrollment", "agent_control", "done_gate", "event_ledger", "provider", "turn_journal" }
local function setup_all()
  local done = {}
  for _, name in ipairs(SETUPS) do
    local ok, module = pcall(dofile, "lua/core/" .. name .. ".lua")
    if ok and type(module) == "table" and type(module.setup) == "function" then
      local called, err = pcall(module.setup)
      if not called then print("SETUP_FAILED " .. name .. ": " .. tostring(err)); os.exit(1) end
      done[#done + 1] = name
    end
  end
  return done
end
local selfloop = dofile("lua/core/selfloop.lua")
setup_all()
local out = {}
local names_list = {}
for _, row in ipairs(decode(host.sql_query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", "[]"))) do
  names_list[#names_list + 1] = tostring(row.name)
end
for _, table in ipairs(names_list) do
  local names = {}
  for _, row in ipairs(decode(host.sql_query("PRAGMA table_info(" .. table .. ")", "[]"))) do names[#names + 1] = tostring(row.name) end
  for i = 2, #names do
    local value, j = names[i], i - 1
    while j >= 1 and names[j] > value do names[j + 1] = names[j]; j = j - 1 end
    names[j + 1] = value
  end
  out[table] = names
end
print(json.encode(out))
LUA

WASM_AGENT_HOME="$W/old" WASM_AGENT_LUA_ROOT="$ROOT" WA_SCRIPT="$HELP_REL/upgrade.lua" \
  env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL \
  "$BIN" --db "$W/old/memory.db" > "$W/upgrade.log" 2>&1 || {
    echo "  FAIL: this tree's setup on the released ledger raised"; tail -6 "$W/upgrade.log"; exit 1; }
WASM_AGENT_HOME="$W/fresh" WASM_AGENT_LUA_ROOT="$ROOT" WA_SCRIPT="$HELP_REL/fresh.lua" \
  env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL \
  "$BIN" --db "$W/fresh/memory.db" > "$W/fresh.log" 2>&1 || { echo "  FAIL: a fresh ledger could not be made"; exit 1; }

UP="$(grep -m1 '^UPGRADED ' "$W/upgrade.log" | cut -d' ' -f2-)"
FR="$(tail -1 "$W/fresh.log")"
if [ -z "$UP" ]; then echo "  FAIL: no column report from the upgraded ledger"; tail -6 "$W/upgrade.log"; exit 1; fi
if [ "$UP" != "$FR" ]; then
  echo "  FAIL: the upgraded ledger's columns are not a fresh ledger's"
  node -e 'const up=JSON.parse(process.argv[1]), fr=JSON.parse(process.argv[2]);
    for (const t of Object.keys(fr)) { const a=up[t]||[], b=fr[t];
      const missing=b.filter((c)=>!a.includes(c)); const extra=a.filter((c)=>!b.includes(c));
      if (missing.length||extra.length) console.log("    "+t+": missing "+JSON.stringify(missing)+" extra "+JSON.stringify(extra)); }' "$UP" "$FR"
  exit 1
fi
echo "  ok: every table's columns after the upgrade equal a fresh ledger's ($(echo "$UP" | head -c 80)...)"
if ! grep -q "TICK called=true dispatched=1" "$W/upgrade.log"; then
  echo "  FAIL: a wake on the upgraded ledger was not claimed and dispatched"
  grep -E '^TICK|^ROW|^SCHEDULE' "$W/upgrade.log" | head -3 | sed 's/^/    /'
  tail -4 "$W/upgrade.log" | sed 's/^/    /'
  exit 1
fi
echo "  ok: a wake scheduled on the upgraded ledger is claimed and dispatched by one tick"
grep -m1 '^ROW ' "$W/upgrade.log" | sed 's/^/    /'
echo "ledger-upgrade ok: the released ledger upgrades to this tree and dispatches"
