// Does a tool row say which file it touched, and what it changed?
//
// The request behind this probe: a person watching a run has to be able to follow what is being created
// as it happens. Two things were missing - the file's path was only ever inside the tool's payload (and
// for a batch call it was not visible at all), and an `edit` never showed which lines it removed versus
// added. This drives the real page through the real event path (`handleEvent`, the same one a live stream
// and a ledger repaint both use) and asserts the DOM: the path on the row, `-`/`+` marked distinctly by
// class and by colour, a huge change bounded and said to be bounded, a non-file tool left alone, and the
// child pane identical to the main one.
(function () {
  const report = document.createElement('pre');
  report.id = 'wa-probe';
  report.hidden = true;
  document.body.append(report);
  let checks = 0;
  const check = (ok, label) => { if (!ok) throw Error(label); checks++; };
  const rowsOf = (root, selector) => Array.from(root.querySelectorAll(selector));
  const rowFor = (root, callId) => rowsOf(root, 'wa-trace .tool-line').find((line) => line.dataset.callId === callId);
  const rowAbout = (root, text) => rowsOf(root, 'wa-trace .tool-line').find((line) => line.textContent.includes(text));
  const full = 'C:/Users/Victor/orca/projects/wasm-agent/ui/components.js';
  const style = (node, key) => getComputedStyle(node)[key];

  (async function () {
    try {
      await rendererLoaded;
      for (let i = 0; i < 200 && !transcriptReady; i++) await new Promise((r) => setTimeout(r, 10));
      check(transcriptReady, 'startup');
      for (let i = 1; i < 10000; i++) { clearTimeout(i); clearInterval(i); }
      document.getElementById('panel').style.width = '640px';
      busy = false; observedRun = null; clearStatus();
      transcript.replaceChildren(); runBubble = null; runStepState = null; runCounts = null;

      const call = (id, name, args) => handleEvent({ type: 'tool', call_id: id, name, arguments: args });
      const settle = (name, value, failed) => handleEvent({ type: 'tool_result', name, result: value, failed });

      // ---- an edit: the path on the row, and a real before/after -------------------------------
      call('call-edit', 'edit', {
        path: full,
        old_text: 'const one = 1;\nconst two = 2;',
        new_text: 'const one = 1;\nconst two = 3;\nconst three = 4;',
      });
      settle('edit', { ok: true, path: full, applied: true, edits: 1 });

      const edit = rowFor(transcript, 'call-edit');
      check(!!edit, 'the edit row exists on the one main renderer');
      check(edit.classList.contains('ok'), 'an applied edit is a settled ok row');
      check(edit.textContent.includes('components.js'), 'the file path is on the tool row itself, not only in the payload');
      check(edit.title.includes(full), 'the full path is the row hover metadata');
      check(edit.querySelector('.tool-output').textContent.includes(full), 'and the result payload still carries it');
      const adds = rowsOf(edit, '.tool-diff .patch-add');
      const dels = rowsOf(edit, '.tool-diff .patch-del');
      check(adds.length === 2 && dels.length === 1, 'the edit draws the two lines it wrote and the one it removed, saw ' + adds.length + '/' + dels.length);
      check(adds.every((node) => node.textContent.startsWith('+')), 'every addition carries its + sign in the text');
      check(dels.every((node) => node.textContent.startsWith('-')), 'every removal carries its - sign in the text');
      check(adds.map((node) => node.textContent).join('|') === '+const two = 3;|+const three = 4;' &&
        dels[0].textContent === '-const two = 2;',
        'and it marks the lines that actually changed, not the whole block');
      check(!edit.textContent.includes('-const one = 1;'), 'a line the edit kept is on neither side');
      check(rowsOf(edit, '.tool-diff .patch-hunk').length === 1, 'the change is framed by its hunk header');
      check(style(adds[0], 'color') !== style(dels[0], 'color'), 'additions and removals are marked distinctly, not just signed');
      check(style(adds[0], 'color') === 'rgb(126, 224, 138)', 'additions take the patch-add token, saw ' + style(adds[0], 'color'));
      check(style(dels[0], 'color') === 'rgb(255, 138, 138)', 'removals take the patch-del token, saw ' + style(dels[0], 'color'));
      check(getComputedStyle(document.documentElement).getPropertyValue('--diff-add').trim() === '#7ee08a' &&
        getComputedStyle(document.documentElement).getPropertyValue('--diff-del').trim() === '#ff8a8a',
        'both colours come from the one token pair in style.css');

      // ---- a write names its file, without repeating it -----------------------------------------
      call('call-write', 'write', { path: 'ui/new-file.js', content: 'first line\nsecond line' });
      settle('write', { ok: true, path: 'C:/Users/Victor/orca/projects/wasm-agent/ui/new-file.js' });
      const write = rowFor(transcript, 'call-write');
      check(!!write && write.textContent.includes('new-file.js'), 'a write names its file on the row');
      check(!write.querySelector('.tool-path'), 'and does not say the same file twice');
      check(write.title.includes('C:/Users/Victor/orca/projects/wasm-agent/ui/new-file.js'),
        'the resolved full path is on the row hover metadata');
      check(rowsOf(write, '.tool-diff .patch-add').length === 2 && rowsOf(write, '.tool-diff .patch-del').length === 0,
        'a write shows the lines it wrote as additions');
      check(rowsOf(write, '.tool-diff .patch-note').some((note) => note.textContent.includes('a write carries only the new lines')),
        'and says that a write does not carry the previous lines');

      // ---- a path only the result knows: the row shows it ---------------------------------------
      call('call-export', 'spell_export', { name: 'nightly' });
      settle('spell_export', { ok: true, path: 'C:/Users/Victor/orca/ephemeral/spells/nightly-plan.json' });
      const exported = rowFor(transcript, 'call-export');
      const chip = exported.querySelector('.tool-path');
      check(!!chip, 'a path only the result reports is shown on the row');
      check(chip.textContent.includes('nightly-plan.json'), 'and identifies the file');
      check(chip.textContent.startsWith('…/') && chip.textContent.length <= 34,
        'the row shows the elided tail, not the whole absolute path, saw ' + chip.textContent);
      check(!chip.textContent.includes('C:/Users'), 'so a full path cannot push the row off a narrow window');
      check(chip.title.includes('C:/Users/Victor/orca/ephemeral/spells/nightly-plan.json'), 'the full path is the element tooltip');
      check(chip.getAttribute('aria-label').includes('C:/Users/Victor/orca/ephemeral/spells/nightly-plan.json'),
        'and its accessibility label');

      // ---- a batch: the file names of the whole batch, from the result ---------------------------
      call('call-many', 'write_many', { requests: [
        { path: 'ui/a.js', content: 'a' },
        { path: 'ui/b.js', content: 'b' },
        { path: 'ui/c.js', content: 'c' },
      ] });
      settle('write_many', { ok: true, applied: 3, results: [
        { ok: true, path: 'C:/Users/Victor/orca/projects/wasm-agent/ui/a.js' },
        { ok: true, path: 'C:/Users/Victor/orca/projects/wasm-agent/ui/b.js' },
        { ok: true, path: 'C:/Users/Victor/orca/projects/wasm-agent/ui/c.js' },
      ] });
      const many = rowFor(transcript, 'call-many');
      check(many.textContent.includes('a.js +2'), 'a batch row names its first file and how many others went with it');
      check(rowsOf(many, '.tool-diff .patch-hunk').length === 3, 'and draws one section per file');
      check(many.title.includes('a.js') && many.title.includes('b.js') && many.title.includes('c.js'),
        'every full path of the batch is on the row hover metadata');
      const manyChip = many.querySelector('.tool-path');
      check(!!manyChip && manyChip.textContent === '…/ui/b.js · …/ui/c.js',
        'the rest of the batch is named on the row, elided to the project convention, saw ' + (manyChip ? manyChip.textContent : 'nothing'));
      check(!manyChip.textContent.includes('C:/Users') && !many.querySelector('.tool-head').textContent.includes('C:/Users'),
        'no absolute path is drawn on the row, so it cannot push the outcome off a narrow line');
      check(many.querySelector('.tool-title').getClientRects().length === 1,
        'and the row still lays out on one line with the path chip beside the title');

      // ---- the window is often narrow (measured 430px): the row must not push the outcome off it ----
      // One row whose own title is longer than the window (a deep first path, elided only to its last two
      // segments) and one whose paths come from the result: neither may overflow the line.
      const longPath = 'src/a-very-long-subdirectory-name-here/a-very-long-file-name-that-is-unbreakable.js';
      call('call-long', 'write_many', { requests: [
        { path: longPath, content: 'a' }, { path: 'ui/a.js', content: 'b' }, { path: 'ui/b.js', content: 'c' },
      ] });
      settle('write_many', { ok: true, applied: 3, results: [
        { ok: true, path: 'C:/Users/Victor/orca/projects/wasm-agent/' + longPath },
        { ok: true, path: 'C:/Users/Victor/orca/projects/wasm-agent/ui/a.js' },
        { ok: true, path: 'C:/Users/Victor/orca/projects/wasm-agent/ui/b.js' },
      ] });
      const longRow = rowFor(transcript, 'call-long');
      check(!!longRow && !!longRow.querySelector('.tool-path'), 'a long-tailed batch still names its files on the row');
      const panel = document.getElementById('panel');
      const wide = panel.style.width;
      panel.style.width = '430px';
      for (const [label, row] of [['the batch row', many], ['the long-title row', longRow]]) {
        const head = row.querySelector('.tool-head');
        check(head.scrollWidth <= head.clientWidth + 1,
          label + ' must not overflow its line at 430px, saw ' + head.scrollWidth + ' of ' + head.clientWidth);
        const outcome = row.querySelector('.tool-outcome');
        check(outcome.getBoundingClientRect().right <= head.getBoundingClientRect().right + 1,
          label + ' must keep its outcome on the row at 430px');
        check(row.getBoundingClientRect().right <= panel.getBoundingClientRect().right + 1,
          label + ' must fit inside a 430px window');
      }
      check(longRow.querySelector('.tool-title').getClientRects().length > 1 ||
        longRow.querySelector('.tool-title').getBoundingClientRect().width <= 430,
        'a title too long for the row wraps inside it instead of pushing the outcome off');
      panel.style.width = wide;

      // ---- a big change is bounded, and says so --------------------------------------------------
      const big = Array.from({ length: 100 }, (unused, index) => 'line ' + index).join('\n');
      call('call-big', 'write_many', { requests: [{ path: 'ui/big.js', content: big }] });
      settle('write_many', { ok: true, applied: 1, results: [{ ok: true, path: 'C:/Users/Victor/orca/projects/wasm-agent/ui/big.js' }] });
      const huge = rowFor(transcript, 'call-big');
      const drawn = rowsOf(huge, '.tool-diff .patch-line');
      const cap = toolChange('write_many', { requests: [{ path: 'x', content: big }] });
      check(cap.lines.length === 40, 'the inline cap is 40 lines, saw ' + cap.lines.length);
      check(drawn.length === 40, 'a 101-line change draws exactly the cap, saw ' + drawn.length);
      const cut = rowsOf(huge, '.tool-diff .patch-note').find((note) => note.textContent.includes('more line'));
      check(!!cut, 'and a truncated change says it was truncated');
      check(cut.textContent.includes('61 more lines'), 'with the number left out, saw ' + (cut ? cut.textContent : 'nothing'));
      check(cut.textContent.includes('the full change is in the change topic under the answer'),
        'and where the whole change can be read');

      // ---- a refused change is not drawn as a change ---------------------------------------------
      call('call-refused', 'edit', { path: full, old_text: 'not in the file', new_text: 'x' });
      settle('edit', { error: 'old_text_not_found', path: full }, true);
      const refused = rowFor(transcript, 'call-refused');
      check(refused.classList.contains('err'), 'a refused edit is an error row');
      check(!refused.querySelector('.tool-diff'), 'and draws no change it did not make');
      check(refused.textContent.includes('components.js'), 'but still names the file the reader has to look at');

      // ---- a tool that touches no file is exactly as it was --------------------------------------
      call('call-bash', 'bash', { command: 'ls -la' });
      settle('bash', { code: 0, stdout: 'total 0' });
      const shell = rowFor(transcript, 'call-bash');
      check(!shell.querySelector('.tool-diff') && !shell.querySelector('.tool-path'),
        'a shell call draws neither a path nor a change');
      check(!shell.hasAttribute('title'), 'and gains no hover metadata it has no paths for');
      check(shell.querySelector('.tool-title').textContent === 'bash $ ls -la', 'its title is unchanged');

      // ---- the child pane is the same renderer, not a second one ---------------------------------
      const childRows = [
        { seq: 1, id: 'child-user', role: 'user', content: 'change the file', created_at: Date.now() / 1000 },
        { seq: 2, id: 'child-call', role: 'assistant', content: '', created_at: Date.now() / 1000,
          tool_calls: [{ id: 'child-edit', function: { name: 'edit', arguments: JSON.stringify({
            path: full, old_text: 'const one = 1;\nconst two = 2;', new_text: 'const one = 1;\nconst two = 3;\nconst three = 4;' }) } }] },
        { seq: 3, role: 'tool', tool_name: 'edit', tool_call_id: 'child-edit',
          content: JSON.stringify({ ok: true, path: full, applied: true }), ok: 1, created_at: Date.now() / 1000 },
      ];
      const host = document.createElement('wa-orchestrator');
      document.body.append(host);
      const pane = host.pin({ subagent_id: 'probe-child', attempt_id: 'probe-attempt', session_id: 'probe-child',
        profile: 'orchestration-worker', model: 'fixture-model', state: 'running', settled: false,
        started_at: Date.now() / 1000 });
      pane.style.height = '500px';
      paintChildTranscript(pane.transcript, childRows, { task: pane.task, active: false, events: [], identity: { attempt_id: 'probe-attempt' }, notify: false });
      const childEdit = rowFor(pane.transcript, 'child-edit');
      check(!!childEdit, 'the child pane draws the same edit row');
      check(childEdit.textContent.includes('components.js'), 'with the path on the row');
      check(rowsOf(childEdit, '.tool-diff .patch-add').length === 2 && rowsOf(childEdit, '.tool-diff .patch-del').length === 1,
        'and the same additions and removals');      check(rowsOf(childEdit, '.tool-diff .patch-add')[0].className === rowsOf(edit, '.tool-diff .patch-add')[0].className,
        'marked by the same classes as main');
      check(style(rowsOf(childEdit, '.tool-diff .patch-add')[0], 'color') === style(adds[0], 'color') &&
        style(rowsOf(childEdit, '.tool-diff .patch-del')[0], 'color') === style(dels[0], 'color'),
        'and painted in the same colours as main');

      // Leave the evidence on the screen for the screenshot: the rows, with their paths and changes. The
      // 40-line capped row has made its point above and would push every other row out of the frame, and
      // the child's folded run has to be opened to show that its row is the same row.
      huge.remove();
      const childTopic = pane.transcript.querySelector('wa-run');
      if (childTopic) childTopic.open = true;
      const childTrace = pane.transcript.querySelector('wa-trace');
      if (childTrace) childTrace.open = true;
      pane.style.height = '560px';
      document.getElementById('panel').style.width = '640px';
      follow = false;
      transcript.scrollTop = 0;
      report.dataset.status = 'pass';
      report.textContent = JSON.stringify({ checks, skipped: 0 });
    } catch (error) {
      report.dataset.status = 'fail';
      report.textContent = String(error.stack || error);
    }
  })();
})();
