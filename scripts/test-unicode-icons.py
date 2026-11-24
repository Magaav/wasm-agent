#!/usr/bin/env python3
"""THE UNICODE ICON SET, MEASURED IN FONT FILES (item 7, Victor 23/11).

Victor on the work node's spaced icons: "that is horrible ... our quality should be the same everywhere".
The unicode set is what a terminal draws when wa Icons is not known to be there, so every glyph in it has
to be ONE CELL WIDE and PRESENT in the monospace faces a stock machine has - otherwise the terminal takes
the glyph from a fallback face (another size), or a CJK-locale terminal spends two cells on it and every
number after it moves.

WHAT THIS MEASURES, per glyph of the set, and it refuses rather than passes when it cannot tell:

  * East Asian Width Narrow or Neutral - NEVER Ambiguous (a CJK locale may draw it double), never Wide or
    Fullwidth, and never a codepoint with emoji presentation (the block below names the ranges);
  * PRESENT in the stock monospace families of the machine - read from the font FILES, not guessed: the
    cmap of each face, through fontconfig's answer for the family;
  * ONE CELL: the glyph's advance equals that face's own cell (the advance of `M`), measured in the same
    hmtx table.

A family that is not installed here (DejaVu Sans Mono, Menlo, Consolas, Cascadia Code on this node) is
NAMED as unmeasured in the output and never counted as a pass: this row cannot claim a font it cannot
open. The set's glyphs are ASCII, Latin-1 or squares/circles those faces carry, which is the reason it is
allowed to stand while they are absent - said plainly, not hidden.

No fontTools (not installed on a gate host, by rule): head, hhea, hmtx and cmap are read with struct.

  usage: python3 scripts/test-unicode-icons.py [--root <tree>] [--quiet]
  exit: 0 every measurable rule held; 1 a glyph failed a rule; 3 the set itself could not be read.
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The families a stock monospace machine has, and the ones this row asks for by name in Victor's brief.
FAMILIES = ["JetBrains Mono", "Liberation Mono", "Noto Sans Mono", "Adwaita Mono",
            "DejaVu Sans Mono", "Menlo", "Consolas", "Cascadia Code"]

# Emoji presentation lives here; a glyph from one of these ranges is never one cell in every terminal.
EMOJI = [(0x1F000, 0x1FAFF), (0x2600, 0x27BF), (0x2B00, 0x2BFF), (0xFE00, 0xFE0F), (0x1F1E6, 0x1F1FF)]


def unicode_table(path):
    """The `unicode` set out of lua/core/icons.lua: its glyphs, decoded from the octal escapes the file
    writes (so this row reads the SAME table the rows draw, never a copy that can drift)."""
    text = open(path, encoding="utf-8").read()
    start = text.find("  unicode = {")
    if start < 0:
        return None
    end = text.find("  },", start)
    if end < 0:
        return None
    block = text[start:end]
    glyphs = {}
    for name, raw in re.findall(r'^\s*(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', block, re.M):
        if name == "gap":
            continue
        glyphs[name] = lua_string(raw)
    return glyphs


def lua_string(raw):
    """One Lua string literal's bytes: `\226\150\171` is three BYTES of one UTF-8 character, and
    reading it as a Python escape is how a glyph turns into two (measured while writing this row)."""
    out = bytearray()
    index = 0
    while index < len(raw):
        ch = raw[index]
        if ch == "\\" and index + 1 < len(raw) and raw[index + 1].isdigit():
            digits = ""
            at = index + 1
            while at < len(raw) and len(digits) < 3 and raw[at].isdigit():
                digits += raw[at]
                at += 1
            # Lua's \ddd is DECIMAL (up to three digits), not octal: \128 is 128, not 0o128.
            out.append(int(digits, 10) & 0xFF)
            index = at
            continue
        if ch == "\\" and index + 1 < len(raw):
            out.extend(raw[index + 1].encode("utf-8"))
            index += 2
            continue
        out.extend(ch.encode("utf-8"))
        index += 1
    return bytes(out).decode("utf-8")


def font_file(family):
    out = subprocess.run(["fc-match", "-f", "%{file}%{family}", family], capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        return None, None
    answer = out.stdout.strip()
    # fc-match answers with a substitute when the family is absent ("JetBrainsMonoNerdFont") - a font that
    # is not the one asked for is NOT that family's measurement.
    at = answer.rfind(".", 0, len(answer) - 4)
    path = answer
    for ext in (".ttf", ".otf", ".ttc"):
        cut = answer.lower().rfind(ext)
        if cut >= 0:
            path = answer[:cut + len(ext)]
            break
    else:
        return None, None
    families = answer[len(path):].split(",")
    return path, [f.strip() for f in families]


def tables(data):
    count = struct.unpack(">H", data[4:6])[0]
    out = {}
    for index in range(count):
        at = 12 + index * 16
        tag = data[at:at + 4].decode("latin-1")
        start, length = struct.unpack(">II", data[at + 8:at + 16])
        out[tag] = (start, length)
    return out


def cmap_of(data, tab):
    start = tab["cmap"][0]
    count = struct.unpack(">H", data[start + 2:start + 4])[0]
    best = None
    for index in range(count):
        at = start + 4 + index * 8
        platform, encoding, offset = struct.unpack(">HHI", data[at:at + 8])
        sub = start + offset
        fmt = struct.unpack(">H", data[sub:sub + 2])[0]
        if fmt == 12 and (platform, encoding) in ((3, 10), (0, 4), (0, 6)):
            best = (12, sub)
            break
        if fmt == 4 and (platform, encoding) in ((3, 1), (0, 3), (0, 1)) and best is None:
            best = (4, sub)
    if not best:
        return {}
    fmt, sub = best
    glyphs = {}
    if fmt == 4:
        segx2 = struct.unpack(">H", data[sub + 6:sub + 8])[0]
        segs = segx2 // 2
        ends = struct.unpack(">%dH" % segs, data[sub + 14:sub + 14 + segx2])
        starts = struct.unpack(">%dH" % segs, data[sub + 16 + segx2:sub + 16 + 2 * segx2])
        deltas = struct.unpack(">%dh" % segs, data[sub + 16 + 2 * segx2:sub + 16 + 3 * segx2])
        offpos = sub + 16 + 3 * segx2
        ranges = struct.unpack(">%dH" % segs, data[offpos:offpos + segx2])
        for index in range(segs):
            if starts[index] == 0xFFFF:
                continue
            for cp in range(starts[index], min(ends[index], 0xFFFF) + 1):
                if ranges[index] == 0:
                    glyph = (cp + deltas[index]) & 0xFFFF
                else:
                    at = offpos + index * 2 + ranges[index] + (cp - starts[index]) * 2
                    if at + 2 > len(data):
                        continue
                    glyph = struct.unpack(">H", data[at:at + 2])[0]
                    if glyph:
                        glyph = (glyph + deltas[index]) & 0xFFFF
                if glyph:
                    glyphs[cp] = glyph
    else:
        groups = struct.unpack(">I", data[sub + 12:sub + 16])[0]
        for index in range(groups):
            at = sub + 16 + index * 12
            first, last, base = struct.unpack(">III", data[at:at + 12])
            for cp in range(first, last + 1):
                glyphs[cp] = base + (cp - first)
    return glyphs


class Face:
    def __init__(self, family):
        path, names = font_file(family)
        self.family = family
        self.path = path
        self.present = bool(path) and names is not None and any(n == family for n in names)
        if not self.present:
            return
        data = open(path, "rb").read()
        tab = tables(data)
        self.cmap = cmap_of(data, tab)
        head = tab["head"][0]
        self.upem = struct.unpack(">H", data[head + 18:head + 20])[0]
        hhea = tab["hhea"][0]
        self.hmetrics = struct.unpack(">H", data[hhea + 34:hhea + 36])[0]
        self.hmtx = tab["hmtx"][0]
        self.data = data

    def advance(self, cp):
        glyph = self.cmap.get(cp)
        if glyph is None:
            return None
        index = min(glyph, self.hmetrics - 1)
        return struct.unpack(">H", self.data[self.hmtx + index * 4:self.hmtx + index * 4 + 2])[0]

    def cell(self):
        return self.advance(ord("M"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=ROOT)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    glyphs = unicode_table(os.path.join(args.root, "lua/core/icons.lua"))
    if not glyphs:
        print("unicode-icons: refused(set_unreadable): the unicode table could not be read from lua/core/icons.lua")
        return 3
    faces = [Face(family) for family in FAMILIES]
    measured = [face for face in faces if face.present]
    absent = [face.family for face in faces if not face.present]
    failures = 0
    if not args.quiet:
        print("unicode-icons: %d glyphs, %d faces measured, %d named unmeasured" % (len(glyphs), len(measured), len(absent)))
        print("  measured: " + (", ".join("%s (cell %d/%d)" % (f.family, f.cell(), f.upem) for f in measured) or "none"))
        print("  unmeasured (not installed here): " + (", ".join(absent) or "none"))
    for name in sorted(glyphs):
        glyph = glyphs[name]
        if len(glyph) != 1:
            print("FAIL unicode.%s is one character (%r)" % (name, glyph))
            failures += 1
            continue
        cp = ord(glyph)
        width = unicodedata.east_asian_width(glyph)
        if width not in ("N", "Na"):
            print("FAIL unicode.%s U+%04X is East-Asian-%s: a CJK locale may draw it two cells wide" % (name, cp, width))
            failures += 1
        for first, last in EMOJI:
            if first <= cp <= last:
                print("FAIL unicode.%s U+%04X is in the emoji range U+%04X..U+%04X" % (name, cp, first, last))
                failures += 1
                break
        for face in measured:
            advance = face.advance(cp)
            if advance is None:
                print("FAIL unicode.%s U+%04X is NOT in %s" % (name, cp, face.family))
                failures += 1
            elif advance != face.cell():
                print("FAIL unicode.%s U+%04X is %d/%d of a cell in %s, not one cell" % (name, cp, advance, face.cell(), face.family))
                failures += 1
    if not measured:
        print("unicode-icons: refused(no_font_measured): no family of the list is installed, so nothing was measured")
        return 3
    print("unicode-icons: %s (%d glyphs, %d failures, %d families unmeasured: %s)" % (
        "ok" if failures == 0 else "FAILED", len(glyphs), failures, len(absent), ", ".join(absent) or "none"))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
