-- Turn feed: the model's own `<turn>` notes, collected, grouped and ranked into a queue.
--
-- WHY. Every session ends with a note - what hurt the reasoning, what removing it would buy, and the
-- one harness optimisation to focus on (`lua/core/agent.lua`, the `turn` prompt section). Every real
-- fix this fleet landed began with one of them: empty connector schemas, a value buried in an evidence
-- envelope, `json_number_invalid` from a no-argument call, nameless tool calls, a comment asserting a
-- fix on the path not taken. But they were found by a human reading transcripts by chance, because
-- nothing collected them. This module is the collection: it reads the notes out of the ledger, groups
-- the ones that describe the same problem, ranks the groups by frequency x cost x recency, and answers
-- with a mission brief skeleton an operator can hand to a session.
--
-- The three parts are the model's OWN words about the harness (that is what the section asks for), so a
-- note is evidence about the tool surface, not about the operator's data. It can still quote user data -
-- a model writing "the WhatsApp message said ..." - which is why every record goes through `M.redact`
-- before it is stored, printed, digested or sent to a peer. Stripping happens at collection, not at
-- printing: a caller cannot forget it.
--
-- Grouping is deterministic and explainable, never a model call: a note joins the group it is most
-- similar to, where similarity is a weighted Dice coefficient over named signals (tool names, error
-- codes, file paths - weight 3) and ordinary words (weight 1). A signal that appears in more than half
-- the notes cannot name a group and is dropped from the comparison, which is what keeps a fleet where
-- every note mentions `bash` from collapsing into one group. Two notes belong together when they share
-- a named signal and at least a fifth of their weight, or when they agree on half of everything.
--
-- "Fixed" is a fact recorded, not a claim trusted: a marker names a cluster and the commit that claims
-- it, with the commit's own time, so the report can answer "are new notes about this still arriving
-- after that commit?" on any node, including one that cannot see the repository.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")

local M = {}

M.SCHEMA = 1
-- Bounded the way every other reader of the ledger is: a report is a page, not a dump. The cap is per
-- query and the query is ordered newest first when it truncates, because an old note is not the queue.
M.MAX_NOTES = 2000
-- A note is a paragraph. The cap is applied after redaction, so a field can never be carried past the
-- limit by the thing redaction inserted.
M.MAX_FIELD = 1200
-- What one line of a report quotes. Long enough to recognise the problem, short enough that forty
-- clusters stay readable on a terminal.
M.QUOTE = 220
-- A marker older than this is not proof of a fix any more - the note has had three weeks to come back.
M.QUIET_DAYS = 21

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- One line, no control bytes: a note's text reaches a report, a terminal and JSON, and a stray tab or
-- CR from a pasted block would break all three differently.
function M.one_line(text)
  return (tostring(text or ""):gsub("[%z\1-\31\127]", " "):gsub("%s+", " "))
end

local function cap(text, limit)
  local value = M.one_line(text)
  if #value > limit then value = value:sub(1, limit - 1) .. "…" end
  return value
end

-- --------------------------------------------------------------------------- privacy

-- Third-party payload stripping, as named rules, so a leak names the rule that missed.
--
-- The order matters and is not arbitrary: dates and clock times are protected first (a phone-shaped
-- match would otherwise eat `2026-11-13 20:22` out of the model's own sentence), then credentials, then
-- the two channels a person's data arrives through - an address, a number - and last the quoted bodies
-- themselves. A quoted run of 24 characters or more is treated as somebody else's words: the model's
-- own remark about the harness is prose, not a quotation, and the sentences around a quotation survive.
local DATE_LIKE = "\1%d%d%d%d%-%d%d%-%d%d\1"
local TIME_LIKE = "\1%d%d:%d%d\1"

local function protect(text)
  local kept = {}
  local function stash(match)
    kept[#kept + 1] = match
    return "\1" .. (#kept) .. "\2"
  end
  text = text:gsub("%d%d%d%d%-%d%d%-%d%d", stash)
  text = text:gsub("%d%d:%d%d", stash)
  return text, kept
end

local function restore(text, kept)
  return (text:gsub("\1(%d+)\2", function(index)
    return kept[tonumber(index)] or ""
  end))
end

-- The rules, in the order `M.redact` applies them. Exposed as data so a test asserts every rule ran.
M.PRIVACY_RULES = { "notice", "bearer", "key", "email", "phone", "payload", "quoted" }

function M.redact(text)
  local value = M.one_line(text)
  if value == "" then return value end
  -- An automated notice's body is the Sentinel's status text, never the model's own words.
  value = value:gsub("%[Sentinel notice%][^%[]*", "[Sentinel notice] ")
  value = value:gsub("[Bb]earer%s+[%w%-%._~%+/=]+", "Bearer <secret>")
  value = value:gsub("%f[%w]sk%-[%w%-_]+", "<secret>")
  value = value:gsub("%f[%w%-%.][%w._%%%+%-]+@[%w%-]+%.[%a][%a]+", "<email>")
  local body, kept = protect(value)
  -- A number is a phone number when it is long enough to be one: nine digits or more, which is every
  -- international subscriber number and no date, no port, no pid.
  body = body:gsub("%+?%d[%d%s%-%.%(%)]*%d", function(candidate)
    local digits = #(candidate:gsub("%D", ""))
    if digits < 9 then return candidate end
    return "<phone>"
  end)
  -- A field carrying a person's message: `From:`, `Subject:`, `jid:`, `body:`, `text:` and the JSON
  -- spelling of the same field, up to the end of the line or the closing quote.
  body = body:gsub("(%f[%a]%a+:%s*\")[^\"]-\"", "%1<payload>\"")
  -- The plain field spellings (`From:`, `Subject:`, `jid:` ...). One pattern per name: a Lua pattern
  -- has no alternation, and the single-pattern version of this line matched nothing at all.
  for _, field in ipairs({ "From", "from", "To", "to", "Subject", "subject", "Body", "body",
      "jid", "Jid", "chat", "Chat" }) do
    body = body:gsub("(%f[%a]" .. field .. "%s*:)([^;,%(%)%[%]]*)", "%1<payload>")
  end
  value = restore(body, kept)
  -- Somebody else's words: a long quotation is a message or a transcript, the model's own remark is not.
  value = value:gsub("\"[^\"\n]-\"", function(quoted)
    if #quoted - 2 >= 24 then return "\"<quoted>\"" end
    return quoted
  end)
  value = value:gsub("\226\128\156[^\226]*\226\128\157", function(quoted)
    if #quoted - 6 >= 24 then return "\226\128\156<quoted>\226\128\157" end
    return quoted
  end)
  return trim(value:gsub("%s+", " "))
end

-- --------------------------------------------------------------------------- the note itself

local HEADINGS = {
  { key = "hurt", label = "what hurt" },
  { key = "buys", label = "what it buys" },
  { key = "focus", label = "focus" },
}

-- Which part a line opens, if any. The label can be fenced in `**`, followed by `—`, `-`, `:` or
-- nothing: every spelling this fleet's models have used, and the prompt's own line is one of them.
local function heading(line)
  -- The spellings this fleet's models have used, all of them already in the ledger: `**what hurt** —`,
  -- `- **what hurt** —`, `• what hurt —`, `1. what hurt:`, `_what hurt_`. A list marker or a fence in
  -- front of the label is formatting, not a different heading, and reading it as prose is how a note
  -- once arrived with its whole block as a single "what hurt".
  local bare = trim(line)
  for _ = 1, 3 do
    local stripped = bare:gsub("^[%-%*%+•–—]%s*", ""):gsub("^#+%s*", ""):gsub("^%d+[%.)]%s*", "")
    if stripped == bare then break end
    bare = stripped
  end
  local lower = bare:lower()
  for _, entry in ipairs(HEADINGS) do
    if lower:sub(1, #entry.label) == entry.label then
      local rest = bare:sub(#entry.label + 1)
      if rest == "" or rest:match("^[%*_%s]") or rest:match("^[—%-–:]") then
        -- `**focus:** text`, `**focus** — text`, `focus: text`: the fence can sit on either side of
        -- the separator, so both are peeled until neither is left.
        local tail = rest
        for _ = 1, 4 do
          local stripped = tail:gsub("^[%*_%s]+", ""):gsub("^[—%-–:]+", "")
          if stripped == tail then break end
          tail = stripped
        end
        return entry.key, trim(tail)
      end
    end
  end
  return nil
end

-- The `<turn>` block of one message, as its three parts. `nil` when the message carries no block:
-- a session that answered without a retrospective is not a note, and inventing one would put the
-- model's ordinary prose into a queue about the harness.
-- Where the block starts, or nil. The tag has to OPEN A LINE: a message that mentions `<turn>` in a
-- sentence ("every session ends with a `<turn>` note") is talking about the section, not writing one,
-- and parsing it turned a session's ordinary prose into a note about the harness (measured on the real
-- ledger: 1 of 51 notes was such a mention, quoting the sentence that named the tag).
local function block_start(content)
  local from = 1
  while true do
    local at = content:find("<turn>", from, true)
    if not at then return nil end
    local line_start = (content:sub(1, at - 1):match(".*()\n") or 0) + 1
    if content:sub(line_start, at - 1):match("^%s*$") then return at end
    from = at + 1
  end
end

function M.parse(content)
  if type(content) ~= "string" then return nil end
  local start = block_start(content)
  if not start then return nil end
  local body = content:sub(start + 6)
  local stop = body:find("</turn>", 1, true)
  if stop then body = body:sub(1, stop - 1) end
  local parts = { hurt = {}, buys = {}, focus = {} }
  local order, current = {}, nil
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local key, first = heading(line)
    if key then
      current = key
      if parts[key][1] == nil then order[#order + 1] = key end
      if first and first ~= "" then parts[key][#parts[key] + 1] = first end
    elseif current then
      if trim(line) ~= "" then parts[current][#parts[current] + 1] = trim(line) end
    end
  end
  local out = { hurt = trim(table.concat(parts.hurt, " ")), buys = trim(table.concat(parts.buys, " ")),
    focus = trim(table.concat(parts.focus, " ")) }
  if #order == 0 then
    -- One line and no headings - the shape the section itself asks for when nothing hurt
    -- ("say so in one line and stop"). It is still a note, but only when the block is closed: an
    -- opening tag with no close and no labels is a mention, not a retrospective.
    if not stop then return nil end
    local flat = trim((body:gsub("<[^>]->", " ")))
    if flat == "" then return nil end
    out.hurt = flat
  end
  if out.hurt == "" and out.buys == "" and out.focus == "" then return nil end
  return out
end

-- --------------------------------------------------------------------------- signals

-- Connective tissue: nothing here names a subsystem, a tool or an error.
local STOP = {}
for word in ([[the a an and or but if then than that this these those it its is are was were be been being
of to in on at for with from by as not no nor so such only also just very more most less least
what which who whom whose when where why how there here their them they we our you your i me my
would could should can may might must will shall do does did done have has had into over under
same other another each every any all some one two three step steps call calls turn turns note notes
because before after again still even about while since within without against between through
first second third last next both either neither own same another thing things way ways time times
case cases part parts make makes made made get gets got give gives given take takes taken
row rows line lines code lines file files says said say see seen look looks looked
work works worked run runs ran try tries tried need needs needed want wants use uses used
true false nil error errors right wrong good better best bad worse worst]]):gmatch("%S+") do
  STOP[word] = true
end

-- The tools and capabilities a note can name as a single word. Most of the surface is snake-cased
-- (`read_many`, `spell_run`) and is caught generically; these are the ones the catalogue spells without
-- an underscore, and without them a note about `edit` and a note about `bash` had no named signal at
-- all - only their prose, which is exactly the comparison the grouping is supposed to avoid.
local TOOL_WORDS = {}
for word in ([[bash codemode read write edit grep ls glob session sessions search recall remember
memories skill skills spell spells subagent operation remote nodes health status time wake notes
memory tools tool dispatch prompt model provider vault whatsapp mail component sandbox]]):gmatch("%S+") do
  TOOL_WORDS[word] = true
end

local KNOWN_EXT = { lua = true, rs = true, mjs = true, cjs = true, js = true, sh = true, ps1 = true,
  md = true, json = true, sql = true, toml = true, yml = true, yaml = true, wit = true, wasm = true,
  txt = true, csv = true }

-- A snake identifier: starts with a letter, letters/digits/underscores only, at least one underscore,
-- no doubled or trailing one. Lua patterns cannot repeat a group (`(_[a-z0-9]+)+` silently matches
-- nothing), so this is a small function rather than a pattern - the version written as a pattern made
-- every tool name and error code in a note invisible to the grouping.
local function snake(token)
  if not token:match("^[a-z]") then return false end
  if not token:match("^[a-z0-9_]+$") then return false end
  if not token:find("_", 1, true) then return false end
  if token:find("__", 1, true) or token:sub(-1) == "_" then return false end
  return true
end

-- The named things a note talks about, sorted so two runs of the same text agree byte for byte.
-- Named means: a tool/capability/error identifier (`read_many`, `json_number_invalid`, `stale_binary`)
-- or a path/file (`lua/core/init.lua`, `scripts/fast.sh`). Everything else is a word.
function M.signals(text)
  local lower = M.one_line(text):lower()
  local names, files, words = {}, {}, {}
  for token in lower:gmatch("[%w_][%w_%./%-]*") do
    local bare = token:gsub("[%.,;:%)]+$", "")
    local ext = bare:match("%.(%a+)$")
    if bare == "" then
      -- nothing to name
    elseif snake(bare) then
      -- A snake identifier: a tool, a capability or an error code (`read_many`, `stale_binary`).
      names[bare] = true
    elseif ext and KNOWN_EXT[ext] then
      -- A path or a file name with a known extension (`lua/core/init.lua`, `scripts/fast.sh`).
      files[bare] = true
    elseif TOOL_WORDS[bare] then
      names[bare] = true
    elseif #bare >= 3 and bare:match("^[a-z][a-z%-]*$") and not STOP[bare] then
      words[bare] = true
    end
  end
  local function sorted(set)
    local list = {}
    for key in pairs(set) do list[#list + 1] = key end
    table.sort(list)
    return list
  end
  return { named = sorted(names), files = sorted(files), words = sorted(words) }
end

-- --------------------------------------------------------------------------- collection

function M.state_dir()
  local override = host.getenv("WA_TURNS_STATE")
  if override and override ~= "" then return (override:gsub("\\", "/"):gsub("/+$", "")) end
  return paths.config() .. "/turns"
end

function M.reports_dir()
  local override = host.getenv("WA_TURNS_REPORTS")
  if override and override ~= "" then return (override:gsub("\\", "/"):gsub("/+$", "")) end
  return paths.config() .. "/reports"
end

function M.fixed_path() return M.state_dir() .. "/fixed.json" end

local function query(statement, params)
  local ok, raw = pcall(host.sql_query, statement, json.encode(params or {}))
  if not ok or type(raw) ~= "string" then return {} end
  local value = json.decode(raw)
  if type(value) ~= "table" then return {} end
  return value
end

local function exec(statement, params)
  local ok, raw = pcall(host.sql_exec, statement, json.encode(params or {}))
  if not ok then return false, tostring(raw) end
  return true, raw
end

-- "24h", "7d", "90m", "2w", or an ISO date "2026-11-01". Seconds since the epoch, or nil for "all".
function M.parse_since(text, now)
  now = now or host.now()
  if text == nil or text == "" or text == "all" then return nil end
  local value = tostring(text)
  local count, unit = value:match("^(%d+)%s*([hdwm])$")
  if count then
    local seconds = { h = 3600, d = 86400, w = 604800, m = 60 }
    return now - tonumber(count) * seconds[unit]
  end
  local y, mo, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y then
    local epoch = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 0 })
    return epoch
  end
  return nil, "invalid_since"
end

local function previous_user_seq(session_id, seq)
  local rows = query("SELECT MAX(seq) AS seq FROM messages WHERE session_id=? AND role='user' AND seq<?",
    { session_id, seq })
  return tonumber(rows[1] and rows[1].seq) or 0
end

-- What one turn cost, measured in the ledger rather than estimated from the note's prose: the span is
-- "after the user asked, up to and including the answering message", the way `runs` counts a turn.
-- `steps` is the model calls the turn took, `tool_calls` what it asked for, `tool_errors` the ones that
-- came back failed (a redo the model had to pay for) and `retries` the provider retries it ate.
local function turn_cost(session_id, seq)
  local from = previous_user_seq(session_id, seq)
  local rows = query([[
    SELECT SUM(CASE WHEN role='tool' THEN 1 ELSE 0 END) AS tool_calls,
           SUM(CASE WHEN role='tool' AND ok=0 THEN 1 ELSE 0 END) AS tool_errors,
           SUM(CASE WHEN role='retry' THEN 1 ELSE 0 END) AS retries,
           SUM(CASE WHEN role='assistant' THEN 1 ELSE 0 END) AS steps,
           SUM(tokens) AS tokens
    FROM messages WHERE session_id=? AND seq>? AND seq<=?]], { session_id, from, seq })
  local row = rows[1] or {}
  return { steps = tonumber(row.steps) or 0, tool_calls = tonumber(row.tool_calls) or 0,
    tool_errors = tonumber(row.tool_errors) or 0, retries = tonumber(row.retries) or 0,
    tokens = tonumber(row.tokens) or 0 }
end

-- The "5 → 2" a note sometimes states outright: the steps the model says the fix would save. The arrow
-- is matched as its UTF-8 bytes (a Lua character class is a byte class, so `[→-]` would match one byte of
-- the arrow and then fail on the digits), and `->` is accepted beside it.
local function stated_delta(text)
  local value = M.one_line(text)
  local from, to = value:match("(%d+)%s*\226\134\146%s*(%d+)")
  if not from then from, to = value:match("(%d+)%s*%-%->%s*(%d+)") end
  from, to = tonumber(from), tonumber(to)
  if from and to and from > to then return from - to end
  return 0
end

-- The cost of one note, as an integer, from the two places it is visible: the ledger (failed calls,
-- provider retries, model calls the turn needed) and the note itself (its own "N → M" claim).
function M.cost(measured, parts)
  -- One statement per note, wherever it was written: a model that puts "5 → 2" in what it buys has said
  -- the same thing as one that puts it in what hurt, and summing the three would count it three times.
  local delta = math.max(stated_delta(parts.hurt), stated_delta(parts.buys or ""), stated_delta(parts.focus))
  local cost = measured.tool_errors + measured.retries + math.floor(measured.steps / 10) + delta
  if cost < 0 then cost = 0 end
  return cost, delta
end

local function model_of(content, session_id, seq)
  local from_trace = M.one_line(content):match('"model"%s*:%s*"([^"%s]+)"')
  if from_trace then return from_trace end
  local rows = query([[SELECT payload FROM harness_events WHERE session_id=? AND kind='model_call' AND seq<?
    ORDER BY seq DESC LIMIT 1]], { session_id, seq })
  local payload = rows[1] and rows[1].payload or ""
  return payload:match('"model"%s*:%s*"([^"%s]+)"') or ""
end

local function node_name()
  local ok, nodes = pcall(dofile, "lua/core/nodes.lua")
  if ok and type(nodes) == "table" and type(nodes.node_name) == "function" then
    local ran, name = pcall(nodes.node_name)
    if ran and type(name) == "string" and name ~= "" then return name end
  end
  return "local"
end
M.node_name = node_name

-- Every note this node holds, normalized and redacted. `opts.since` is seconds (see `M.parse_since`),
-- `opts.limit` caps the result.
function M.notes(opts)
  opts = opts or {}
  local since = tonumber(opts.since)
  local limit = math.max(1, math.min(tonumber(opts.limit) or M.MAX_NOTES, M.MAX_NOTES))
  local statement = [[SELECT m.id, m.session_id, m.seq, m.content, m.trace, m.created_at,
      s.title, s.user_id, s.node_id
    FROM messages m LEFT JOIN sessions s ON s.id=m.session_id
    WHERE m.role='assistant' AND instr(m.content,'<turn>')>0]]
  local params = {}
  if since then
    statement = statement .. " AND m.created_at>=?"
    params[#params + 1] = since
  end
  statement = statement .. " ORDER BY m.created_at ASC, m.seq ASC LIMIT ?"
  params[#params + 1] = limit
  local rows = query(statement, params)
  local name = opts.node or node_name()
  local out = {}
  for _, row in ipairs(rows) do
    local parsed = M.parse(row.content)
    if parsed then
      local hurt = cap(M.redact(parsed.hurt), M.MAX_FIELD)
      local buys = cap(M.redact(parsed.buys), M.MAX_FIELD)
      local focus = cap(M.redact(parsed.focus), M.MAX_FIELD)
      local measured = turn_cost(row.session_id, tonumber(row.seq) or 0)
      local cost, delta = M.cost(measured, { hurt = hurt, buys = buys, focus = focus })
      out[#out + 1] = {
        schema = M.SCHEMA,
        node = name,
        session = tostring(row.session_id or ""),
        message = tostring(row.id or ""),
        seq = tonumber(row.seq) or 0,
        at = tonumber(row.created_at) or 0,
        title = cap(row.title or "", 120),
        model = model_of(row.trace or "", row.session_id, tonumber(row.seq) or 0),
        hurt = hurt, buys = buys, focus = focus,
        quote = cap(focus ~= "" and focus or hurt, M.QUOTE),
        quote_field = focus ~= "" and "focus" or "hurt",
        cost = cost, delta = delta,
        measured = measured,
      }
    end
  end
  return out
end

-- --------------------------------------------------------------------------- grouping

local function weighted(signals, df, total)
  local map, named = {}, {}
  local function offer(token)
    local seen = df[token] or 0
    -- A signal in three quarters of the notes cannot name a group: it is the shape of the fleet's prose,
    -- not the shape of the problem (measured on this node's ledger: `scripts/fast.sh` and `bash` are in
    -- most notes, and a rule at half would also drop a tool named in three notes of five - which is a
    -- genuine cluster, not noise). The rule needs a corpus before it means anything, so a handful of
    -- notes is compared on everything it says.
    if total >= 5 and seen * 4 > total * 3 then return end
    map[token] = 3
    named[token] = true
  end
  for _, token in ipairs(signals.named) do offer(token) end
  for _, token in ipairs(signals.files) do offer(token) end
  for _, token in ipairs(signals.words) do
    if not map[token] then map[token] = 1 end
  end
  return map, named
end

local function dice(a, b)
  local shared, named_shared, sum_a, sum_b = 0, 0, 0, 0
  for token, weight in pairs(a) do
    sum_a = sum_a + weight
    local other = b[token]
    if other then
      shared = shared + math.min(weight, other)
      if weight > 1 and other > 1 then named_shared = named_shared + 1 end
    end
  end
  for _, weight in pairs(b) do sum_b = sum_b + weight end
  if sum_a + sum_b == 0 then return 0, 0 end
  return 2 * shared / (sum_a + sum_b), named_shared
end

-- The rule, because it is the whole of the answer to "why are these together?": a shared NAMED signal
-- plus a fifth of the weight, or half the weight agreeing on its own.
--
-- The fifth is measured, not chosen for taste. On this node's own ledger (50 notes) the same run answers
-- 27 clusters at 0.20, 46 at 0.30 and 50 at 0.40: a note is a paragraph, so its word set is large and the
-- Dice denominator grows with it, which makes three tenths unreachable except for near-identical text.
-- Raising the bar does not sharpen the grouping, it removes it. What keeps the 0.20 clusters honest is the
-- named-signal requirement beside it and the "three quarters of the notes" filter above.
local JOIN_NAMED_SIMILARITY = 0.20
local JOIN_PLAIN_SIMILARITY = 0.5

-- One spelling per file. Two notes about `scripts/fast.sh` do not belong apart because one of them
-- wrote `fast.sh`: a bare name that is the tail of exactly one full path in this run IS that path. A
-- bare name that matches several is left alone, because guessing would merge two different files.
local function normalize_paths(enriched)
  local tails = {}
  for _, item in ipairs(enriched) do
    for _, token in ipairs(item.signals.files) do
      if token:find("/", 1, true) then
        local tail = token:match("([^/]+)$")
        if tail then
          tails[tail] = tails[tail] or {}
          tails[tail][token] = true
        end
      end
    end
  end
  for _, item in ipairs(enriched) do
    local rewritten, touched = {}, false
    for _, token in ipairs(item.signals.files) do
      local candidates = (not token:find("/", 1, true)) and tails[token] or nil
      local count = 0
      local only = nil
      for path in pairs(candidates or {}) do count = count + 1; only = path end
      if count == 1 then
        rewritten[only] = true
        touched = true
      else
        rewritten[token] = true
      end
    end
    if touched then
      local list = {}
      for token in pairs(rewritten) do list[#list + 1] = token end
      table.sort(list)
      item.signals.files = list
    end
  end
end

-- The signals of a list of notes, with one spelling per file across the list. Exported because the
-- brief's anchor asks the same question the grouping asks, and two answers to "what does this note
-- name?" would drift - `fast.sh` in one and `scripts/fast.sh` in the other.
function M.note_signals(notes)
  local enriched = {}
  for index, note in ipairs(notes) do
    enriched[index] = { note = note,
      signals = M.signals(table.concat({ note.hurt, note.buys, note.focus }, " ")) }
  end
  normalize_paths(enriched)
  local out = {}
  for index, item in ipairs(enriched) do out[index] = item.signals end
  return out
end

local function clusters_of(notes)
  local df = {}
  local enriched = {}
  local prepared = M.note_signals(notes)
  for index, note in ipairs(notes) do
    enriched[index] = { note = note, signals = prepared[index] }
  end
  for _, item in ipairs(enriched) do
    local signals = item.signals
    local seen = {}
    for _, token in ipairs(signals.named) do seen[token] = true end
    for _, token in ipairs(signals.files) do seen[token] = true end
    for token in pairs(seen) do df[token] = (df[token] or 0) + 1 end
  end
  local total = #enriched
  local clusters = {}
  for _, item in ipairs(enriched) do
    local map, named = weighted(item.signals, df, total)
    local best, best_similarity = nil, -1
    for _, cluster in ipairs(clusters) do
      local similarity, named_shared = dice(map, cluster.weights)
      local joins = (named_shared > 0 and similarity >= JOIN_NAMED_SIMILARITY)
        or similarity >= JOIN_PLAIN_SIMILARITY
      if joins and similarity > best_similarity then best, best_similarity = cluster, similarity end
    end
    if not best then
      best = { notes = {}, weights = {}, named = {}, files = {}, similarity = 0 }
      clusters[#clusters + 1] = best
    end
    best.notes[#best.notes + 1] = item.note
    best.similarity = math.max(best.similarity, best_similarity)
    for token, weight in pairs(map) do
      if not best.weights[token] or best.weights[token] < weight then best.weights[token] = weight end
    end
    for token in pairs(named) do best.named[token] = true end
    for _, token in ipairs(item.signals.files) do best.files[token] = true end
  end
  for _, cluster in ipairs(clusters) do
    local sorted = {}
    for token in pairs(cluster.weights) do sorted[#sorted + 1] = token end
    table.sort(sorted)
    local named, files = {}, {}
    for token in pairs(cluster.named) do named[#named + 1] = token end
    for token in pairs(cluster.files) do files[#files + 1] = token end
    table.sort(named)
    table.sort(files)
    cluster.signals = sorted
    cluster.named, cluster.files = named, files
    -- The identity of a cluster is what it NAMES and what it says about it, so the same problem on two
    -- nodes (or two months apart) answers with the same id - which is what makes a "fixed" marker
    -- addressable at all. The words have to be in the anchor: three clusters whose only named signal
    -- was `fast.sh` once shared one id, and a marker would have marked all three.
    local words = {}
    for _, token in ipairs(sorted) do
      if cluster.weights[token] == 1 then words[#words + 1] = token end
    end
    local anchor = table.concat(named, "|") .. "#" .. table.concat(words, "|")
    cluster.id = "T-" .. host.sha256(anchor):sub(1, 6)
  end
  return clusters
end
M.clusters_of = clusters_of

-- Frequency x cost x recency, each visible in the record: `count` notes, `cost` their summed integer
-- cost, and a recency weight that is 2.0 for a note written today and approaches 1.0 as it ages (a
-- problem nobody has hit in a month is not the top of today's queue).
function M.rank(clusters, opts)
  opts = opts or {}
  local now = opts.now or host.now()
  for _, cluster in ipairs(clusters) do
    local nodes, sessions, newest, cost, deltas = {}, {}, 0, 0, 0
    for _, note in ipairs(cluster.notes) do
      nodes[note.node] = (nodes[note.node] or 0) + 1
      sessions[note.session] = true
      if note.at > newest then newest = note.at end
      cost = cost + (note.cost or 0)
      deltas = deltas + (note.delta or 0)
    end
    local names, sessions_list = {}, {}
    for name in pairs(nodes) do names[#names + 1] = name end
    for session in pairs(sessions) do sessions_list[#sessions_list + 1] = session end
    table.sort(names)
    table.sort(sessions_list)
    local age_days = math.max(0, (now - newest) / 86400)
    local recency = 1 + 1 / (1 + age_days / 7)
    cluster.nodes = names
    cluster.sessions = sessions_list
    cluster.count = #cluster.notes
    cluster.cost = cost
    cluster.delta = deltas
    cluster.newest = newest
    cluster.age_days = age_days
    cluster.recency = recency
    cluster.score = cluster.count * (1 + cost) * recency
  end
  table.sort(clusters, function(a, b)
    if math.abs(a.score - b.score) > 1e-9 then return a.score > b.score end
    if a.newest ~= b.newest then return a.newest > b.newest end
    return a.id < b.id
  end)
  return clusters
end

-- --------------------------------------------------------------------------- fixed markers

local function read_json(path)
  local text = host.read_file(path)
  if not text or text == "" then return nil end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" then return nil, "unreadable" end
  return value
end

-- Every marker, keyed by cluster id. A corrupt store is named, never replaced by an empty one in
-- silence: "no cluster has been fixed" and "the file is broken" are different answers.
function M.fixed(opts)
  opts = opts or {}
  local store = read_json(M.fixed_path())
  if store == nil then return {}, nil end
  if type(store.clusters) ~= "table" then return {}, "store_corrupt" end
  return store.clusters, store.error
end

local function write_fixed(store)
  host.write_file(M.state_dir() .. "/.keep", "")
  return host.write_file(M.fixed_path(), json.encode({ version = M.SCHEMA, clusters = store })) and true or false
end

-- The commit's own time, so a node that cannot see the repository still compares against the fix.
-- A sha that does not parse is refused before anything is run; a repository that cannot answer is
-- reported as `at_source = "marked_at"` rather than silently treated as "the fix time".
function M.commit_time(sha)
  if type(sha) ~= "string" or not sha:match("^%x%x%x%x%x%x%x%x+$") then return nil, "invalid_sha" end
  local root = host.getenv("WASM_AGENT_LUA_ROOT") or ""
  local ok, raw = pcall(host.exec, "git show -s --format=%ct " .. sha, root, 60)
  if not ok then return nil, "git_unavailable" end
  local value = type(raw) == "string" and json.decode(raw) or raw
  if type(value) ~= "table" or tonumber(value.code) ~= 0 then return nil, "commit_not_found" end
  local at = tonumber(trim(value.stdout or ""))
  if not at then return nil, "commit_time_unreadable" end
  return at
end

function M.mark_fixed(cluster, sha, opts)
  opts = opts or {}
  if type(cluster) ~= "string" or cluster == "" then return nil, "missing_cluster" end
  if type(sha) ~= "string" or sha == "" then return nil, "missing_sha" end
  local at, problem = M.commit_time(sha)
  local source = "commit"
  if not at then
    if problem ~= "invalid_sha" and problem ~= "commit_not_found" then
      -- No repository here to ask: the mark time is the honest bound, and the report says so.
      at, source = host.now(), "marked_at"
    else
      return nil, problem
    end
  end
  local store = read_json(M.fixed_path()) or { clusters = {} }
  if type(store.clusters) ~= "table" then store.clusters = {} end
  store.clusters[cluster] = { cluster = cluster, sha = sha, at = at, at_source = source,
    marked_at = host.now(), node = opts.node or node_name(), note = cap(opts.note or "", 200) }
  if not write_fixed(store.clusters) then return nil, "store_write_failed" end
  return store.clusters[cluster]
end

function M.unmark_fixed(cluster)
  local store = read_json(M.fixed_path()) or { clusters = {} }
  if type(store.clusters) ~= "table" or not store.clusters[cluster] then return nil, "not_marked" end
  store.clusters[cluster] = nil
  if not write_fixed(store.clusters) then return nil, "store_write_failed" end
  return true
end

-- Was this cluster's problem seen after its fix? The answer is the count of notes newer than the
-- commit, so "quiet" is a measurement, not an absence.
function M.status(cluster, markers, now)
  local marker = (markers or {})[cluster.id]
  if not marker then return { state = "unfixed" } end
  local after, newest = 0, 0
  for _, note in ipairs(cluster.notes) do
    if note.at > (marker.at or 0) then
      after = after + 1
      if note.at > newest then newest = note.at end
    end
  end
  local days = math.max(0, ((now or host.now()) - (marker.at or 0)) / 86400)
  if after > 0 then
    return { state = "still_hurting", after = after, sha = marker.sha, at = marker.at,
      at_source = marker.at_source, days = days, newest = newest }
  end
  return { state = "quiet", after = 0, sha = marker.sha, at = marker.at,
    at_source = marker.at_source, days = days, newest = newest }
end

-- --------------------------------------------------------------------------- peers

-- Peers answer their own notes. This is the read-only capability a master's `wa turns` calls on every
-- node it can see, so the queue is the fleet's and not the stopping-point's. Answering is the same
-- normalization the local run uses, redaction included: a peer never hands over a transcript, only the
-- notes it derived from one.
function M.serve(args)
  args = args or {}
  local since, problem = M.parse_since(args.since, host.now())
  if problem then return { error = problem, schema = M.SCHEMA } end
  local notes = M.notes({ since = since, limit = args.limit })
  return { schema = M.SCHEMA, node = node_name(), collected_at = host.now(), count = #notes, notes = notes }
end

local function node_list(opts)
  local ok, nodes = pcall(dofile, "lua/core/nodes.lua")
  if not ok or type(nodes) ~= "table" then return {}, "nodes_unavailable" end
  local ran, rows = pcall(nodes.list, { cached = true })
  if not ran or type(rows) ~= "table" then return {}, "nodes_unavailable" end
  local out = {}
  for _, node in ipairs(rows) do
    if not node.local_node and node.online ~= false then out[#out + 1] = node end
  end
  return out, nil
end

-- Every peer that answers, and every peer that does not - by name, because a fleet report that
-- silently covers one node is a report about that node only.
function M.peer_notes(opts)
  opts = opts or {}
  local nodes, problem = node_list(opts)
  if problem then return {}, { { node = "peers", error = problem } } end
  local wanted = opts.nodes
  local nodeslib = dofile("lua/core/nodes.lua")
  local notes, failures = {}, {}
  for _, node in ipairs(nodes) do
    local name = tostring(node.name or node.node_id or "")
    if not wanted or wanted[name] then
      local ok, answer = pcall(nodeslib.remote_call, node.node_id or name, "turns",
        { since = opts.since_text, limit = opts.limit, schema = M.SCHEMA })
      if ok and type(answer) == "table" and type(answer.notes) == "table" then
        for _, note in ipairs(answer.notes) do
          if type(note) == "table" then
            note.node = tostring(note.node or name)
            notes[#notes + 1] = note
          end
        end
      else
        failures[#failures + 1] = { node = name,
          error = tostring(type(answer) == "table" and answer.error or answer) }
      end
    end
  end
  return notes, failures
end

-- --------------------------------------------------------------------------- report

local function plural(count, word) return tostring(count) .. " " .. word .. (count == 1 and "" or "s") end

local function when(at) return os.date("%Y-%m-%d %H:%M", math.floor(tonumber(at) or 0)) end
M.when = when

local function brief(cluster, status)
  local listed, seen = {}, {}
  for _, token in ipairs(cluster.named or {}) do
    if not seen[token] then seen[token] = true; listed[#listed + 1] = token end
  end
  for _, token in ipairs(cluster.files or {}) do
    if not seen[token] then seen[token] = true; listed[#listed + 1] = token end
  end
  table.sort(listed)
  local named = #listed > 0 and table.concat(listed, ", ") or "(no tool, error or path named)"
  -- The anchor is the thing the acceptance line can address: the signal these notes name most often,
  -- and where two are named equally often, the more specific one - a path before a snake identifier
  -- before a bare tool word. Without the specificity tie-break a cluster about `scripts/fast.sh` was
  -- summed up as "no note naming `read`", which is true of every note in the fleet.
  local frequencies = {}
  for _, signals in ipairs(M.note_signals(cluster.notes)) do
    local seen = {}
    for _, token in ipairs(signals.named) do seen[token] = true end
    for _, token in ipairs(signals.files) do seen[token] = true end
    for token in pairs(seen) do frequencies[token] = (frequencies[token] or 0) + 1 end
  end
  local function specificity(token)
    if token:find("/", 1, true) or token:match("%.%a+$") then return 2 end
    if token:find("_", 1, true) then return 1 end
    return 0
  end
  local anchor = nil
  for token in pairs(frequencies) do
    if not anchor then
      anchor = token
    else
      local mine, theirs = frequencies[token], frequencies[anchor]
      if mine > theirs or (mine == theirs and specificity(token) > specificity(anchor))
        or (mine == theirs and specificity(token) == specificity(anchor) and token < anchor) then
        anchor = token
      end
    end
  end
  anchor = anchor or cluster.signals[1] or "the symptom"
  local evidence = {}
  for index = #cluster.notes, math.max(1, #cluster.notes - 2), -1 do
    local note = cluster.notes[index]
    evidence[#evidence + 1] = string.format("%s#%s %s: %s", note.node, note.session:sub(1, 8), when(note.at), note.quote)
  end
  local acceptance = string.format(
    "no note whose focus names `%s` after the fix commit for %d days, and the notes already in this cluster re-read as old",
    anchor, M.QUIET_DAYS)
  if status.state == "still_hurting" then
    acceptance = string.format("the %d note(s) after %s stop recurring: no note whose focus names `%s` in the next %d days",
      status.after, string.sub(status.sha or "?", 1, 8), anchor, M.QUIET_DAYS)
  end
  return {
    named = named,
    problem = string.format("%d note(s) on %s describe the same harness cost (cost %d, newest %s)",
      cluster.count, table.concat(cluster.nodes, ","), cluster.cost, when(cluster.newest)),
    evidence = table.concat(evidence, " | "),
    acceptance = acceptance,
  }
end

local function status_line(status)
  if status.state == "unfixed" then return "unfixed" end
  local sha = string.sub(tostring(status.sha or "?"), 1, 8)
  if status.state == "still_hurting" then
    return string.format("still hurting: %d note(s) after %s (%.1f days since the fix)", status.after, sha, status.days)
  end
  return string.format("quiet since %s (%.1f days)", sha, status.days)
end
M.status_line = status_line

-- The report, as lines. One block per cluster: what it is, who hit it, what it names, whether it is
-- fixed, and the brief a session can start from.
function M.report(opts)
  opts = opts or {}
  local markers = opts.markers or {}
  local now = opts.now or host.now()
  -- A report IS a ranking, so it ranks: a caller that hands over freshly grouped clusters (as the tests
  -- and any future reader do) gets the same numbers the command prints, instead of nils where the
  -- scores should be. `M.rank` is idempotent - it recomputes each cluster's count and cost from its own
  -- notes - so ranking an already-ranked set changes nothing.
  local clusters = M.rank(opts.clusters or {}, { now = now })
  local lines = {}
  local header = string.format("turn feed: %s from %s, %s%s", plural(opts.note_count or 0, "note"),
    plural(#(opts.nodes or {}), "node"), plural(#clusters, "cluster"),
    opts.since_text and (" (since " .. opts.since_text .. ")") or " (all time)")
  lines[#lines + 1] = header
  for _, failure in ipairs(opts.failures or {}) do
    lines[#lines + 1] = string.format("  peer %s: not collected (%s)", failure.node, failure.error)
  end
  if #clusters == 0 then
    lines[#lines + 1] = "  no <turn> note matches: nothing to rank"
    return lines
  end
  local shown = math.min(#clusters, tonumber(opts.top) or 10)
  for index = 1, shown do
    local cluster = clusters[index]
    local status = M.status(cluster, markers, now)
    local block = brief(cluster, status)
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("%2d. %s  count %d  nodes %s  cost %d  score %.1f", index, cluster.id,
      cluster.count, table.concat(cluster.nodes, ","), cluster.cost, cluster.score)
    local latest = cluster.notes[#cluster.notes]
    -- Not wrapped in quotes: the model's own words often contain a quotation, and a line that ends in
    -- two sets of marks reads as a malformed quote rather than as one remark.
    lines[#lines + 1] = "    " .. (latest.quote_field or "focus") .. ": " .. latest.quote
    lines[#lines + 1] = "    named: " .. block.named
    lines[#lines + 1] = "    status: " .. status_line(status)
    lines[#lines + 1] = "    brief:"
    lines[#lines + 1] = "      problem: " .. block.problem
    lines[#lines + 1] = "      evidence: " .. block.evidence
    lines[#lines + 1] = "      acceptance: " .. block.acceptance
  end
  if #clusters > shown then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("  (%d more cluster(s); --top %d lists them)", #clusters - shown, #clusters)
  end
  return lines
end

-- The digest: the same ranking as markdown, for a reader who was not at the terminal. It is written to
-- the node's own reports directory, never into a repository (`wa clean` and `.gitignore` both know the
-- home), and it carries the same redacted text the terminal shows - the digest is not a second,
-- less careful surface.
function M.digest(opts)
  opts = opts or {}
  local markers = opts.markers or {}
  local now = opts.now or host.now()
  local clusters = M.rank(opts.clusters or {}, { now = now })
  local day = os.date("%Y-%m-%d", math.floor(now))
  local out = { "# Turn feed - " .. day, "" }
  out[#out + 1] = string.format("%s from %s, %s%s.", plural(opts.note_count or 0, "note"),
    plural(#(opts.nodes or {}), "node"), plural(#clusters, "cluster"),
    opts.since_text and (" since " .. opts.since_text) or " (all time)")
  out[#out + 1] = ""
  out[#out + 1] = "Notes are the model's own `<turn>` retrospectives, redacted at collection: quoted third-party"
  out[#out + 1] = "text, addresses, numbers and connector payloads are stripped before they reach this file."
  out[#out + 1] = ""
  if #clusters == 0 then
    out[#out + 1] = "No `<turn>` note matched, so there is nothing to rank."
  end
  for index, cluster in ipairs(clusters) do
    local status = M.status(cluster, markers, now)
    local block = brief(cluster, status)
    out[#out + 1] = string.format("## %d. %s - %s, cost %d, score %.1f", index, cluster.id,
      plural(cluster.count, "note"), cluster.cost, cluster.score)
    out[#out + 1] = ""
    out[#out + 1] = "- **nodes**: " .. table.concat(cluster.nodes, ", ")
    out[#out + 1] = "- **named**: " .. block.named
    out[#out + 1] = "- **status**: " .. status_line(status)
    local latest = cluster.notes[#cluster.notes]
    out[#out + 1] = "- **" .. (latest.quote_field or "focus") .. "**: " .. latest.quote
    out[#out + 1] = ""
    out[#out + 1] = "```"
    out[#out + 1] = "problem: " .. block.problem
    out[#out + 1] = "evidence: " .. block.evidence
    out[#out + 1] = "acceptance: " .. block.acceptance
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  local path = M.reports_dir() .. "/turns-" .. day .. ".md"
  host.write_file(M.reports_dir() .. "/.keep", "")
  local written = host.write_file(path, table.concat(out, "\n") .. "\n")
  return path, written and true or false
end

return M
