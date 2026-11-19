-- What THIS node is running, against what the tree says (item 4 of the node-ops round, #45).
--
-- MEASURED: a session graded a binary built from an older commit while the tree had moved, and one row
-- was green against another commit's node. The fast path grew a banner for exactly this
-- (scripts/lib/fast-binary.sh) because nothing a MODEL could call answered the question. So the answer is
-- data here, and it names three separate facts instead of one verdict:
--   * the binary: its path, sha256, and the commit it says it was built from (host.runtime_info);
--   * the tree: HEAD, the branch, and whether the paths the binary embeds are unmodified;
--   * the RELATION: fresh (same commit, clean tree), stale (a different commit), edited (same commit but
--     uncommitted changes under lua/ or rust/), or unknown when a fact could not be read.
-- Unknown is never fresh: a build nobody can identify is the state this tool exists to expose.
local json = dofile('lua/vendor/json.lua')
local M = {}

-- A git answer, or nil: a tree that is not a repository is not this tool's error to raise.
local function git(root, args)
  local ran, raw = pcall(host.exec, "git -C " .. ("%q"):format(root) .. " " .. args, '', 60)
  if not ran then return nil end
  local answer = type(raw) == 'string' and (select(2, pcall(json.decode, raw))) or raw
  if type(answer) ~= 'table' then return nil end
  if (tonumber(answer.code) or 0) ~= 0 then return nil end
  return (tostring(answer.stdout or ''):gsub('%s+$', ''))
end

-- The paths whose bytes the binary embeds: an edit there makes a same-commit binary not this tree.
local EMBEDDED = { 'lua/', 'rust/' }

-- The relation, and every branch is a REFUSAL to say fresh when a fact is missing or disagrees.
--
-- Item 7 of the node-ops round (#45). The four facts, in the order they can rule a build out:
--   * the tree must be a git work tree and the binary must name a commit (unknown otherwise);
--   * the commits must be equal (stale otherwise) - that was the only comparison before;
--   * the binary must not record ITSELF as built from a dirty work tree: a dirty build at this same
--     commit embeds code this tree's git state does not describe, and calling it fresh is the lie the
--     item names;
--   * the binary's stamped source tree must equal the tree's own (a tree hash differs when the COMMITTED
--     bytes differ, which a commit comparison cannot see after a rewrite or an amend),
--   * and the paths the binary embeds must be unmodified now (edited otherwise).
function M.relation(tree, binary)
  local relation, why
  if not tree.head then
    relation = 'unknown'
    why = 'the tree ' .. tostring(tree.root or '(none)') .. ' is not a git work tree this node can read, so its commit cannot be compared with the binary'
  elseif not binary.commit then
    relation = 'unknown'
    why = 'the binary does not say which commit it was built from, so it cannot be shown to be this tree'
  elseif binary.commit ~= tree.head then
    relation = 'stale'
    why = 'the binary was built from ' .. binary.commit .. ' and the tree is at ' .. tree.head .. ': those are another commit bytes'
  elseif binary.built_dirty == true or binary.built_dirty == 'true' then
    -- A DIRTY BUILD AT THIS COMMIT IS NOT FRESH. Measured: a binary built from a work tree with edits
    -- at commit C embeds those edits, and the same commit C checked out cleanly has none of them;
    -- grading it 'fresh' says the binary is these bytes when it is those bytes plus edits.
    relation = 'edited'
    why = 'the binary records that it was built from a DIRTY tree at ' .. binary.commit .. ': it embeds edits this tree does not have, so it is not this tree bytes'
  elseif binary.built_tree and tree.tree and binary.built_tree ~= tree.tree then
    relation = 'stale'
    why = 'the binary names source tree ' .. binary.built_tree .. ' and this tree is ' .. tree.tree .. ' at the same commit: the committed bytes differ, which a commit comparison cannot see'
  elseif tree.clean == false then
    relation = 'edited'
    why = 'the binary and the tree name the same commit, but ' .. tostring(#(tree.edited or {})) .. ' uncommitted path(s) under lua/ or rust/ differ from it: the binary does not embed those edits'
  elseif tree.clean == nil then
    relation = 'unknown'
    why = 'the tree commit matches the binary, but git could not say whether the working tree is clean, so the binary cannot be shown to be these bytes'
  else
    relation = 'fresh'
    why = 'the binary was built from the commit and source tree this tree is at, from a clean work tree, and the paths it embeds are unmodified'
  end
  return relation, why
end
function M.status()
  local runtime = {}
  if host.runtime_info then
    local ok, raw = pcall(host.runtime_info)
    if ok then
      local decoded, value = pcall(json.decode, type(raw) == 'string' and raw or json.encode(raw))
      if decoded and type(value) == 'table' then runtime = value end
    end
  end
  local binary = {
    path = runtime.binary_path or runtime.binary or nil,
    commit = (runtime.build_source_commit and runtime.build_source_commit ~= '') and runtime.build_source_commit or nil,
    -- The two facts a clean-tree comparison alone cannot see (item 7 of the node-ops round). A build
    -- stamps the TREE it read (HEAD^{tree}) and whether that work tree had uncommitted changes. Without
    -- them, a dirty build at the same commit was graded 'fresh' - the binary embeds no edits and the
    -- tree has some, which is the definition of 'edited', not of 'fresh'.
    built_dirty = runtime.build_source_dirty,
    built_tree = (runtime.build_source_tree and runtime.build_source_tree ~= '') and runtime.build_source_tree or nil,
    built_branch = runtime.build_source_branch,
    version = runtime.version,
  }
  if not binary.path then
    return { ok = false, error = 'runtime_info_unavailable', relation = 'unknown', binary = binary, tree = nil,
      why = 'this node cannot say which binary is running (host.runtime_info named no binary path), so a build cannot be compared with the tree. Unknown is not fresh.' }
  end
  if host.file_sha256 then
    local ok, sha = pcall(host.file_sha256, binary.path)
    if ok and type(sha) == 'string' and sha ~= '' then binary.sha256 = sha end
  end

  -- The tree this Lua came from: the root the node itself resolves, never a guess from whatever
  -- directory the asking process happens to be in.
  local root = host.getenv('WASM_AGENT_LUA_ROOT') or runtime.source_root or ''
  local tree = { root = (root ~= '') and root or nil }
  if tree.root then
    tree.head = git(tree.root, 'rev-parse HEAD')
    tree.tree = git(tree.root, 'rev-parse HEAD^{tree}')
    tree.branch = git(tree.root, 'rev-parse --abbrev-ref HEAD')
    local porcelain = git(tree.root, 'status --porcelain -- ' .. table.concat(EMBEDDED, ' '))
    if porcelain ~= nil then
      tree.clean = (porcelain == '')
      if porcelain ~= '' then
        local paths = {}
        for line in porcelain:gmatch('[^\n]+') do paths[#paths + 1] = line end
        tree.edited = paths
      end
    end
  end

  local relation, why = M.relation(tree, binary)

  return { ok = relation == 'fresh', binary = binary, tree = tree, relation = relation, why = why,
    note = 'relation is about the IDENTITY of bytes, not about whether the tree builds: fresh means the binary embeds this commit and these edits. Unknown is never fresh.' }
end

return M
