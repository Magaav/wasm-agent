-- Consistent SQLite snapshot, including committed WAL data. No migrations,
-- transcript reads, provider calls or writes to the source DB's application data.
-- WA_BACKUP_PATH must name a new absolute file in an existing backup directory.
-- WA_SCRIPT=scripts/backup-db.lua WA_BACKUP_PATH=... wa --db <source.db>
local json=dofile('lua/vendor/json.lua')
local target=host.getenv('WA_BACKUP_PATH') or ''
assert(target:match('^%a:[/\\]') or target:sub(1,1)=='/', 'absolute WA_BACKUP_PATH required')
assert(host.read_file(target)==nil,'backup target already exists')
local result=host.sql_exec('VACUUM INTO ?',json.encode({target}))
if type(result)=='string' then result=json.decode(result) end
assert(result and not result.error,'backup failed: '..tostring(result and result.error))
print('database snapshot created: '..target)
