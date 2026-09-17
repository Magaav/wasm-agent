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
        id: "aaaaaaaa-0000-0000-0000-000000000001", title: "interrupted thread",
        mode: "chat", turn_count: 61, updated_at: 1789000000,
        state: "interrupted", state_detail: "died after a tool result with no next decision",
      },
      {
        id: "bbbbbbbb-0000-0000-0000-000000000002", title: "settled thread",
        mode: "chat", turn_count: 12, updated_at: 1789000000,
        state: "answered", state_detail: "the last turn is a reply",
      },
    ],
  },
  nodes: { nodes: [] },
  tools: { tools: [] },
  spells: { spells: [] },
  env: {},
  usage: {},
};

const realFetch = window.fetch ? window.fetch.bind(window) : null;
window.fetch = function (input, init) {
  const url = String(typeof input === "string" ? input : (input && input.url) || "");
  const key = Object.keys(window.__fixtures).find((name) => url.includes(name));
  if (key) {
    const payload = window.__fixtures[key];
    return Promise.resolve({
      ok: true, status: 200,
      json: () => Promise.resolve(payload),
      text: () => Promise.resolve(JSON.stringify(payload)),
    });
  }
  return realFetch ? realFetch(input, init) : Promise.reject(new Error("no fixture for " + url));
};
