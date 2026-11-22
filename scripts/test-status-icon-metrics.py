#!/usr/bin/env python3
"""THE STATUS ROWS' ICONS, MEASURED IN THE FONT FILES (change/tui-chrome item 2, Victor 21/11;
the glyphs redrawn by change/icons-box, Victor 22/11).

Two missions (wa-fonts, fonts-glue) built "wa Icons" and the gap between an icon and its number stayed
wrong. A terminal has whole cells only, so that gap is decided INSIDE each glyph: by its advance and by
the empty strip its drawing leaves on the left and on the right of its cell. This script opens the
committed fonts and measures every glyph the two status rows draw (lua/core/cli_view.lua run_numbers and
session_summary), then asserts:

  for every wa Icons glyph the rows draw
    advance == ONE JetBrains Mono cell          (that is what "glued" means)
    right bearing == 18% of the cell            (the box's right edge - the ONE gap a following digit sees)
    left bearing  >=  6% of the cell            (foot clips a glyph that starts before its cell)
    the drawing fits the square box it was built into   (never squashed)
    centre == the digits' centre                (the same height line as the numbers)

  for every glyph of both rows, icons AND text
    one of wa's two faces draws it - none comes from a fallback font - and that face is named here.

THE FIFTH RULE IS A CORRECTION, and it is written down because it looks like a loosening: it used to be
"the same yMin and same yMax for all of them". A glyph fitted by ONE scale into a box cannot have both -
the check is wide and therefore short, the steps are tall and therefore narrow - so what is one box is
the CENTRE and the BOUNDS, and the font is what shrinks inside them.

WHEN IT WAS A MEASUREMENT ONLY (21/11) this printed the numbers and ended with a named SKIP: the glyphs
were not redrawn. THEY ARE (scripts/build-wa-icons.py, geometry()), so the SKIP, the --strict flag that
turned it into a failure and the fast path's grep for that line are all GONE: a violation is a failure
here, by default (scripts/fast.sh, check status-icon-metrics).

It needs no fontTools (not installed on a gate host, by rule): a TrueType file's head, hhea, hmtx, cmap,
loca and glyf tables are read with struct, which is all a bounding box and an advance need.

  usage: test-status-icon-metrics.py           the rules above; exit 1 when any of them does not hold
         test-status-icon-metrics.py --foot    ... and NAME, for every glyph, the family this machine's
                                               own foot config hands it, refusing one that is a fallback.
                                               Needs fontconfig and the operator's foot.ini: read-only,
                                               never edited, and off unless asked.
"""
import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "assets/fonts/waIcons-Regular.ttf")
MONO = os.path.join(ROOT, "assets/fonts/JetBrainsMono-Regular.ttf")
ICONS_FACE, MONO_FACE = "waIcons-Regular.ttf", "JetBrainsMono-Regular.ttf"

# The box, as the shares of the cell scripts/build-wa-icons.py builds with (RIGHT_BEARING_PCT there is
# the number the eye test ships). These are ASSERTED against the manifest's own statement of them, so a
# font rebuilt to other numbers cannot pass this script by moving the numbers in the manifest.
LEFT_PCT, RIGHT_PCT = 6.0, 18.0
# The coordinate rounding of a scaled outline, in percent of the cell - nothing else.
BEARING_TOL = 0.2
# "The same height line", measured on JetBrains Mono's own digits.
CENTRE_TOL = 2.0

# The nine context balls, in the order M.context_ball indexes them (empty first, full last).
BALLS = [(0xF0766, "ballEmpty"), (0xF0A9E, "ballEighth"), (0xF0A9F, "ballQuarter"),
         (0xF0AA0, "ballThreeEighths"), (0xF0AA1, "ballHalf"), (0xF0AA2, "ballFiveEighths"),
         (0xF0AA3, "ballThreeQuarters"), (0xF0AA4, "ballSevenEighths"), (0xF0AA5, "ballFull")]

# THE ICONS: the code points wa Icons carries, which are the ones the rows must draw from that face.
WA_CODEPOINTS = {0xF0DFA, 0xF051B, 0xF012C, 0xF0450, 0xF01BC} | {cp for cp, _ in BALLS}

# EVERY GLYPH OF BOTH ROWS, once, with the row(s) that draw it:
#   run     - METHODS:run_numbers: steps rounds.':step-clock' [delta up] [down] space clock run-clock
#             [. middle-dot check finish-time]     (M.finish_time writes 18:47, hence the colon)
#   session - M.session_summary: turns runs " sigma-up </> sigma-down" [ball pct/budget] [cache pct]
#   footer  - M.footer draws the same two facts (cache, ball) with the same glyphs, so it is listed
#             beside the session row: a glyph that leaves this table but stays in that function is a row
#             nobody measured.
ROW_GLYPHS = [
    (0xF0DFA, "steps", "run"),
    (0xF051B, "clock", "run"),
    (0xF012C, "check", "run"),
    (0x00B7, "middle dot", "run"),
    (0x0394, "delta", "run"),
    (0x2191, "arrow up", "run session"),
    (0x2193, "arrow down", "run session"),
    (0x003A, "colon", "run session"),
    (0xF0450, "turns", "session"),
    (0x03A3, "sigma", "session"),
    (0x0025, "percent", "session"),
    (0x002F, "slash", "session"),
    (0x002E, "period", "session"),
] + [(0x30 + digit, "digit %d" % digit, "run session") for digit in range(10)] \
  + [(0xF01BC, "cache", "session footer")] + [(cp, name, "session footer") for cp, name in BALLS]

# THE ANIMATED LINE ABOVE THEM (M.spinner's frames), listed because it is the same chrome and the same
# question - and MEASURED, not asserted: the two rows above are the subject of this file, and seven of
# these ten frames are not in JetBrains Mono at all, which is a finding for the report and a look change
# (which shapes the spinner cycles) that needs Victor's eye. Printed on every run, never hidden.
STATUS_LINE = [(0x2736, "spinner first frame"), (0x2733, "spinner"), (0x2737, "spinner"),
               (0x2738, "spinner"), (0x2739, "spinner"), (0x273A, "spinner"), (0x2726, "spinner"),
               (0x2727, "spinner"), (0x2022, "spinner"), (0x00B7, "spinner (also the separator)")]


class Font:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as handle:
            self.data = handle.read()
        count = struct.unpack(">H", self.data[4:6])[0]
        self.tables = {}
        for index in range(count):
            tag, _, offset, length = struct.unpack(">4sIII", self.data[12 + 16 * index:28 + 16 * index])
            self.tables[tag.decode("latin-1")] = (offset, length)
        head = self.table("head")
        self.upm = struct.unpack(">H", head[18:20])[0]
        self.long_loca = struct.unpack(">h", head[50:52])[0] == 1
        self.hmetrics = struct.unpack(">H", self.table("hhea")[34:36])[0]
        self.cmap = self.read_cmap()

    def table(self, tag):
        offset, length = self.tables[tag]
        return self.data[offset:offset + length]

    def read_cmap(self):
        cmap = self.table("cmap")
        mapping = {}
        count = struct.unpack(">H", cmap[2:4])[0]
        offsets = sorted({struct.unpack(">HHI", cmap[4 + 8 * i:12 + 8 * i])[2] for i in range(count)})
        for offset in offsets:
            fmt = struct.unpack(">H", cmap[offset:offset + 2])[0]
            if fmt == 12:
                groups = struct.unpack(">I", cmap[offset + 12:offset + 16])[0]
                for g in range(groups):
                    start, end, glyph = struct.unpack(">III", cmap[offset + 16 + 12 * g:offset + 28 + 12 * g])
                    for cp in range(start, end + 1):
                        mapping.setdefault(cp, glyph + cp - start)
            elif fmt == 4:
                seg = struct.unpack(">H", cmap[offset + 6:offset + 8])[0] // 2
                ends = struct.unpack(">%dH" % seg, cmap[offset + 14:offset + 14 + 2 * seg])
                base = offset + 16 + 2 * seg
                starts = struct.unpack(">%dH" % seg, cmap[base:base + 2 * seg])
                deltas = struct.unpack(">%dh" % seg, cmap[base + 2 * seg:base + 4 * seg])
                ranges_at = base + 4 * seg
                ranges = struct.unpack(">%dH" % seg, cmap[ranges_at:ranges_at + 2 * seg])
                for i in range(seg):
                    for cp in range(starts[i], ends[i] + 1):
                        if cp == 0xFFFF:
                            continue
                        if ranges[i] == 0:
                            glyph = (cp + deltas[i]) & 0xFFFF
                        else:
                            at = ranges_at + 2 * i + ranges[i] + 2 * (cp - starts[i])
                            glyph = struct.unpack(">H", cmap[at:at + 2])[0]
                            if glyph:
                                glyph = (glyph + deltas[i]) & 0xFFFF
                        if glyph:
                            mapping.setdefault(cp, glyph)
        return mapping

    def measure(self, codepoint):
        """(advance, xMin, yMin, xMax, yMax) in font units, or None when the font has no such glyph."""
        glyph = self.cmap.get(codepoint)
        if glyph is None:
            return None
        hmtx = self.table("hmtx")
        advance = struct.unpack(">H", hmtx[4 * min(glyph, self.hmetrics - 1):][:2])[0]
        loca = self.table("loca")
        if self.long_loca:
            start, end = struct.unpack(">II", loca[4 * glyph:4 * glyph + 8])
        else:
            start, end = (2 * value for value in struct.unpack(">HH", loca[2 * glyph:2 * glyph + 4]))
        if start == end:
            return (advance, 0, 0, 0, 0)
        x_min, y_min, x_max, y_max = struct.unpack(">hhhh", self.table("glyf")[start + 2:start + 10])
        return (advance, x_min, y_min, x_max, y_max)


def measure(font, codepoint, cell):
    """One glyph, every number this script talks about, in PERCENT OF ONE CELL."""
    found = font.measure(codepoint)
    if found is None:
        return None
    advance, x_min, y_min, x_max, y_max = (value / font.upm for value in found)
    return {
        "advance": 100 * advance / cell,
        "left": 100 * x_min / cell,
        "right": 100 * (advance - x_max) / cell,
        "bottom": 100 * y_min / cell,
        "top": 100 * y_max / cell,
        "width": 100 * (x_max - x_min) / cell,
        "height": 100 * (y_max - y_min) / cell,
        "centre": 100 * (y_min + y_max) / 2 / cell,
    }


# ---- the face that really draws each glyph on THIS machine (--foot) -------------------------------


def foot_families(path):
    """The families foot's own config asks for, in its order (foot takes the first face that has the
    glyph, then falls back to fontconfig). `include=` is followed one level, which is how Omarchy
    splits its foot.ini."""
    families, seen = [], set()
    todo = [path]
    while todo:
        current = todo.pop(0)
        if current in seen or not os.path.exists(current):
            continue
        seen.add(current)
        with open(current, "r", errors="replace") as handle:
            for line in handle:
                text = line.split("#", 1)[0].strip()
                if text.startswith("include"):
                    target = text.split("=", 1)[1].strip() if "=" in text else ""
                    todo.append(os.path.expanduser(target))
                elif text.startswith("font"):
                    value = text.split("=", 1)[1].strip() if "=" in text else ""
                    for item in value.split(","):
                        family = item.split(":", 1)[0].strip()
                        if family and family not in families:
                            families.append(family)
    return families


def fc_match(pattern):
    result = subprocess.run(["fc-match", "-f", "%{family}|%{file}", pattern],
                            capture_output=True, text=True, timeout=20)
    text = result.stdout.strip()
    family, _, path = text.partition("|")
    return (family or None), (path or None)


def foot_report(codepoints, fonts):
    """[(codepoint, name, verdict, kind)] - kind is "configured" or "fallback"."""
    families = foot_families(os.path.expanduser("~/.config/foot/foot.ini"))
    resolved = {}
    for family in families:
        _, path = fc_match(family)
        if path and os.path.exists(path):
            resolved[family] = path
    out = []
    for entry in codepoints:
        cp, name = entry[0], entry[1]
        verdict, kind = None, "fallback"
        for family in families:
            path = resolved.get(family)
            if not path:
                continue
            if path not in fonts:
                fonts[path] = Font(path)
            if fonts[path].measure(cp) is not None:
                verdict, kind = "%s (%s)" % (family, os.path.basename(path)), "configured"
                break
        if kind == "fallback":
            family, path = fc_match(":charset=%X" % cp)
            verdict = "FALLBACK -> %s (%s)" % (family, os.path.basename(path) if path else "nothing has it")
        out.append((cp, name, verdict, kind))
    return families, out


def main():
    foot = "--foot" in sys.argv[1:]
    icons, mono = Font(ICONS), Font(MONO)
    cell = mono.measure(0x30)[0] / mono.upm  # one JetBrains Mono cell, in em
    zero, eight = measure(mono, 0x30, cell), measure(mono, 0x38, cell)
    digits_centre = (zero["centre"] + eight["centre"]) / 2
    print("one cell = %.3f em (JetBrains Mono's advance); every column below is a percent of that cell"
          % cell)
    print("the digits' centre is at %.1f%% of the cell (0 and 8 measured), and the box is centred on it"
          % digits_centre)
    print("the box: advance one cell, right bearing %.1f%%, left bearing >= %.1f%%, one square inside"
          % (RIGHT_PCT, LEFT_PCT))

    problems = []
    manifest = os.path.join(ROOT, "assets/fonts/waIcons.json")
    try:
        with open(manifest) as handle:
            stated = json_load(handle.read()).get("box", {})
    except (OSError, ValueError) as error:
        stated = {}
        problems.append("the manifest %s is unreadable (%s), so the box this font was built with is "
                        "unknown" % (manifest, error))
    if not stated:
        # Unknown is not yes: a manifest that does not state the box cannot confirm it.
        problems.append("the manifest %s states no box, so the numbers this font was built to are "
                        "unknown" % manifest)
    else:
        for key, want in (("right_bearing_pct", RIGHT_PCT), ("left_bearing_pct", LEFT_PCT)):
            if abs((stated.get(key) if stated.get(key) is not None else -1) - want) > 1e-9:
                problems.append("the manifest says %s = %r, this script asserts %r: a font rebuilt to "
                                "other numbers must move this script, not the manifest"
                                % (key, stated.get(key), want))

    print("%-9s %-22s %-13s %-24s %8s %7s %7s %8s %7s" % (
        "codepoint", "glyph", "rows", "drawing face", "advance", "left", "right", "centre", "height"))
    drawn_from = {}
    measured = []
    for cp, name, rows in ROW_GLYPHS:
        for face_name, font in ((ICONS_FACE, icons), (MONO_FACE, mono)):
            found = measure(font, cp, cell) if font.measure(cp) is not None else None
            if found is not None:
                break
        if found is None:
            print("U+%-7X %-22s %-13s %-24s %8s" % (cp, name, rows, "NEITHER wa face", "-"))
            problems.append("U+%04X %s is in neither of wa's faces, so foot draws it from a fallback font"
                            % (cp, name))
            continue
        drawn_from.setdefault(face_name, []).append(name)
        print("U+%-7X %-22s %-13s %-24s %7.1f%% %6.1f%% %6.1f%% %7.1f%% %6.1f%%" % (
            cp, name, rows, face_name, found["advance"], found["left"], found["right"],
            found["centre"], found["height"]))
        if abs(found["advance"] - 100) > BEARING_TOL:
            problems.append("U+%04X %s advances %.1f%% of the cell: an icon or a letter is ONE cell"
                            % (cp, found["advance"]))
        if cp in WA_CODEPOINTS:
            measured.append((cp, name, found))
            if abs(found["right"] - RIGHT_PCT) > BEARING_TOL:
                problems.append("U+%04X %s right bearing %.1f%% of the cell, the box says %.0f%%"
                                % (cp, name, found["right"], RIGHT_PCT))
            if found["left"] < LEFT_PCT - BEARING_TOL:
                problems.append("U+%04X %s left bearing %.1f%% < %.0f%% - foot clips it"
                                % (cp, name, found["left"], LEFT_PCT))
            if found["width"] > 100 - LEFT_PCT - RIGHT_PCT + BEARING_TOL * 2:
                problems.append("U+%04X %s is %.1f%% wide, outside its %.0f%% box"
                                % (cp, name, found["width"], 100 - LEFT_PCT - RIGHT_PCT))
            if found["height"] > 100 - LEFT_PCT - RIGHT_PCT + BEARING_TOL * 2:
                problems.append("U+%04X %s is %.1f%% tall, outside its square box"
                                % (cp, name, found["height"]))
            if abs(found["centre"] - digits_centre) > CENTRE_TOL:
                problems.append("U+%04X %s is centred at %.1f%%, the digits at %.1f%%"
                                % (cp, name, found["centre"], digits_centre))

    if measured:
        rights = [found["right"] for _, _, found in measured]
        lefts = [found["left"] for _, _, found in measured]
        centres = [found["centre"] for _, _, found in measured]
        print("wa Icons: right bearing %.1f%%..%.1f%%, left bearing %.1f%%..%.1f%%, centre %.1f%%..%.1f%% "
              "(%d glyphs)" % (min(rights), max(rights), min(lefts), max(lefts),
                               min(centres), max(centres), len(measured)))
    print("each row glyph's face, as the font files answer: " + "; ".join(
        "%d from %s" % (len(names), face) for face, names in sorted(drawn_from.items())))

    # THE LINE ABOVE THE ROWS, measured and named (not asserted - see STATUS_LINE).
    frames = []
    for cp, name in STATUS_LINE:
        face = ICONS_FACE if icons.measure(cp) is not None else (
            MONO_FACE if mono.measure(cp) is not None else None)
        frames.append((cp, name, face))
    outside = [(cp, name) for cp, name, face in frames if face is None]
    print("the animated status line's frames: %d of %d are drawn by %s, %d by no wa face (%s)" % (
        len(frames) - len(outside), len(frames), MONO_FACE, len(outside),
        ", ".join("U+%04X" % cp for cp, _ in outside) or "none"))

    if foot:
        families, report = foot_report(ROW_GLYPHS + STATUS_LINE, {})
        if not families:
            problems.append("--foot: %s names no font, so the face foot really draws is unknown"
                            % os.path.expanduser("~/.config/foot/foot.ini"))
        else:
            print("foot asks for, in this order: " + ", ".join(families))
            print("%-9s %-22s %-13s %s" % ("codepoint", "glyph", "rows", "the face foot draws it with"))
            for (cp, name, verdict, kind) in report:
                rows = {glyph[0]: glyph[2] for glyph in ROW_GLYPHS}.get(cp, "status line")
                print("U+%-7X %-22s %-13s %s" % (cp, name, rows, verdict))
                if kind == "fallback" and cp not in {frame[0] for frame in STATUS_LINE}:
                    problems.append("U+%04X %s is drawn by a fallback face in foot: %s" % (cp, name, verdict))

    if problems:
        for problem in problems:
            print("  outside the rule - " + problem)
        print("FAIL - %d measurement(s) outside the rule" % len(problems))
        return 1
    print("ok - %d wa Icons status glyphs in one box (right %.0f%%, left >= %.0f%%, centre %.1f%%), and "
          "every glyph of both rows drawn by one of wa's own faces" % (
              len(measured), RIGHT_PCT, LEFT_PCT, digits_centre))
    return 0


def json_load(text):
    import json
    return json.loads(text)


if __name__ == "__main__":
    sys.exit(main())
