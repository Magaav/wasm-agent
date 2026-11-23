#!/usr/bin/env node
// Measure one transcription engine against another on the same clips (docs/TRANSCRIPTION.md).
//
// WHY A HARNESS AND NOT A RECOMMENDATION FROM MEMORY. The question Victor asked is "which recognizer
// should each node run", and the only honest answer is a number measured on the same audio: word error
// rate, seconds per minute of audio, peak memory, and whether the thing runs at all where the node is.
// Every engine below is a command line, so an engine is a JSON object, not a module: the harness never
// imports an SDK, never downloads a model and never touches the network.
//
// WHAT IT NEVER DOES: put audio or a transcript in this repository. `--clips` points at a directory
// outside the tree, the manifest is its own file beside it, and a clip's reference text is the only
// thing that reaches the report.
//
// USAGE
//   node scripts/measure-transcription.mjs --clips /tmp/clips --manifest /tmp/clips/manifest.json \
//        --engines /tmp/clips/engines.json [--out docs/measurements/transcription-$(date +%F).json]
//
// manifest.json:  [{ "file": "pt-short-1.wav", "language": "pt", "reference": "...", "seconds": 4.2 }]
// engines.json:   [{ "name": "faster-whisper-small", "argv": ["python", "-m", "...", "{audio}"],
//                    "result": { "kind": "stdout" } }]
//
// where `result.kind` is `stdout` (the text is the whole output), `json` (the output is JSON and
// `result.path` names the text, dot-separated) or `cmd` (run `result.argv` afterwards, e.g.
// `superwhisper read`, and read the text from its JSON). An engine that fails is REPORTED as failed with
// its own words - a missing model is a fact about the node, never a zero that reads like a perfect run.
import { readFileSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, resolve } from 'node:path'

function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name)
  return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback
}

const clips = arg('clips')
const manifestPath = arg('manifest')
const enginesPath = arg('engines')
const out = arg('out')
if (!clips || !manifestPath || !enginesPath) {
  console.error('measure-transcription: --clips, --manifest and --engines are required (see the header)')
  process.exit(2)
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
const engines = JSON.parse(readFileSync(enginesPath, 'utf8'))
if (!Array.isArray(manifest) || manifest.length === 0) {
  console.error('measure-transcription: the manifest is empty; there is nothing to measure')
  process.exit(2)
}
if (!Array.isArray(engines) || engines.length === 0) {
  console.error('measure-transcription: no engines; a run with no engine measures nothing')
  process.exit(2)
}

/** The text an engine printed, or the reason there is none. Never a guess. */
function text_of(spec, stdout) {
  const result = spec.result || { kind: 'stdout' }
  if (result.kind === 'stdout') return stdout.trim()
  if (result.kind === 'json') {
    let value
    try { value = JSON.parse(stdout) } catch { return stdout.trim() }
    for (const part of String(result.path || 'text').split('.')) value = value?.[part]
    return typeof value === 'string' ? value : ''
  }
  if (result.kind === 'cmd') {
    const run = spawnSync(result.argv[0], result.argv.slice(1), { encoding: 'utf8', timeout: 120_000 })
    if (run.status !== 0) return ''
    let value
    try { value = JSON.parse(run.stdout) } catch { return run.stdout.trim() }
    for (const part of String(result.path || 'text').split('.')) value = value?.[part]
    return typeof value === 'string' ? value : ''
  }
  return stdout.trim()
}

/** Lowercase, no punctuation, one space: the comparison a WER is defined on. */
function words(text) {
  return text
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9\s]/g, ' ')
    .split(/\s+/)
    .filter(Boolean)
}

/** Token-level Levenshtein: the edit count a word error rate divides by the reference length. */
function edits(reference, hypothesis) {
  const a = words(reference)
  const b = words(hypothesis)
  let previous = Array.from({ length: b.length + 1 }, (_, j) => j)
  for (let i = 1; i <= a.length; i++) {
    const current = [i]
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1))
    }
    previous = current
  }
  return { errors: previous[b.length], reference: a.length }
}

/** Peak RSS of one child, in KiB: `/usr/bin/time -v` when the box has it, else `-` (unknown, not zero). */
const hasTime = spawnSync('sh', ['-c', 'command -v /usr/bin/time'], { encoding: 'utf8' }).status === 0

function run(spec, clipPath) {
  const argv = spec.argv.map(a => a.replaceAll('{audio}', clipPath))
  const started = process.hrtime.bigint()
  let run
  if (hasTime) {
    // `/usr/bin/time -v` writes its report to stderr; the child's own stderr is kept beside it.
    run = spawnSync('/usr/bin/time', ['-v', ...argv], { encoding: 'utf8', timeout: 600_000, env: { ...process.env, ...(spec.env || {}) } })
  } else {
    run = spawnSync(argv[0], argv.slice(1), { encoding: 'utf8', timeout: 600_000, env: { ...process.env, ...(spec.env || {}) } })
  }
  const wall = Number(process.hrtime.bigint() - started) / 1e6
  const peak = hasTime ? Number((/-\s*(\d+)\s+kB\s+maximum resident set size/.exec(run.stderr || '') || [])[1] || 0) : null
  if (run.status !== 0) {
    const why = (run.stderr || run.stdout || `exit ${run.status}`).trim().split('\n').slice(-3).join(' | ')
    return { ok: false, wall_ms: Math.round(wall), peak_kib: peak, text: '', why }
  }
  const text = text_of(spec, run.stdout || '')
  return { ok: true, wall_ms: Math.round(wall), peak_kib: peak, text, why: '' }
}

const results = []
for (const spec of engines) {
  const rows = []
  for (const clip of manifest) {
    const audio = resolve(clips, clip.file)
    const outcome = run(spec, audio)
    const compared = outcome.ok ? edits(clip.reference || '', outcome.text) : { errors: 0, reference: 0 }
    rows.push({
      file: clip.file,
      language: clip.language || '',
      seconds: clip.seconds ?? null,
      ok: outcome.ok,
      why: outcome.why,
      wall_ms: outcome.wall_ms,
      peak_kib: outcome.peak_kib,
      wer: outcome.ok && compared.reference > 0 ? Number((compared.errors / compared.reference).toFixed(4)) : null,
      hypothesis_chars: outcome.text.length,
    })
  }
  const ok = rows.filter(r => r.ok)
  const audio_seconds = ok.reduce((sum, r) => sum + (r.seconds || 0), 0)
  const decode_ms = ok.reduce((sum, r) => sum + r.wall_ms, 0)
  const rated = ok.filter(r => r.wer !== null)
  results.push({
    engine: spec.name,
    licence: spec.licence || 'unknown',
    headless: spec.headless ?? null,
    clips: rows,
    // Seconds of decoding per minute of audio is the one number that predicts whether a note waits.
    seconds_per_audio_minute: audio_seconds > 0 ? Number((decode_ms / 1000 / (audio_seconds / 60)).toFixed(2)) : null,
    wer_mean: rated.length > 0 ? Number((rated.reduce((s, r) => s + r.wer, 0) / rated.length).toFixed(4)) : null,
    peak_kib_max: ok.reduce((max, r) => Math.max(max, r.peak_kib || 0), 0) || null,
    failed: rows.length - ok.length,
  })
}

const report = {
  schema: 1,
  measured_at: new Date().toISOString(),
  host: { node: process.version, arch: process.arch, platform: process.platform, cpus: (await import('node:os')).cpus().length },
  clips: manifest.length,
  engines: results,
}
if (out) writeFileSync(out, JSON.stringify(report, null, 2) + '\n')
console.log(JSON.stringify(report, null, 2))
