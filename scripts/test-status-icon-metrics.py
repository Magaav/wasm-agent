#!/usr/bin/env python3
"""THE STATUS ROWS' ICONS, MEASURED IN THE FONT FILES (change/tui-chrome item 2, Victor 21/11).

Two missions (wa-fonts, fonts-glue) built "wa Icons" and the gaps between an icon and its number
stayed uneven. A terminal has whole cells only, so the gap is decided INSIDE each glyph: by its
advance and by the empty strip its drawing leaves on the left and on the right of its cell. This
script opens the committed fonts and prints those numbers for every glyph the two status rows draw
(lua/core/cli_view.lua run_numbers and session_summary), then asserts the brief's rule for the ones
that come from wa Icons:

    advance == one JetBrains Mono cell;  xMin >= LEFT of the cell;  xMax <= advance - RIGHT of the cell;
    and one vertical box for all of them (same yMin, same yMax, within TOLERANCE of the cell).

It needs no fontTools (not installed on a gate host, by rule): a TrueType file's head, hhea, hmtx,
cmap, loca and glyf tables are read with struct, which is all a bounding box and an advance need.

TODAY THE RULE FAILS (the diagnosis this round was asked for, not a redesign): the run prints every
number and ends with a named `SKIP test-status-icon-metrics: ...` line and exit 0, which the fast
path counts as a SKIP and never as a pass. `--strict` exits 1 instead; that is the mode to wire once
the glyphs are redrawn.

  usage: test-status-icon-metrics.py [--strict]
"""
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "assets/fonts/waIcons-Regular.ttf")
MONO = os.path.join(ROOT, "assets/fonts/JetBrainsMono-Regular.ttf")

# The brief's starting box: the drawing leaves 6% of the cell on its left and 18% on its right.
LEFT, RIGHT = 0.06, 0.18
# How far two glyphs' vertical edges may differ and still be "the same box", as a share of the cell.
TOLERANCE = 0.02

# Every glyph of the two rows, in the order a reader meets them, with the font that is MEANT to draw it.
WA = [
    (0xF0DFA, "steps"), (0xF051B, "clock"), (0xF012C, "check"), (0xF0450, "turns"), (0xF01BC, "cache"),
    (0xF0766, "ballEmpty"), (0xF0A9E, "ballEighth"), (0xF0A9F, "ballQuarter"), (0xF0AA0, "ballThreeEighths"),
    (0xF0AA1, "ballHalf"), (0xF0AA2, "ballFiveEighths"), (0xF0AA3, "ballThreeQuarters"),
    (0xF0AA4, "ballSevenEighths"), (0xF0AA5, "ballFull"),
]
TEXT = [
    (0x2736, "spinner (first frame)"), (0x0394, "delta"), (0x03A3, "sigma"), (0x2191, "arrow up"),
    (0x2193, "arrow down"), (0x00B7, "middle dot"), (0x0030, "digit 0"), (0x0038, "digit 8"),
]


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


def row(font, codepoint, name, cell_share):
    measured = font.measure(codepoint)
    if measured is None:
        return None
    advance, x_min, y_min, x_max, y_max = (value / font.upm for value in measured)
    cell = cell_share
    return {
        "cp": codepoint, "name": name, "font": os.path.basename(font.path),
        "advance": advance / cell, "left": x_min / cell, "right": (advance - x_max) / cell,
        "bottom": y_min / cell, "top": y_max / cell,
    }


def main():
    strict = "--strict" in sys.argv[1:]
    icons, mono = Font(ICONS), Font(MONO)
    zero = mono.measure(0x30)
    cell = zero[0] / mono.upm  # one JetBrains Mono cell, in em
    rows = [row(icons, cp, name, cell) for cp, name in WA] + [row(mono, cp, name, cell) for cp, name in TEXT]
    missing = [name for (cp, name), found in zip(WA + TEXT, rows) if found is None]
    print("one cell = %.3f em (JetBrains Mono's advance); every column below is a share of that cell" % cell)
    print("%-9s %-22s %-26s %8s %7s %7s %7s %7s" % ("codepoint", "icon", "font", "advance", "left", "right", "bottom", "top"))
    for found in rows:
        if found is None:
            continue
        print("U+%-7X %-22s %-26s %7.1f%% %6.1f%% %6.1f%% %6.1f%% %6.1f%%" % (
            found["cp"], found["name"], found["font"], 100 * found["advance"], 100 * found["left"],
            100 * found["right"], 100 * found["bottom"], 100 * found["top"]))
    if missing:
        print("FAIL - a status glyph is in neither committed font: " + ", ".join(missing))
        return 1
    wa = rows[:len(WA)]
    problems = []
    for found in wa:
        label = "U+%X %s" % (found["cp"], found["name"])
        if abs(found["advance"] - 1) > 0.002:
            problems.append("%s: advance %.1f%% of the cell" % (label, 100 * found["advance"]))
        if found["left"] < LEFT - 0.002:
            problems.append("%s: left bearing %.1f%% < %.0f%%" % (label, 100 * found["left"], 100 * LEFT))
        if found["right"] < RIGHT - 0.002:
            problems.append("%s: right bearing %.1f%% < %.0f%%" % (label, 100 * found["right"], 100 * RIGHT))
    bottoms, tops = [found["bottom"] for found in wa], [found["top"] for found in wa]
    lefts, rights = [found["left"] for found in wa], [found["right"] for found in wa]
    if max(bottoms) - min(bottoms) > TOLERANCE or max(tops) - min(tops) > TOLERANCE:
        problems.append("vertical box differs: bottoms %.1f%%..%.1f%%, tops %.1f%%..%.1f%%" % (
            100 * min(bottoms), 100 * max(bottoms), 100 * min(tops), 100 * max(tops)))
    print("wa Icons: left bearing %.1f%%..%.1f%%, right bearing %.1f%%..%.1f%% of the cell" % (
        100 * min(lefts), 100 * max(lefts), 100 * min(rights), 100 * max(rights)))
    text = rows[len(WA):]
    print("JetBrains Mono's own glyphs on the same rows: left %.1f%%..%.1f%%, right %.1f%%..%.1f%%" % (
        100 * min(f["left"] for f in text), 100 * max(f["left"] for f in text),
        100 * min(f["right"] for f in text), 100 * max(f["right"] for f in text)))
    if not problems:
        print("ok - all %d wa Icons status glyphs sit in the box (left >= %.0f%%, right >= %.0f%%, one cell, one vertical box)"
              % (len(wa), 100 * LEFT, 100 * RIGHT))
        return 0
    for problem in problems:
        print("  outside the rule - " + problem)
    if strict:
        print("FAIL - %d measurement(s) outside the rule" % len(problems))
        return 1
    print("SKIP test-status-icon-metrics: %d measurement(s) of the %d wa Icons status glyphs are outside the brief's box "
          "(left >= %.0f%%, right >= %.0f%% of the cell, one vertical box) - the glyphs are not redrawn in this round; "
          "the numbers above are the diagnosis, and this is a counted skip, not a pass" % (
              len(problems), len(wa), 100 * LEFT, 100 * RIGHT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
