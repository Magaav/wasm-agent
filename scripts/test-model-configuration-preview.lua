-- A selected configuration/tool preview is not a model-call request.
local json = dofile('lua/vendor/json.lua')
dofile('lua/core/server.lua')
local users = dofile('lua/core/users.lua')
local tools = dofile('lua/core/tools.lua')
local guest = users.login('guest')

for _, session in ipairs({ '', guest }) do
  local selected = json.decode(wa_model_configuration_preview(session))
  local legacy = json.decode(wa_envelope(session))
  assert(json.encode(selected) == json.encode(legacy), 'legacy preview alias must preserve its response')
  assert(type(selected.request.model) == 'string' and selected.request.model ~= '')
  assert(type(selected.request.tools) == 'table' and selected.tool_count == #selected.request.tools)
  assert(selected.tool_count == #tools.all(selected.role), 'preview must show the role-filtered tool surface')
  assert(selected.request.messages == nil and selected.request.tool_choice == nil
    and selected.request.stream == nil, 'preview must not masquerade as a model-call request')
  if selected.role == 'guest' then
    for _, schema in ipairs(selected.request.tools) do
      assert(schema['function'].name ~= 'bash', 'guest preview must not offer operator tools')
    end
  end
end
print('model request preview ok')
