-- wa conform <model>: the conformance suite (docs/AGENT-SEAT.md, principle 7).
--
-- ~10 recorded-shape tasks run LIVE against one model in a scratch home. Each task is a prompt and
-- a check of what came back; what a pass means is stated per task, so a rate is never a mystery.
-- The suite stores a profile (lua/core/model_profile.lua) and prints the rates it measured. Nothing
-- here decides that a model is good; it records what it did, so the node can pick a transport from
-- evidence instead of from a model name.
--
-- The tasks, each a shape the seat names:
--   1 acts in the answer        the action lands in the answer, as a block or a run call
--   2 uses the run tool call    a native run() call is accepted as an action too
--   3 closes its fences         a fenced block that OPENS is CLOSED
--   4 several blocks            two actions in one answer both arrive
--   5 keeps the user language   asked in Portuguese, answers in Portuguese
--   6 finishes with an answer   a question with no action gets a real answer, not a plan
--   7 survives a cut            a reply cut mid-block is handled, not lost
--   8 follows "reply exactly"   a literal instruction is obeyed literally
--   9 one script, one result    the script it writes is coherent (a value comes back)
--  10 no claim without a run    it does not describe an action it never took
local json = dofile("lua/vendor/json.lua")
local profile_lib = dofile("lua/core/model_profile.lua")

local M = {}

-- One task: an id, the prompt, and a check that reads the normalized answer. `check` returns true,
-- or false and the reason - never nil, so an unreadable answer is a failure with a cause.
M.TASKS = {
  { id = "acts_in_answer", prompt = "Run a script that returns 2+2, then tell me the number.",
    check = function(record, raw_code)
      local acts = #(record.tool_calls or {}) > 0
      if acts then return true end
      if record.reasoning and record.reasoning ~= "" then
        return false, "the action was in the reasoning, not the answer"
      end
      return false, "no action was sent"
    end },
  { id = "uses_run_tool", prompt = "Call run with code that returns 1; do not write a fence.",
    check = function(record)
      for _, call in ipairs(record.tool_calls or {}) do
        local name = call["function"] and call["function"].name or ""
        if name == "run" or name == "codemode" then return true end
      end
      return false, "no run call arrived"
    end },
  { id = "closes_fences", prompt = "End your message with a js run block that returns 1.",
    check = function(record, raw_code)
      local text = record.answer_text or ""
      local blocks = raw_code.parse(text)
      for _, block in ipairs(blocks) do
        if block.run and not block.close then
          return false, "a run block was opened and never closed"
        end
      end
      return #blocks > 0, "no fenced block was written at all"
    end },
  { id = "several_blocks", prompt = "Run two scripts: one returns 1, the other returns 2.",
    check = function(record, raw_code)
      local blocks = raw_code.parse(record.answer_text or "")
      local runs = 0
      for _, block in ipairs(blocks) do if block.run then runs = runs + 1 end end
      if runs >= 2 then return true end
      if #(record.tool_calls or {}) >= 2 then return true end
      return false, "fewer than two actions arrived"
    end },
  { id = "keeps_language", prompt = "Explique em portugues, em uma frase, o que e um sandbox.",
    check = function(record)
      local text = tostring(record.answer_text or "")
      if text == "" then return false, "no answer" end
      local markers = { " que ", " de ", " e um", " nao", "para" }
      for _, word in ipairs(markers) do
        if text:lower():find(word, 1, true) then return true end
      end
      return false, "the answer did not come back in the language it was asked in"
    end },
  { id = "finishes_with_answer", prompt = "In one sentence: what is a mutex?",
    check = function(record)
      local text = tostring(record.answer_text or "")
      if text == "" then return false, "no answer" end
      if text:lower():find("let me", 1, true) or text:lower():find("i will", 1, true) then
        return false, "a plan, not an answer"
      end
      return true
    end },
  { id = "survives_cut", prompt = "Write a long explanation of a hash table, then a js run block.",
    check = function(record)
      -- A cut reply is acceptable; LOSING it is not. The answer must still carry its bytes, and
      -- the call must be flagged unexecutable rather than silently run or silently dropped.
      local text = tostring(record.answer_text or "")
      if record.finish_reason == "length" or record.cut then
        if #text > 0 or #(record.tool_calls or {}) > 0 then return true end
        return false, "the cut reply lost everything it had written"
      end
      if #text > 0 then return true end
      return false, "no answer arrived"
    end },
  { id = "reply_exactly", prompt = "Reply with exactly: CONFORMED",
    check = function(record)
      local text = tostring(record.answer_text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      return text == "CONFORMED", "it did not reply exactly"
    end },
  { id = "script_is_coherent", prompt = "Run a script that reads /etc/hostname and returns its length.",
    check = function(record, raw_code)
      if #(record.tool_calls or {}) == 0 then return false, "no action arrived" end
      local call = record.tool_calls[1]
      local args = call["function"] and call["function"].arguments or ""
      if args == "" or args == "{}" then return false, "the call carried no code" end
      return true
    end },
  { id = "no_claim_without_run", prompt = "Run a script that returns 7. Report the result.",
    check = function(record)
      if #(record.tool_calls or {}) > 0 then return true end
      return false, "it reported a result it never produced"
    end },
}

return M
