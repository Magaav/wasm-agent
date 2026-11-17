-- The core's handle on a stateless helper (`pure` in lua/core/reload.lua): `dofile("lua/core/pure.lua")(path)`.
--
-- A field is looked up when it is USED, not when the caller loaded: `agent.lua` is loaded before the chat
-- parses `--dev`, so a handle fixed at load time would never see the reload source. With a source active
-- the field comes from the reloader's copy - which changes only at a turn boundary, so a run sees one
-- version - and with none it is the node's own module, read once. No source, no reloader: exactly the
-- plain `dofile` this replaced.
--
-- Guards never use this: a guard reads its dependencies with the plain `dofile`, from the node's own tree.
local handles = {}
return function(path)
  local handle = handles[path]
  if handle then return handle end
  local node
  handle = setmetatable({}, {
    __index = function(_, key)
      local reloader = rawget(_G, "__wa_reload")
      if reloader and reloader.mode and reloader.mode() and reloader.class(path) == "pure" then
        return reloader.require(path)[key]
      end
      node = node or dofile(path)
      return node[key]
    end,
  })
  handles[path] = handle
  return handle
end
