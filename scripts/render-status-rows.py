#!/usr/bin/env python3
"""THE EYE TEST FOR THE STATUS ROWS (change/icons-box item 4, Victor 22/11).

The numbers in scripts/test-status-icon-metrics.py prove the box is even; only an eye can say whether
18% of a cell is the right GAP beside a digit. This script draws both status rows from REAL FONT FILES -
the wa Icons committed on main 57551064, the one this branch ships, and two more bearings the builder can
produce (14% and 24%) - at the terminal's real size and at 4x, into one PNG per candidate.

WHY IT BUILDS THE CANDIDATES: the 14% and 24% pictures must be the pixels of a font the builder really
made, not a drawing of what it would have made. So each candidate is a full rebuild through
scripts/build-wa-icons.py's own geometry() and build() (the source archive comes from the pinned cache,
re-hashed), and the "old" face is read out of git at the base commit.

WHAT IT DRAWS, and why these strings: they are the two rows as lua/core/cli_view.lua writes them -
  run      METHODS:run_numbers   icon + GAP + rounds + '.' + step clock + ' ' + delta/arrows + ' ' + clock + GAP + run clock + ' . ' + check + finish time
  session  M.session_summary     icon + GAP + runs + ' ' + sigma-up/down + ' ' + ball + GAP + pct/budget + ' ' + cache + GAP + percentage
with GAP = "" in the wa (glued) set, which is what this font is for, and a space where the Lua source
puts a literal one. The digits are JetBrains Mono's, the icons are wa Icons', exactly as foot draws them:
one baseline, one cell per glyph, the primary face's advance.

IT IS NOT A GATE TEST and is not wired into scripts/test.sh or scripts/fast.sh: it needs fontTools, PIL
and the network (or the pinned cache) and its answer is a picture a human judges. Nothing here decides
anything; scripts/test-status-icon-metrics.py does.

  python3 scripts/render-status-rows.py --out ~/Work/missions/icons-box/compare
  needs: fontTools + pillow (see the venv note in scripts/build-wa-icons.py)
"""
import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE_COMMIT = "57551064"
TEXT_FACE = os.path.join(ROOT, "assets/fonts/JetBrainsMono-Regular.ttf")

# The two rows, as cli_view.lua composes them. Icons are named by the codepoint the wa set carries; the
# text between them is the source's own.
STEPS, CLOCK, CHECK, TURNS, CACHE, BALL_EIGHTH = 0xF0DFA, 0xF051B, 0xF012C, 0xF0450, 0xF01BC, 0xF0A9E
RUN_ROW = [STEPS, "1\u00b712s", " \u0394\u21910", " \u21931.2k", " ", CLOCK, "0:25", " \u00b7 ", CHECK, "18:47"]
SESSION_ROW = [TURNS, "2", " \u03a3\u21911.1M \u03a3\u219314.5k", " ", BALL_EIGHTH, "6.5%/1.0M", " ", CACHE, "94.05%"]

# What each candidate is, and what its right bearing means in pixels at the terminal's size (9 pt at
# 96 dpi = a 12 px em, so one cell is 7.2 px and 1% of it is 0.072 px).
CANDIDATES = [
    ("01-old-a2", None, "the OLD font (main " + BASE_COMMIT + ", A2): every icon fills its cell, "
                        "right bearing 13.8% = 1.0 px, left bearing 0%..17.7%, two vertical boxes"),
    ("02-shipped-18", 18.0, "THE SHIPPED FONT: one box, right bearing 18% = 1.3 px, left >= 6%, "
                            "one centre on the digits' line"),
    ("03-candidate-14", 14.0, "candidate: right bearing 14% = 1.0 px (a tighter gap, closer to A2's)"),
    ("04-candidate-24", 24.0, "candidate: right bearing 24% = 1.7 px (a wider gap)"),
]

PT_SIZE = 9
DPI = 96
# foot's font=...:size=9 is 9 POINTS: at 96 dpi that is a 12 px em, and one cell of JetBrains Mono is
# 0.600 em = 7.2 px - the size the rows are really drawn at on this laptop. 72 px per inch is what
# turns a point into a pixel; 96 is the dpi.
EM_PX = PT_SIZE * DPI / 72          # 12 px em, 7.2 px cell
SCALES = [(1, EM_PX), (4, EM_PX * 4)]


def builder():
    """scripts/build-wa-icons.py as a module: the geometry and the build are ITS numbers, not copies."""
    path = os.path.join(ROOT, "scripts", "build-wa-icons.py")
    spec = importlib.util.spec_from_file_location("build_wa_icons", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def base_font(tmp):
    """The wa Icons face committed on the base commit, straight out of git."""
    path = os.path.join(tmp, "waIcons-base.ttf")
    with open(path, "wb") as handle:
        result = subprocess.run(["git", "-C", ROOT, "show", BASE_COMMIT + ":assets/fonts/waIcons-Regular.ttf"],
                                stdout=handle)
    if result.returncode != 0:
        sys.exit("refused: git cannot read assets/fonts/waIcons-Regular.ttf at %s" % BASE_COMMIT)
    return path


def render(row, icons_path, em_px, mono, wa, cell_px, draw, x0, baseline):
    """One row, glyph by glyph: one cell each, the primary face's advance, one baseline - as foot draws it."""
    from fontTools.ttLib import TTFont
    from PIL import ImageFont

    faces = {}
    at = x0
    for part in row:
        if isinstance(part, int):
            face = wa if part in wa else mono
            font = faces.setdefault(icons_path if face is wa else TEXT_FACE,
                                    ImageFont.truetype(icons_path if face is wa else TEXT_FACE,
                                                       int(round(em_px))))
            draw.text((at, baseline), chr(part), font=font, fill=(232, 232, 232), anchor="ls")
            at += cell_px
        else:
            for character in part:
                font = faces.setdefault(TEXT_FACE, ImageFont.truetype(TEXT_FACE, int(round(em_px))))
                draw.text((at, baseline), character, font=font, fill=(232, 232, 232), anchor="ls")
                at += cell_px
    return at


def main():
    parser = argparse.ArgumentParser(description="Draw the two status rows from real font files.")
    parser.add_argument("--out", required=True, help="directory the PNGs are written into")
    parser.add_argument("--cache", default=os.path.join(os.path.expanduser("~"), ".cache", "wa-icons"),
                        help="the pinned archives (re-hashed on every use)")
    args = parser.parse_args()

    from PIL import Image, ImageDraw, ImageFont
    from fontTools.ttLib import TTFont

    build_module = builder()
    os.makedirs(args.out, exist_ok=True)
    mono = set(TTFont(TEXT_FACE).getBestCmap())
    cell_em = 600 / 1000.0                      # JetBrains Mono's advance, in em

    with tempfile.TemporaryDirectory() as tmp:
        source_fonts = {}
        source_fonts["01-old-a2"] = base_font(tmp)
        staging = os.path.join(tmp, "symbols-source.ttf")
        with open(staging, "wb") as handle:
            handle.write(build_module.extract("symbols", "SymbolsNerdFontMono-Regular.ttf", args.cache))
        for name, right, _ in CANDIDATES:
            if name in source_fonts:
                continue
            out = os.path.join(tmp, name + ".ttf")
            build_module.build(staging, out, build_module.geometry(right))
            problems = build_module.verify(out, build_module.geometry(right))
            if problems:
                sys.exit("refused: the %s candidate does not hold its own box: %s" % (name, "; ".join(problems)))
            source_fonts[name] = out

        for name, right, caption in CANDIDATES:
            icons_path = source_fonts[name]
            wa = set(TTFont(icons_path).getBestCmap())
            # The image is sized from the widest row at 4x, so no row is ever clipped.
            cells = max(sum(1 if isinstance(part, int) else len(part) for part in row)
                        for row in (RUN_ROW, SESSION_ROW))
            line_at = lambda em: int(round(em * (1020 + 300) / 1000))
            width = int(round(cells * cell_em * EM_PX * 4)) + 48
            first, second = 60, 60 + 2 * line_at(EM_PX) + 60
            height = second + 2 * line_at(EM_PX * 4) + 40
            image = Image.new("RGB", (width, height), (24, 24, 27))
            draw = ImageDraw.Draw(image)
            label = ImageFont.truetype(TEXT_FACE, 14)
            draw.text((16, 12), caption, font=label, fill=(200, 200, 200))
            for scale, em_px in SCALES:
                cell_px = cell_em * em_px
                line = line_at(em_px)
                top = first if scale == 1 else second
                draw.text((16, top - 20), "%dx (%d px em, cell %.1f px)" % (scale, round(em_px), cell_px),
                          font=label, fill=(120, 180, 240))
                # The digits' baseline sits cap-height below the row's top: em * ascender / 1000.
                baseline = top + int(round(em_px * 1020 / 1000))
                render(RUN_ROW, icons_path, em_px, mono, wa, cell_px, draw, 24, baseline)
                render(SESSION_ROW, icons_path, em_px, mono, wa, cell_px, draw, 24, baseline + line)
            path = os.path.join(args.out, name + ".png")
            image.save(path)
            print("wrote %s (%dx%d)" % (path, width, height))

    print("\nthe four pictures: right bearing %s. The number that ships is 18%%."
          % ", ".join(str(right) if right else "13.8 (old)" for _, right, _ in CANDIDATES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
