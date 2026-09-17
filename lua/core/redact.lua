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

return M
