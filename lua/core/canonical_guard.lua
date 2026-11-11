-- The canonical checkout is one shared resource: landings merge into it under the landing queue's lease
-- (scripts/landing-queue.mjs, docs/LANDING-QUEUE.md), and a deploy resolves the commit it builds from it.
-- A session that edits it directly is not working "in the repo"; it is editing the one tree every
-- landing and every deploy reads, and the cost was measured three times on 2026-11-10 (sessions
-- e0fc6da6, 3e9b0fa6, 42801f80): a dirty canonical tree refused a landing, and once blocked a deploy for
-- about seven minutes.
--
-- So edits are refused at the tool layer, by name, with the worktree the caller should use instead - not
-- discovered later by a queue refusal. Three tools can reach it: `write`, `edit` and `bash` (including
-- its redirections), and `operation start` of a shell. Reads stay allowed: reading the canonical tree is
-- how a session learns what main contains.
--
-- The one exception is the lease holder: the landing queue publishes its holder beside the queue
-- (`holder.json`: id, owner, kind, lease), and a session whose id is that owner may write there. The file
-- is a hint - the queue's own row is the authority - so a stale file can only make this guard stricter,
-- never laxer, and a missing file never blocks a legitimate reader.
local M = {}

M.RULE = "canonical_checkout_protected"

-- Git verbs that change the index, a ref or the working tree. A `git -C <canonical> status` is a read;
-- `git -C <canonical> merge` is a landing decision, and it belongs to the queue.
M.MUTATING_GIT = {
  add = true, am = true, apply = true, branch = true, checkout = true, cherry_pick = true, clean = true,
  commit = true, config = true, fetch = true, gc = true, merge = true, mv = true, pull = true, push = true,
  rebase = true, reflog = true, reset = true, restore = true, revert = true, rm = true, stash = true,
  switch = true, tag = true, ["update-ref"] = true, worktree = true,
}

-- Commands whose whole effect is reading. A command that starts with one of these and contains no
-- redirection is allowed even when it names the canonical checkout; anything else that names it is
-- treated as a write, because guessing the other way is the failure this module exists to stop.
local READ_ONLY = {
  "git%s+%-C%s+[^%s]+%s+status", "git%s+%-C%s+[^%s]+%s+log", "git%s+%-C%s+[^%s]+%s+diff",
  "git%s+%-C%s+[^%s]+%s+show", "git%s+%-C%s+[^%s]+%s+rev%-parse", "git%s+%-C%s+[^%s]+%s+ls%-files",
  "git%s+%-C%s+[^%s]+%s+ls%-tree", "git%s+%-C%s+[^%s]+%s+ls%-remote", "git%s+%-C%s+[^%s]+%s+describe",
  "git%s+%-C%s+[^%s]+%s+cat%-file", "git%s+%-C%s+[^%s]+%s+blame", "git%s+%-C%s+[^%s]+%s+shortlog",
  "git%s+%-C%s+[^%s]+%s+branch%s+%-%-show%-current", "git%s+%-C%s+[^%s]+%s+worktree%s+list",
  "^%s*cat%f[%W]", "^%s*grep%f[%W]", "^%s*rg%f[%W]", "^%s*ls%f[%W]", "^%s*find%f[%W]",
  "^%s*stat%f[%W]", "^%s*head%f[%W]", "^%s*tail%f[%W]", "^%s*wc%f[%W]", "^%s*file%f[%W]",
  "^%s*sha256sum%f[%W]", "^%s*shasum%f[%W]", "^%s*du%f[%W]", "^%s*df%f[%W]", "^%s*git%s+%-C%s+[^%s]+%s+show%f[%W]",
}

local function norm(path)
  local text = tostring(path or ""):gsub("\\", "/")
  text = text:gsub("/+$", "")
  return text
end

-- Is `path` inside `root`? Case-insensitive on Windows-shaped paths, because a refusal that misses
-- `C:/Repo` vs `c:/repo` is the same edit with a different spelling.
function M.inside(path, root)
  local p, r = norm(path), norm(root)
  if p == "" or r == "" then return false end
  if p:sub(1, 1) == "/" and r:sub(1, 2) ~= "/" then return false end
  local pl, rl = p:lower(), r:lower()
  if pl == rl then return true end
  return pl:sub(1, #rl + 1) == rl .. "/"
end

local function mentions(command, root)
  local c, r = tostring(command or ""):lower(), norm(root):lower()
  if c == "" or r == "" then return false end
  return c:find(r, 1, true) ~= nil
end

-- A bash command that would write to the canonical checkout, or nil. Conservative by construction:
-- naming the tree with anything but a recognised read-only command is refused.
function M.bash_mutates(command, canonical)
  local text = tostring(command or "")
  if not mentions(text, canonical) then return nil end
  if text:find("[^>]>[^>]") or text:find(">>", 1, true) then return "redirection into the canonical checkout" end
  for _, pattern in ipairs(READ_ONLY) do
    if text:lower():find(pattern) then return nil end
  end
  -- `git -C <canonical> <verb>`: the verb decides, so a refusal names what was about to happen.
  local verb = text:lower():match("git%s+%-%-?c%s+[^%s]+%s+([%a%-_]+)")
  if verb then
    verb = verb:gsub("-", "_")
    if M.MUTATING_GIT[verb] or M.MUTATING_GIT[verb:gsub("_", "-")] then
      return "git " .. verb:gsub("_", "-") .. " in the canonical checkout"
    end
    return nil
  end
  return "a command that names the canonical checkout outside a read-only verb"
end

-- The pure decision. `facts` is what `guard` gathers, and what the test supplies:
--   canonical, worktree, tool, path, command, session, holder (the queue's published holder or nil)
function M.decide(facts)
  facts = facts or {}
  local canonical = norm(facts.canonical)
  if canonical == "" then return nil end
  local session = facts.session and tostring(facts.session) or ""
  if facts.holder and session ~= "" and tostring(facts.holder.owner or "") == session then
    return nil -- the lease holder may land; the queue's own row is the authority it acts under
  end
  local tool = tostring(facts.tool or "")
  local reason, target
  if tool == "write" or tool == "edit" then
    target = facts.path
    if M.inside(target, canonical) then reason = tool .. " of a file inside the canonical checkout" end
  elseif tool == "bash" or tool == "operation" then
    reason = M.bash_mutates(facts.command, canonical)
    target = facts.command
  end
  if not reason then return nil end
  local worktree = facts.worktree or ""
  local holder = facts.holder
  return {
    error = M.RULE,
    effect = "none",
    rule = "the canonical checkout is not an editor: it is the tree landings merge into and deploys build from",
    detail = reason,
    canonical = canonical,
    worktree = worktree ~= "" and worktree or nil,
    holder = holder and {id = holder.id, owner = holder.owner, kind = holder.kind, branch = holder.branch} or nil,
    next = "Work in your own worktree" .. (worktree ~= "" and (" (" .. worktree .. ")") or "")
      .. " on a change/<name> branch, commit and push it, and land it with `node scripts/landing-queue.mjs land`."
      .. (holder and (" The tree is held by " .. tostring(holder.owner) .. " (" .. tostring(holder.kind or "landing")
        .. " on " .. tostring(holder.branch or "?") .. "), so an edit now would also land someone else's merge.") or
        " Nobody holds the landing lease now; if you believe this edit is the landing itself, take the lease first (`node scripts/landing-queue.mjs acquire`)."),
  }
end

-- The host-facing wrapper. Everything that needs the machine is here; everything that decides is above.
local resolved = {}

local function repository_of(cwd)
  local key = tostring(cwd or "")
  if resolved[key] ~= nil then return resolved[key] end
  local answer = nil
  local ok, repo = pcall(dofile, "lua/core/git_repository.lua")
  if ok and repo and repo.identity and key ~= "" then
    local good, identity = pcall(repo.identity, key)
    if good and type(identity) == "table" and identity.main and identity.common then
      answer = {canonical = identity.main, queue = identity.common .. "/wa-landing-queue"}
    end
  end
  resolved[key] = answer or false
  return answer
end

local function read_holder(queue_dir)
  if not queue_dir or not host or not host.read_file then return nil end
  local ok, text = pcall(host.read_file, queue_dir .. "/holder.json")
  if not ok or type(text) ~= "string" or text == "" then return nil end
  local decoded_ok, holder = pcall(function() return dofile("lua/vendor/json.lua").decode(text) end)
  if not decoded_ok or type(holder) ~= "table" then return nil end
  return holder
end

-- `guard(name, args, ctx)`: the refusal, or nil to let the call through.
function M.guard(name, args, ctx)
  if name ~= "write" and name ~= "edit" and name ~= "bash" and name ~= "operation" then return nil end
  if name == "operation" and (args or {}).action ~= "start" then return nil end
  if type(args) ~= "table" then return nil end
  local cwd = (ctx and (ctx.worktree or ctx.cwd)) or (platform and platform.cwd and platform.cwd()) or ""
  local repo = repository_of(cwd)
  if not repo then return nil end
  local holder = read_holder(repo.queue)
  local worktree = cwd
  if host and host.canonical_path then
    local ok, canonical = pcall(host.canonical_path, cwd)
    if ok and type(canonical) == "string" and canonical ~= "" then worktree = canonical end
  end
  return M.decide({tool = name, path = args.path, command = args.command,
    canonical = repo.canonical, worktree = worktree,
    session = ctx and ctx.session_id or nil, holder = holder})
end

return M
