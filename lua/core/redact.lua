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
