// Focused probe for the shared structural-fingerprint helper, scripts/wa-probe-support.js.
//
// The helper is what lets a UI probe say "the subject path produced what the CONTROL path produced
// in this same page" instead of "an element with this tag and class exists" - the second claim is
// satisfied by a lookalike. So the helper itself needs a probe: one that fails when it stops
// distinguishing things, and fails when it throws on a node that is not there.
//
//   node scripts/agent-benchmark-ui-observe.mjs --ui ui --out <dir> \
//     --probe scripts/probe-fingerprint-support.js
//
// It is deliberately application-free: fixtures built here, no fixtures needed from the page. What
// it proves, in order: the observer injects the helper before every probe; identical nodes are
// equal; a changed class / attribute / reordered child each diverge at a NAMED path; two different
// data: payloads of the SAME length still differ (the digest, not the length); bounds are reported
// as truncated:true rather than silently shortening; a missing node is a root divergence and never a
// throw; and the failure message is one line.
(async function () {
  "use strict";
  var problems = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  var measured = {};
  var result = { status: "fail", text: "probe did not finish" };

  function make(html) {
    var host = document.createElement("div");
    host.className = "fingerprint-fixture";
    host.innerHTML = html;
    document.body.append(host);
    return host.firstElementChild;
  }
  function countNodes(fingerprint) {
    var total = 1;
    for (var i = 0; i < fingerprint.children.length; i++) total += countNodes(fingerprint.children[i]);
    return total;
  }
  function oneLine(text) { return typeof text === "string" && text.indexOf("\n") < 0 && text.indexOf("\r") < 0; }

  try {
    // 1. The observer's own wiring. A probe that silently ran without the helper would otherwise
    //    report on nothing, so this is asserted before anything else uses it.
    check(typeof window.waProbeFingerprint === "function" &&
      typeof window.waProbeSameAs === "function" &&
      typeof window.waProbeDiff === "function",
      "the observer must inject wa-probe-support.js before every probe, saw fingerprint:"
      + typeof window.waProbeFingerprint + " sameAs:" + typeof window.waProbeSameAs
      + " diff:" + typeof window.waProbeDiff);
    check(typeof window.waProbeFormat === "function" && window.waProbeFormat === window.waProbeDiff,
      "the one-line formatter must be reachable as waProbeFormat as well as waProbeDiff");
    if (problems.length) throw Error(problems[0]);

    // 2. Identical nodes are equal, and equality carries no path.
    var gallery = '<div class="message-images"><span class="message-image" alt="plain.png"></span></div>';
    var control = make(gallery);
    var twin = make(gallery);
    var identical = waProbeSameAs(control, twin);
    check(identical.equal === true && identical.path === "",
      "two identical nodes must be equal with no path: " + waProbeDiff(identical));
    check(waProbeDiff(identical) === "no divergence",
      "an equal comparison must format as no divergence, saw " + waProbeDiff(identical));

    // 3. A changed class. Root-level first (path `classes`), then a child (path
    //    `children[<i>].classes`), because a probe's subject is usually a subtree.
    var base = make('<div class="card"></div>');
    var decorated = make('<div class="card ghost"></div>');
    var classChanged = waProbeSameAs(base, decorated);
    check(classChanged.equal === false && classChanged.path === "classes",
      "a changed class must diverge at `classes`, saw path " + JSON.stringify(classChanged.path)
      + " / " + waProbeDiff(classChanged));
    check(Array.isArray(classChanged.control) && classChanged.control.join(" ") === "card" &&
      classChanged.subject.join(" ") === "card ghost",
      "the divergence must report both class lists, saw " + waProbeDiff(classChanged));
    var ghostChild = make('<div class="message-images"><span class="message-image ghost" alt="plain.png"></span></div>');
    var childClass = waProbeSameAs(control, ghostChild);
    check(childClass.equal === false && childClass.path === "children[0].classes",
      "a changed child class must diverge at children[0].classes, saw path "
      + JSON.stringify(childClass.path) + " / " + waProbeDiff(childClass));

    // 4. A changed attribute diverges at `attrs.<name>`.
    var altA = make('<div class="message-images"><span class="message-image" alt="plain.png"></span></div>');
    var altB = make('<div class="message-images"><span class="message-image" alt="other.png"></span></div>');
    var attrChanged = waProbeSameAs(altA, altB);
    check(attrChanged.equal === false && attrChanged.path === "children[0].attrs.alt",
      "a changed attribute must diverge at children[0].attrs.alt, saw path "
      + JSON.stringify(attrChanged.path) + " / " + waProbeDiff(attrChanged));
    check(attrChanged.control === "plain.png" && attrChanged.subject === "other.png",
      "the divergence must report the two attribute values, saw " + waProbeDiff(attrChanged));
    var rootAttr = make('<span title="one"></span>');
    var rootAttrB = make('<span title="two"></span>');
    var rootAttrChanged = waProbeSameAs(rootAttr, rootAttrB);
    check(rootAttrChanged.equal === false && rootAttrChanged.path === "attrs.title",
      "a changed root attribute must diverge at attrs.title, saw " + JSON.stringify(rootAttrChanged.path));
    // Present on the control, absent on the subject: the shape a lookalike renderer produces.
    var presentOnControl = waProbeSameAs(rootAttr, make("<span></span>"));
    check(presentOnControl.equal === false && presentOnControl.path === "attrs.title" &&
      presentOnControl.subject === undefined && waProbeDiff(presentOnControl).indexOf("<absent>") >= 0,
      "an attribute missing on the subject must be a labelled divergence, saw "
      + waProbeDiff(presentOnControl));

    // 5. A reordered child diverges at `children[<i>].<field>` - the order is structure, not noise.
    var orderA = make('<div><span class="one"></span><span class="two"></span></div>');
    var orderB = make('<div><span class="two"></span><span class="one"></span></div>');
    var reordered = waProbeSameAs(orderA, orderB);
    check(reordered.equal === false && reordered.path === "children[0].classes",
      "a reordered child must diverge at children[0].classes, saw path "
      + JSON.stringify(reordered.path) + " / " + waProbeDiff(reordered));
    var shorter = make('<div><span class="one"></span></div>');
    var lengthDiff = waProbeSameAs(orderA, shorter);
    check(lengthDiff.equal === false && lengthDiff.path === "children.length",
      "a missing child must diverge at children.length, saw " + JSON.stringify(lengthDiff.path)
      + " / " + waProbeDiff(lengthDiff));

    // 6. Two DIFFERENT data: payloads of the SAME length must differ. This is the case a byte count
    //    cannot see, and the one a real image comparison depends on.
    var pngA = "data:image/png;base64,QUFBQQ==";   // payload "AAAA"
    var pngB = "data:image/png;base64,QkJCQg==";   // payload "BBBB", same encoded length
    check(pngA.length === pngB.length, "the fixture data URLs must be the same length to test the digest");
    var imageA = make('<a href="' + pngA + '"></a>');
    var imageB = make('<a href="' + pngB + '"></a>');
    var digestA = waProbeFingerprint(imageA).attrs.href;
    var digestB = waProbeFingerprint(imageB).attrs.href;
    measured.digest = digestA;
    check(/^data:image\/png,len=4,h=[0-9a-f]{8}$/.test(digestA),
      "a data: URL must collapse to data:<mime>,len=<n>,h=<fnv1a>, saw " + JSON.stringify(digestA));
    check(digestA.indexOf("len=" + 4) >= 0 && digestB.indexOf("len=" + 4) >= 0,
      "both fixtures must digest to the same payload length, saw " + digestA + " / " + digestB);
    check(digestA !== digestB,
      "two different payloads of the same length must not share a digest, both were " + digestA);
    check(digestA.length === digestB.length && digestA.length < 60,
      "the digest must stay readable and same-length, saw " + digestA.length + "/" + digestB.length);
    var imageDiff = waProbeSameAs(imageA, imageB);
    check(imageDiff.equal === false && imageDiff.path === "attrs.href",
      "a different image of the same length must diverge at attrs.href, saw "
      + JSON.stringify(imageDiff.path) + " / " + waProbeDiff(imageDiff));
    check(waProbeSameAs(imageA, make('<a href="' + pngA + '"></a>')).equal === true,
      "the same data: URL on two nodes must still be equal");
    // A blob: URL cannot be read synchronously, so its own URL is its identity - and it is not
    // printed in full either.
    var blob = waProbeFingerprint(make('<a href="blob:http://127.0.0.1/8f4a-11ee"></a>')).attrs.href;
    var blobB = waProbeFingerprint(make('<a href="blob:http://127.0.0.1/8f4a-11ff"></a>')).attrs.href;
    check(/^blob:,len=\d+,h=[0-9a-f]{8}$/.test(blob) && blob !== blobB,
      "two different blob: URLs must collapse to different digests, saw " + blob + " / " + blobB);

    // 7. Bounds are reported, never silently applied. maxDepth first, then maxNodes, then a long
    //    attribute value (the other place a fingerprint could quietly get shorter).
    var deep = make('<div class="d0"><div class="d1"><div class="d2"><div class="d3"></div></div></div></div>');
    var bounded = waProbeFingerprint(deep, { maxDepth: 2 });
    check(bounded.truncated === undefined, "a node inside the depth bound must not claim truncation");
    check(!!bounded.children[0] && !!bounded.children[0].children[0],
      "the fingerprint must follow children up to maxDepth");
    check(bounded.children[0].children[0].truncated === true,
      "a node at maxDepth with children must report truncated:true, saw "
      + JSON.stringify(bounded.children[0].children[0].truncated));
    check(bounded.children[0].children[0].children.length === 0,
      "a truncated node must not report children below the bound");
    var leaf = waProbeFingerprint(make('<div class="leaf"></div>'), { maxDepth: 2 });
    check(leaf.truncated === undefined, "a node with no children must not be marked truncated");
    var wide = make('<div>' + new Array(61).join("<span></span>") + "</div>");
    var capped = waProbeFingerprint(wide, { maxNodes: 10 });
    check(capped.truncated === true, "a fingerprint cut by maxNodes must report truncated:true");
    check(countNodes(capped) <= 10, "maxNodes must bound the node count, saw " + countNodes(capped));
    check(countNodes(waProbeFingerprint(wide)) === 61, "and the same tree unbounded must be whole, saw "
      + countNodes(waProbeFingerprint(wide)));
    var long = waProbeFingerprint(make('<span title="' + new Array(201).join("x") + '"></span>'));
    check(long.attrs.title.length < 200 && /\.\.\.\+\d+$/.test(long.attrs.title),
      "an ordinary long value must truncate with its remainder named, saw " + long.attrs.title.length);

    // 8. A missing node is a divergence at the root with a clear label, and never a throw. This is
    //    the shape a probe hits when the subject path drew nothing at all.
    var threw = null;
    var missing = null;
    try { missing = waProbeSameAs(control, null); } catch (error) { threw = error; }
    check(threw === null, "comparing against a null node must not throw, threw: " + String(threw && threw.message));
    check(!!missing && missing.equal === false && missing.path === "(root)",
      "a null subject must diverge at (root), saw " + (missing && missing.path));
    check(!!missing && missing.subject === "<null node>",
      "a null subject must be labelled, saw " + JSON.stringify(missing && missing.subject));
    var absent = null;
    threw = null;
    try { absent = waProbeSameAs(control, undefined); } catch (error) { threw = error; }
    check(threw === null && !!absent && absent.equal === false && absent.subject === "<missing node>",
      "an absent subject must diverge at the root and be labelled, saw "
      + JSON.stringify(absent && { path: absent.path, subject: absent.subject }));
    var controlGone = null;
    threw = null;
    try { controlGone = waProbeSameAs(null, control); } catch (error) { threw = error; }
    check(threw === null && !!controlGone && controlGone.control === "<null node>" &&
      controlGone.subject === "div",
      "an absent control must be labelled and the surviving node named, saw "
      + JSON.stringify(controlGone && { control: controlGone.control, subject: controlGone.subject }));
    check(oneLine(waProbeDiff(missing)) && waProbeDiff(missing).indexOf("(root)") >= 0,
      "a missing node's message must be one line naming (root), saw " + waProbeDiff(missing));
    var notAnElement = null;
    threw = null;
    try { notAnElement = waProbeSameAs(control, "a string a probe passed by mistake"); } catch (error) { threw = error; }
    check(threw === null && !!notAnElement && notAnElement.equal === false &&
      String(notAnElement.subject).indexOf("not an element") >= 0,
      "a non-element subject must be refused as a labelled divergence, not a throw, saw "
      + (threw ? String(threw.message) : JSON.stringify(notAnElement && notAnElement.subject)));

    // 9. The default surface a probe may rely on: id and style ignored, classes and attribute names
    //    sorted, no text unless asked for.
    var surface = waProbeFingerprint(make('<div id="x" style="color:red" class="b a" data-z="1" aria-label="L"></div>'));
    check(surface.tag === "div", "the tag must be the lowercased tag name, saw " + JSON.stringify(surface.tag));
    check(surface.classes.join(",") === "a,b", "classes must be sorted, saw " + JSON.stringify(surface.classes));
    check(Object.keys(surface.attrs).join(",") === "aria-label,data-z",
      "default ignore is style and id, and attribute names are sorted, saw "
      + JSON.stringify(Object.keys(surface.attrs)));
    check(!("text" in surface), "text must be absent unless asked for, saw " + JSON.stringify(surface.text));
    var withText = waProbeFingerprint(make('<span class="t">  hello   world </span>'), { text: true });
    check(withText.text === "hello world",
      "text must be the collapsed text when asked for, saw " + JSON.stringify(withText.text));
    var noIgnore = waProbeFingerprint(make('<div id="x" class="a"></div>'), { ignore: [] });
    check(Object.keys(noIgnore.attrs).join(",") === "id",
      "ignore:[] must keep every attribute, saw " + JSON.stringify(Object.keys(noIgnore.attrs)));

    // 10. The failure message: one line, naming the path and both values, not a wall of HTML.
    var line = waProbeDiff(childClass);
    measured.line = line;
    check(oneLine(line), "the diff message must be a single line, saw " + JSON.stringify(line));
    check(line.indexOf("children[0].classes") >= 0 && line.indexOf("control") >= 0 &&
      line.indexOf("subject") >= 0,
      "the diff message must name the path and both sides, saw " + JSON.stringify(line));

    result = {
      status: problems.length ? "fail" : "pass",
      text: problems.length ? "FAIL: " + problems.join(" ;; ")
        : "PASS: the shared fingerprint helper is injected before every probe and distinguishes what a"
          + " probe must distinguish - identical nodes equal; a changed class at `classes` (a child's at"
          + " `children[i].classes`), a changed attribute at `attrs.<name>`, a reordered child at"
          + " `children[i].<field>`, and two different data: payloads of the SAME length (digest "
          + measured.digest + "); bounds reported as truncated:true at maxDepth/maxNodes; a missing node"
          + " a labelled (root) divergence that never throws; and one-line failures: " + measured.line,
    };
  } catch (error) {
    result = { status: "fail", text: "probe threw: " + (error && (error.stack || error.message || error)) };
  }

  var pre = document.createElement("pre");
  pre.id = "wa-probe";
  pre.setAttribute("data-status", result.status);
  pre.textContent = result.text;
  document.body.append(pre);
})();
