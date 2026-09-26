-- /merge is a scoped integration brief; the skill owns the procedure.
local M = {}

M.brief = table.concat({
  "Act as the git orchestrator for this repository.",
  "Load skills/git-orchestrator and run its deterministic audit before merging.",
  "Integrate every in-scope committed local and remote branch tip, including actor branches and local-only work, into main.",
  "Review the changes, gate the combined result, push, then re-fetch and repeat until the audit proves convergence.",
  "Report integration separately from worktree sync and optional branch cleanup; dirty or live worktrees do not block integrating their committed tips.",
  "The AGENTS.md hand-off rule is suspended: you are the integrator and may merge to main.",
  "Preserve uncommitted work and active checkouts. Resolve understood conflicts without losing either intent; escalate an unresolved decision, never force it.",
  "Scope: internal branches only. Open PR work is excluded; use /merge all to explicitly include PRs.",
}, " ")

M.all_brief = table.concat({
  "Act as the git orchestrator for this repository.",
  "Load skills/git-orchestrator and run its deterministic audit before merging.",
  "Integrate every in-scope committed local and remote branch tip, including actor branches and local-only work, into main.",
  "Review the changes, gate the combined result, push, then re-fetch and repeat until the audit proves convergence.",
  "Report integration separately from worktree sync and optional branch cleanup; dirty or live worktrees do not block integrating their committed tips.",
  "The AGENTS.md hand-off rule is suspended: you are the integrator and may merge to main.",
  "Preserve uncommitted work and active checkouts. Resolve understood conflicts without losing either intent; escalate an unresolved decision, never force it.",
  "Scope: /merge all explicitly includes every open PR head, including forks. Review each PR and honor required checks and approvals before integration.",
}, " ")

return M
