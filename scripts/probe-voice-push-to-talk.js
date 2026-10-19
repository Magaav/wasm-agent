// Focused browser probe for push-to-talk: no Recognition must disable the mic without
// throwing, a supported browser must put a transcript in the composer, and the spoken
// reply must be the answer's prose only - not a tool argument, result or code fence.
(async function () {
  const report = document.createElement('pre');
  report.id = 'wa-probe';
  report.hidden = true;
  document.body.append(report);
  let checks = 0;
  const check = (ok, label) => { if (!ok) throw Error(label); checks++; };
  try {
    await window.rendererLoaded;
    const mic = document.getElementById('mic');
    const speak = document.getElementById('voice-speak');
    const keep = document.getElementById('voice-keep');
    const lang = document.getElementById('voice-lang');
    const note = document.getElementById('voice-note');

    // 1. A browser with no speech recognition: the mic is disabled and nothing throws.
    delete window.SpeechRecognition;
    delete window.webkitSpeechRecognition;
    Object.defineProperty(window, 'speechSynthesis', { configurable: true, writable: true, value: undefined });
    Object.defineProperty(window, 'SpeechSynthesisUtterance', { configurable: true, writable: true, value: undefined });
    window.setupVoice();
    check(mic.disabled === true, 'no Recognition must disable the mic');
    check(mic.getAttribute('aria-pressed') === 'false' && mic.dataset.voiceState === 'idle',
      'a disabled mic still reports an honest idle state');
    check(speak.disabled === true, 'no synthesis must make reply speech visibly unavailable');
    check(keep.checked === false && keep.disabled === true, 'keep listening is off without a recognizer');

    // 2. A supported browser: dictation reaches the composer, unforced and unchanged.
    class FixtureRecognition {
      constructor() { FixtureRecognition.last = this; this.started = 0; this.lang = ''; }
      start() { this.started += 1; this.onstart?.(); }
      stop() { this.onend?.(); }
    }
    const spoken = [];
    const voice = { lang: 'en-US', name: 'Fixture English' };
    Object.defineProperty(window, 'SpeechRecognition', { configurable: true, writable: true, value: FixtureRecognition });
    Object.defineProperty(window, 'SpeechSynthesisUtterance', {
      configurable: true, writable: true,
      value: class { constructor(text) { this.text = text; } },
    });
    Object.defineProperty(window, 'speechSynthesis', {
      configurable: true, writable: true,
      value: {
        speak(utterance) {
          spoken.push({ text: utterance.text, lang: utterance.lang, voice: utterance.voice });
          utterance.onstart?.();
          Promise.resolve().then(() => utterance.onend?.());
        },
        cancel() {},
        getVoices() { return [voice]; },
        addEventListener() {},
        removeEventListener() {},
      },
    });
    window.setupVoice();
    const recognizer = FixtureRecognition.last;
    check(!!recognizer && mic.disabled === false && speak.disabled === false,
      'a supported browser enables the mic and reply speech');
    check(recognizer.lang === (navigator.language || 'en-US'),
      'recognition defaults to navigator.language, saw ' + recognizer.lang);
    lang.value = 'fr-FR';
    lang.dispatchEvent(new Event('input'));
    check(recognizer.lang === 'fr-FR', 'a configured recognition language is applied, saw ' + recognizer.lang);
    lang.value = 'en-US';
    lang.dispatchEvent(new Event('input'));
    mic.click();
    check(recognizer.started === 1, 'the mic starts recognition');
    const placeholder = input.value;
    recognizer.onresult({ results: [{ 0: { transcript: 'hello phone' }, isFinal: true }] });
    check(input.value === placeholder + 'hello phone', 'the transcript reaches the composer, saw ' + input.value);

    // 3. Speech: only the final prose of a completed run, code and tool noise omitted.
    messages.replaceChildren();
    runBubble = null;
    streamBody = null;
    streamText = '';
    handleEvent({ type: 'reply', text: 'Final answer.\n\n```js\nconst toolNoise = 1;\n```\n\n**Done**.' });
    handleEvent({ type: 'tool', name: 'bash', arguments: { command: 'secret tool argument' } });
    handleEvent({ type: 'tool_result', name: 'bash', result: 'secret tool output' });
    handleEvent({ type: 'done' });
    check(spoken.length === 1, 'a completed run speaks exactly once, saw ' + spoken.length);
    check(spoken[0].text === 'Final answer. Done.', 'spoken text is the answer prose, saw ' + JSON.stringify(spoken[0].text));
    check(!spoken[0].text.includes('toolNoise') && !spoken[0].text.includes('secret tool'),
      'code fences and tool output are never spoken');

    // 4. A configured language with no installed voice is reported, not silently mispronounced.
    lang.value = 'fr-FR';
    lang.dispatchEvent(new Event('input'));
    messages.replaceChildren();
    runBubble = null;
    streamBody = null;
    streamText = '';
    handleEvent({ type: 'reply', text: 'Bonjour.' });
    handleEvent({ type: 'done' });
    check(spoken.length === 1, 'no matching voice means no speech rather than the wrong voice');
    check(note.textContent.includes('No installed voice speaks fr-FR'),
      'a missing voice is said visibly in the voice panel, saw ' + JSON.stringify(note.textContent));
    check(chatShell.warning.textContent.includes('No installed voice speaks fr-FR'),
      'a missing voice is also visible in the chat warning, saw ' + JSON.stringify(chatShell.warning.textContent));

    report.dataset.status = 'pass';
    report.textContent = JSON.stringify({ checks, skipped: 0 });
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = String(error && error.stack || error);
  }
})();
