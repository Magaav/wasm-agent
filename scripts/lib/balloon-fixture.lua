-- The data every balloon snapshot is taken from: an MCP inventory and a provider state, with no node, no
-- registry and no clock in them.
--
-- Why a fixture instead of a real registry: a snapshot that changes with the machine it ran on is not a
-- snapshot. These four connectors cover the four things the list has to say - connected, from a peer,
-- failed with an error long enough to wrap, and a credential the far end refused - and the tool table
-- covers a schema (so "input: chat, limit" is measured, not assumed) and a tool nobody approved.
local M = {}

function M.mcp_view()
  return {
    ok = true, read_only = false, role = 'master', revision = 42, peers_at = 1762700000,
    counts = { connectors = 4, services = 4, built_in = 1, mcp = 3, here = 3, from_peers = 1, enabled = 2, tools = 5 },
    note = 'A change applies to new sessions at once; sessions already running are told on their next turn '
      .. 'by the existing [session update] note, because the callable tool list is part of the frozen prefix.',
    connectors = {
      {
        key = 'whatsapp', id = 'whatsapp', name = 'WhatsApp', where = 'this node', scope = 'built-in',
        type = 'built-in', node = 'openclaw', node_phrase = 'account on openclaw', state_label = 'connected',
        count_phrase = '36 chats',
        transport = 'native', state = 'enabled', enabled = true, tool_count = 3, approved = 3, discovered = 3,
        -- No `revision`: a built-in service has no registry row, so the page must not print one.
        observed = 'probe ok 4 min ago',
        policy = { tier = 'mcp', approval = 'each tool is approved locally as read or write',
          note = 'Trusted executable code, not a sandbox.' },
        tools = {
          { name = 'mcp_whatsapp_read', approval = 'read', published = true,
            description = 'Read one WhatsApp chat newest-first, from the linked device journal.',
            schema = '{"type":"object","properties":{"chat":{"type":"string"},"limit":{"type":"integer"}}}' },
          { name = 'mcp_whatsapp_search', approval = 'read', published = true,
            description = 'Search the journal by text.', schema = '{"type":"object","properties":{"query":{"type":"string"}}}' },
          { name = 'mcp_whatsapp_send', approval = 'write', published = true,
            description = 'Send one message to one chat.', schema = '{"type":"object","properties":{"chat":{},"text":{}}}' },
        },
      },
      {
        key = 'openclaw:whatsapp_native', id = 'whatsapp_native', name = 'whatsapp_native', peer = 'openclaw',
        type = 'MCP', node = 'openclaw', node_phrase = 'on openclaw',
        where = 'openclaw', scope = 'peer', transport = 'native', state = 'enabled', enabled = true,
        tool_count = 1, approved = 1, discovered = 1, revision = 7,
        policy = { tier = 'mcp', managed_by = 'openclaw (lua/core/mcp.lua there)',
          approval = 'approved on openclaw as read or write; this node calls it through the fabric' },
        tools = {
          { name = 'peer_openclaw__read_newest', approval = 'read', published = true,
            description = 'MCP whatsapp_native / read_newest: read one chat', schema = '{}' },
        },
      },
      {
        key = 'native_reads', id = 'native_reads', name = 'Filesystem reads', where = 'this node', scope = 'local',
        type = 'MCP', node = 'this node', node_phrase = 'on this node',
        transport = 'stdio', state = 'failing', enabled = false, tool_count = 0, approved = 1, discovered = 0,
        revision = 42, error = 'probe failed: connect to /run/wasm-agent/mcp/native_reads.sock: connection refused '
          .. '(the component was rebuilt without its socket, so this node has no catalogue of its tools)',
        policy = { tier = 'mcp', approval = 'each tool is approved locally as read or write' },
        tools = {
          { name = 'mcp_native_reads_read_newest_x9f1', tool = 'read_newest', approval = 'read', published = false,
            description = '(approved, but the last probe did not list this tool)', schema = '{}',
            note = 'approved_but_not_discovered' },
        },
      },
      {
        key = 'gated', id = 'gated', name = 'Gated reports', where = 'this node', scope = 'local', transport = 'http',
        type = 'MCP', node = 'this node', node_phrase = 'on this node',
        state = 'disabled', enabled = false, tool_count = 0, approved = 0, discovered = 0, revision = 42,
        error = '401 unauthorized: the access token was rejected by the reports service', secret_env = { 'GATED_MCP_TOKEN' },
        policy = { tier = 'mcp', approval = 'each tool is approved locally as read or write' }, tools = {},
      },
    },
  }
end

function M.provider_state()
  return {
    selected = 'opencode-go', revision = 12,
    providers = {
      { id = 'opencode-go', label = 'OpenCode Go', source = 'vault', configured = true, enabled = true,
        operator_url = 'https://vault.example/#vault=0f7d1b0a-0000-4000-8000-000000000000' },
      { id = 'openai-sub', label = 'ChatGPT subscription', source = 'vault', configured = false,
        operator_url = nil, error = { code = 'vault_status_unknown' } },
      { id = 'env', label = 'Environment key', source = 'legacy environment', configured = true, enabled = true },
    },
  }
end

return M
