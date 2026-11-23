-- The way `changeset` reaches a file that lives on a PEER.
--
-- A change made on another node is verified and undone THERE: the undo of a remote edit must put the
-- peer's file back, not write the same path over a local one (mission remote-edit-first-class, item 2).
-- `lua/core/changeset.lua` owns no transport; it asks for one by node name, and this is the module that
-- answers. It lives apart from `lua/core/server.lua`, where it used to be inline, because the CLI chat
-- never loads the server: `/undo` in a terminal has to reach the same peer the change was made on
-- (mission remote-undo-works), and two copies of a transport is how one of them quietly stops matching
-- the other's answer.
--
-- The interface `changeset` uses is two functions, and only these two:
--   digest(path)      -> sha256 of the file's text as it is NOW, or nil and the reason (e.g. not_found)
--   write(path,text)  -> true, or nil and the reason
-- A digest rather than the text is what makes a large file checkable: the read capability answers the
-- whole file's `version` even for a one-line page, so the guard costs one small call and no transfer.
--
-- Nothing is loosened by being callable from the chat: the peer answers as it does for any peer call -
-- its own guards, its own workspace, its own refusal - and the caller still signs the body
-- (`nodes.remote_call`).
local M = {}

-- The nodes module. It is passed in when the caller already holds one (`server.lua` does, and a test's
-- fixture does), because a peer call is signed and its answer verified by THAT module's identity and
-- roster: a second instance would sign with a different view of this node than the rest of the process.
local function nodes_module(given)
  if type(given) == "table" then return given end
  return dofile("lua/core/nodes.lua")
end

-- The transport for one node, in the shape `changeset.set_file_host` expects: a function that takes a
-- node name and answers the table below, or nil when this build cannot reach a peer at all (changeset
-- then refuses a remote entry by name instead of writing to the wrong machine).
function M.transport(node, given)
  local nodeslib = nodes_module(given)
  return {
    -- The digest of the file's text as the peer has it, not the text: the read capability answers the
    -- whole file's `version` for a one-line page too, so a 200 KB file is verified without moving it.
    digest = function(path)
      local answer = nodeslib.remote_call(node, "read", { path = path, offset = 1, limit = 1 })
      if type(answer) ~= "table" then return nil, "node_no_answer" end
      if type(answer.version) == "string" and answer.version ~= "" then return answer.version end
      return nil, tostring(answer.error or "node_no_answer")
    end,
    write = function(path, text)
      local answer = nodeslib.remote_call(node, "write", { path = path, content = text })
      if type(answer) == "table" and answer.ok == true then return true end
      return nil, tostring(type(answer) == "table" and (answer.error or "write_refused") or "node_no_answer")
    end,
  }
end

-- Install this module as `changeset`'s transport. Returns true, or nil and the reason, so a caller that
-- hands over something that is not the changeset learns instead of believing it was installed.
function M.install(changeset, given)
  if type(changeset) ~= "table" or type(changeset.set_file_host) ~= "function" then
    return nil, "no_changeset"
  end
  local nodeslib = nodes_module(given)
  changeset.set_file_host(function(node) return M.transport(node, nodeslib) end)
  return true
end

return M
