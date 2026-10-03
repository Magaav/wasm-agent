dofile('lua/core/provider.lua')
dofile('lua/core/orchestrator.lua')
dofile('lua/core/server.lua')
print('SOURCE_PROOF '..dofile('lua/vendor/json.lua').encode(LOADED_SOURCES))