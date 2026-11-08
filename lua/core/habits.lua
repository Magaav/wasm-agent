-- Operating habits: the base instructions that make an agent careful (docs/FLEET-OPS.md).
--
-- One module, one string, rendered once into the `generic` layer of the system prompt
-- (`lua/core/agent.lua`, GENERIC_ORDER). That placement is the whole point: the generic layer is
-- built once per session and frozen by `lua/core/prompt_cache.lua`, so these lines are in the
-- cache-stable prefix - present in every request of a session, and byte-identical across its turns.
--
-- Rules this file keeps to:
--
-- * **Advice, never a budget.** Nothing here counts turns, shortens work, or pushes the model to
--   wrap up. A habit is a way to do the work, not a limit on it (the hard rule in the fleet-ops job:
--   no turn budgets, limits or nudges that force the model).
-- * **Stable bytes.** No clock, no node name, no environment, no tool-catalogue text: a line that
--   changes between turns would cost a prompt-cache miss on every call, and `M.text()` is compared
--   byte for byte by `scripts/test-fleetops-habits.lua`.
-- * **No tool names.** A name the envelope cannot reach is a broken instruction
--   (`scripts/test-prompt-tool-names.lua`); the habits are phrased so they hold in every envelope.
-- * **One home.** The fleet-specific version of these habits (what a fleet *is*, what must never be
--   touched) is the `fleetops` skill. This module is the part that is true of any machine.
local M = {}

M.VERSION = 1

-- The habits, one sentence each, in the order a task actually meets them: before the change, during
-- it, after it, and when it went wrong. Deliberately short: this is in every request of every
-- session, so a line that does not change a decision is not worth its bytes.
local LINES = {
  '- Look before you change: read the code, the live state and the doc you are about to edit. A guess about how something works is the most expensive kind of edit.',
  '- Know the blast radius before you act, and say it: what else depends on the thing you are touching, and who is pinned to it. A shared control plane is never a local fix.',
  '- Prefer the reversible, supported path first - a flag, a backup, a switch, a documented command. Hand-editing production config, or restarting a shared service to gain control, is the last resort, and it needs an explicit reason.',
  '- Cheapest check first: the read, the status line, the log line and the grep come before a rebuild, a restart or a deploy.',
  '- Back up before you edit config, and make one change at a time so a failure has one cause instead of several.',
  '- Long work goes into a managed operation that outlives the call and can be read back. Never background a build or a migration inside a single command and walk away from it.',
  '- Verify the effect, not the command: read the thing back, run it, test it. "It returned 0" is not "it worked".',
  '- Check the side effects you did not ask for, including on nodes and clients you cannot see. If you cannot check one, say which one you could not check.',
  '- Distrust a misleading result: an empty value, a refusal that still ran, a zero that means unknown. Re-read from a second source before acting on it.',
  '- Roll back fast when the effect is not the one you wanted, and report the rollback - not only the attempt.',
  '- Record what you learned. When a failure repeats - yours or an earlier session\'s - write it down as a lesson (symptom, cause, fix, rule) so the next session starts from the rule.',
  '- Report plainly, including your own mistakes: what you verified, what you did not verify, what you did not do, and what is still unknown.',
}

-- The rendered section text. Stable for a given VERSION; the test compares two calls' bytes.
function M.text()
  return table.concat(LINES, '\n')
end

-- The lines, for a test or a diagnostic that checks one habit rather than the whole block.
function M.lines()
  local copy = {}
  for index, line in ipairs(LINES) do copy[index] = line end
  return copy
end

return M
