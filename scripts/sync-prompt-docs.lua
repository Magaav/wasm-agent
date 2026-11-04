-- Generated prompt docs: the facts a doc states about the model-request envelope (which tools are
-- declared, which are on demand, their arguments and cues, the order of the prompt layers) are
-- rendered here from the live code, between markers, so a doc cannot drift from the code it
-- describes:
--
--   <!-- generated:<block> (scripts/sync-prompt-docs.lua) -->
--   ...
--   <!-- /generated -->
--
-- WA_PROMPT_DOCS_MODE=write rewrites the blocks; anything else (the default) checks and fails,
-- naming each stale block. Run through scripts/sync-prompt-docs.sh, which the pre-commit hook calls.
-- Only built-in tools are rendered (a node's WASM plugins and MCP connectors vary per machine).
local tools = dofile("lua/core/tools.lua")
local envelope = dofile("lua/core/envelope.lua")
local agent = dofile("lua/core/agent.lua")

local MODE = host.getenv("WA_PROMPT_DOCS_MODE") == "write" and "write" or "check"
local DOCS = { "docs/ENVELOPE.md", "docs/LAYERED-PROMPT.md", "docs/PROGRESSIVE-ENVELOPE.md" }

local function code(name) return "`" .. name .. "`" end
local function codes(list)
  local out = {}
  for i, name in ipairs(list) do out[i] = code(name) end
  return table.concat(out, ", ")
end
local function set(list)
  local out = {}
  for _, name in ipairs(list) do out[name] = true end
  return out
end

-- Built-in catalogue for a role: every tool with an authored cue, in catalogue order.
local function builtin(role)
  local out = {}
  for _, item in ipairs(tools.catalog(role)) do
    local name = item["function"].name
    if tools.snippet(name) then out[#out + 1] = item end
  end
  return out
end

local function args_of(item)
  local params = item["function"].parameters or {}
  local required = set(params.required or {})
  local names = {}
  for key in pairs(params.properties or {}) do names[#names + 1] = key end
  table.sort(names, function(a, b)
    if required[a] ~= required[b] then return required[a] == true end
    return a < b
  end)
  local out = {}
  for _, key in ipairs(names) do out[#out + 1] = code(key .. (required[key] and "" or "?")) end
  return #out > 0 and table.concat(out, " ") or "-"
end

local lean, classic = envelope.core_names("lean"), envelope.core_names("classic")
local lean_set = set(lean)
local extra = {}
for _, name in ipairs(classic) do if not lean_set[name] then extra[#extra + 1] = name end end

local blocks = {}

blocks["bootstrap-tools"] = table.concat({
  "New operator sessions declare " .. #lean .. " tools from the start (`lean`, the default): "
    .. codes(lean) .. ".",
  "`codemode` is also declared when code mode is admitted for the run. Orchestration mode adds "
    .. codes(envelope.orchestration_names()) .. ".",
  "`WASM_AGENT_BOOTSTRAP_MODE=classic` adds " .. codes(extra) .. " (" .. #classic .. " in all).",
  "Every other permitted tool is called on demand with `tool_call`; the system prompt lists it with its cue.",
}, "\n")

do
  local lines = { "Built-in tools not declared at bootstrap, as the progressive prompt lists them "
    .. "(the role, profile and mode still decide visibility):", "" }
  for _, item in ipairs(builtin("master")) do
    local name = item["function"].name
    if not lean_set[name] and name ~= "tool_call" and name ~= "tool_search" and name ~= "codemode" then
      lines[#lines + 1] = "- " .. code(name) .. ": " .. tools.snippet(name)
    end
  end
  blocks["deferred-tools"] = table.concat(lines, "\n")
end

do
  local lines = { "| Tool | Args (`?` optional) | Cue |", "| --- | --- | --- |" }
  for _, item in ipairs(builtin("master")) do
    local name = item["function"].name
    lines[#lines + 1] = "| " .. code(name) .. " | " .. args_of(item) .. " | " .. tools.snippet(name) .. " |"
  end
  local guest = {}
  for _, item in ipairs(builtin("guest")) do guest[#guest + 1] = item["function"].name end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "A guest's catalogue is " .. codes(guest) .. "."
  blocks["tool-catalogue"] = table.concat(lines, "\n")
end

do
  local layers = agent.PROMPT_LAYERS
  local lines = {}
  for _, layer in ipairs(layers.order) do
    local inner = layers.sections[layer]
    lines[#lines + 1] = "- `<" .. layer .. ">`" .. (inner and (": " .. codes(inner)) or "")
  end
  blocks["prompt-layers"] = table.concat(lines, "\n")
end

local OPEN = "<!%-%- generated:([%w%-]+) %(scripts/sync%-prompt%-docs%.lua%) %-%->\n"
local CLOSE = "<!-- /generated -->"

local stale, changed, seen = {}, {}, {}
for _, path in ipairs(DOCS) do
  local text = assert(host.read_file(path), "missing " .. path)
  local out, pos = {}, 1
  while true do
    local s, e, name = text:find(OPEN, pos)
    if not s then break end
    local close = text:find(CLOSE, e + 1, true)
    assert(close, path .. ": block " .. name .. " has no closing marker")
    local body = blocks[name]
    assert(body, path .. ": unknown generated block " .. name)
    seen[name] = true
    local current = text:sub(e + 1, close - 1)
    local wanted = body .. "\n"
    if current ~= wanted then stale[#stale + 1] = path .. ": " .. name end
    out[#out + 1] = text:sub(pos, e) .. wanted
    pos = close
  end
  out[#out + 1] = text:sub(pos)
  local rendered = table.concat(out)
  if rendered ~= text then
    changed[#changed + 1] = path
    if MODE == "write" then assert(host.write_file(path, rendered), "cannot write " .. path) end
  end
end
for name in pairs(blocks) do
  if not seen[name] then stale[#stale + 1] = "no doc carries block " .. name end
end
table.sort(stale)

if MODE == "write" then
  print("sync-prompt-docs: wrote " .. #changed .. " doc(s)" .. (#changed > 0 and (": " .. table.concat(changed, ", ")) or ""))
elseif #stale > 0 then
  error("sync-prompt-docs: stale generated blocks (run scripts/sync-prompt-docs.sh --write):\n  "
    .. table.concat(stale, "\n  "))
else
  local count = 0
  for _ in pairs(blocks) do count = count + 1 end
  print("sync-prompt-docs: ok (" .. count .. " blocks current)")
end
