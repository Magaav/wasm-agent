#!/usr/bin/env node
// The host page, rendered headlessly, for one ask - and asserted from inside the browser.
//
//   node scripts/test-modules-host.mjs --tree <tree> --out <dir> --observer <mjs> \
//     --ask <ids> --capabilities <caps> --bin <wa> [--label <name>] [--chrome <path>]
//
// Why this file exists: `scripts/test-modules-removal.sh` proves the listing and the tree with no
// browser, but "the host mounts nothing for it and reports no error" is a claim about a *page*, and
// the only place that can be observed is a page that rendered. So this stages the module tree the
// way a node serves it, renders the host page with the headless observer, and asserts the render
// from a probe inside it - the module mounted and refused when enabled, nothing mounted and no
// error when not, and the module's files unreachable when its directory is gone.
//
// It names no module. The module it renders is the first directory under `modules/` that carries a
// manifest, and everything it asserts is computed from that manifest, the ask and the grant - so it
// can be run against a tree whose module has been deleted, which is the state it is most needed in.
//
// The listing the page fetches is not written by hand: it is the route's own answer for the staged
// tree, printed by `scripts/modules-listing.lua` through the node binary. A checked-in listing would
// survive a deletion and lie, and a hand-built one would be this file's opinion of the route.
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function usage(problem) {
  if (problem) process.stderr.write(`test-modules-host: ${problem}\n`);
  process.stderr.write('usage: test-modules-host.mjs --tree <tree> --out <dir> --observer <mjs> ' +
    '--ask <ids> --capabilities <caps> --bin <wa> [--label <name>] [--chrome <path>]\n');
  process.exit(2);
}

function argumentsFrom(argv) {
  const opts = { ask: '', capabilities: '', label: 'render' };
  const valued = ['tree', 'out', 'observer', 'ask', 'capabilities', 'bin', 'label', 'chrome'];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--') || !valued.includes(arg.slice(2))) usage(`unknown argument: ${arg}`);
    opts[arg.slice(2)] = argv[++i];
  }
  for (const required of ['tree', 'out', 'observer', 'bin']) {
    if (!opts[required]) usage(`--${required} is required`);
  }
  return opts;
}

function tokens(text) {
  return String(text || '').split(/[,\s]+/).filter(Boolean);
}

// A JSON value for the probe's source: JSON is a subset of JavaScript, so the probe cannot be
// broken by a quote or a backslash in what it is given. This is the whole reason the expectations
// are data and not a printed literal.
function literal(value) {
  return JSON.stringify(value);
}

function readManifest(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

// The module the render is about, found rather than named - and `null` when the tree no longer holds
// one, which is the deleted case.
function findModule(tree) {
  const modules = path.join(tree, 'modules');
  let names = [];
  try { names = fs.readdirSync(modules, { withFileTypes: true }); } catch { return null; }
  const found = names.filter(entry => entry.isDirectory()
      && fs.existsSync(path.join(modules, entry.name, 'module.json')))
    .map(entry => entry.name)
    .sort();
  if (!found.length) return null;
  const id = found[0];
  const manifest = readManifest(path.join(modules, id, 'module.json'));
  if (!manifest) return null;
  return {
    id,
    dir: path.join(modules, id),
    entry: typeof manifest.entry === 'string' ? manifest.entry : '',
    declared: Array.isArray(manifest.capabilities) ? manifest.capabilities.filter(c => typeof c === 'string') : [],
    enabledInManifest: manifest.enabled === true,
  };
}

// The ask, and what it means: off unless asked for, and a capability this host does not grant is
// refused out loud. `panel` is the one grant this host always has; `--capabilities` adds to it, so
// the falsifier - grant it and the badge has to disappear - is one argument away.
function expects(module_, ask, capabilities) {
  const asked = new Set(tokens(ask));
  const granted = new Set(['panel', ...tokens(capabilities)]);
  const enabled = module_ ? (asked.has(module_.id) || module_.enabledInManifest) : false;
  const mounted = enabled && module_.entry !== '' ? [module_.id] : [];
  const refusals = mounted.length
    ? module_.declared.filter(capability => !granted.has(capability)).length : 0;
  return { mounted, refusals };
}

function run(command, args, options) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.error) throw new Error(`${command}: ${result.error.message}`);
  return result;
}

function main() {
  const opts = argumentsFrom(process.argv.slice(2));
  const tree = path.resolve(opts.tree);
  const out = path.resolve(opts.out);
  const observer = path.resolve(opts.observer);
  const bin = path.resolve(opts.bin);
  if (!fs.existsSync(path.join(tree, 'modules', 'index.html'))) {
    throw new Error(`no host page at ${path.join(tree, 'modules', 'index.html')}`);
  }
  if (!fs.existsSync(observer)) throw new Error(`no observer at ${observer}`);
  if (!fs.existsSync(bin)) throw new Error(`no node binary at ${bin}`);
  // The observer refuses an --out inside its --ui, and this refuses the reverse: a tree that is
  // rendered must not be the tree that is written to.
  fs.mkdirSync(out, { recursive: true });

  const ui = path.join(out, 'ui');
  fs.rmSync(ui, { recursive: true, force: true });
  fs.mkdirSync(ui, { recursive: true });
  fs.copyFileSync(path.join(tree, 'modules', 'index.html'), path.join(ui, 'index.html'));
  const module_ = findModule(tree);
  for (const entry of fs.readdirSync(path.join(tree, 'modules'), { withFileTypes: true })) {
    if (entry.isDirectory()) {
      fs.cpSync(path.join(tree, 'modules', entry.name), path.join(ui, entry.name), { recursive: true });
    }
  }

  // The node the listing comes from, as the shell fixtures run it: this tree's Lua, this node's
  // binary, a scratch home and database, and no inherited provider, home or rendezvous.
  const env = { ...process.env };
  for (const name of Object.keys(env)) {
    if (/^(WASM_AGENT_|WA_|OPENAI_|OPENCODE_|ANTHROPIC_)/.test(name)) delete env[name];
  }
  Object.assign(env, {
    WASM_AGENT_LUA_ROOT: tree,
    WASM_AGENT_MODULES_DIR: ui,
    WASM_AGENT_MODULES: opts.ask,
    WASM_AGENT_MODULE_CAPABILITIES: opts.capabilities,
    WASM_AGENT_HOME: path.join(out, 'home'),
    WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:1',
    WASM_AGENT_LLM_API_KEY: 'fixture-only',
  });
  const script = path.join(tree, 'scripts', 'modules-listing.lua');
  const printed = run(bin, ['--db', path.join(out, 'listing.db')], { cwd: tree,
    env: { ...env, WA_SCRIPT: script } });
  if (printed.status !== 0 || !printed.stdout.trim()) {
    throw new Error(`no listing from ${script} (exit ${printed.status}): ${printed.stderr.slice(0, 400)}`);
  }
  const listingText = printed.stdout.trim();
  fs.writeFileSync(path.join(ui, 'index.json'), listingText);
  let listingData = null;
  try { listingData = JSON.parse(listingText); } catch (error) {
    throw new Error(`the route did not answer JSON: ${error.message}`);
  }

  // What the page must do, in the browser's own terms.
  const expected = expects(module_, opts.ask, opts.capabilities);
  const entry = module_ && module_.entry ? `${module_.id}/${module_.entry}` : null;
  const entryFile = module_ && module_.entry ? path.join(module_.dir, module_.entry) : null;
  const probeExpectations = {
    mounted: expected.mounted,
    refusals: expected.refusals,
    label: opts.label,
    entry: null,
    entryStatus: null,
    entryLength: null,
    entryTitle: null,
  };
  if (entry && fs.existsSync(entryFile)) {
    // Mounted: the entry has to arrive over HTTP, with the length of the file on disk and, for HTML,
    // the title it carries. Present but off has no HTTP expectation: a static tree serves every file
    // it holds, and the refusal of an unasked module's files is the route's job - asserted by the
    // route harness, not by the file server.
    if (expected.mounted.length) {
      const bytes = fs.readFileSync(entryFile);
      const title = (bytes.toString('utf8').match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [])[1] || null;
      Object.assign(probeExpectations, {
        entry, entryStatus: 200, entryLength: bytes.length, entryTitle: title ? title.trim() : null,
      });
    }
  } else if (entry) {
    // Gone from the tree: nothing is mounted, and the module's own files do not answer either.
    Object.assign(probeExpectations, { entry, entryStatus: 404, entryLength: null });
  } else if (tokens(opts.ask)[0]) {
    // The tree holds no module at all and the ask names one: the module directory is not there to
    // serve anything. `module.json` is a file every module has, so its name is known without a
    // manifest to read - which is the state this case exists to render.
    Object.assign(probeExpectations,
      { entry: `${tokens(opts.ask)[0]}/module.json`, entryStatus: 404, entryLength: null });
  }

  const probe = probeSource(probeExpectations);
  const probeFile = path.join(out, 'probe.js');
  fs.writeFileSync(probeFile, probe);
  // A probe with a syntax error renders a normal page and reports nothing, which reads as a missing
  // instrument rather than a failure. Checked here, where the reason is still ours.
  const syntax = run(process.execPath, ['--check', probeFile], {});
  if (syntax.status !== 0) throw new Error(`the probe does not parse: ${syntax.stderr.slice(0, 300)}`);

  const observerArgs = ['--ui', ui, '--out', out, '--probe', probeFile, '--require', 'Module host'];
  if (opts.chrome) observerArgs.push('--chrome', opts.chrome);
  const observed = run(process.execPath, [observer, ...observerArgs], { cwd: path.dirname(observer) });
  let verdict = null;
  try { verdict = JSON.parse(observed.stdout.trim().split('\n').pop()); } catch { /* reported below */ }

  const problems = [];
  if (!verdict) {
    problems.push(`the observer said something unreadable (exit ${observed.status}): ` +
      `${observed.stdout.slice(-400)}${observed.stderr.slice(-400)}`);
  } else {
    if (verdict.browserError) problems.push(`browser: ${verdict.browserError}`);
    if (verdict.renderError) problems.push(verdict.renderError);
    if (verdict.probeStatus !== 'pass') problems.push(`probe ${verdict.probeStatus}: ${verdict.probeText || ''}`);
  }

  // The DOM the observer dumped is the page's own structure, so it is asserted here as well: the
  // probe could be right about a page that never mounted the section it looked for.
  let dom = '';
  try { dom = fs.readFileSync(path.join(out, 'dom.html'), 'utf8'); } catch { dom = ''; }
  if (!dom) problems.push('no dom.html from the observer');
  else {
    const mounted = dom.includes(`data-module="${module_ ? module_.id : ''}"`)
      && expected.mounted.length > 0;
    if (expected.mounted.length && !mounted) problems.push('the DOM holds no section for the mounted module');
    if (!expected.mounted.length && /data-module="/.test(dom)) problems.push('the DOM holds a mounted section nothing asked for');
    if (expected.mounted.length && entry && !dom.includes(`/${entry}"`)) {
      problems.push(`no frame addresses /${entry} (the module's entry, beside the page)`);
    }
    if (/class="issues"/.test(dom)) problems.push('the page rendered an issue banner');
  }

  const result = {
    label: opts.label,
    ok: problems.length === 0,
    tree,
    ask: opts.ask,
    capabilities: opts.capabilities,
    module: module_ ? module_.id : null,
    available: listingData ? listingData.available : null,
    mounted: expected.mounted,
    refusals: expected.refusals,
    entry,
    probe: verdict ? verdict.probeStatus : 'unreadable',
    probeText: verdict ? verdict.probeText : null,
    browser: verdict ? verdict.browser : null,
    screenshot: path.join(out, 'screenshot.png'),
    dom: path.join(out, 'dom.html'),
    problems,
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (!result.ok) process.exitCode = 1;
}

// The probe: it runs in the rendered page, waits for the page's own promise, and writes the verdict
// into `pre#wa-probe[data-status]`, which is the one element the observer reads back. It is written
// without escape sequences and checked with `node --check` before it is used.
function probeSource(expect) {
  return `'use strict';
(function () {
  var expect = ${literal(expect)};
  var pre = document.createElement('pre');
  pre.id = 'wa-probe';
  pre.textContent = 'waiting for the host page';
  document.body.appendChild(pre);
  function finish(status, text) {
    pre.setAttribute('data-status', status);
    pre.textContent = text;
  }
  function entryProblems() {
    if (!expect.entry) return Promise.resolve([]);
    return fetch(expect.entry, { cache: 'no-store' }).then(function (response) {
      return response.text().then(function (body) { return { status: response.status, body: body }; });
    }).then(function (result) {
      var problems = [];
      if (result.status !== expect.entryStatus) {
        problems.push('the entry answered HTTP ' + result.status + ', expected ' + expect.entryStatus);
      }
      if (expect.entryLength !== null && result.body.length !== expect.entryLength) {
        problems.push('the entry served ' + result.body.length + ' bytes, the file on disk holds ' + expect.entryLength);
      }
      if (expect.entryTitle && result.body.indexOf(expect.entryTitle) === -1) {
        problems.push('the entry served does not carry its own title');
      }
      return problems;
    }).catch(function (error) { return ['the entry could not be fetched: ' + error.message]; });
  }
  function inspect(state) {
    var problems = [];
    var sections = document.querySelectorAll('section[data-module]');
    var ids = [];
    for (var i = 0; i < sections.length; i += 1) ids.push(sections[i].getAttribute('data-module'));
    if (JSON.stringify(ids) !== JSON.stringify(expect.mounted)) {
      problems.push('mounted ' + JSON.stringify(ids) + ', expected ' + JSON.stringify(expect.mounted));
    }
    if (state.errors.length !== 0) {
      problems.push('the page reported ' + state.errors.length + ' problem(s): ' + state.errors.join('; '));
    }
    var badges = document.querySelectorAll('.refusal').length;
    if (badges !== expect.refusals) problems.push(badges + ' refusal badge(s), expected ' + expect.refusals);
    if (document.querySelectorAll('p.issues').length !== 0) problems.push('the page rendered an issue banner');
    var status = document.getElementById('status');
    var text = status ? status.textContent : '';
    if (text.indexOf('mounted ' + expect.mounted.length + ' module') !== 0) {
      problems.push('the status line reads "' + text + '"');
    }
    if (document.querySelectorAll('main#mount iframe').length !== expect.mounted.length) {
      problems.push('the mount holds ' + document.querySelectorAll('main#mount iframe').length + ' frame(s)');
    }
    return problems;
  }
  var ready = window.waHostReady;
  if (!ready || typeof ready.then !== 'function') {
    finish('fail', 'the host page did not announce window.waHostReady');
    return;
  }
  ready.then(function (state) {
    return entryProblems().then(function (entry) { return inspect(state).concat(entry); });
  }).then(function (problems) {
    if (problems.length) finish('fail', problems.join(' | '));
    else finish('pass', expect.label + ': mounted ' + JSON.stringify(expect.mounted) +
      ', refusals ' + expect.refusals + (expect.entry ? ', entry HTTP ' + expect.entryStatus : ''));
  }, function (error) {
    finish('fail', 'the host page rejected: ' + (error && error.message));
  });
})();
`;
}

try {
  main();
} catch (error) {
  process.stdout.write(`${JSON.stringify({ ok: false, error: error.message })}\n`);
  process.exitCode = 1;
}
