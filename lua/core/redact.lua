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
local file_cache, file_cache_at = nil, -1

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
  local now = host.now and host.now() or 0
  if file_cache and now - file_cache_at < 30 then return file_cache end
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
    local auth_ok, auth = pcall(dofile, "lua/core/openai_sub_auth.lua")
    if auth_ok and type(auth) == "table" then
      if auth.store_path then json_secrets(auth.store_path(), "OPENAI_SUB_CREDENTIAL", out) end
      if auth.pi_auth_path then json_secrets(auth.pi_auth_path(), "PI_AUTH_CREDENTIAL", out) end
    end
  end)
  file_cache, file_cache_at = out, now
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

-- Redact every string in a tool result, tables included, so the value is gone before the
-- result is projected, stored, journalled or sent to the provider - not only before it is
-- displayed. Tables are copied; the caller's table is left alone. Returns the copy and the
-- aggregated `{NAME = count, ...}` of what was found.
function M.value(v)
  local secrets = M.secret_values()
  local hits = {}
  local function walk(x)
    if type(x) == "string" then
      for _, secret in ipairs(secrets) do
        local replaced, count = x:gsub(secret.escape, "<redacted>")
        if count > 0 then
          x = replaced
          hits[secret.name] = (hits[secret.name] or 0) + count
        end
      end
      return x
    elseif type(x) == "table" then
      local out = {}
      for key, item in pairs(x) do out[key] = walk(item) end
      return out
    end
    return x
  end
  return walk(v), hits
end

return M
