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
-- description. Block scalars are not optional though: `description: >-` followed by an indented
-- paragraph is the *normal* way these files are written - pi's own skills use it, and so do the
-- user's - and reading it as the two characters ">-" told the model that every such skill is
-- described as ">-". It was found by listing the skills in the engine, which is the one place a
-- wrong description is visible rather than merely unhelpful.
local function parse_frontmatter(text)
  local block = text:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-")
  if not block then return nil end
  local fields = {}
  local pending, block_lines = nil, nil
  local function flush()
    if pending and block_lines and #block_lines > 0 then
      -- Folded and literal both become one line here: a description is shown in a list and put
      -- in a prompt, and a multi-line one would only be reflowed anyway.
      fields[pending] = table.concat(block_lines, " "):gsub("%s+$", "")
    end
    pending, block_lines = nil, nil
  end
  for line in block:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_%-]+)%s*:%s*(.*)$")
    if key then
      flush()
      value = value:gsub("^[\"']", ""):gsub("[\"']$", ""):gsub("%s+$", "")
      if value == ">" or value == ">-" or value == "|" or value == "|-" or value == ">+" or value == "|+" then
        pending, block_lines = key, {}
      else
        fields[key] = value
      end
    elseif pending then
      -- A continuation line of the block scalar: everything up to the next key.
      local text_line = line:gsub("^%s+", "")
      if text_line ~= "" or #block_lines > 0 then block_lines[#block_lines + 1] = text_line end
    end
  end
  flush()
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

-- Is this directory the root of a checkout? `.git` is a directory in a normal
-- clone and a file in a worktree, and either way list_dir reports it.
local function is_repo_root(dir)
  local ok, raw = pcall(host.list_dir, dir)
  if not ok or not raw then return false end
  local decoded = dofile("lua/vendor/json.lua").decode(raw)
  if type(decoded) ~= "table" or type(decoded.entries) ~= "table" then return false end
  for _, entry in ipairs(decoded.entries) do
    if entry.name == ".git" then return true end
  end
  return false
end

-- The directories to scan. Global first, then project ones from the working
-- directory upwards, stopping at the checkout root - walking past it adopts the
-- parent project's skills, which is how this repo (nested under another
-- checkout) started advertising that project's unrelated ones.
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
    if is_repo_root(dir) then break end
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

-- Where a skill came from. Three roots matter, and they mean different things: the repository's
-- own `skills/` is what the agent ships with, the node's config is what this node was given, and
-- `.agents/skills` is whatever the person running it has accumulated.
local function source_of(skill)
  local path = tostring(skill.path or "")
  if path:find("/.agents/", 1, true) then return "user" end
  if path:find(paths.config() .. "/skills", 1, true) then return "node" end
  return "repo"
end

-- The engine's view: every skill this node can see, and what is true of each one.
--
-- Two different facts live in one row, which is why the topic exists. The *description* is always
-- in the model's context (unless the skill opts out of that), so the agent knows the skill exists;
-- the *body* is only read when a task matches, so "the agent can load this on demand" is a
-- separate claim - and a skill whose file cannot be read is visible here and useless to the model.
function M.report(role)
  local out = {}
  local loadable, described = 0, 0
  for _, skill in ipairs(M.list(true)) do
    local body = M.content(skill)
    local can_load = body ~= nil and body ~= ""
    if can_load then loadable = loadable + 1 end
    if not skill.hidden then described = described + 1 end
    out[#out + 1] = {
      name = skill.name,
      description = skill.description or "",
      path = skill.path,
      source = source_of(skill),
      hidden = skill.hidden == true,
      loadable = can_load,
      body_chars = can_load and #body or 0,
    }
  end
  return {
    skills = out,
    count = #out,
    loadable = loadable,
    described = described,
    role = role or "",
  }
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
    "While using any skill, crystallize repeatable deterministic sequences into verified spells, " ..
      "then refactor the skill to call them. Verify the postconditions before preferring the spell.",
    "Compose consecutive spells into one reusable spell when their sequence and parameter bindings " ..
      "are repeatable and no inference decision lies between them; preserve every boundary check.",
    "On spell failure, use inference by default: inspect the trace and reconcile effects, then " ..
      "finish safely, repair and reverify the segment, or retire the spell and restore inference. " ..
      "A correct refusal is not a spell defect. Never weaken checks or blindly replay effects. " ..
      "Stay within your allowed tools and editable skill scope.",
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
