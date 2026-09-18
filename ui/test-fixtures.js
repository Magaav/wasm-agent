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
    base_url: "http://fixture.invalid", usage: {},
  },
  sessions: {
    sessions: [
      {
        id: "aaaaaaaa-0000-0000-0000-000000000001", title: "unfinished thread",
        mode: "chat", turn_count: 61, updated_at: 1789000000,
        state: "unfinished", state_detail: "stopped after a tool result with no next decision",
      },
      {
        id: "bbbbbbbb-0000-0000-0000-000000000002", title: "settled thread",
        mode: "chat", turn_count: 12, updated_at: 1789000000,
        state: "answered", state_detail: "the last turn is a reply",
      },
    ],
  },
  nodes: {
    nodes: [
      {
        id: "aaaaaaaa-1111-2222-3333-444444444444", node_id: "aaaaaaaa-1111-2222-3333-444444444444",
        name: "foundation", kind: "host", role: "master", online: true, local_node: true,
        worktree: "foundation", endpoints: {},
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
  spells: { spells: [] },
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
  const key = Object.keys(window.__fixtures).find((name) => url.includes(name));
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
