#!/usr/bin/env node
// Review leads for UI refactors: names that existed before a patch and no longer
// exist anywhere in the candidate UI. A removal can be intentional; inspect it.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

function options(argv) {
  const opts = { root: process.cwd(), base: 'HEAD' };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--root' || argv[i] === '--base') opts[argv[i].slice(2)] = argv[++i];
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return opts;
}

function git(root, ...args) {
  return execFileSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
}

function candidates(root, dir = 'ui') {
  const found = [];
  const absolute = path.join(root, dir);
  if (!fs.existsSync(absolute)) return found;
  for (const entry of fs.readdirSync(absolute, { withFileTypes: true })) {
    const relative = `${dir}/${entry.name}`;
    if (entry.isDirectory()) found.push(...candidates(root, relative));
    else if (entry.isFile() && /\.(?:js|mjs|css|html)$/.test(entry.name)) found.push(relative);
  }
  return found;
}

function inventory(files) {
  const kinds = { classes: new Map(), css: new Map(), elements: new Map(), events: new Map() };
  function add(kind, name, file, source, offset) {
    if (!name || !/^[A-Za-z_][\w-]*$/.test(name)) return;
    const line = 1 + (source.slice(0, offset).match(/\n/g)?.length || 0);
    const map = kinds[kind];
    if (!map.has(name)) map.set(name, []);
    map.get(name).push(`${file}:${line}`);
  }
  function matches(kind, text, regex, group, file, source) {
    for (const match of text.matchAll(regex)) add(kind, match[group], file, source, match.index);
  }
  for (const [file, source] of files) {
    if (file.endsWith('.css')) {
      const clean = source.replace(/\/\*[\s\S]*?\*\//g, part => part.replace(/[^\n]/g, ' '));
      matches('css', clean, /\.([A-Za-z_][\w-]*)/g, 1, file, source);
      continue;
    }
    if (file.endsWith('.html')) {
      for (const match of source.matchAll(/\bclass\s*=\s*["']([^"']+)["']/g)) {
        for (const name of match[1].split(/\s+/)) add('classes', name, file, source, match.index);
      }
      matches('elements', source, /<(wa-[\w-]+)\b/g, 1, file, source);
      continue;
    }
    for (const match of source.matchAll(/\bclassName\s*=\s*["'`]([^"'`]+)["'`]/g)) {
      for (const name of match[1].split(/\s+/)) add('classes', name, file, source, match.index);
    }
    for (const match of source.matchAll(/\bclassList\.(?:add|remove|toggle|contains)\s*\(([^)]*)\)/g)) {
      for (const value of match[1].matchAll(/["'`]([A-Za-z_][\w-]*)["'`]/g)) {
        add('classes', value[1], file, source, match.index);
      }
    }
    for (const match of source.matchAll(/\bquerySelector(?:All)?\s*\(\s*["'`]([^"'`]+)["'`]/g)) {
      for (const name of match[1].matchAll(/\.([A-Za-z_][\w-]*)/g)) {
        add('classes', name[1], file, source, match.index);
      }
    }
    for (const match of source.matchAll(/\bsetAttribute\s*\(\s*["'`]class["'`]\s*,\s*["'`]([^"'`]+)["'`]/g)) {
      for (const name of match[1].split(/\s+/)) add('classes', name, file, source, match.index);
    }
    matches('elements', source, /\bcustomElements\.define\s*\(\s*["'`](wa-[\w-]+)["'`]/g,
      1, file, source);
    matches('events', source, /\bnew\s+CustomEvent\s*\(\s*["'`]([\w-]+)["'`]/g,
      1, file, source);
  }
  return kinds;
}

function lost(before, after) {
  return [...before].filter(([name]) => !after.has(name))
    .map(([name, locations]) => ({ name, before: [...new Set(locations)] }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function main() {
  const opts = options(process.argv.slice(2));
  const root = path.resolve(opts.root);
  const paths = git(root, 'ls-tree', '-r', '--name-only', opts.base, 'ui').trim().split(/\r?\n/)
    .filter(file => /\.(?:js|mjs|css|html)$/.test(file));
  const before = inventory(paths.map(file => [file, git(root, 'show', `${opts.base}:${file}`)]));
  const after = inventory(candidates(root).map(file => [file,
    fs.readFileSync(path.join(root, file), 'utf8')]));
  const removedClasses = lost(before.classes, after.classes);
  const removedElements = lost(before.elements, after.elements);
  const removedEvents = lost(before.events, after.events);
  const lostStyles = [...before.css].filter(([name]) => after.classes.has(name) && !after.css.has(name))
    .map(([name, locations]) => ({ name, before: [...new Set(locations)] }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const orphanedStyles = [...after.css].filter(([name]) =>
    before.classes.has(name) && !after.classes.has(name))
    .map(([name, locations]) => ({ name, after: [...new Set(locations)] }))
    .sort((a, b) => a.name.localeCompare(b.name));
  console.log(JSON.stringify({ base: opts.base, reviewRequired: !!(
    removedClasses.length || removedElements.length || removedEvents.length ||
    lostStyles.length || orphanedStyles.length),
  removedClasses, removedElements, removedEvents, lostStyles, orphanedStyles,
  note: 'Review leads only: a removal can be intentional; a clean result does not prove the UI works.' }, null, 2));
}

try { main(); }
catch (error) {
  console.error(JSON.stringify({ error: error.message }));
  process.exitCode = 1;
}
