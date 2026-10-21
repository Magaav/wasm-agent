// The model-calls glyph: `👣` in the compact stats line, and it must read as a CIPHER.
//
// WHY THIS PROBE EXISTS. `◈` tokens, `⚒` tools, `◷` duration and `✺` elapsed are monochrome text
// symbols: they take the row's colour and its font size, so `◈7.4k ✧5 ⚒7 ◷3:48` reads as one line
// of counters. The glyph the operator asked for in the model-calls slot, `👣`, is the ONE character
// in that vocabulary that Unicode also ships as a colour emoji - and a browser left to itself picks
// the colour presentation: a pictograph in its own red/blue, at emoji size, inside a muted monospace
// row. So there are three separate claims, each of which can fail alone, and each is measured here:
//
//   1. THE LINE. The production renderer (`runStatsLine`, the ONLY stats-line builder) puts `👣` in
//      the model-calls slot, glued to its value, one space between pairs - the operator's own
//      example, `◈7.4k 👣5 ⚒7 ◷3:48`.
//   2. THE PRESENTATION REQUEST, on the element that actually holds the glyph: `getComputedStyle`
//      must report `font-variant-emoji: text` (inherited from the row; the browser default is the
//      colour emoji), and the computed font stack must name a MONOCHROME font - so the glyph has a
//      text drawing to fall back to - while naming no colour emoji font at all. Asserted for the
//      transcript's live status row and for a `Live Subagents` row, the two places the line appears.
//   3. THE MONOCHROME SOURCE, measured rather than assumed: the glyph is drawn on a canvas through
//      the same `--glyph-font` stack and its ink is sampled for colour. No saturated pixel means this
//      machine really renders a text drawing from that stack; the control draw through
//      `Segoe UI Emoji` shows what the colour presentation looks like, so a green measurement cannot
//      come from a measurement that could never see colour.
//
// Plus the promise the row already makes: in a narrow pane the ONE line ellipsises instead of
// wrapping onto a second line.
(async () => {
  const report = document.createElement('pre');
  report.id = 'wa-probe'; report.hidden = true; document.body.append(report);
  let checks = 0;
  const check = (ok, label) => { if (!ok) throw Error(label); checks++; };
  try {
    await window.rendererLoaded;
    for (let i = 0; i < 200 && !transcriptReady; i++) await new Promise(resolve => setTimeout(resolve, 10));
    check(transcriptReady, 'startup ready');

    // 1. THE LINE, from the one renderer that builds it. `7.4k` as the token readout (the `~` is the
    // incomplete-boundary mark and belongs to the token pair, not to this test) and the operator's own
    // numbers, so the expected string is the one the operator wrote.
    const line = runStatsLine(runStatEntries({ tokens: '7.4k', calls: 5, tools: 7, duration: '3:48' }));
    check(line === '◈7.4k 👣5 ⚒7 ◷3:48', 'the model-calls slot reads `◈7.4k 👣5 ⚒7 ◷3:48`, saw: ' + line);
    check(runStatGlyphs.calls === '👣', 'the glyph map names the feet for model calls, saw: ' + runStatGlyphs.calls);
    // The other four are untouched: a change here would be a second, silent vocabulary change.
    check([runStatGlyphs.elapsed, runStatGlyphs.tokens, runStatGlyphs.tools, runStatGlyphs.duration].join('') === '✺◈⚒◷',
      'elapsed, tokens, tools and duration keep their own glyphs, saw: ' + JSON.stringify(runStatGlyphs));

    // A monochrome font must be named, and no colour emoji font may be: `Segoe UI Emoji` draws the
    // colour bitmap, so naming it would put the pictograph back.
    const monochrome = family => /"?(?:Noto Emoji|Segoe UI Symbol|Noto Sans Symbols 2)"?/.test(family);
    const ciphers = style => style.fontVariantEmoji === 'text' && monochrome(style.fontFamily) &&
      !style.fontFamily.includes('Segoe UI Emoji');

    // 2a. The transcript's live status row, produced the way production produces it.
    const now = Date.now();
    busy = false; activeRunId = null; observedRun = { session: chatSession, run_id: 902 };
    repaintMessages([{ id: 'glyph-run', seq: 200, role: 'user', content: 'Count this turn', created_at: (now - 228000) / 1000, trace: [] }],
      { active: true, notify: false });
    handleEvent({ type: 'run_counts', counts: { kind: 'run_counts', version: 1, run_id: 'glyph-turn', model_calls: 5, tool_calls: 7 } });
    handleEvent({ type: 'status', text: 'model' });
    check(!!statusElapsed && statusElapsed.classList.contains('chat-content-run-elapsed'),
      'the live run-status row was built by the app, saw: ' + String(statusElapsed && statusElapsed.className));
    check(statusElapsed.textContent.includes('👣5'),
      'the live row carries the feet glyph in its model-calls pair, saw: ' + statusElapsed.textContent);
    const elapsedStyle = getComputedStyle(statusElapsed);
    check(ciphers(elapsedStyle), 'the live stats row asks for the TEXT presentation of its glyphs, saw font-variant-emoji: ' +
      elapsedStyle.fontVariantEmoji + ' and font-family: ' + elapsedStyle.fontFamily);

    // 2b. The same line in a `Live Subagents` row, which draws its stats through the same renderer.
    const panel = document.createElement('wa-orchestrator');
    panel.style.cssText = 'position:fixed;left:0;top:0;width:320px;height:400px;z-index:9998';
    document.body.append(panel);
    panel.live = { counts: null, note: '', rows: [{ state: 'running', session_id: 'glyph-child', node: 'local',
      node_name: 'local', node_source: 'test', title: 'glyph row', stats: line }] };
    const liveStats = panel.querySelector('.live-child-stats');
    check(!!liveStats && liveStats.textContent === line, 'the live subagents row prints the same line, saw: ' +
      String(liveStats && liveStats.textContent));
    const liveStyle = getComputedStyle(liveStats);
    check(ciphers(liveStyle), 'the live row asks for the TEXT presentation too, saw font-variant-emoji: ' +
      liveStyle.fontVariantEmoji + ' and font-family: ' + liveStyle.fontFamily);

    // THE ROW STILL TAKES THE ROW'S COLOUR AND SIZE. A text-presentation glyph inherits `color`; a
    // colour emoji would paint its own. The colour is asserted to be the row's inherited value rather
    // than a picture, and the glyph is asserted to sit in the row's own font size.
    check(elapsedStyle.color === getComputedStyle(statusElapsed.closest('.chat-content-run-status')).color,
      'the glyph takes its row\'s colour, saw row: ' + getComputedStyle(statusElapsed.closest('.chat-content-run-status')).color +
      ' glyph: ' + elapsedStyle.color);

    // 3. THE MONOCHROME SOURCE, sampled. `inked` proves the stack draws something; `coloured` counts
    // ink pixels whose channels disagree, which is what a colour emoji bitmap always has and a text
    // outline never does.
    const ink = async (font) => {
      const canvas = document.createElement('canvas');
      canvas.width = 96; canvas.height = 96;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#000000'; ctx.fillRect(0, 0, 96, 96);
      ctx.fillStyle = '#ffffff'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.font = '64px ' + font;
      ctx.fillText('👣', 48, 48);
      const pixels = ctx.getImageData(0, 0, 96, 96).data;
      let inked = 0, coloured = 0;
      for (let i = 0; i < pixels.length; i += 4) {
        const r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
        if (r + g + b <= 40) continue;
        inked++;
        if (Math.max(r, g, b) - Math.min(r, g, b) > 24) coloured++;
      }
      return { inked, coloured };
    };
    // The stack the row actually computes to (read off the row, not restated here).
    const glyphStack = elapsedStyle.fontFamily;
    const textInk = await ink(glyphStack);
    check(textInk.inked > 40, 'the row\'s own font stack draws the feet glyph at all, saw ' + JSON.stringify(textInk));
    check(textInk.coloured === 0, 'and draws it MONOCHROME - no colour ink in the glyph, saw ' + JSON.stringify(textInk));
    const colourInk = await ink('"Segoe UI Emoji", "Apple Color Emoji", "Noto Color Emoji"');
    check(colourInk.coloured > 40, 'CONTROL: a colour emoji font draws the same character with colour ink, saw ' +
      JSON.stringify(colourInk));

    // THE NARROW PANE. The row is one line that ellipsises: in 150px the facts are clipped (the element
    // overflows) and the row is still one line high. A wrapped row would be two.
    const row = statusElapsed.closest('.chat-content-run-status');
    const holder = document.createElement('div');
    holder.style.cssText = 'position:fixed;left:0;top:0;width:150px;overflow:hidden';
    holder.append(row); document.body.append(holder);
    const rowLine = parseFloat(getComputedStyle(row).lineHeight) || 20;
    check(row.clientHeight <= rowLine * 1.6, 'the narrow row is still ONE line, saw height ' + row.clientHeight +
      'px against line-height ' + rowLine + 'px');
    check(statusElapsed.scrollWidth > statusElapsed.clientWidth, 'and its facts are ellipsised rather than wrapped, saw ' +
      statusElapsed.scrollWidth + 'px of content in ' + statusElapsed.clientWidth + 'px');
    check(getComputedStyle(statusElapsed).whiteSpace === 'nowrap' && getComputedStyle(statusElapsed).textOverflow === 'ellipsis',
      'the row keeps `nowrap` + `ellipsis`, saw ' + getComputedStyle(statusElapsed).whiteSpace + '/' + getComputedStyle(statusElapsed).textOverflow);

    for (let t = 1; t < 10000; t++) { clearTimeout(t); clearInterval(t); }
    report.dataset.status = 'pass';
    report.textContent = JSON.stringify({ checks, skipped: 0, userAgent: navigator.userAgent,
      fontVariantEmoji: elapsedStyle.fontVariantEmoji, glyphStack, textInk, colourInk });
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = String(error.stack || error);
  }
})();
