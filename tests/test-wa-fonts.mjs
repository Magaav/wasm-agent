#!/usr/bin/env node
// wa's two fonts, checked as BYTES (item 1 of the wa-fonts mission, Victor 19/11).
//
// The look Victor approved is three numbers: an icon FILLS its cell, its right edge sits 1 px inside
// the cell, its ink is centred on the capitals - and the value after it is GLUED, which is to say the
// icon's advance is EXACTLY one cell of JetBrains Mono. A font is a derived artifact, so the honest
// check is not "the file is committed" but "the committed file still has those numbers", read from the
// tables a terminal reads.
//
// fontTools is deliberately NOT a dependency here: it is not installed on a gate host, and a test that
// skips where it runs cannot catch anything. So this parses the sfnt itself - head, hhea, maxp, hmtx,
// cmap, loca/glyf, post, name - a few hundred lines of DataView, no network, no venv, no subprocess.
// The metrics are the SAME constants scripts/build-wa-icons.py builds with; if you change one, change
// both, and the manifest (assets/fonts/waIcons.json) with them.
//
// It also refuses drift between the font and the code: the code points lua/core/cli_view.lua's GLYPH
// table names must be exactly the code points the font carries. A glyph wa draws and the font lacks is
// a tofu box in a status row; a glyph the font carries and wa stopped drawing is dead weight shipped.
//
//   node tests/test-wa-fonts.mjs      exit 0 ok, 1 a claim that does not hold
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FONTS = path.join(ROOT, 'assets', 'fonts');

// ---- A2, the approved geometry, in JetBrains Mono's units ----------------------------------------
// Measured from JetBrainsMono-Regular.ttf: upm 1000, advance 600, cap height 730, hhea 1020/-300.
const ADV_EM = 600, CELL_PX_AT_9 = 7.2, PX_UNITS = Math.round(ADV_EM / CELL_PX_AT_9);
const A2_SIZE = ADV_EM - PX_UNITS;              // 517
const CAP_HEIGHT = 730, YMID = CAP_HEIGHT / 2;  // 365
const UPEM_OUT = 2048, K = UPEM_OUT / 1000;
const ADVANCE = Math.round(ADV_EM * K), RIGHT_EDGE = A2_SIZE * K, YMID_OUT = YMID * K;

// ---- the sfnt reader ----------------------------------------------------------------------------
// Reads only what the claims need. Every table it is told to want must exist: a missing table is a
// failure here, never a skip - the font is the artifact under test.
function readFont(file) {
  const buf = fs.readFileSync(file);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const numTables = view.getUint16(4);
  const tables = {};
  for (let i = 0; i < numTables; i++) {
    const at = 12 + i * 16;
    const tag = buf.toString('latin1', at, at + 4);
    tables[tag] = {offset: view.getUint32(at + 8), length: view.getUint32(at + 12)};
  }
  for (const needed of ['head', 'hhea', 'maxp', 'hmtx', 'cmap', 'loca', 'glyf', 'post', 'name']) {
    assert.ok(tables[needed], file + " has no " + needed + " table");
  }
  const i16 = (tag, at) => view.getInt16(tables[tag].offset + at);
  const u16 = (tag, at) => view.getUint16(tables[tag].offset + at);
  const u32 = (tag, at) => view.getUint32(tables[tag].offset + at);

  const unitsPerEm = u16('head', 18), longLoca = i16('head', 50) === 1;
  const numGlyphs = u16('maxp', 4);
  const numberOfHMetrics = u16('hhea', 34);
  const advances = [], lsbs = [];
  for (let g = 0; g < numGlyphs; g++) {
    const i = Math.min(g, numberOfHMetrics - 1);
    advances.push(u16('hmtx', i * 4));
    lsbs.push(i16('hmtx', i * 4 + 2));
  }
  const loca = [];
  for (let g = 0; g <= numGlyphs; g++) loca.push(longLoca ? u32('loca', g * 4) : u16('loca', g * 2) * 2);
  const bbox = (g) => {
    const start = tables.glyf.offset + loca[g], end = tables.glyf.offset + loca[g + 1];
    if (end <= start) return null;                 // an empty outline has no bbox at all
    return {xMin: view.getInt16(start + 2), yMin: view.getInt16(start + 4),
            xMax: view.getInt16(start + 6), yMax: view.getInt16(start + 8)};
  };
  // cmap: prefer a full-repertoire subtable (format 12) over the BMP one (format 4). wa's icons all
  // live in plane 15 (U+F0000..), so a font read through format 4 alone would look EMPTY - which is
  // exactly the false green this preference exists to prevent.
  const cmapOffset = tables.cmap.offset, records = view.getUint16(cmapOffset + 2);
  let best = null;
  for (let i = 0; i < records; i++) {
    const at = cmapOffset + 4 + i * 8;
    const sub = cmapOffset + view.getUint32(at + 4), format = view.getUint16(sub);
    const score = format === 12 ? 3 : format === 4 ? 1 : 0;
    if (score && (!best || score > best.score)) best = {sub, format, score};
  }
  assert.ok(best, file + ' has no usable cmap subtable (format 4 or 12)');
  const cmap = new Map();
  if (best.format === 12) {
    const groups = view.getUint32(best.sub + 12);
    for (let i = 0; i < groups; i++) {
      const at = best.sub + 16 + i * 12;
      const start = view.getUint32(at), end = view.getUint32(at + 4), glyph = view.getUint32(at + 8);
      for (let cp = start; cp <= end; cp++) cmap.set(cp, glyph + (cp - start));
    }
  } else {
    const segX2 = view.getUint16(best.sub + 6), segments = segX2 / 2;
    const ends = best.sub + 14, starts = ends + segX2 + 2, deltas = starts + segX2;
    const ranges = deltas + segX2;
    for (let s = 0; s < segments; s++) {
      const end = view.getUint16(ends + s * 2), start = view.getUint16(starts + s * 2);
      const delta = view.getInt16(deltas + s * 2), rangeAt = ranges + s * 2;
      const range = view.getUint16(rangeAt);
      for (let cp = start; cp <= end && cp !== 0xFFFF; cp++) {
        let glyph;
        if (range === 0) glyph = (cp + delta) & 0xFFFF;
        else {
          const at = rangeAt + range + (cp - start) * 2;
          if (at + 2 > tables.cmap.offset + tables.cmap.length) continue;
          glyph = view.getUint16(at);
          if (glyph) glyph = (glyph + delta) & 0xFFFF;
        }
        if (glyph) cmap.set(cp, glyph);
      }
    }
  }
  // name: the strings a font chooser shows. Platform 3 (and 0) are UTF-16BE.
  const namesById = {};
  const nameCount = u16('name', 2);
  const stringOffset = tables.name.offset + u16('name', 4);
  for (let i = 0; i < nameCount; i++) {
    const at = tables.name.offset + 6 + i * 12;
    const platform = view.getUint16(at), nameId = view.getUint16(at + 6);
    const length = view.getUint16(at + 8), offset = view.getUint16(at + 10);
    const raw = Buffer.from(buf.subarray(stringOffset + offset, stringOffset + offset + length));
    const text = (platform === 3 || platform === 0) ? raw.swap16().toString('utf16le') : raw.toString('latin1');
    if (namesById[nameId] === undefined) namesById[nameId] = text;
  }
  return {unitsPerEm, numGlyphs, advances, lsbs, bbox, cmap, namesById,
          ascent: i16('hhea', 4), descent: i16('hhea', 6), lineGap: i16('hhea', 8),
          isFixedPitch: u32('post', 12)};
}

// The code points lua/core/cli_view.lua's GLYPH table names, read from the SOURCE. A table copied into
// this test would agree with itself and prove nothing, so each row's trailing "-- U+XXXXX" comment is
// what is parsed - the same comment a reader checks the escape against.
// The code points lua/core/icons.lua's wa SET draws - the table the rows ask by name (item 4 moved it
// there from cli_view, so this reads the one place wa's characters live now). Each row's trailing
// "-- U+XXXXX" comment is what is parsed: a table copied into this test would agree with itself.
function luaGlyphs() {
  const source = fs.readFileSync(path.join(ROOT, 'lua', 'core', 'icons.lua'), 'utf8');
  const start = source.indexOf('  wa = {');
  assert.ok(start > 0, 'lua/core/icons.lua no longer has a wa set');
  const body = source.slice(start);
  const stop = body.indexOf('\n  },');
  assert.ok(stop > 0, 'the wa set is not closed on its own line');
  const table = body.slice(0, stop);
  const found = new Map();
  for (const line of table.split('\n')) {
    const row = line.match(/^\s*(\w+)\s*=\s*"/);
    const comment = line.match(/--\s*U\+([0-9A-Fa-f]+)/);
    if (row && comment) found.set(row[1], parseInt(comment[1], 16));
  }
  // The brief's floor: the status/footer icons (steps, clock, turns, cache) plus the finish stamp is 5,
  // and the context ball keeps NINE states in this set - so 14 is the least a table that still holds the
  // approved set can name. Fewer means a row lost its glyph, and this refuses to compare a short table
  // against a font and call the result agreement.
  assert.ok(found.size >= 14, 'the GLYPH table named only ' + found.size + ' glyphs, the approved set is 14');
  return found;
}

// ---- the claims ---------------------------------------------------------------------------------
const checks = [];
function check(name, fn) {
  try { fn(); checks.push({name, ok: true}); }
  catch (error) { checks.push({name, ok: false, why: error.message}); }
}
const fontFile = path.join(FONTS, 'waIcons-Regular.ttf');
const icons = readFont(fontFile);
const glyphs = luaGlyphs();

check('the font sits on JetBrains Mono\'s grid: upm 2048, ascent 2089, descent -614',
  () => { assert.equal(icons.unitsPerEm, UPEM_OUT);
          assert.equal(icons.ascent, Math.round(1020 * K));
          assert.equal(icons.descent, Math.round(-300 * K)); });
check('the font is fixed pitch, so one icon is one cell',
  () => { assert.equal(icons.isFixedPitch, 1); });
check('it is its own family, with both licences in name ID 13',
  () => { assert.equal(icons.namesById[1], 'wa Icons');
          assert.match(icons.namesById[13] || '', /MIT/);
          assert.match(icons.namesById[13] || '', /Open Font License/); });

for (const [role, cp] of glyphs) {
  const glyph = icons.cmap.get(cp);
  const hex = cp.toString(16).toUpperCase();
  check(role + ' (U+' + hex + ') is in the font',
    () => assert.ok(glyph !== undefined, 'U+' + hex + ' is drawn by a row and missing from the font'));
  if (glyph === undefined) continue;
  check(role + ' advances ONE JetBrains Mono cell (' + ADVANCE + '/2048 = 0.600 em): the value is glued',
    () => assert.equal(icons.advances[glyph], ADVANCE));
  check(role + ' fills its cell and stops 1 px short of the value (A2, right edge ' + RIGHT_EDGE.toFixed(1) + ')',
    () => { const box = icons.bbox(glyph);
            assert.ok(box, 'the glyph has no outline');
            assert.ok(box.xMax <= Math.round(RIGHT_EDGE) + 1, 'right edge ' + box.xMax + ' is past the 1 px margin');
            const width = box.xMax - box.xMin, height = box.yMax - box.yMin;
            if (width >= height) assert.ok(Math.abs(box.xMax - RIGHT_EDGE) <= 1,
              'fills ' + box.xMax + ', A2 says ' + RIGHT_EDGE.toFixed(1));
            assert.ok(box.xMax <= ADVANCE, 'wider than its own cell'); });
  check(role + ' is centred on the capitals (A2, ymid ' + YMID_OUT.toFixed(1) + ')',
    () => { const box = icons.bbox(glyph);
            assert.ok(box, 'the glyph has no outline');
            const centre = (box.yMax + box.yMin) / 2;
            assert.ok(Math.abs(centre - YMID_OUT) <= 1.5, 'centred at ' + centre.toFixed(1)); });
}

check('the font carries EXACTLY the code points wa draws, and no others',
  () => { const drawn = new Set([...glyphs.values()].map(cp => icons.cmap.get(cp)));
          assert.equal(drawn.size, glyphs.size, 'two roles share one glyph, so one cannot be drawn');
          for (const cp of icons.cmap.keys()) {
            assert.ok([...glyphs.values()].includes(cp),
              'U+' + cp.toString(16).toUpperCase() + ' is shipped and no row draws it');
          } });

// JetBrains Mono ships as the upstream bytes: the OFL requires its own name and copyright to travel
// with it, and every terminal config that asks for "JetBrains Mono" matches on that name.
for (const weight of ['Regular', 'Bold']) {
  check('JetBrainsMono-' + weight + '.ttf is the real JetBrains Mono, not a renamed subset',
    () => { const jb = readFont(path.join(FONTS, 'JetBrainsMono-' + weight + '.ttf'));
            assert.match(jb.namesById[1] || '', /JetBrains Mono/);
            assert.equal(jb.unitsPerEm, 1000); });
}

// The manifest is what the release bundle and the setup copy move, so it has to agree with the bytes
// beside it - a font swapped by hand is a failing test, not a silent change of look.
check('the manifest lists every committed font file with its sha256, and nothing else',
  () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(FONTS, 'waIcons.json'), 'utf8'));
    const onDisk = fs.readdirSync(FONTS).filter(name => name !== 'waIcons.json'
      && fs.statSync(path.join(FONTS, name)).isFile()).sort();
    assert.deepEqual(Object.keys(manifest.files).sort(), onDisk);
    for (const [name, want] of Object.entries(manifest.files)) {
      const got = crypto.createHash('sha256').update(fs.readFileSync(path.join(FONTS, name))).digest('hex');
      assert.equal(got, want, name + ' changed since the manifest was written');
    }
    assert.equal(manifest.a2.advance, ADVANCE);
    assert.equal(manifest.a2.size_units_1000, A2_SIZE);
    assert.equal(manifest.a2.gap, '', 'A2 is GLUED: the gap is the empty string');
    for (const needed of [
      'waIcons-Regular.ttf', 'JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf',
      'OFL-JetBrainsMono.txt', 'LICENSE-SymbolsNerdFont-MIT.txt']) {
      assert.ok(manifest.files[needed] !== undefined, 'the bundle ships ' + needed);
    }
  });

// The window embeds the same two faces (item 5). The node serves ONE directory and its CSP allows this
// origin only, so the woff2 the page loads lives under ui/fonts - and a served copy that has drifted
// from the committed one is a window drawing a glyph the terminal no longer draws.
for (const name of ['waIcons-Regular.ttf', 'JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf']) {
  check('ui/fonts/' + name + ' is the byte-identical twin of assets/fonts/' + name,
    () => {
      const served = path.join(ROOT, 'ui', 'fonts', name);
      assert.ok(fs.existsSync(served), 'the page asks for ui/fonts/' + name + ' and it is not there');
      const a = crypto.createHash('sha256').update(fs.readFileSync(served)).digest('hex');
      const b = crypto.createHash('sha256').update(fs.readFileSync(path.join(FONTS, name))).digest('hex');
      assert.equal(a, b, 'run scripts/build-wa-icons.py again: the served copy is stale');
    });
}
check('the page loads the faces through one stylesheet, from this origin',
  () => {
    const html = fs.readFileSync(path.join(ROOT, 'ui', 'index.html'), 'utf8');
    assert.match(html, /<link rel="stylesheet" href="fonts\.css"/);
    const css = fs.readFileSync(path.join(ROOT, 'ui', 'fonts.css'), 'utf8');
    for (const name of ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf', 'waIcons-Regular.ttf']) {
      // Relative to the page ('fonts/...'), never absolute: the node serves one directory.
      assert.ok(css.includes('url("fonts/' + name + '")'), 'fonts.css does not load fonts/' + name);
    }
    assert.doesNotMatch(css, /https?:\/\//);
    assert.match(css, /font-family: "wa Icons"/);
  });

const failed = checks.filter(row => !row.ok);
for (const row of checks) if (!row.ok) console.log('FAIL ' + row.name + ': ' + row.why);
console.log('wa fonts ok (' + checks.length + ' checks, ' + failed.length + ' failed, 0 skipped; '
  + glyphs.size + ' glyphs drawn, ' + (icons.numGlyphs - 1) + ' in the font)');
process.exit(failed.length === 0 ? 0 : 1);
