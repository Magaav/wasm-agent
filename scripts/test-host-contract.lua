-- Host capability contract checks that need a real interpreter.
--
--   WA_SCRIPT=scripts/test-host-contract.lua wa --db <scratch>
--
-- A host function ALWAYS returns a value: an absent one is nil, never "no
-- values". Zero results expand to nothing when used as an argument, which is how
-- `tonumber(host.getenv(X))` once became `tonumber()` and failed. These checks
-- pin the arity of the database-readiness capabilities.
local memory = dofile("lua/core/memory.lua")
memory.setup()

-- mark_db_ready returns exactly one value, and that value is nil.
assert(select("#", host.mark_db_ready()) == 1, "host.mark_db_ready must return one value (nil)")
assert(host.mark_db_ready() == nil, "host.mark_db_ready must return nil")
assert(select("#", host.db_ready()) == 1, "host.db_ready must return one value")
assert(host.db_ready() == true, "host.db_ready must be true after mark_db_ready")

print("host contract ok")
