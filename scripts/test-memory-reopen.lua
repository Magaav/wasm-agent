-- A database this build created must open again: setup() runs the shape migration on every open (29/10).
local memory=dofile('lua/core/memory.lua')
memory.setup()
-- A new process: db_ready() is per process, so a second setup() in this one would skip the migration.
host.db_ready=function()return false end
memory.setup()
local json=dofile('lua/vendor/json.lua')
local idx=json.decode(host.sql_query("SELECT name FROM sqlite_master WHERE type='index' AND name='messages_time_idx'",'[]'))
assert(#idx==1,'the transcript keeps its time index across reopen')
print(json.encode({ok=true,checks=2}))
