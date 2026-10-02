// Reviewer's probe of the lane outcomes across lane shapes, on the new tip.
//
// The durable suite pins each lane's `data-state`. This probe pins the other half of the original
// finding: the row's own reason, which is what a reader sees on hover - a state of `no` beside a reason
// claiming "its children work in the node checkout" would be the old lie with the state corrected.
// It also covers two shapes the suite's block does not: a child with NO session record at all, and the
// sentinel lane key `main` colliding with a child whose recorded branch is literally named `main`.
(function () {
  var notes = [], problems = [], facts = {}, phase = 'booting';
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', 'running');
  log.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:99;pointer-events:none;background:#000;color:#0f0;font:10px monospace;padding:4px;max-height:45%;overflow:auto';
  function report() {
    var failed = problems.length > 0;
    log.textContent = (failed ? 'LANE SHAPES FAIL' : 'LANE SHAPES PASS') + ' (' + notes.length + ' checks, '
      + problems.length + ' failures) phase=' + phase + (failed ? ' | FAILURES: ' + problems.join(' ;; ') : '')
      + ' || FACTS ' + JSON.stringify(facts);
  }
  function check(ok, label) { (ok ? notes : problems).push(label); report(); }
  function tick() { return Promise.resolve(); }
  function textOf(node) { return node ? String(node.textContent || '') : null; }

  (async function () {
    try {
      document.body.appendChild(log);
      phase = 'waiting for the view';
      if (window.rendererLoaded) await window.rendererLoaded;
      for (var mount = 0; mount < 60 && !document.querySelector('wa-orchestrator'); mount += 1) await tick();
      var panel = document.querySelector('wa-orchestrator');
      if (!panel) throw new Error('the orchestrator view did not mount');

      // Recorded shapes, one child each, plus one child with no session row at all.
      var plan = [
        {child: 'a', session: 's-a', branch: 'change/lane-alpha', worktree: 'C:/work/wt-alpha', state: 'allocated'},
        {child: 'b', session: 's-b', branch: 'change/lane-beta', worktree: 'C:/work/wt-beta', state: 'released'},
        {child: 'g', session: 's-g', branch: '', worktree: 'C:/work/wt-gamma', state: 'allocated'},
        {child: 'm', session: 's-m', branch: '', worktree: '', state: 'unbound'}
      ];
      var tasks = [], sessions = [];
      plan.forEach(function (entry, index) {
        tasks.push({subagent_id: 'child-' + entry.child, session_id: entry.session, profile: 'task-worker',
          model: 'fixture-model', reasoning: 'high', execution_node: 'local', state: 'running', settled: false,
          title: 'lane shape ' + entry.child, created_at: 100 + index});
        sessions.push({id: entry.session, title: 'lane ' + entry.child, state: 'unfinished', workspace_required: 1,
          workspace_branch: entry.branch, worktree: entry.worktree, workspace_state: entry.state});
      });
      // A dispatch whose session is not in the ledger produces it no lane of its own.
      tasks.push({subagent_id: 'child-orphan', session_id: 's-not-in-ledger', profile: 'task-worker',
        model: 'fixture-model', reasoning: 'high', execution_node: 'local', state: 'running', settled: false,
        title: 'lane shape orphan', created_at: 200});
      window.__fixtures.subagents = {subagents: tasks};
      window.__fixtures.sessions = {sessions: sessions};

      phase = 'reading lanes';
      for (var tries = 0; tries < 25 && panel.querySelectorAll('nav .lane').length < 5; tries += 1) {
        await window.__refreshOrchestrator();
        for (var settle = 0; settle < 20; settle += 1) await tick();
      }
      var groups = Array.prototype.slice.call(panel.querySelectorAll('nav .lane'));
      facts.lanes = groups.map(function (group) {
        return {key: group.dataset.lane,
          path: textOf(group.querySelector('.lane-path')),
          count: group.querySelectorAll('.agent-card').length,
          checklist: Array.prototype.slice.call(group.querySelectorAll('.lane-check')).map(function (item) {
            return {outcome: item.dataset.outcome, state: item.dataset.state, reason: item.title};
          })};
      });
      report();
      function laneOf(key) { return facts.lanes.filter(function (lane) { return lane.key === key; })[0]; }
      function rowOf(key, outcome) {
        var lane = laneOf(key);
        return lane ? lane.checklist.filter(function (item) { return item.outcome === outcome; })[0] : null;
      }
      var mainOnlyOf = function (key) { var row = rowOf(key, 'main-only'); return row ? row.state : 'missing'; };
      var reasonOf = function (key, outcome) { var row = rowOf(key, outcome); return row ? String(row.reason || '') : ''; };

      check(!!laneOf('change/lane-alpha') && !!laneOf('change/lane-beta') && !!laneOf('C:/work/wt-gamma')
        && !!laneOf('main'),
        'the four recorded shapes must produce four lane keys, saw '
        + JSON.stringify(facts.lanes.map(function (lane) { return lane.key + ':' + lane.count; })));
      check(mainOnlyOf('C:/work/wt-gamma') === 'no',
        'a lane holding a worktree and no branch name must not be main-only, saw ' + mainOnlyOf('C:/work/wt-gamma'));
      check(mainOnlyOf('main') === 'yes' && mainOnlyOf('change/lane-alpha') === 'no'
        && mainOnlyOf('change/lane-beta') === 'no',
        'main-only must be measured from the same facts as the key, saw alpha=' + mainOnlyOf('change/lane-alpha')
        + ' beta=' + mainOnlyOf('change/lane-beta') + ' main=' + mainOnlyOf('main'));
      check(rowOf('change/lane-beta', 'retired') && rowOf('change/lane-beta', 'retired').state === 'yes'
        && rowOf('change/lane-alpha', 'retired').state === 'no',
        'retired must be measured from the recorded workspace state, saw beta='
        + reasonOf('change/lane-beta', 'retired') + ' alpha=' + reasonOf('change/lane-alpha', 'retired'));

      // The reason, not just the state: a `no` must name the checkout the lane actually holds, and a
      // `yes` must say the children are in the node's own checkout.
      var checkoutLanes = ['change/lane-alpha', 'change/lane-beta', 'C:/work/wt-gamma'];
      check(checkoutLanes.every(function (key) {
        var lane = laneOf(key);
        var reason = reasonOf(key, 'main-only');
        // The code names the checkout it holds as `branch || worktree`: either identifier is honest, as
        // long as the reason names one of the two the lane actually carries.
        return reason.indexOf(key) >= 0 || (!!lane.path && reason.indexOf(lane.path) >= 0);
      }), 'a lane with a checkout of its own must name that checkout in its main-only reason, saw '
        + JSON.stringify(checkoutLanes.map(function (key) { return [key, laneOf(key).path, reasonOf(key, 'main-only')]; })));
      check(/node checkout/.test(reasonOf('main', 'main-only'))
        && !/(holds a checkout of its own)/.test(reasonOf('main', 'main-only')),
        'the node-checkout lane must say so and must not claim a checkout of its own, saw '
        + JSON.stringify(reasonOf('main', 'main-only')));

      // A child the ledger has no row for has no recorded checkout to be grouped by.
      var orphan = laneOf('no recorded checkout');
      check(!!orphan && orphan.count === 1 && orphan.checklist.length === 4
        && orphan.checklist.every(function (item) { return item.state === 'unknown'; }),
        'a child with no session record must be in its own lane with four unknown outcomes, saw '
        + JSON.stringify(orphan));

      // Reported, not asserted: a recorded branch literally named `main` shares the sentinel key the
      // view uses for "no checkout at all" (MAIN_LANE = 'main'). Added after the four clean shapes have
      // been read, because it contaminates the `main` lane by design. No code path I can read writes
      // `workspace_branch='main'` (the allocator writes `change/wa-session-<id>`), so this is a hazard
      // demonstration, not a reachable record.
      phase = 'sentinel collision';
      window.__fixtures.subagents = {subagents: tasks.concat([{subagent_id: 'child-c', session_id: 's-c',
        profile: 'task-worker', model: 'fixture-model', reasoning: 'high', execution_node: 'local',
        state: 'running', settled: false, title: 'lane shape c', created_at: 300}])};
      window.__fixtures.sessions = {sessions: sessions.concat([{id: 's-c', title: 'lane c', state: 'unfinished',
        workspace_required: 1, workspace_branch: 'main', worktree: 'C:/work/wt-sentinel', workspace_state: 'allocated'}])};
      for (var collide = 0; collide < 12; collide += 1) {
        await window.__refreshOrchestrator();
        for (var settle5 = 0; settle5 < 20; settle5 += 1) await tick();
      }
      var collided = Array.prototype.slice.call(panel.querySelectorAll('nav .lane')).map(function (group) {
        return {key: group.dataset.lane, path: textOf(group.querySelector('.lane-path')),
          count: group.querySelectorAll('.agent-card').length,
          mainOnly: (group.querySelector('.lane-check[data-outcome="main-only"]') || {}).dataset
            ? group.querySelector('.lane-check[data-outcome="main-only"]').dataset.state : 'missing',
          reason: (group.querySelector('.lane-check[data-outcome="main-only"]') || {}).title || ''};
      });
      facts.sentinelCollision = {lanes: collided,
        merged: (collided.filter(function (lane) { return lane.key === 'main'; })[0] || {}).count > 1};
      phase = 'done';
      log.setAttribute('data-status', problems.length ? 'fail' : 'pass');
      report();
    } catch (error) {
      problems.push('the probe threw: ' + ((error && error.stack) || error));
      phase = 'threw';
      log.setAttribute('data-status', 'fail');
      report();
    }
  })();
})();
