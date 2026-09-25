// Fixture data for scripts/test-ui.ps1, loaded before app.js.
//
// This is what makes the data-driven half of the UI testable: without it every
// panel renders its error path, and any assertion about it is an assertion about
// failure. With it, opening a view and asserting its contents is deterministic.
// A shell that records what the page asks it to do, for the checks that need one. Deliberately *not*
// installed here: the page must be loaded without a shell first, because a page that assumes one is a page
// that breaks in a browser, and that degradation is itself checked. The harness installs this with
// `__setShell` only for the window path.
window.__makeShell = () => ({
  calls: [],
  openView(view, url) { window.__shellCalls.push({ call: "openView", view: view, url: url }); },
  closeView() { window.__shellCalls.push({ call: "closeView" }); },
  setMode(mode, w, h) { window.__shellCalls.push({ call: "setMode", mode: mode, w: w, h: h }); },
  expand() { window.__shellCalls.push({ call: "expand" }); },
  compact() { window.__shellCalls.push({ call: "compact" }); },
  maximize() { window.__shellCalls.push({ call: "maximize" }); },
});
window.__shellCalls = [];

window.__fixtures = {
  version: { version: "test" },
  jobs: {jobs: [{id:'fixture-job', name:'<img src=x onerror=alert(1)>', enabled:false, revision:1,
    trigger:{kind:'event',topic:'fixture.message'}, action:{kind:'wake',session:'fixture',prompt:'review only'},
    queued:0, source_status:'waiting for explicit event ingress'}]},
  // The `/update` report. Shaped like the node's answer (lua/core/update.lua), because the window
  // shows the node's own sentence rather than inventing one: a fixture that invents its own wording
  // would let the two drift and still pass.
  update: {
    ok: true, queued: true, status: "queued", commit: "abc1234", dirty: 0,
    tree: "C:/work/foundation", candidate: "C:/work/foundation/rust/target/release/wa.exe",
    request: "C:/Users/test/.wasm-agent/sentinel/requests/1789987058-5708.json",
    reason: "/update: install the build in C:/work/foundation",
    message: "queued: the sentinel will install abc1234 once this node is idle. This is not done yet.",
    next: "the sentinel performs it when this node is idle.",
  },
  // The `/efficiency` read behind the window's `/efficiency_report`. Preformatted text, shaped
  // like the node's answer (lua/core/efficiency.lua) - the window shows the node's own report
  // rather than building one, so a fixture with its own wording would let the two drift.
  efficiency: {
    session_id: "session-fixture-1",
    text: "efficiency report - session fixture\n  last call\n    prompt 1,000 tok   cache read 900 (90.0%)   uncached input 100   cache write 0   prefix append_only (12 appended, 40 shared)\n  session totals (3 inference calls)\n",
  },
  models: {
    model: "fixture-model", provider: "fixture", configured: true,
    context_limit: 128000, database: "/tmp/fixture.db",
    node_name: "foundation", node_worktree: "foundation",
    base_url: "http://fixture.invalid", usage: {},
    reasoning:{supported:true,levels:['low','high'],selected:'high',source:'fixture'},
    observability:{available:true,scope:'session',session_id:'fixture-session',since:1,
      total:{calls:3,failed:1,prompt:12000,input:2000,cacheRead:10000,cacheWrite:0,output:400,
        reasoning:200,reasoning_unknown:0,missing_usage:0,missing_cache:0,unpriced:3,cost_known:false,cache_known:true},
      inference:{calls:2,ms:2000},compaction:{calls:1,prompt:3000,output:200,ms:1000},
      last:{normalized:{prompt:6000,reasoning:100},finish_reason:'stop'},
      last_request:{model:'previous-model',provider:'fixture',settings:{reasoning:{selected:'low'},output_limit:16000},
        prompt_shape:{system_bytes:1200,schema_bytes:800,user_bytes:300,assistant_bytes:900,
          tool_result_bytes:400,reasoning_source_bytes:200,tool_arguments_source_bytes:100,
          tool_calls:3,tool_results:3}},
      context:{unsummarized_rows:620,summary_watermark:10},pending:1,tool_calls:2,tool_failures:1,
      runs:1,incomplete_runs:0,compaction_failures:1,errors:[]},
  },
  reasoning:{error:'unsupported_reasoning_level'},
  'observability/events':{error:'fixture_export_failure'},
  sessions: {
    sessions: [
      {
        id: "aaaaaaaa-0000-0000-0000-000000000001", title: "unfinished thread",
        mode: "chat", message_count: 61, updated_at: Math.floor(Date.now() / 1000) - 3600,
        state: "unfinished", state_detail: "stopped after a tool result with no next step",
      },
      {
        id: "bbbbbbbb-0000-0000-0000-000000000002", title: "settled thread",
        mode: "chat", message_count: 12, updated_at: Math.floor(Date.now() / 1000) - 120,
        state: "answered", state_detail: "the last message is a reply",
      },
    ],
  },
  me: { user: { id: "master", name: "master" }, role: "master" },
  // What the node says about right now. The window asks this before believing a run is over, so a
  // notice can be taken down when the thread is settled - and a run that completed is not "unfinished".
  health: { current: null, operations: [], ok: true, queue: 0, stalled_ms: 0, worker: "alive" },
  // `POST /runs` is the node-side cancel/status route. The UI fires it and does not wait on the
  // answer, but the fixture must exist so the request is answered locally and never reaches a node.
  runs: { ok: true, conversation: "fixture", runs: [], cancelled: false },
  // `POST /operation` with `action:'read'`: the running operation's output page. The progress
  // check overwrites this with the line it wants to see.
  operation: { content: "", offset: 0, next_offset: 0, bytes: 0, eof: true },
  // The resume path posts a run. It must be answered *here*: the fallback below used to forward an
  // unstubbed route to the real node, and since the app now auto-resumes a failed session, a run of this
  // harness queued 33 real runs on a live node before anyone noticed. A test that spends runs is not a
  // test. The body is deliberately not a stream: `send` fails to read it, catches, and the checks that
  // matter are about what the UI said, not what the model replied.
  chat: { ok: true, reply: "(the harness does not run a model)" },
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
  frame: { ok: true, full: true, width: 2, height: 2, screen_width: 20,
    screen_height: 20, origin_x: -10, origin_y: 0, tiles: [] },
  client: { ok: true },
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

// The UI test reloads the actual browser page halfway through a recorded tool call.
// Install the second-load fixture before app.js starts its boot requests.
if (sessionStorage.getItem("wa-ui-reload-stage") === "active") {
  const id = "eeeeeeee-0000-0000-0000-000000000005";
  window.__fixtures.sessions = { sessions: [{
    id, title: "running reload proof", user_id: "master", mode: "chat", message_count: 2,
    updated_at: Math.floor(Date.now() / 1000), state: "unfinished",
    state_detail: "1 tool call(s) with no recorded result: bash",
  }] };
  window.__fixtures.session = {
    session: { id, title: "running reload proof" },
    state: { state: "unfinished", detail: "1 tool call(s) with no recorded result: bash" },
    messages: [
      { seq: 1, role: "user", content: "EARLIER-INTERRUPTED-QUESTION", tool_calls: [] },
      { seq: 2, role: "assistant", content: "", reasoning: "EARLIER-REASONING",
        tool_calls: [
        { id: "earlier-lost", type: "function", function: { name: "bash", arguments: "{\"command\":\"earlier check\"}" } },
      ] },
      { seq: 3, role: "user", content: "RELOAD-MID-RUN-QUESTION", tool_calls: [] },
      { seq: 4, role: "assistant", content: "", tool_calls: [
        { id: "reload-tool", type: "function", function: { name: "bash", arguments: "{\"command\":\"slow check\"}" } },
      ] },
      // A finished run, so a repainted transcript has something that *should* carry a footer. The two
      // above are both mid-run (tool calls with no result), and a repaint of those must keep the
      // in-progress notice rather than claim they completed.
      { seq: 5, role: "user", content: "FINISHED-QUESTION", created_at: 1790000000, tool_calls: [] },
      { seq: 6, role: "assistant", content: "FINISHED-ANSWER", created_at: 1790000004, tool_calls: [] },
    ],
  };
  window.__fixtures.health = {
    // A UI read can occupy worker 0 while a chat turn runs on another worker.
    current: { label: "GET /models", ms: 30 },
    // The run belongs to *this* window's conversation. `activeRun` matches the conversation, so a
    // worker with no `session` would (correctly) not be claimed as this window's run - and this
    // fixture exists to prove the reload sees its own run, so it must name it.
    workers: [{ label: "POST /chat", busy_ms: 15000, session: id }], ok: true, queue: 0,
    stalled_ms: 20, worker: "alive", exec_timeout_seconds: 300,
  };
}

const realFetch = window.fetch ? window.fetch.bind(window) : null;
window.fetch = function (input, init) {
  const url = String(typeof input === "string" ? input : (input && input.url) || "");
  // Record what the UI asked for: some properties are about the request, not the render.
  (window.__calls = window.__calls || []).push({
    url,
    method: (init && init.method) || "GET",
    body: (init && init.body) || "",
    headers: (init && init.headers) || {},
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
  if (path === 'jobs' && init?.method === 'POST') {
    const request = JSON.parse(init.body);
    if (window.__fixtures.jobsRefuse) return Promise.resolve({ok:false,status:403,json:()=>Promise.resolve({error:'fixture_job_refused'})});
    const job = window.__fixtures.jobs.jobs.find(j=>j.id===request.id);
    if (job) job.enabled = request.action === 'enable';
    return Promise.resolve({ok:true,status:200,json:()=>Promise.resolve(job || {error:'not_found'})});
  }
  // `/version` is the page's once-a-second liveness loop. `__failVersion` makes it fail so a test can
  // prove the shell heartbeat does not depend on the node answering.
  if (path === 'version') {
    if (window.__failVersion) return Promise.reject(new Error('fixture: version unavailable'));
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ version: 'fixture' }) });
  }
  // A transcript read can fail after `/sessions` has already advertised its new sequence. The
  // follower must retry that same sequence rather than marking it seen and waiting for another row.
  if (path === 'session' && Number(window.__failSessionReads) > 0) {
    window.__failSessionReads -= 1;
    return Promise.reject(new Error('fixture: transient session read failure'));
  }
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
  // A diff request is answered by its action rather than by one fixed body: the topic asks whether the
  // change can still be undone, and when a changed file is clicked it asks for that file's patch.
  if (path === "diff" && (init && init.method) === "POST") {
    let request = {};
    try { request = JSON.parse((init && init.body) || "{}"); } catch (error) { /* keep {} */ }
    if (request.action === "patch") {
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve({
          path: request.path, truncated: false, added: 1, removed: 1, created: false,
          patch: "--- before/" + request.path + "\n+++ after/" + request.path +
                 "\n@@ -1,2 +1,2 @@\n same line\n-old line\n+new line",
        }),
        text: () => Promise.resolve("{}"),
      });
    }
    return Promise.resolve({
      ok: true, status: 200,
      json: () => Promise.resolve({ can_undo: true, reason: "undoable" }),
      text: () => Promise.resolve("{}"),
    });
  }
  // Refused, not forwarded - with one exception. See the note on the `chat` fixture: reaching the real
  // node by accident is how this harness queued real runs. API routes are where a run is spent, so they
  // must be stubbed. Static assets cost nothing and one of them is a real file the checks need (the wasm
  // markdown renderer), so those may be fetched. A route that genuinely needs the live node asks by name.
  const isStaticAsset = /\.(wasm|css|js|png|jpg|svg|woff2?|ico)$/.test(path);
  if ((window.__fixtures.__allowReal || isStaticAsset) && realFetch) return realFetch(input, init);
  return Promise.reject(new Error("no fixture for " + url + " - the harness does not reach the real node"));
};

// A connection loss must be recognisable: the UI classifies it so it can say
// something actionable instead of printing "TypeError: network error".
window.__classifyProbe = function () {
  const results = [];
  if (typeof window.isConnectionLoss !== "function") return ["isConnectionLoss is not exposed"];
  if (!window.isConnectionLoss(new TypeError("network error"))) results.push("a TypeError must classify as a lost connection");
  if (window.isConnectionLoss({ name: "AbortError" })) results.push("an abort must not classify as a lost connection");
  if (!/wa ui/.test(window.connectionMessage())) results.push("the message must say how to start the node");
  if (!/resume/.test(window.connectionMessage())) results.push("the message must say the run is recoverable");
  return results;
};
