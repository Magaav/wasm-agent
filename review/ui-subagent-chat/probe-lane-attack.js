// Claim 5, attacked: is `main-only` measured from the child's record, or invented?
//
// The lane key is `workspace_branch || worktree || 'main'` and the checklist derives
// `main-only` from `lane.branch` alone. A session record whose checkout is its own worktree but
// whose recorded branch is empty therefore lands in a lane keyed by that worktree (whose header
// draws the worktree path) while its checklist claims "this lane holds no branch of its own: its
// children work in the node checkout". This probe asserts the corrected rule: a lane that displays a
// recorded worktree of its own must not be reported as main-only.
(function () {
  var notes = [], problems = [], facts = {}, phase = 'booting';
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', 'running');
  log.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:99;pointer-events:none;background:#000;color:#0f0;font:10px monospace;padding:4px;max-height:45%;overflow:auto';
  function report() {
    var failed = problems.length > 0;
    log.textContent = (failed ? 'ATTACK PROBE FAIL' : 'ATTACK PROBE PASS') + ' (' + notes.length + ' checks, '
      + problems.length + ' failures) phase=' + phase + (failed ? ' | FAILURES: ' + problems.join(' ;; ') : '')
      + ' || FACTS ' + JSON.stringify(facts);
  }
  function check(ok, label) { (ok ? notes : problems).push(label); report(); }
  function tick() { return Promise.resolve(); }

  (async function () {
    try {
      document.body.appendChild(log);
      phase = 'waiting for the view';
      if (window.rendererLoaded) await window.rendererLoaded;
      for (var mount = 0; mount < 60 && !document.querySelector('wa-orchestrator'); mount += 1) await tick();
      var panel = document.querySelector('wa-orchestrator');
      if (!panel) throw new Error('the orchestrator view did not mount');

      // One child, one session: a recorded checkout of its own, and no recorded branch name.
      // `sessions.workspace_branch` is TEXT NOT NULL DEFAULT '' (memory.lua), and workspaces.lua's
      // verify_binding treats an empty recorded branch as a value to replace, not an error.
      window.__fixtures.subagents = {subagents: [{subagent_id: 'child-x', session_id: 'child-session-x',
        parent_session_id: 'parent-fixture', profile: 'task-worker', execution_node: 'local',
        title: 'worktree-without-branch', prompt: 'p', state: 'running', settled: false,
        model: 'fixture-model', reasoning: 'high', created_at: 101}]};
      window.__fixtures.sessions = {sessions: [{id: 'child-session-x', title: 'child session x',
        state: 'unfinished', workspace_required: 1, workspace_branch: '', worktree: 'C:/work/wt-gamma',
        workspace_state: 'allocated'}]};

      phase = 'reading the lane';
      for (var tries = 0; tries < 25 && panel.querySelectorAll('nav .lane').length < 1; tries += 1) {
        await window.__refreshOrchestrator();
        for (var settle = 0; settle < 20; settle += 1) await tick();
      }
      var groups = Array.prototype.slice.call(panel.querySelectorAll('nav .lane'));
      facts.lanes = groups.map(function (group) {
        return {key: group.dataset.lane,
          path: group.querySelector('.lane-path') ? group.querySelector('.lane-path').textContent : null,
          checklist: Array.prototype.slice.call(group.querySelectorAll('.lane-check')).map(function (item) {
            return {outcome: item.dataset.outcome, state: item.dataset.state, reason: item.title};
          })};
      });
      report();
      var guide = facts.lanes[0] || {checklist: [], path: null};
      var mainOnly = (guide.checklist.filter(function (item) { return item.outcome === 'main-only'; })[0] || {}).state;
      var other = (guide.checklist.filter(function (item) { return item.outcome === 'retired'; })[0] || {}).state;
      check(facts.lanes.length === 1 && guide.key === 'C:/work/wt-gamma',
        'the lane key must be the recorded checkout, saw ' + JSON.stringify(facts.lanes.map(function (lane) { return lane.key; })));
      check(!!guide.path,
        'a lane with a recorded worktree must show it, saw ' + JSON.stringify(guide.path));
      check(mainOnly !== 'yes',
        'a lane whose children recorded their OWN worktree must not be called main-only (its children do not '
        + 'work in the node checkout), saw main-only=' + mainOnly + ' with the reason '
        + JSON.stringify((guide.checklist.filter(function (item) { return item.outcome === 'main-only'; })[0] || {}).reason)
        + ' beside the lane path ' + JSON.stringify(guide.path));
      facts.observed = {mainOnly: mainOnly, retired: other};
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
