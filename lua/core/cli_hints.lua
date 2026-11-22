-- What a search that found nothing can still say (22/11).
--
-- WHAT HAPPENED. A turn asked to "check github": `searchTools("github")` answered `[]`, `capabilities()`
-- listed no GitHub tool, and the turn spent two discovery calls before it found that `gh` was installed
-- and `tools.bash` runs it. The empty list carried no reason, and nothing on this node listed the
-- command-line tools the machine has - only the tools the node grants.
--
-- WHAT THIS IS. One question, asked at MISS time only: does a word of the query name a program that is
-- installed here? The table is short and explicit - the model's word on the left, the program it means on
-- the right - so this is an allow-list, never an inventory: a query probes the PATH for a word the table
-- names, and for no other word. At most ONE lookup per miss (`host.executable_on_path`, the same function
-- the kernel starts a bare program name with), no login probe (nothing here reads a keyring or runs a
-- program), and nothing at load: a node that never misses never asks.
local M = {}

-- The sentence a miss carries when the table names no installed program: the fact a model without a
-- github tool needed. It lives in the search's own RESULT, so the prompt and the tool list stay
-- byte-identical (a prompt cache holds them).
M.FALLBACK = "Any command-line tool on this machine runs through tools.bash."

-- The table starts with the words measured on 22/11: a host with `gh` 2.105 installed and logged in that
-- answered no tool for "github". A program's own name maps to itself, so the query the model types
-- ("docker", "kubectl") and the word it does not ("github") are answered the same way. Adding a row is
-- the whole cost of a new alias.
M.PROGRAMS = {
  gh = 'gh', github = 'gh',
  glab = 'glab', gitlab = 'glab',
  git = 'git', docker = 'docker', kubectl = 'kubectl',
  aws = 'aws', gcloud = 'gcloud', az = 'az',
}

--- The program the query names and where it lives: `{name, path, word}`, or nil.
--- The FIRST word the table names decides, installed or not - one lookup per miss - so a query cannot
--- walk the table and turn a hint into an inventory of the machine. A host that cannot resolve a bare
--- name answers nil, and an unverified path is never a hint.
function M.hint(query)
  if type(query) ~= 'string' then return nil end
  if type(host) ~= 'table' or type(host.executable_on_path) ~= 'function' then return nil end
  for term in query:lower():gmatch('[%w_]+') do
    local program = M.PROGRAMS[term]
    if program then
      local path = host.executable_on_path(program)
      if type(path) == 'string' and path ~= '' then return {name = program, path = path, word = term} end
      return nil
    end
  end
  return nil
end

--- What a miss says: `subject` is the sentence's own subject ("no tool in this script's catalogue matches
--- 'github'."), so the two search surfaces word their own fact and share the rest - the installed program
--- and its path when there is one, and the command-line fact when there is not.
function M.reason(subject, found)
  if found then
    return subject .. ' ' .. found.name .. ' is installed (' .. found.path .. '): run it with tools.bash.'
  end
  return subject .. ' ' .. M.FALLBACK
end

return M
