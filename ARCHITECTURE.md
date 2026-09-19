# wasm-agent architecture

How the system is put together: what is scoped to what, what a capability tier means, and where a
concern belongs. The *UI* rules - components, spacing, balloons, what a view may do - are in
[`DESIGN.md`](DESIGN.md), and they are enforced the same way. Both are contracts: when a change
conflicts with a rule here, change the change, or amend the file first with a reason.

## 1. Scope an instruction to where it is true

The agent's instructions are assembled per turn from files, and every line of them is
paid for on every turn. So an instruction lives where it is true, and nowhere else:

| Scope | Where it lives | Injected |
|---|---|---|
| every turn, every node | `AGENTS.md` | always |
| one role | `AGENTS.guest.md` | guests only |
| one platform | `AGENTS.<platform>.md` (`AGENTS.windows.md`) | only on that platform |
| a technique, on demand | `skills/<name>/SKILL.md` | only when the model asks |
| a fact about a subsystem | `docs/*.md` | only when read |

**And prefer a mechanism to a sentence.** If the machine can enforce it - a path that
gets converted, a route that refuses, a startup warning, a test - then it belongs in
code, because code costs no context and cannot be forgotten. Prose is for what neither a
role, a platform, a skill, nor the code can carry.

The test for a rule is not "is it important" but "is it true here, and is it cheap". A
rule about Windows in the global file is neither: it spends tokens on Linux turns and
it teaches a node to distrust rules it cannot check.

1. Search `ui/components.js` and `ui/style.css` first.
2. If something is close but not a fit, **extend the existing component** (add a
   property, a slot, a variant) instead of forking it.
3. Only add a brand-new component when nothing existing can carry the behaviour.
   When you do, you must:
   - implement it as a custom element in `ui/components.js`;
   - style it with the shared tokens in `:root`;
   - document it in the "Component registry" below in the same change.

Duplicated markup that should have been a component is a defect.


## 2. Memory is on demand

Memory is a feature the agent uses when a task calls for it, not a dashboard.
The UI must not foreground memory: no memory counters in the status balloon, the
header, or the empty state. Surface memory only inside a turn (a `recall` tool
chip) or when the user explicitly asks for it.


## 3. Capability tiers

Tools are grouped by the role that may call them (§ see `lua/core/tools.lua`):

Roles are `master` (full) and `guest` (on demand memory); `admin` is a legacy
alias for `master`. Binding between nodes is `master:master` or `master:guest`.

| Tier | Tools | Roles |
| --- | --- | --- |
| memory | `remember`, `recall` | everyone |
| capabilities | `capabilities` (list what this role may call) | everyone |
| environment (pi) | `bash`, `read`, `write`, `edit`, `ls`, `grep` | master |
| shell | `shell` (shell on the client host, also the UI terminal) | master |
| ledger | `search_messages`, `conversation`, `list_conversations` | master |
| client | `client` (screenshot, frame, mouse, keyboard, shell, CDP) | master |
| nodes | `nodes`, `remote` | master |
| spells | `spell_save`, `spell_run`, `spell_list`, `spell_get`, `spell_forget` (crystallized macros) | master |
| plugins | every WASM plugin | master |

Never expose a master tier to a non-master turn; filter schemas *and* re-check in
`dispatch`, because the model can ask for a tool it was not offered.
The `client` and `shell` tools drive a real machine — the highest-risk tiers.

A **node** has a role as well, and it answers a different question from the role
of a turn. A *guest node* exists so that a master can have something done on the
machine it runs on: it owns no worktree and no branch, so it is never named
after a directory and a rename never moves a branch on its behalf, and its own
capabilities are read-only. When a master calls it (`/node/call`, signed), the
work runs **as that master** — the session and every tool call are filed under
the master's name, never the guest's. There is one answer to "who did this?"
whether the edit happened here or on a guest. `verify_peer` refuses a caller
whose node is not a master, so a guest cannot command another node, and
`nodes.author_of` is the single gate that turns a caller into an author.
