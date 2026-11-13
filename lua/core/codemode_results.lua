-- Explicit reuse, change awareness and the retained-result reader of one code-mode session
-- (docs/CODEMODE.md, "Always fresh, explicit reuse").
--
-- Every call a script makes runs, every time. There is no implicit cache: an agent that repeats a
-- read is either rechecking (and gets the new answer, with `prior` saying whether it moved) or it
-- wants the earlier answer and asks for it by name (`results.get(hash)`, `results.last(n)`) or by
-- option (`tools.x(args, {reuse: "60s"})`). Implicit caching was rejected on 11/11 because "sometimes
-- models want to recheck if something turned out differently, so caching risks breaking awareness".
--
-- The journal is durable per scope (session x user x role x workspace, the same scope the guest store
-- uses) in `memory.meta`, bounded to the newest KEEP rows: those rows are what `results.last`,
-- `results.diff`, `{reuse}` and `prior` read. The *content* of an earlier result is already retained
-- by hash in the node's tool-results directory (`lua/core/tool_output.lua`), so nothing here copies a
-- result body - a journal row is a name, two hashes, a time and a verdict.
local json = dofile("lua/vendor/json.lua")
local output = dofile("lua/core/tool_output.lua")
local M = {}

M.PREFIX = "codemode-results.v1:"
-- Newest rows kept per scope. A row is ~200 bytes, so this is a bounded metadata record, never a
-- second copy of any result.
M.KEEP = 200
-- The largest result body `results.get` will answer as a decoded value; past this it answers a page
-- with `next_offset`, because decoding 8 MiB to hand it to a guest is not an answer a script can use.
M.MAX_READ = 262144
M.MAX_DIFF = 40
M.MAX_DIFF_TEXT = 240
M.MAX_AGE_S = 86400

-- One classifier for "did this call change anything": the node's own (`orchestration_mode.effectful`),
-- which the steering and orchestration gates already use, and which counts an unlisted tool as a
-- read and `bash`/`shell` as a read only for an allowlisted read command. `prior` and `{reuse}` are
-- statements about a *read*; an effect is never reused or compared, because "the same result" would be
-- a claim about the world that this layer cannot make.
local orchestration
local function read_only(name, args)
  local ok, mode = pcall(function()
    orchestration = orchestration or dofile("lua/core/orchestration_mode.lua")
    return orchestration.effectful(name, args)
  end)
  if not ok then return false end
  return mode ~= true
end

-- Telemetry is best-effort by contract (it never raises); a node whose telemetry table is refusing
-- writes must not fail a script over a count.
local telemetry
local function count(ctx, kind, payload)
  local ok, span = pcall(function()
    telemetry = telemetry or dofile("lua/core/telemetry.lua")
    return telemetry.start(ctx, kind, payload)
  end)
  if ok and span then pcall(telemetry.finish, span, payload) end
end

local function now_seconds()
  local clock = host.now and host.now() or nil
  return tonumber(clock) or 0
end

local function key(scope) return M.PREFIX .. tostring(scope) end

function M.load(memory, scope)
  local journal = { entries = {} }
  if not memory or type(scope) ~= "string" then return journal end
  local raw = memory.meta_get(key(scope))
  if type(raw) ~= "string" or raw == "" then return journal end
  local ok, decoded = pcall(json.decode, raw)
  if ok and type(decoded) == "table" and type(decoded.entries) == "table" then return decoded end
  return journal
end

function M.save(memory, scope, journal)
  if not memory or type(scope) ~= "string" or type(journal) ~= "table" or not journal.dirty then return end
  journal.dirty = nil
  local ok, encoded = pcall(json.encode, journal)
  if ok then memory.meta_set(key(scope), encoded) end
end

-- The newest row for this exact name and argument list, or nil. `args` is compared as the hash of the
-- arguments the guest sent, so `{a=1,b=2}` and `{b=2,a=1}` are the same read - as they are to the tool.
function M.prior(journal, tool, args_sha)
  for index = #journal.entries, 1, -1 do
    local entry = journal.entries[index]
    if entry.tool == tool and entry.args == args_sha then return entry, index end
  end
end

local function age_of(entry, now)
  return math.max(0, math.floor(((tonumber(now) or now_seconds()) - (tonumber(entry.at) or 0)) * 1000 + 0.5) / 1000)
end

local function annotate(value, prior, same)
  if type(value) ~= "table" then return value end
  -- A list keeps its shape: adding a key to a Lua array would turn the result into an object for every
  -- reader downstream (a `tool_call` calls batch answers a list of per-item results), so a list result carries the
  -- hint in the journal only - `results.last(n)` still shows that the repeat happened and whether it
  -- changed, and the repeat is counted in telemetry either way.
  if value[1] ~= nil then return value end
  local out = {}
  for name, field in pairs(value) do out[name] = field end
  out.prior = { call = prior.id, age_s = age_of(prior, now_seconds()), same = same }
  return out
end

-- One admitted call, journaled. Returns the value the caller should hand the guest: the same table,
-- with `prior` when a fresh read-only call repeated an earlier identical read.
--   `entry` = {id=<guest call id>, tool=<name>, args=<args hash>, at=<secs>, ok=<bool>, args_value=<arguments>}
--
-- Two hashes per row, because `prior.same` and `results.get` ask different questions:
--   `raw`    the answer the tool gave, before any annotation here - the stable identity a repeat is
--            compared against;
--   `result` the bytes this node retained and the script received (`tool_output.store` hashes the same
--            table), which is what `results.get`/`results.diff`/`{reuse}` read back.
-- One hash for both made an annotated repeat lose its own `{reuse}` and answer `output_not_found`
-- from `results.get` (measured while this was being written).
function M.record(ctx, journal, entry, value)
  local raw_hash = host.sha256(json.encode(value))
  entry.at = entry.at or now_seconds()
  entry.read = read_only(entry.tool, entry.args_value)
  entry.args_value = nil
  local prior = entry.read and M.prior(journal, entry.tool, entry.args) or nil
  if prior and prior.read then
    local same = (prior.raw or prior.result) == raw_hash
    count(ctx, "codemode_repeat", { tool = entry.tool, age_s = age_of(prior, entry.at), same = same, arguments_hash = entry.args })
    value = annotate(value, prior, same)
  end
  journal.seq = (tonumber(journal.seq) or 0) + 1
  entry.guest_call = entry.id
  entry.id = journal.seq
  entry.raw = raw_hash
  entry.result = host.sha256(json.encode(value))
  journal.entries[#journal.entries + 1] = entry
  while #journal.entries > M.KEEP do table.remove(journal.entries, 1) end
  journal.dirty = true
  return value
end

-- The full prior result behind a hash: the node already retains every admitted result byte for byte
-- (`tool_output.store`), so this is a read of that original, verified by its own hash.
local function read_result(id)
  local page = output.read(id, 1, M.MAX_READ)
  if page.error then return nil, page.error end
  if not page.eof then return { hash = id, text = page.content, next_offset = page.next_offset, bytes = page.bytes, truncated = true } end
  local decoded_ok, decoded = pcall(json.decode, page.content)
  if not decoded_ok then return { hash = id, text = page.content, bytes = page.bytes } end
  return decoded
end

local function clip(value)
  if type(value) == "string" then
    if #value > M.MAX_DIFF_TEXT then return value:sub(1, M.MAX_DIFF_TEXT) .. "…(" .. (#value - M.MAX_DIFF_TEXT) .. " more bytes)" end
    return value
  end
  if type(value) == "table" then
    local ok, encoded = pcall(json.encode, value)
    if ok and #encoded > M.MAX_DIFF_TEXT then return encoded:sub(1, M.MAX_DIFF_TEXT) .. "…" end
    return ok and encoded or type(value)
  end
  return value
end

local function is_list(value)
  if type(value) ~= "table" or value[1] == nil then return false end
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count == #value
end

-- `prior` is this layer's own annotation, not part of the answer: a diff reports what the *tool*
-- answered differently, so the hint does not appear as a change of its own.
local function without_annotation(value)
  if type(value) ~= "table" or value.prior == nil then return value end
  local out = {}
  for name, field in pairs(value) do if name ~= "prior" then out[name] = field end end
  return out
end

local function diff(before, after, path, out, depth)
  if #out >= M.MAX_DIFF then return end
  if depth > 12 then return end
  if type(before) ~= type(after) then out[#out + 1] = { path = path, before = clip(before), after = clip(after) }; return end
  if type(before) ~= "table" then
    if before ~= after then out[#out + 1] = { path = path, before = clip(before), after = clip(after) } end
    return
  end
  if is_list(before) ~= is_list(after) then out[#out + 1] = { path = path, before = "list of " .. #before, after = "object or list of " .. #after }; return end
  local seen = {}
  for name in pairs(before) do seen[name] = true end
  for name in pairs(after) do seen[name] = true end
  local keys = {}
  for name in pairs(seen) do keys[#keys + 1] = name end
  table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
  for _, name in ipairs(keys) do
    local this = tostring(path) .. "." .. tostring(name)
    if before[name] == nil then out[#out + 1] = { path = this, after = clip(after[name]) }
    elseif after[name] == nil then out[#out + 1] = { path = this, before = clip(before[name]) }
    else diff(before[name], after[name], this, out, depth + 1) end
    if #out >= M.MAX_DIFF then return end
  end
end

-- `results({op=...})`: the guest's one door to the retained results and the journal. Read-only over
-- records the node already keeps: it dispatches nothing and admits nothing.
function M.answer(request, ctx, journal)
  if type(request) ~= "table" then return { error = "results_requires_an_object", effect = "none" }, false end
  local op = tostring(request.op or "")
  local now = now_seconds()
  if op == "get" then
    local asked = type(request.hash) == "string" and request.hash or nil
    -- A pending call's handle is a name too: `results.get(op)` re-reads what the call answered
    -- without re-running it, because the settled result is retained under the operation's id
    -- (`lua/core/codemode_pending.lua`). A hash and a handle are the same question - what did this
    -- call answer - so they are one branch, never a second door with its own rules.
    if asked and asked:match("^op%-") then
      local value, why = dofile("lua/core/codemode_pending.lua").retained(asked, nil)
      if value == nil then
        return { error = "results_get_unknown_op", op = asked, reason = why, effect = "none",
          note = "op handles come from {state:\"pending\", op}; wait(op) settles one" }, false
      end
      return { ok = true, op = asked, value = value }, true
    end
    local id = type(asked) == "string" and asked:lower() or nil
    if not id or #id ~= 64 or id:find("[^0-9a-f]") then return { error = "results_get_requires_a_sha256_or_op", effect = "none" }, false end
    local value, problem = read_result(id)
    if value == nil then
      return { error = problem, hash = id, effect = "none",
        note = "results.get reads a result hash from this session's attempts (attempts[].result.sha256, or results.last)." }, false
    end
    return { ok = true, hash = id, value = value }, true
  elseif op == "last" then
    local wanted = tonumber(request.n) or 1
    if wanted % 1 ~= 0 or wanted < 1 or wanted > 50 then return { error = "results_last_requires_n_1_to_50", effect = "none" }, false end
    local tool = request.tool ~= nil and tostring(request.tool) or nil
    local rows, left = {}, wanted
    for index = #journal.entries, 1, -1 do
      local entry = journal.entries[index]
      if not tool or entry.tool == tool then
        rows[#rows + 1] = { call = entry.id, tool = entry.tool, age_s = age_of(entry, now), ok = entry.ok,
          read = entry.read, arguments = entry.args, result = entry.result }
        left = left - 1
        if left <= 0 then break end
      end
    end
    return { ok = true, results = rows, count = #rows, requested = wanted }, true
  elseif op == "diff" then
    local first = type(request.a) == "string" and request.a:lower() or nil
    local second = type(request.b) == "string" and request.b:lower() or nil
    if not first or not second then return { error = "results_diff_requires_two_sha256", effect = "none" }, false end
    local before, before_error = read_result(first)
    if before == nil then return { error = before_error, which = "a", effect = "none" }, false end
    local after, after_error = read_result(second)
    if after == nil then return { error = after_error, which = "b", effect = "none" }, false end
    local changed = {}
    diff(without_annotation(before), without_annotation(after), "$", changed, 0)
    return { ok = true, a = first, b = second, same = #changed == 0, count = #changed, changed = changed,
      truncated = #changed >= M.MAX_DIFF }, true
  elseif op == "reuse" then
    local tool = tostring(request.tool or "")
    if tool == "" then return { error = "results_reuse_requires_a_tool", effect = "none" }, false end
    local seconds = tonumber(request.max_age_s)
    if not seconds or seconds <= 0 then return { error = "results_reuse_requires_max_age_s", effect = "none" }, false end
    local args = request.args
    if type(args) ~= "table" then args = {} end
    local entry = M.prior(journal, tool, host.sha256(json.encode(args)))
    if entry and entry.read and age_of(entry, now) <= math.min(seconds, M.MAX_AGE_S) then
      local value, problem = read_result(entry.result)
      if value ~= nil then
        count(ctx, "codemode_reuse", { tool = tool, age_s = age_of(entry, now), hit = true, call = entry.id })
        return { ok = true, reused_from = entry.id, age_s = age_of(entry, now), value = value,
          note = "Reused an earlier identical read, asked for explicitly by {reuse}. Nothing was dispatched." }, true
      end
      return { ok = true, note = "the earlier result is no longer retained (" .. tostring(problem) .. "); this call ran fresh" }, true
    end
    count(ctx, "codemode_reuse", { tool = tool, hit = false })
    return { ok = true, note = "no identical read within the requested age; this call ran fresh" }, true
  end
  return { error = "results_unknown_op:" .. op, effect = "none", ops = { "get", "last", "diff", "reuse" } }, false
end

-- `searchTools("select:results")[0]` answers this: the shape a script should expect, in one place.
M.HELP = {
  name = "results",
  description = "Read this session's earlier code-mode results. results.get(sha256) returns {ok,hash,value} - the full prior result under value - for a hash from attempts[].result.sha256 or results.last; a result too large to decode answers {hash,text,next_offset,bytes,truncated} instead. results.last(n, {tool}) lists the newest n journal rows {call,tool,age_s,ok,read,arguments,result}. results.diff(a,b) compares two result hashes and answers {same,count,changed:[{path,before,after}]}. Nothing here dispatches a call: every tool call is always fresh, and reuse happens only when a script asks for it explicitly - results.get/results.last by hash, or tools.x(args,{reuse:\"60s\"}) which returns the newest identical read younger than that age marked {reused_from,age_s} and otherwise runs fresh. A fresh read-only call that repeats an identical earlier one carries prior:{call,age_s,same}. Reuse an earlier result only by asking for it (results.get / {reuse}).",
  code = "const earlier = await results.last(3, {tool:'read'}); const same = earlier.results.filter(r => r.result === earlier.results[0].result).length; const full = await results.get(earlier.results[0].result); return {same, bytes: JSON.stringify(full).length};",
}

return M
