// Fixture data for scripts/test-ui.ps1, loaded before app.js.
//
// This is what makes the data-driven half of the UI testable: without it every
// panel renders its error path, and any assertion about it is an assertion about
// failure. With it, opening a view and asserting its contents is deterministic.
window.__fixtures = {
  version: { version: "test" },
  models: {
    model: "fixture-model", provider: "fixture", configured: true,
    context_limit: 128000, database: "/tmp/fixture.db",
    node_name: "foundation", node_worktree: "foundation",
    base_url: "http://fixture.invalid", usage: {},
  },
  sessions: {
    sessions: [
      {
        id: "aaaaaaaa-0000-0000-0000-000000000001", title: "unfinished thread",
        mode: "chat", turn_count: 61, updated_at: Math.floor(Date.now() / 1000) - 3600,
        state: "unfinished", state_detail: "stopped after a tool result with no next decision",
      },
      {
        id: "bbbbbbbb-0000-0000-0000-000000000002", title: "settled thread",
        mode: "chat", turn_count: 12, updated_at: Math.floor(Date.now() / 1000) - 120,
        state: "answered", state_detail: "the last turn is a reply",
      },
    ],
  },
  me: { user: { id: "master", name: "master" }, role: "master" },
  users: { users: [] },
  nodes: {
    nodes: [
      {
        id: "aaaaaaaa-1111-2222-3333-444444444444", node_id: "aaaaaaaa-1111-2222-3333-444444444444",
        name: "foundation", kind: "host", role: "master", online: true, local_node: true,
        worktree: "foundation", endpoints: {},
      },
      // The desktop running this window: local, but not the node. Both are local and they
      // must not both claim to be "this node".
      {
        id: "client", node_id: "client", name: "client", kind: "client", online: true,
        local_node: true, capabilities: ["screenshot", "frame", "click", "move", "type", "key", "shell", "cdp"],
      },
      {
        id: "bbbbbbbb-5555-6666-7777-888888888888", node_id: "bbbbbbbb-5555-6666-7777-888888888888",
        name: "openclaw", kind: "peer", online: true, local_node: false, endpoints: {},
      },
    ],
  },
  // There is deliberately no "node/name" fixture: a static stub for it would shadow the
  // handler below, and the point of the test is that the rename is a write with a
  // consequence. The write is modelled where the write is handled.
  // GET /sync: what wa_sync_status returns. Three peers on purpose, so the panel's three
  // states are all exercised by one fixture: behind (two + rows), ahead (one - row) and
  // level (the = row).
  sync: {
    node_id: "aaaaaaaa-1111-2222-3333-444444444444",
    head: 42,
    pushing_to: "openclaw.ohana",
    peers: [
      { peer_id: "bbbbbbbb-5555-6666-7777-888888888888", cursor: 40 },
      { peer_id: "cccccccc-8888-9999-aaaa-bbbbbbbbbbbb", cursor: 45 },
      { peer_id: "dddddddd-cccc-dddd-eeee-ffffffffffff", cursor: 42 },
    ],
  },
  tools: { tools: [] },
  // One thread, with a turn that was cut off: the chat must say so where the answer would have been,
  // and offer to continue. `session` is the key the stub matches after it strips the query.
  session: {
    session: { id: "aaaaaaaa-0000-0000-0000-000000000001", title: "unfinished thread" },
    state: "unfinished",
    state_detail: "1 tool call(s) with no recorded result: bash",
    turns: [
      { seq: 1, role: "user", content: "check the installer on the node", ok: 1, tool_calls: [] },
      { seq: 2, role: "assistant", content: "Running it now.", ok: 1, tool_calls: [] },
      { seq: 3, role: "assistant", content: "", ok: 1,
        tool_calls: [{ id: "c1", type: "function", function: { name: "bash", arguments: '{"command":"wa toolchain check"}' } }] },
      { seq: 4, role: "tool", content: '{"code":0,"stdout":"git yes"}', ok: 1, tool_name: "bash", tool_calls: [] },
    ],
  },
  spells: { spells: [] },
  // Two skills, one of them hidden from the model: the topic must show that difference, because
  // "the agent has this skill" and "the agent is told about this skill" are not the same claim.
  skills: {
    count: 2, loadable: 2, described: 1, role: "master",
    skills: [
      { name: "handoff-gate", description: "How to hand work off so a reviewer can verify it.",
        source: "repo", hidden: false, loadable: true, body_chars: 4200 },
      { name: "quiet-internals", description: "Notes that are never advertised to the model.",
        source: "user", hidden: true, loadable: true, body_chars: 900 },
    ],
  },
  env: {},
  usage: {},
};

const realFetch = window.fetch ? window.fetch.bind(window) : null;
window.fetch = function (input, init) {
  const url = String(typeof input === "string" ? input : (input && input.url) || "");
  // Record what the UI asked for: some properties are about the request, not the render.
  (window.__calls = window.__calls || []).push({
    url,
    method: (init && init.method) || "GET",
    body: (init && init.body) || "",
  });
  // Match the path, not a substring of it: url.includes("me") matched "node/name", so a
  // rename POST was answered with the account payload and the write never reached its
  // handler. A stub that answers the wrong request is worse than one that answers none.
  let path = url.split("?")[0];
  const schemeAt = path.indexOf("://");
  if (schemeAt >= 0) path = path.slice(schemeAt + 3);
  const slashAt = path.indexOf("/");
  // A relative fetch like "nodes" has no slash at all: keep it as the path.
  path = slashAt >= 0 ? path.slice(slashAt + 1) : path;
  if (path.endsWith("/")) path = path.slice(0, -1);
  const key = Object.keys(window.__fixtures).find((name) => path === name);
  if (key) {
    const payload = window.__fixtures[key];
    return Promise.resolve({
      ok: true, status: 200,
      json: () => Promise.resolve(payload),
      text: () => Promise.resolve(JSON.stringify(payload)),
    });
  }
  // A rename is a write, so the stub models its consequence: the node's name changes and
  // every later read of the list shows it.
  if (url.indexOf("node/name") >= 0 && (init && init.method) === "POST") {
    let wanted = "";
    try { wanted = String(JSON.parse((init && init.body) || "{}").name || ""); } catch (error) { /* keep "" */ }
    // A name the node refuses: the branch on GitHub could not be renamed, so the node keeps
    // what it had. The UI must not have moved on.
    if (wanted === "refused") {
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve({ error: "github_push_failed" }),
        text: () => Promise.resolve(JSON.stringify({ error: "github_push_failed" })),
      });
    }
    const local = window.__fixtures.nodes.nodes.find((entry) => entry.local_node);
    if (local && wanted) local.name = wanted;
    return Promise.resolve({
      ok: true, status: 200,
      json: () => Promise.resolve(window.__fixtures.nodes),
      text: () => Promise.resolve(JSON.stringify(window.__fixtures.nodes)),
    });
  }
  return realFetch ? realFetch(input, init) : Promise.reject(new Error("no fixture for " + url));
};

// A connection loss must be recognisable: the UI classifies it so it can say
// something actionable instead of printing "TypeError: network error".
window.__classifyProbe = function () {
  const results = [];
  if (typeof window.isConnectionLoss !== "function") return ["isConnectionLoss is not exposed"];
  if (!window.isConnectionLoss(new TypeError("network error"))) results.push("a TypeError must classify as a lost connection");
  if (window.isConnectionLoss({ name: "AbortError" })) results.push("an abort must not classify as a lost connection");
  if (!/wa ui/.test(window.connectionMessage())) results.push("the message must say how to start the node");
  if (!/resume/.test(window.connectionMessage())) results.push("the message must say the turn is recoverable");
  return results;
};
