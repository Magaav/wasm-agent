-- Central secret redaction.
--
-- Anything that leaves the process - logs, errors, tool results, trace rows,
-- diagnostics, test output - should pass through here first. Per-call-site care
-- is how secrets leak (a diff of two config files printed both in full, because
-- a CRLF/LF mismatch made every line "changed"), so the rule lives in one place
-- and is applied at the boundaries instead.
--
-- Masking keeps the last four characters so an operator can tell *which* key
-- was involved without being able to use it: `sk-...7f2a`.
local M = {}

local function mask(value)
  value = tostring(value or "")
  if #value < 12 then return "<redacted>" end
  return value:sub(1, 3) .. "..." .. value:sub(-4)
end

M.mask = mask

-- Value shapes that are credentials no matter what they are called.
local VALUE_PATTERNS = {
  -- OpenAI/opencode style, and the long random strings they resemble.
  { "(sk%-[%w_%-]+)", function(v) return mask(v) end },
  -- GitHub, GitLab, Slack, AWS, Google.
  { "((ghp_|github_pat_|glpat%-|xox[baprs]%-|AKIA|AIza)[%w_%-]+)", function(v) return mask(v) end },
  -- JWTs (header.payload.signature).
  { "(eyJ[%w_%-]+%.[%w_%-]+%.[%w_%-]+)", function(v) return mask(v) end },
}

-- `NAME=value`, `NAME: value`, `NAME="value"` where NAME looks like a secret.
local NAME_PATTERN =
  "([%w_%.%-]*(API_?KEY|_KEY|KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH)[%w_%.%-]*\"?%s*[=:]%s*[\"']?)([^\"'%s,}]+)"

-- Redact a string. Applied repeatedly until it stops changing, because a
-- replacement can expose a neighbouring pattern (and because masking is
-- idempotent).
function M.text(value)
  local text = tostring(value or "")
  if text == "" then return text end
  for _ = 1, 3 do
    local before = text
    for _, pattern in ipairs(VALUE_PATTERNS) do
      text = text:gsub(pattern[1], pattern[2])
    end
    text = text:gsub(NAME_PATTERN, function(name, secret)
      -- Leave already-masked values alone so repeated passes are stable.
      if secret == "<redacted>" or secret:find("%.%%.%.") then return name .. secret end
      return name .. mask(secret)
    end)
    text = text:gsub("([Bb]earer%s+)([%w_%.-]+)", function(prefix, token)
      if token == "<redacted>" or token:find("%.%%.%.") then return prefix .. token end
      return prefix .. mask(token)
    end)
    if text == before then break end
  end
  return text
end

-- Convenience for `NAME=value` pairs where the caller already knows the name is
-- sensitive: always masks, regardless of the value's shape.
function M.pair(name, value)
  return tostring(name) .. "=" .. mask(value)
end

-- The node's own configured secrets, by name. The shape patterns above catch credentials by
-- their look; these catch the node's *own* key, which a tool can reach by reading its config
-- file. Measured: a `bash` call dumped the config file into the transcript, and the shape
-- patterns missed the value because it has no `sk-` prefix - `M.text` was never applied to
-- tool results at all. This is exact-value replacement, so unlike the shape patterns it
-- cannot mangle ordinary text (`task-runner` contains `sk-`).
local SECRET_ENV = {
  "WASM_AGENT_LLM_API_KEY", "OPENAI_API_KEY", "OPENCODE_GO_API_KEY", "WASM_AGENT_PROMPT_CACHE_KEY",
}

local function escape_pattern(text)
  return (tostring(text):gsub("([^%w])", "%%%1"))
end

-- Secrets the node keeps in files rather than the environment: its own signing key and the OAuth
-- credentials it can log in with. `cat` of any of them would otherwise put a refresh token or the
-- node's private key into the transcript, the provider request and the sync journal sent to peers.
-- Re-read at each output boundary: rotation during a turn must not leak the
-- fresh token for a cache window.

local function json_secrets(path, label, out)
  local raw = host.read_file and host.read_file(path)
  if type(raw) ~= "string" or raw == "" then return end
  local ok, decoded = pcall(function() return dofile("lua/vendor/json.lua").decode(raw) end)
  if not ok or type(decoded) ~= "table" then return end
  local function walk(node, key)
    if type(node) == "table" then
      for k, v in pairs(node) do walk(v, tostring(k)) end
    elseif type(node) == "string" and #node >= 20 then
      local lowered = tostring(key or ""):lower()
      if lowered:find("token") or lowered:find("refresh") or lowered:find("access")
          or lowered:find("secret") or lowered:find("key") then
        out[#out + 1] = { name = label, escape = escape_pattern(node), value = node }
      end
    end
  end
  walk(decoded, "")
end

local function file_secret_values()
  local out = {}
  pcall(function()
    local paths = dofile("lua/core/paths.lua")
    for _, dir in ipairs({ paths.config(), paths.home() .. "/.wasm-agent" }) do
      local key = host.read_file(dir .. "/node.key")
      if type(key) == "string" then
        key = key:gsub("%s+", "")
        if #key >= 32 then out[#out + 1] = { name = "NODE_KEY", escape = escape_pattern(key), value = key } end
      end
    end
    local override=host.getenv('WASM_AGENT_NODE_KEY')
    if override and override~='' then
      local key=host.read_file(override)
      if type(key)=='string' then key=key:gsub('%s+','');if #key>=32 then out[#out+1]={name='NODE_KEY',escape=escape_pattern(key),value=key} end end
    end
    local auth_ok, auth = pcall(dofile, "lua/core/openai_sub_auth.lua")
    if auth_ok and type(auth) == "table" then
      if auth.store_path then json_secrets(auth.store_path(), "OPENAI_SUB_CREDENTIAL", out) end
      if auth.pi_auth_path then json_secrets(auth.pi_auth_path(), "PI_AUTH_CREDENTIAL", out) end
    end
  end)
  return out
end

function M.secret_values()
  local values = {}
  if host and host.getenv then
    for _, name in ipairs(SECRET_ENV) do
      local value = host.getenv(name)
      if type(value) == "string" and #value >= 8 then
        values[#values + 1] = { name = name, escape = escape_pattern(value), value = value }
      end
    end
  end
  if host and host.read_file then
    for _, secret in ipairs(file_secret_values()) do values[#values + 1] = secret end
  end
  return values
end

-- Where the node's own secret values appear in a string: `{NAME = count, ...}`. Never the
-- value. This is the detection half - a caller can report that it saw a secret even when it
-- is about to redact it, and an operator can be told before a turn is stored or sent.
function M.scan(text)
  local found = {}
  text = tostring(text or "")
  for _, secret in ipairs(M.secret_values()) do
    local _, count = text:gsub(secret.escape, "")
    if count > 0 then found[secret.name] = (found[secret.name] or 0) + count end
  end
  return found
end

-- Redact the node's own secret values from a string, exactly. Returns the text and
-- `{NAME = count, ...}` for whatever it replaced.
function M.secrets(value)
  local text, hits = tostring(value or ""), {}
  for _, secret in ipairs(M.secret_values()) do
    local replaced, count = text:gsub(secret.escape, "<redacted>")
    if count > 0 then
      text = replaced
      hits[secret.name] = (hits[secret.name] or 0) + count
    end
  end
  return text, hits
end

-- Credential shapes in a tool result. Stricter than VALUE_PATTERNS above: the prefix must start a
-- token and the whole token must be long, because tool output is ordinary text (`task-runner`
-- contains `sk-`). These catch keys this node was never configured with - a pasted `sk-...` in a
-- file the agent read - which the exact-value pass cannot know about.
local RESULT_PREFIXES = { "sk%-", "sk_live_", "sk_test_", "rk_live_", "gsk_", "hf_", "ghp_", "gho_",
  "ghs_", "github_pat_", "glpat%-", "xoxb%-", "xoxp%-", "npm_", "AKIA", "AIza" }
local function mask_shapes(text, hits)
  for _, prefix in ipairs(RESULT_PREFIXES) do
    text = text:gsub("%f[%w_]" .. prefix .. "[%w_%-]+", function(token)
      if #token < 20 then return token end
      hits.KEY_SHAPE = (hits.KEY_SHAPE or 0) + 1
      return mask(token)
    end)
  end
  return text
end

-- A call that touched a `*.key` file - `read` of one, a shell command naming one - has every long
-- token in its result masked: what such a file holds is a key, whatever its shape. (wa-vault keeps
-- its own key files where the agent cannot reach them; this is for any other `.key` on disk.)
local function touches_key_file(ctx)
  if type(ctx) ~= "table" then return false end
  local args = type(ctx.args) == "table" and ctx.args or {}
  for _, field in ipairs({ "path", "file_path", "command", "pattern" }) do
    local value = args[field]
    if type(value) == "string" and value:find("%.key%f[^%w_]") then return true end
  end
  return false
end
M.touches_key_file = touches_key_file

local function mask_key_file(text, hits)
  return (text:gsub("[%w_%-%.%+=]+", function(token)
    if #token < 16 or token:find("^[%a_%.%-]+$") then return token end
    hits.KEY_FILE = (hits.KEY_FILE or 0) + 1
    return "<redacted .key content>"
  end))
end

-- Redact every string in a tool result, tables included, so the value is gone before the
-- result is projected, stored, journalled or sent to the provider - not only before it is
-- displayed. Tables are copied; the caller's table is left alone. Returns the copy and the
-- aggregated `{NAME = count, ...}` of what was found.
-- `ctx` (optional) is `{tool = name, args = table}`: the call the result came from.
function M.value(v, ctx)
  local secrets = M.secret_values()
  local hits = {}
  local key_file = touches_key_file(ctx)
  local function walk(x)
    if type(x) == "string" then
      for _, secret in ipairs(secrets) do
        local replaced, count = x:gsub(secret.escape, "<redacted>")
        if count > 0 then
          x = replaced
          hits[secret.name] = (hits[secret.name] or 0) + count
        end
      end
      if ctx then
        x = mask_shapes(x, hits)
        if key_file then x = mask_key_file(x, hits) end
      end
      return x
    elseif type(x) == "table" then
      local out = {}
      for key, item in pairs(x) do out[key] = walk(item) end
      -- Preserve only payload-free JSON shape tags. Never copy __json_raw or
      -- arbitrary metatables: all actual strings must pass through walk above.
      local tag=getmetatable(x)
      if next(x)==nil and type(tag)=='table' and (tag.__json_empty=='object' or tag.__json_empty=='null') then
        setmetatable(out,{__json_empty=tag.__json_empty})
      end
      return out
    end
    return x
  end
  return walk(v), hits
end

return M
