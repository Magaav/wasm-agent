// The selector half of the stub DOMs in tests/*.js (bug-hunt, composer-input, composer-attachments).
//
// app.js reads the transcript through querySelectorAll/querySelector/closest/matches with the selectors it
// really uses (`wa-message[role="user"]`, `:scope > wa-run`, `.seg[data-ledger-key],wa-reasoning[...]`,
// ...). A stub that answered `[]` for every query hid what app.js does with the result, and one that threw
// stopped the suite at the first send (30/10). This answers them over the stub's own children with the
// subset CSS app.js uses: comma lists, the `>` and descendant combinators, `:scope`, tag, `#id`, `.class`,
// `[attr]` and `[attr="value"]`. An unsupported selector throws by name instead of answering wrong.
//
// installQuery(El) adds the methods to a stub element class. Attributes live in `_attrs`; `data-*` reads
// `dataset`, `class` reads `className` and `classList`, and `id`/`role` fall back to the property.
'use strict';

function attrOf(el, name) {
  if (el._attrs && Object.prototype.hasOwnProperty.call(el._attrs, name)) return el._attrs[name];
  if (name.startsWith('data-') && el.dataset) {
    const key = name.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    if (el.dataset[key] !== undefined) return String(el.dataset[key]);
  }
  if (name === 'class') return classesOf(el).join(' ') || null;
  if ((name === 'id' || name === 'role' || name === 'rel') && el[name]) return String(el[name]);
  return null;
}

function classesOf(el) {
  const out = new Set(String(el.className || '').split(/\s+/).filter(Boolean));
  if (el.classList && el.classList._set) for (const c of el.classList._set) out.add(c);
  return [...out];
}

// One compound selector, e.g. `wa-message[role="user"].x#y`.
function parseCompound(text) {
  const src = text.trim();
  const parts = { tag: null, id: null, classes: [], attrs: [] };
  let i = 0;
  const ident = () => { const m = /^[A-Za-z0-9_-]+/.exec(src.slice(i)); if (!m) throw new Error('stub-dom-query: unsupported selector ' + JSON.stringify(text)); i += m[0].length; return m[0]; };
  if (src[i] === '*') i++;
  else if (/[A-Za-z]/.test(src[i] || '')) parts.tag = ident().toUpperCase();
  while (i < src.length) {
    const c = src[i];
    if (c === '#') { i++; parts.id = ident(); }
    else if (c === '.') { i++; parts.classes.push(ident()); }
    else if (c === '[') {
      const end = src.indexOf(']', i);
      if (end < 0) throw new Error('stub-dom-query: unsupported selector ' + JSON.stringify(text));
      const m = /^\s*([A-Za-z0-9_-]+)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\]\s]+)))?\s*$/.exec(src.slice(i + 1, end));
      if (!m) throw new Error('stub-dom-query: unsupported selector ' + JSON.stringify(text));
      parts.attrs.push({ name: m[1], value: m[2] ?? m[3] ?? m[4] });
      i = end + 1;
    } else throw new Error('stub-dom-query: unsupported selector ' + JSON.stringify(text));
  }
  return parts;
}

function matchesCompound(el, p) {
  if (!el || typeof el !== 'object') return false;
  if (p.tag && String(el.tagName || '').toUpperCase() !== p.tag) return false;
  if (p.id && attrOf(el, 'id') !== p.id) return false;
  if (p.classes.length) { const have = classesOf(el); if (!p.classes.every((c) => have.includes(c))) return false; }
  for (const a of p.attrs) {
    const v = attrOf(el, a.name);
    if (v === null || v === undefined) return false;
    if (a.value !== undefined && String(v) !== a.value) return false;
  }
  return true;
}

// `a b > c` -> [{comb:null,p:a},{comb:' ',p:b},{comb:'>',p:c}]; a leading `:scope` binds to the root.
function parseComplex(text) {
  const tokens = text.trim().replace(/\s*>\s*/g, ' > ').split(/\s+/).filter(Boolean);
  const steps = [];
  let comb = null, scoped = false;
  for (const t of tokens) {
    if (t === '>') { comb = '>'; continue; }
    if (t === ':scope' && !steps.length) { scoped = true; continue; }
    steps.push({ comb: steps.length || scoped ? (comb || ' ') : null, p: parseCompound(t) });
    comb = null;
  }
  if (!steps.length) throw new Error('stub-dom-query: unsupported selector ' + JSON.stringify(text));
  return { steps, scoped };
}

const parentOf = (el) => el.parentNode || el.parentElement || null;

function matchesComplex(el, complex, root) {
  const walk = (node, k) => {
    if (!matchesCompound(node, complex.steps[k].p)) return false;
    const comb = complex.steps[k].comb;
    if (k === 0) return !complex.scoped || (comb === '>' ? parentOf(node) === root : isInside(node, root));
    if (comb === '>') { const up = parentOf(node); return !!up && up !== root && walk(up, k - 1); }
    for (let up = parentOf(node); up && up !== root; up = parentOf(up)) if (walk(up, k - 1)) return true;
    return false;
  };
  // `:scope > x` with one step: the step's own combinator relates it to the root.
  if (complex.scoped && complex.steps.length === 1) {
    if (!matchesCompound(el, complex.steps[0].p)) return false;
    return complex.steps[0].comb === '>' ? parentOf(el) === root : isInside(el, root);
  }
  return walk(el, complex.steps.length - 1);
}

function isInside(node, root) { for (let up = parentOf(node); up; up = parentOf(up)) if (up === root) return true; return false; }

function descendants(root) {
  const out = [];
  const visit = (node) => {
    for (const child of node.children || []) {
      if (!child || typeof child !== 'object') continue;
      if (!parentOf(child)) child.parentNode = node;
      out.push(child); visit(child);
    }
    if (node.body && typeof node.body === 'object' && !(node.children || []).includes(node.body)) {
      if (!parentOf(node.body)) node.body.parentNode = node;
      out.push(node.body); visit(node.body);
    }
  };
  visit(root);
  return out;
}

const parseList = (selector) => String(selector).split(',').map(parseComplex);

function installQuery(El) {
  const proto = El.prototype;
  // A child knows its parent, and `remove()` detaches it, as in the DOM: `closest()` and the
  // combinators walk up, and app.js removes nodes it then expects to be gone from a query.
  const append = proto.append;
  proto.append = function (...nodes) { for (const n of nodes) if (n && typeof n === 'object') n.parentNode = this; return append.apply(this, nodes); };
  const remove = proto.remove;
  proto.remove = function () {
    const up = parentOf(this);
    if (up && Array.isArray(up.children)) { const i = up.children.indexOf(this); if (i >= 0) up.children.splice(i, 1); if ('_html' in up) up._html = undefined; }
    this.parentNode = null;
    return remove ? remove.apply(this) : undefined;
  };
  proto.setAttribute = function (name, value) { (this._attrs ||= {})[name] = String(value); if (name === 'id') this.id = String(value); };
  proto.getAttribute = function (name) { return attrOf(this, name); };
  proto.hasAttribute = function (name) { return attrOf(this, name) !== null; };
  proto.removeAttribute = function (name) { if (this._attrs) delete this._attrs[name]; };
  proto.matches = function (selector) { return parseList(selector).some((c) => matchesComplex(this, c, null)); };
  proto.querySelectorAll = function (selector) {
    const list = parseList(selector);
    return descendants(this).filter((el) => list.some((c) => matchesComplex(el, c, this)));
  };
  proto.querySelector = function (selector) { return this.querySelectorAll(selector)[0] || null; };
  proto.closest = function (selector) {
    const list = parseList(selector);
    for (let node = this; node; node = parentOf(node)) if (list.some((c) => matchesComplex(node, c, null))) return node;
    return null;
  };
}

// The custom-element methods app.js calls on what it creates (ui/components.js). Each models the
// observable effect the real element has - its state lands in `dataset`, its text in `textContent` -
// so an assertion reads what the page would show. Unknown tags stay bare elements.
const COMPONENTS = {
  'wa-step': {
    setStep(label, state, ms) {
      this.dataset.state = state; this.textContent = String(label);
      this.dataset.ms = ms == null ? '' : String(ms);
    },
  },
};

function upgrade(el) {
  const methods = COMPONENTS[String(el.tagName || '').toLowerCase()];
  if (methods) for (const [name, fn] of Object.entries(methods)) if (typeof el[name] !== 'function') el[name] = fn;
  return el;
}

module.exports = { installQuery, upgrade };
