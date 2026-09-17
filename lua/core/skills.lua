-- Skills: on-demand capability packages, following the Agent Skills standard that
-- pi implements (and that Orca already feeds to other harnesses).
--
-- Only a skill's name and description are always in context; the body loads when
-- a task matches. That is the point: a procedure needed once a week should not
-- cost context every turn, and the agent should not have to be told the same
-- technique twice.
--
-- A skill is a directory with a SKILL.md:
--
--   ---
--   name: see-your-output
--   description: How to verify visual work when you cannot see the screen.
--   ---
--   # ...
--
-- Everything else in the directory (scripts, references, assets) is freeform and
-- is referenced by relative path from the skill directory.
local M = {}

local paths = dofile("lua/core/paths.lua")
local platform = dofile("lua/core/platform.lua")

local function read(path)
  return host.read_file and host.read_file(path)
end

-- Frontmatter is a tiny subset of YAML: `key: value` lines between --- markers.
-- A full parser would be a dependency; the standard only requires name and
-- description, and a value that spans lines is not a skill worth loading.
local function parse_frontmatter(text)
  local block = text:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-")
  if not block then return nil end
  local fields = {}
  for line in block:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_%-]+)%s*:%s*(.*)$")
    if key then
      value = value:gsub("^[\"']", ""):gsub("[\"']$", ""):gsub("%s+$", "")
      fields[key] = value
    end
  end
  if not fields.name or fields.name == "" then return nil end
  if not fields.description or fields.description == "" then return nil end
  return fields
end

local function split_paths(value)
  local list = {}
  for item in tostring(value or ""):gmatch("[^;:]+") do
    item = item:gsub("%s+$", "")
    if item ~= "" then list[#list + 1] = item end
  end
  return list
end

-- The directories to scan. Global first, then project ones from the working
-- directory upwards, so a repo can carry skills for the work done inside it.
local function roots()
  local list = {}
  for _, dir in ipairs(split_paths(host.getenv("WASM_AGENT_SKILLS"))) do
    list[#list + 1] = dir
  end
  list[#list + 1] = paths.config() .. "/skills"
  list[#list + 1] = paths.home() .. "/.agents/skills"
  local dir = platform.cwd()
  local depth = 0
  while dir and dir ~= "" and depth < 12 do
    list[#list + 1] = dir .. "/skills"
    list[#list + 1] = dir .. "/.agents/skills"
    local parent = dir:match("^(.*)[/\\][^/\\]+$")
    if not parent or parent == dir then break end
    dir = parent
    depth = depth + 1
  end
  return list
end

local SKIP = { [".git"] = true, ["node_modules"] = true, ["target"] = true, [".wasm-agent"] = true }

local function scan(dir, out, depth)
  if depth > 4 then return end
  local ok, raw = pcall(host.list_dir, dir)
  if not ok or not raw then return end
  local decoded = dofile("lua/vendor/json.lua").decode(raw)
  if type(decoded) ~= "table" or type(decoded.entries) ~= "table" then return end
  for _, entry in ipairs(decoded.entries) do
    local path = dir .. "/" .. entry.name
    if entry.kind == "dir" and not SKIP[entry.name] then
      scan(path, out, depth + 1)
    elseif entry.name == "SKILL.md" and entry.kind == "file" then
      local text = read(path)
      local fields = text and parse_frontmatter(text) or nil
      if fields then
        out[#out + 1] = {
          name = fields.name,
          description = fields.description,
          path = path,
          dir = dir,
          hidden = fields["disable-model-invocation"] == "true",
        }
      end
    end
  end
end

local cached = nil

-- Every discoverable skill, deduplicated by name (first root wins).
function M.list(refresh)
  if cached and not refresh then return cached end
  local found, seen = {}, {}
  for _, root in ipairs(roots()) do
    local batch = {}
    scan(root, batch, 0)
    for _, skill in ipairs(batch) do
      if not seen[skill.name] then
        seen[skill.name] = true
        found[#found + 1] = skill
      end
    end
  end
  table.sort(found, function(a, b) return a.name < b.name end)
  cached = found
  return found
end

function M.find(name)
  for _, skill in ipairs(M.list()) do
    if skill.name == name then return skill end
  end
  return nil
end

function M.content(skill)
  local text = read(skill.path)
  if not text then return nil end
  -- Cap it: a skill is instructions, not an archive.
  if #text > 12000 then text = text:sub(1, 12000) .. "\n…(truncated)" end
  return text
end

local function xml_escape(value)
  return tostring(value or "")
    :gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    :gsub("\"", "&quot;"):gsub("'", "&apos;")
end

-- The block injected into the system prompt: pi's wording, so the same skills
-- work in either harness.
function M.prompt_block()
  local visible = {}
  for _, skill in ipairs(M.list()) do
    if not skill.hidden then visible[#visible + 1] = skill end
  end
  if #visible == 0 then return nil end
  local lines = {
    "The following skills provide specialized instructions for specific tasks.",
    "Read the full skill file when the task matches its description.",
    "When a skill file references a relative path, resolve it against the skill directory " ..
      "(parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
    "",
    "<available_skills>",
  }
  for _, skill in ipairs(visible) do
    lines[#lines + 1] = "  <skill>"
    lines[#lines + 1] = "    <name>" .. xml_escape(skill.name) .. "</name>"
    lines[#lines + 1] = "    <description>" .. xml_escape(skill.description) .. "</description>"
    lines[#lines + 1] = "    <location>" .. xml_escape(skill.path) .. "</location>"
    lines[#lines + 1] = "  </skill>"
  end
  lines[#lines + 1] = "</available_skills>"
  return table.concat(lines, "\n")
end

return M
