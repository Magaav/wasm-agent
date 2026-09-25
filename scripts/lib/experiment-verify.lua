-- Outcome verification for the tool-choice experiment, kept apart from the rig because a
-- rig that starts children cannot itself be sourced by a test.
--
-- Substring presence over the whole reply is not verification, and neither is "the line
-- mentions the path and later contains the word": `lua/core/skills.lua: write (calls read
-- later)` is the *wrong* answer and used to pass. So an answer is parsed, not searched:
-- the path must be followed by a separator (`:`, `->`, `=`, `-`), and the name is the
-- identifier right after it. A sentence that merely mentions the path has no separator and
-- is not an answer, so it neither satisfies nor contradicts the fact.
--
-- A task whose outcome is not text cannot pass on an empty fact list. `long-lived` has no
-- facts to match; its success is the live process it was asked to leave running, so
-- `success` combines the parsed facts with the observed process outcome.
local M = {}

local function bare(name)
  return tostring(name or ""):gsub("^M[%.:]", "")
end

-- The name answered for `path` on one line, or nil when the line is not an answer.
local function answer_on(line, path)
  local at = line:find(path, 1, true)
  if not at then return nil end
  local rest = line:sub(at + #path)
  -- Optional closing decoration and spaces, then a separator. No separator means the line
  -- is prose about the path, not an answer for it.
  local separator = rest:match("^[%s`\"'%*%(%)%[%]]*[:=>%-]+%s*")
  if not separator then return nil end
  local token = rest:sub(#separator + 1):match("^([%a_][%w_.]*)")
  if not token then return nil end
  return (token:gsub("%.$", ""))
end

-- `expect` is a list of facts. A fact is `{path=..., name=...}` (the reply must answer that
-- function for that file) or a plain string (the reply must contain it). Returns
-- `{complete, missing, wrong, conflicts}`. A file answered with two different functions is
-- a conflict, not a pass: one right mention must not hide a contradiction.
function M.verify(expect, reply)
  reply = tostring(reply or "")
  local missing, wrong, conflicts = {}, {}, {}
  for _, fact in ipairs(expect or {}) do
    if type(fact) == "table" and fact.path then
      local want = bare(fact.name)
      local seen = {}
      for line in reply:gmatch("[^\n]+") do
        local name = answer_on(line, fact.path)
        if name then seen[bare(name)] = true end
      end
      local answers = {}
      for name in pairs(seen) do answers[#answers + 1] = name end
      table.sort(answers)
      if #answers == 0 then
        missing[#missing + 1] = fact.path
      elseif #answers == 1 and answers[1] == want then
        -- the one answer is the expected fact
      elseif seen[want] then
        conflicts[#conflicts + 1] = "conflicting answers for " .. fact.path .. ": " ..
          table.concat(answers, ", ")
      else
        wrong[#wrong + 1] = "expected " .. want .. " for " .. fact.path ..
          ", got " .. table.concat(answers, ", ")
      end
    elseif not reply:find(tostring(fact), 1, true) then
      missing[#missing + 1] = tostring(fact)
    end
  end
  return {
    complete = #missing == 0 and #wrong == 0 and #conflicts == 0,
    missing = missing, wrong = wrong, conflicts = conflicts,
  }
end

-- Task success: every requested fact answered, and - for a task whose real outcome is not
-- text - that outcome observed. An empty fact list is not a pass by itself.
function M.success(fixture, reply, adoption)
  local verdict = M.verify((fixture and fixture.expect) or {}, reply)
  if fixture and fixture.outcome == "live_process" then
    local alive = false
    for _, item in ipairs(adoption or {}) do
      if item.still_running or item.file_grew then alive = true end
    end
    verdict.observed_outcome = alive
    verdict.complete = verdict.complete and alive
  elseif fixture and fixture.outcome == "external_patch" then
    -- A reply cannot prove a code patch. The outer fixture owns an isolated checkout and
    -- runs an independent verifier after the child settles; keep this explicitly
    -- unadjudicated rather than letting an empty fact list become a pass.
    verdict.complete = nil
    verdict.external_verification_required = true
  end
  return verdict
end

return M
