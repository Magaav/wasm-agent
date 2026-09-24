-- Outcome verification for the tool-choice experiment, kept apart from the rig because a
-- rig that starts children cannot itself be sourced by a test.
--
-- Substring presence over the whole reply is not verification. The `wide` task asks for
-- each file's first function; a reply that names the twelve paths and no functions is
-- *wrong*, and the old check passed it. So each fact is checked in the line that names
-- its path, and a fact that was answered incorrectly is reported as `wrong`, not
-- `missing` - a distinction the substring check could not make.
--
-- The point is not to prefer a tool. Several sequences may solve a task correctly, so the
-- verifier checks the *requested facts*, not the route taken to them.
local M = {}

local function bare(name)
  return tostring(name or ""):gsub("^M[%.:]", "")
end

-- Whole-word match, so `read` does not match `readText` and `all` does not match `always`.
local function has_word(text, word)
  word = tostring(word or "")
  if word == "" then return false end
  local escaped = word:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  return text:find("%f[%w_]" .. escaped .. "%f[^%w_]") ~= nil
end

-- `expect` is a list of facts. A fact is `{path=..., name=...}` (the reply must name that
-- function for that file) or a plain string (the reply must contain it). Returns
-- `{complete, missing, wrong}`.
function M.verify(expect, reply)
  reply = tostring(reply or "")
  local missing, wrong = {}, {}
  for _, fact in ipairs(expect or {}) do
    if type(fact) == "table" and fact.path then
      local rest
      for line in reply:gmatch("[^\n]+") do
        local at = line:find(fact.path, 1, true)
        if at then rest = line:sub(at + #fact.path); break end
      end
      if not rest then
        missing[#missing + 1] = fact.path
      elseif not has_word(rest, bare(fact.name)) then
        wrong[#wrong + 1] = "expected " .. bare(fact.name) .. " for " .. fact.path
      end
    elseif not reply:find(tostring(fact), 1, true) then
      missing[#missing + 1] = tostring(fact)
    end
  end
  return { complete = #missing == 0 and #wrong == 0, missing = missing, wrong = wrong }
end

return M
