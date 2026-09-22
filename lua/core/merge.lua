-- `/merge`: hand the repository to the git orchestrator.
--
-- This is not a node-side operation like `/update` (the node cannot replace itself). It is a
-- *brief* for the agent: the worktrees, the branches and the gate live outside this process, and
-- the agent is the thing that can run them. The command exists so the intent is one word, and so
-- the `AGENTS.md` hand-off rule - which the agent obeys every other turn - is explicitly suspended
-- for this run.
--
-- The procedure lives in `skills/git-orchestrator/SKILL.md`, which the brief names. This file owns
-- only the sentence; the window mirrors it in `ui/app.js`, and both point at the one skill so the
-- detail cannot drift even though the trigger is written twice.
local M = {}

M.brief = table.concat({
  "Act as the git orchestrator for this repository.",
  "Audit every open branch, merge the ones that merge clean into main one at a time, run the gate on",
  "the merged result, push, and sync the worktrees.",
  "Load skills/git-orchestrator for the procedure.",
  "The AGENTS.md hand-off rule is suspended by this command: you may merge to main and enter the",
  "other worktrees to converge them. Escalate a conflict; never force it.",
}, " ")

return M
