-- The A/B arms as ONE build (next-round.md, 19/11 ~17:30): a WASM_AGENT_RAW_CODE-style switch, so
-- the same binary serves every arm and only the arm under measurement changes.
--
-- A   fence     = "only"   (a fenced js run block is the one way to act)
-- B   run tool  = "native" (a native run({code, raw?}) call is the one way to act)
-- C   codemode  = "codemode" (the JSON codemode tool plus the generic tools, no fence)
-- D   bash      = "bash"   (one native bash(command); every wa capability through the existing CLI)
-- E2  two tags  = "e2"     (<message> + one <codeact>; finish = <message> alone)
-- E3  three tags= "e3"     (optional <message> + one <codeact>; finish = <final_message> alone)
--
-- Pure: it reads the switch and answers what the arm means. Nothing here runs an action.
local M = {}

M.ARMS = {
  fence = "only",
  run_tool = "native",
  codemode = "codemode",
  bash = "bash",
  e2 = "e2",
  e3 = "e3",
}

-- The arm this process is running. OFF unless its own switch names one (review MUST 3).
--
-- It used to read WASM_AGENT_RAW_CODE and answer "fence" when that was unset, so EVERY node was
-- silently running an A/B arm: the arm''s allow-list filtered the tool list, and a subagent's
-- declared tools changed against base for a reason nobody had asked for. WASM_AGENT_RAW_CODE already
-- means something else (which transport the fence path offers), so sharing it made the two
-- indistinguishable. WA_AB_ARM is the arm switch and nothing else touches it.
--
-- An unset switch is not an arm: it answers nil with the reason "off", and every caller treats nil as
-- "no filter". An unknown value is refused by name, so a typo cannot be measured as arm A.
M.SWITCH = "WA_AB_ARM"

function M.current()
  local raw = tostring(host.getenv(M.SWITCH) or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if raw == "" then return nil, "off" end
  for arm, value in pairs(M.ARMS) do
    if value == raw then return arm, "switch" end
  end
  return nil, "unknown_arm: " .. tostring(raw) .. " (this build runs: " .. M.VALUES() .. ")"
end

function M.VALUES()
  local names = {}
  for _, value in pairs(M.ARMS) do names[#names + 1] = value end
  table.sort(names)
  return table.concat(names, ", ")
end

-- The single door an arm declares. `arm` answers:
--   tools   which tool names may be DECLARED (an allow-list, never a block-list)
--   guidance the one sentence the prompt carries for this arm
function M.door(arm, raw_code)
  if arm == "bash" then
    return { tools = { bash = true },
      guidance = "Work with the bash tool. Call it with `command`; every wa capability that is not plain "
        .. "shell is reached through the wa CLI (wa call <node> <capability>, wa op, wa sessions, wa read). "
        .. "A message with no tool call is your answer." }
  end
  if arm == "run_tool" then
    return { tools = { run = true },
      guidance = raw_code and raw_code.guidance_for("tool_call") or nil }
  end
  if arm == "fence" then
    return { tools = {}, guidance = raw_code and raw_code.FIRST_GUIDANCE or nil }
  end
  if arm == "e2" or arm == "e3" then
    local tag = dofile("lua/core/arm_tag.lua")
    return { tools = {}, guidance = tag.prompt(arm) }
  end
  -- codemode keeps the node's ordinary surface: this table adds nothing to it.
  return { tools = nil, guidance = nil }
end

-- Does this arm declare the named tool? An allow-list: a name that is not named is not declared.
function M.declares(arm, name)
  local door = M.door(arm)
  if door.tools == nil then return true end
  return door.tools[name] == true
end

return M
