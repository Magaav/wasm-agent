// Live Children: three stable lines per card, the run footer's own stats renderer, and a header
// that names the node first.
//
// WHY A CONTROL. Twice now the same picture has been drawn by a second renderer that merely looked
// right: the assertions passed and the real footer kept its own idea of the glyphs. So the card's
// third line is not compared with a string this probe wrote down - it is compared with the
// PRODUCTION footer renderer (`runCountsFooter`, the line under a finished answer) fed the SAME stat
// set. If those two ever disagree, the card has grown a second stats renderer. The two cards are
// compared with each other through `waProbeSameAs` for the part that must not differ at all.
(async () => {
  const report = document.createElement('pre');
  report.id = 'wa-probe'; report.hidden = true; document.body.append(report);
  let checks = 0;
  const check = (ok, label) => { if (!ok) throw Error(label); checks++; };
  try {
    await rendererLoaded;
    for (let i = 0; i < 200; i++) await Promise.resolve();
    check(typeof waProbeSameAs === 'function' && typeof waProbeDiff === 'function',
      'the shared control-comparison support is injected before this probe');

    // One child's run, with a known stat set. The numbers are the shape the node actually reports
    // (`run_counts`): model/tool calls, a measured context growth, and the run's own elapsed time.
    const nowSeconds = Date.now() / 1000;
    const counts = { version: 1, run_id: 'probe-run', model_calls: 24, tool_calls: 38, elapsed_ms: 138000,
      started_at: nowSeconds - 10,
      context_growth: { version: 1, known: true, added: 62600, baseline: 1000, current: 63600,
        partial: true, pending: false, complete: false } };
    const fleet = { nodes: [{ id: 'n-local', node_id: 'n-local', name: 'wasm_the_first', kind: 'host',
      local_node: true, online: true }] };
    const health = { subagents: { running: 2, queued: 0, active: 2 } };
    const dispatches = [
      { subagent_id: 'child-stats', session_id: 'session-stats', parent_session_id: 'parent-1',
        profile: 'explore', execution_node: 'local', title: 'a resumed task that is long enough to be clipped by the card width',
        state: 'running', settled: false, started_at: nowSeconds - 10 },
      { subagent_id: 'child-bare', session_id: 'session-bare', parent_session_id: 'parent-1',
        profile: 'explore', execution_node: 'local', title: 'a second child whose run counts nobody measured',
        state: 'running', settled: false, started_at: nowSeconds - 10 }];

    // --- the CONTROL: the footer renderer, over the same stat set -------------------------------
    const savedCounts = runCounts, savedReplaying = replayingMessages;
    runCounts = counts; replayingMessages = false;
    let controlStats = null;
    try { controlStats = runCountsFooter('2:18'); }
    finally { runCounts = savedCounts; replayingMessages = savedReplaying; }
    check(controlStats === '◈ ~62.6k · ✧ 24 · ⚒ 38 · ◷ 2:18',
      'control (the answer footer over this stat set) reads: ' + controlStats);

    // --- the cards, through the host builder the panel is actually fed by ------------------------
    const built = liveChildRows({ sessions: [], dispatches, fleet, health,
      runs: { 'session-stats': counts } });
    check(built.rows.length === 2, 'two live rows built, saw ' + built.rows.length);
    const panel = document.createElement('wa-orchestrator');
    panel.style.width = '240px';
    document.body.append(panel);
    panel.live = built;

    const card = id => Array.from(panel.querySelectorAll('.live-child'))
      .find(node => node.dataset.session === id);
    const stats = card('session-stats').querySelector('.live-child-stats');
    const bare = card('session-bare').querySelector('.live-child-stats');

    // 1. THREE lines, in this order, and nothing else.
    const lines = node => Array.from(node.children).map(child => child.className).join('|');
    check(lines(card('session-stats')) === 'live-child-head|live-child-title|live-child-stats',
      'a card is exactly three lines, saw: ' + lines(card('session-stats')));
    check(lines(card('session-bare')) === 'live-child-head|live-child-title|live-child-stats',
      'and so is a card whose statistics are partly unknown, saw: ' + lines(card('session-bare')));
    check(card('session-stats').querySelector('.live-child-state').textContent === 'running' &&
      card('session-stats').querySelector('.live-child-node').textContent === 'wasm_the_first',
      'line 1 is `<status> <node>`, saw: ' + card('session-stats').querySelector('.live-child-head').textContent);

    // 2. Line 3 IS the footer renderer's line, with `✺ elapsed` in front.
    check(stats.textContent === '✺ 10s · ' + controlStats,
      'the card stats line must be the footer stats line plus elapsed, saw: ' + stats.textContent);

    // 3. An absent statistic is omitted - glyph and all. `session-bare` has no run counts at all.
    check(!bare.textContent.includes('◈'), 'a card with no measured tokens must show NO ◈, saw: ' + bare.textContent);
    check(!bare.textContent.includes('✧') && !bare.textContent.includes('⚒') && !bare.textContent.includes('◷'),
      'and no model/tool/duration pair either, saw: ' + bare.textContent);
    check(bare.textContent === '✺ 10s', 'the one fact it does have is stated, saw: ' + bare.textContent);
    check(!/\b0\b/.test(stats.textContent.replace('✺ 10s', '')),
      'no absent statistic is printed as 0, saw: ' + stats.textContent);

    // 4. STABLE HEIGHT: the card with five statistics and the card with one are the same height, and
    //    so is a row with no resumed task at all. Measured, not assumed.
    const height = node => Math.round(node.getBoundingClientRect().height * 100) / 100;
    check(height(card('session-stats')) > 0, 'the card has a measured height: ' + height(card('session-stats')));
    check(height(card('session-stats')) === height(card('session-bare')),
      'a card keeps its height when statistics are missing: ' + height(card('session-stats'))
        + ' vs ' + height(card('session-bare')));
    // A row with no resumed task: the update a run's end makes, where the title is gone but the line
    // must stay. Drawn through the panel contract, because no builder in this tree invents a title.
    panel.live = { rows: [built.rows[0], { ...built.rows[1], title: '', stats: '' }],
      counts: built.counts, note: built.note };
    const emptyTitle = card('session-bare').querySelector('.live-child-title');
    check(emptyTitle.textContent.trim() === '',
      'the no-task row has no visible task text, saw: ' + JSON.stringify(emptyTitle.textContent));
    check(Math.round(emptyTitle.getBoundingClientRect().height) ===
      Math.round(card('session-stats').querySelector('.live-child-title').getBoundingClientRect().height),
      'the resumed-task line keeps its height when there is no resumed task: '
        + emptyTitle.getBoundingClientRect().height + ' vs '
        + card('session-stats').querySelector('.live-child-title').getBoundingClientRect().height);
    check(height(card('session-bare')) === height(card('session-stats')),
      'and the whole card is still the same height: ' + height(card('session-bare'))
        + ' vs ' + height(card('session-stats')));

    // 5. STRUCTURE, by control comparison: with and without a task, with and without statistics, a
    //    card is the same shape. Only its text differs - including the `title`/`aria-label` that carry
    //    that text for a reader - which is why those are ignored here and asserted on their own
    //    elsewhere in this probe.
    const same = waProbeSameAs(card('session-stats'), card('session-bare'),
      { ignore: ['style', 'id', 'title', 'aria-label', 'data-session', 'data-subagent'] });
    check(same.equal, 'two cards differ only in their text: ' + waProbeDiff(same));

    // 6. The header line, verbatim: name first, then icon+count pairs the vocabulary already has.
    panel.live = built;
    const header = panel.querySelector('.live-children-counts');
    check(header.textContent === 'wasm_the_first · ◷ 0 queued · ⚒ 2 · ✺ 2',
      'the header must read `wasm_the_first · ◷ 0 queued · ⚒ 2 · ✺ 2`, saw: '
        + JSON.stringify(header.textContent));

    // 7. Each pair says the same words in `title` and in `aria-label` - a title alone is invisible to
    //    the keyboard and to a screen reader.
    const words = { queued: 'queued: waiting for a free slot', running: 'running: executing now',
      active: 'active: live children with a session' };
    for (const key of Object.keys(words)) {
      const pair = header.querySelector('[data-count="' + key + '"]');
      check(!!pair, 'the header carries a ' + key + ' pair, saw: ' + header.innerHTML.slice(0, 200));
      check(pair.title === words[key] && pair.getAttribute('aria-label') === words[key],
        'the ' + key + ' pair must say ' + JSON.stringify(words[key]) + ' in both title and aria-label, saw '
          + JSON.stringify({ title: pair.title, label: pair.getAttribute('aria-label') }));
    }
    check(!Array.from(header.querySelectorAll('[data-count]')).some(pair => pair.title === ''),
      'every pair carries a title, not just the first');

    // 8. The removed notice is gone from this panel - and only from here. `History remains in
    //    Engine → Sessions` is the main canvas's own sentence and must survive.
    const foot = panel.querySelector('.live-children-foot').textContent;
    check(!/not reachable from here/.test(foot), 'the reachability notice is removed from the live panel, saw: ' + foot);
    check(!/unfinished alone is not active/.test(foot), 'and its second sentence with it, saw: ' + foot);
    check(!panel.textContent.includes('unfinished alone is not active'),
      'that sentence must not be drawn anywhere in this panel');
    check(panel.querySelector('.orchestrator-empty').textContent
      .includes('History remains in Engine → Sessions'),
      'the canvas keeps its own sentence about history');

    for (let t = 1; t < 10000; t++) { clearTimeout(t); clearInterval(t); }
    report.dataset.status = 'pass';
    report.textContent = JSON.stringify({ checks, skipped: 0 });
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = String(error.stack || error);
  }
})();
