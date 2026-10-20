// Browser-global support for UI probes, and only for probes.
//
//   scripts/agent-benchmark-ui-observe.mjs copies this file into the stage and injects it at
//   </body> immediately before the probe, for EVERY --probe run. It is not injected otherwise,
//   it is never served by the node, and it depends on nothing else in the page (not on
//   test-fixtures.js), so a probe may use it before any fixture has run.
//
// WHY IT EXISTS. A probe that asserts "the picture element is there" is satisfied by a
// LOOKALIKE - a second renderer that draws the same tag and class. The claim we actually want
// is "the subject path produced the same structure the CONTROL path produced in this same
// page", where the control is the production path and the subject is the path under test. So:
//
//   var control = messages.querySelector('wa-message.user .message-images .message-image');
//   var subject = topic && topic.querySelector('.message-images .message-image');
//   var same = waProbeSameAs(control, subject, { ignore: ['style', 'id', 'alt'] });
//   check(same.equal, 'the steered turn draws the picture the normal send drew: ' + waProbeDiff(same));
//
// A failure then reads as ONE line naming the first diverging path and the two values there,
// not as a wall of HTML:
//
//   probe fingerprint diverges at children[0].classes: control ["message-image"] vs subject ["message-image","ghost"]
//
// Public surface (all on window, plus grouped on waProbeSupport):
//   waProbeFingerprint(node, options) -> {tag, classes, attrs, text?, children, truncated?}
//   waProbeSameAs(control, subject, options) -> {equal, path, control, subject}
//   waProbeDiff(result) / waProbeFormat(result) -> one readable line
(function (global) {
  "use strict";

  var VERSION = 1;
  // Bounds, so a failure message stays a message. `truncated:true` is set on any node whose
  // children/text were cut, rather than the fingerprint silently getting shorter.
  var DEFAULTS = { ignore: ["style", "id"], maxDepth: 4, maxNodes: 300, text: false };
  var VALUE_LIMIT = 120;   // attribute and text values; other values keep their raw bytes otherwise
  var RENDER_LIMIT = 160;  // one value inside the one-line diff

  function config(options) {
    var given = options || {};
    var ignore = Array.isArray(given.ignore) ? given.ignore.map(String) : DEFAULTS.ignore.slice();
    return {
      ignore: ignore,
      maxDepth: number(given.maxDepth, DEFAULTS.maxDepth),
      maxNodes: number(given.maxNodes, DEFAULTS.maxNodes),
      text: given.text === true,
    };
  }

  function number(value, fallback) {
    var parsed = typeof value === "number" ? value : Number(value);
    if (!isFinite(parsed) || parsed < 0) return fallback;
    return Math.floor(parsed);
  }

  function isElement(value) {
    return !!value && typeof value === "object" && value.nodeType === 1;
  }

  function label(value) {
    if (value === null) return "<null node>";
    if (value === undefined) return "<missing node>";
    if (isElement(value)) return value.tagName.toLowerCase();
    var text = String(value);
    return "<not an element: " + (text.length > 40 ? text.slice(0, 40) + "..." : text) + ">";
  }

  // 32-bit FNV-1a, printed as 8 hex digits. Short enough to read inside a diff line, and it
  // separates two different payloads of the same length - which a byte count cannot do.
  function fnv1a(text) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0;
    }
    return ("0000000" + hash.toString(16)).slice(-8);
  }

  function base64Bytes(text) {
    try {
      if (typeof global.atob === "function") return global.atob(text);
    } catch (error) { /* not base64 after all; the raw text is the identity */ }
    return null;
  }

  // A data: or blob: URL is collapsed to a readable digest, because the alternative is either a
  // megabyte of base64 in a diff or a length that two different images can share.
  //   data:<mime>,len=<payload bytes>,h=<fnv1a of the payload bytes>
  //   blob:<scheme only>,len=<url length>,h=<fnv1a of the url>
  // A blob URL's bytes are not synchronously readable from the page that made it, so its own
  // URL is the identity - two different blobs still differ, and neither is printed in full.
  function digest(value) {
    var text = String(value);
    if (/^data:/i.test(text)) {
      var comma = text.indexOf(",");
      var head = comma < 0 ? text.slice(5) : text.slice(5, comma);
      var body = comma < 0 ? "" : text.slice(comma + 1);
      var mime = (head.split(";")[0] || "").replace(/^\s+|\s+$/g, "") || "text/plain";
      if (/;\s*base64/i.test(head)) {
        var bytes = base64Bytes(body.replace(/\s+/g, ""));
        if (bytes !== null) return "data:" + mime + ",len=" + bytes.length + ",h=" + fnv1a(bytes);
        return "data:" + mime + ",len=" + body.length + ",h=" + fnv1a(body);
      }
      return "data:" + mime + ",len=" + body.length + ",h=" + fnv1a(body);
    }
    if (/^blob:/i.test(text)) return "blob:,len=" + text.length + ",h=" + fnv1a(text);
    return null;
  }

  function value(raw) {
    var text = raw === null || raw === undefined ? "" : String(raw);
    var collapsed = digest(text);
    if (collapsed !== null) return collapsed;
    if (text.length <= VALUE_LIMIT) return text;
    return text.slice(0, VALUE_LIMIT) + "...+" + (text.length - VALUE_LIMIT);
  }

  function classes(node) {
    var raw = node.getAttribute ? node.getAttribute("class") : null;
    if (!raw) return [];
    return String(raw).split(/\s+/).filter(Boolean).sort();
  }

  function attrs(node, ignore) {
    var out = {};
    var list = node.attributes || [];
    var names = [];
    for (var i = 0; i < list.length; i++) names.push(list[i].name);
    names.sort();
    for (var n = 0; n < names.length; n++) {
      // `class` has its own field (sorted, so a reordered class attribute is not a divergence);
      // `ignore` drops the rest, and `style`/`id` are dropped by default because they are identity
      // and appearance, not structure.
      if (names[n] === "class" || ignore.indexOf(names[n]) >= 0) continue;
      out[names[n]] = value(list.getNamedItem(names[n]).value);
    }
    return out;
  }

  function build(node, depth, state, settings) {
    state.nodes += 1;
    var out = { tag: String(node.tagName).toLowerCase(), classes: classes(node), attrs: attrs(node, settings.ignore) };
    if (settings.text) {
      var text = String(node.textContent === null || node.textContent === undefined ? "" : node.textContent)
        .replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "");
      if (text.length > VALUE_LIMIT) {
        out.text = text.slice(0, VALUE_LIMIT) + "...+" + (text.length - VALUE_LIMIT);
        out.truncated = true;
      } else {
        out.text = text;
      }
    }
    out.children = [];
    var kids = node.children || [];
    if (!kids.length) return out;
    if (depth >= settings.maxDepth || state.nodes >= settings.maxNodes) {
      out.truncated = true;
      return out;
    }
    for (var i = 0; i < kids.length; i++) {
      if (state.nodes >= settings.maxNodes) { out.truncated = true; break; }
      out.children.push(build(kids[i], depth + 1, state, settings));
    }
    return out;
  }

  function fingerprint(node, options) {
    var settings = config(options);
    if (!isElement(node)) throw new TypeError("waProbeFingerprint needs an element, saw " + label(node));
    return build(node, 0, { nodes: 0 }, settings);
  }

  function same(list1, list2) {
    if (list1.length !== list2.length) return false;
    for (var i = 0; i < list1.length; i++) if (list1[i] !== list2[i]) return false;
    return true;
  }

  function compareNode(a, b, prefix, out) {
    var at = function (field) { return prefix ? prefix + "." + field : field; };
    if (a.tag !== b.tag) return record(out, at("tag"), a.tag, b.tag);
    if (!same(a.classes, b.classes)) return record(out, at("classes"), a.classes, b.classes);
    var name;
    var names = Object.keys(a.attrs);
    for (name in b.attrs) if (name && names.indexOf(name) < 0) names.push(name);
    names.sort();
    for (var n = 0; n < names.length; n++) {
      name = names[n];
      if (a.attrs[name] !== b.attrs[name]) return record(out, at("attrs." + name), a.attrs[name], b.attrs[name]);
    }
    if (!!a.truncated !== !!b.truncated) return record(out, at("truncated"), !!a.truncated, !!b.truncated);
    if ("text" in a || "text" in b) {
      if (a.text !== b.text) return record(out, at("text"), a.text, b.text);
    }
    if (a.children.length !== b.children.length) {
      return record(out, at("children.length"), a.children.length, b.children.length);
    }
    for (var c = 0; c < a.children.length; c++) {
      if (!compareNode(a.children[c], b.children[c], at("children[" + c + "]"), out)) return false;
    }
    return true;
  }

  function record(out, path, controlValue, subjectValue) {
    out.path = path;
    out.control = controlValue;
    out.subject = subjectValue;
    return false;
  }

  function sameAs(control, subject, options) {
    var out = { equal: true, path: "", control: null, subject: null };
    try {
      var controlMissing = !isElement(control);
      var subjectMissing = !isElement(subject);
      if (controlMissing || subjectMissing) {
        if (controlMissing && subjectMissing) return out;
        out.equal = false;
        record(out, "(root)", controlMissing ? label(control) : control.tagName.toLowerCase(),
          subjectMissing ? label(subject) : subject.tagName.toLowerCase());
        return out;
      }
      var settings = config(options);
      var left = fingerprint(control, settings);
      var right = fingerprint(subject, settings);
      if (!compareNode(left, right, "", out)) out.equal = false;
      else { out.path = ""; out.control = null; out.subject = null; }
      return out;
    } catch (error) {
      out.equal = false;
      out.path = "(root)";
      out.control = control;
      out.subject = "<compare threw: " + String((error && error.message) || error) + ">";
      return out;
    }
  }

  function render(value) {
    // A missing attribute is a divergence too, and "undefined" would read like a bug in the diff.
    if (value === undefined) return "<absent>";
    if (value === null) return "<null>";
    var text;
    try { text = JSON.stringify(value); }
    catch (error) { text = String(value); }
    if (text === undefined) text = String(value);
    if (text.length > RENDER_LIMIT) text = text.slice(0, RENDER_LIMIT) + "...+" + (text.length - RENDER_LIMIT);
    return text;
  }

  function diff(result) {
    if (result && result.equal) return "no divergence";
    if (!result || typeof result !== "object") return "probe fingerprint has no result: " + render(result);
    return "probe fingerprint diverges at " + (result.path || "(root)") +
      ": control " + render(result.control) + " vs subject " + render(result.subject);
  }

  var support = {
    version: VERSION,
    defaults: DEFAULTS,
    fingerprint: fingerprint,
    sameAs: sameAs,
    diff: diff,
    format: diff,
  };
  global.waProbeFingerprint = fingerprint;
  global.waProbeSameAs = sameAs;
  global.waProbeDiff = diff;
  global.waProbeFormat = diff;
  global.waProbeSupport = support;
})(typeof window === "undefined" ? this : window);
