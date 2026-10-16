local files={'wave_autoflush','update','agent','tools','completions','integrate','codemode','hook_events'}
for _,name in ipairs(files) do assert(loadfile('lua/core/'..name..'.lua'));print('syntax '..name) end
