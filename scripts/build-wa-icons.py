#!/usr/bin/env python3
"""Build and ship wa's two fonts: "wa Icons" and JetBrains Mono.

Victor's decision (19/11 ~10:00, _specs/wa-icons-A2/decision-19-11.md): wa's look is JetBrains Mono for
text plus "wa Icons" for the glyphs wa draws, each icon advancing exactly ONE cell of JetBrains Mono's
grid with the value GLUED to it (no space). The geometry INSIDE that cell is the box in geometry()
below - one scale for both axes, 6% of the cell free on the drawing's left and 18% on its right,
centred on the capitals. It is the 22/11 correction of the "A2" layout that filled the cell (the
comment above the constants says what A2 measured wrong, and docs/missions/reports/icons-box.md says
why), and this script is the approved prototype (_specs/wa-icons-A2/waicons-build.py) made
reproducible: every source is downloaded from a pinned
release and checked against a pinned sha256 before a byte of it is used, every number is a named
constant below, and two builds of the same inputs are byte-identical (fixed timestamps, dropped foundry
tables, one subsetting pass with shaping disabled).

WHY A SCRIPT AND NOT A HAND-MADE FILE: a font is a derived artifact. Its inputs are the source font,
the code points wa draws and the geometry numbers below; any of them can be wrong in a way the eye
forgives and a cell width does not - which is why tests/test-wa-fonts.mjs parses the COMMITTED font and
asserts those numbers, instead of trusting the bytes in the repo.

  usage: build-wa-icons.py --out assets/fonts        build wa Icons + ship JetBrains Mono, licences, webfonts
         build-wa-icons.py --check                  verify the committed fonts' metrics, manifest and hashes
         build-wa-icons.py --check --sources        ... and re-download/re-hash the pinned archives
         build-wa-icons.py --verify-font <path>     verify ONE font file, no sources needed

fontTools is needed to BUILD and is not installed system-wide, by rule: never
sudo, never system pip:

  python3 -m venv .venv && .venv/bin/pip install fonttools
  .venv/bin/python scripts/build-wa-icons.py

--check and --verify-font also need fontTools (it is what parses a font); they never need the network.
Change a pinned sha256 only with the release notes in front of you, and say why in the commit.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import zipfile

# ---- the pinned inputs ---------------------------------------------------------------------------
#
# Both archives are release ASSETS of a tagged release, not branches: a tag can be moved, an asset's
# bytes cannot change without its zip sha256 changing, and that is checked on every use (a cache
# directory is shared space - a file that arrived yesterday is not evidence about today). The
# per-member hashes pin the files actually read, so a rebuilt archive with different members is
# refused rather than silently shipped.
SOURCES = {
    "symbols": {
        "url": "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/NerdFontsSymbolsOnly.zip",
        "zip_sha256": "2078603c1e7a2fc2fa9e625ba1c30264d5d7c39907813d89beaa373f73a3a340",
        "version": "Nerd Fonts v3.3.0 (NerdFontsSymbolsOnly.zip)",
        "licence": "MIT, Copyright (c) 2014 Ryan L McIntyre",
        "licence_member": "LICENSE",
        "licence_sha256": "84a7a98c82140fb12c37fe42b93805baa16024cb3e5acc599b7ffe612c55d847",
        "members": {
            "SymbolsNerdFontMono-Regular.ttf": "7f14415832a929155c3d6d1c7d404fae00dfbfe4f1b29940e3736e6e790e3312",
        },
    },
    "jetbrains": {
        "url": "https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip",
        "zip_sha256": "6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf",
        "version": "JetBrains Mono v2.304",
        "licence": "SIL Open Font License 1.1, Copyright 2020 The JetBrains Mono Project Authors",
        "licence_member": "OFL.txt",
        "licence_sha256": "30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad",
        "members": {
            "fonts/ttf/JetBrainsMono-Regular.ttf": "a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f",
            "fonts/ttf/JetBrainsMono-Bold.ttf": "5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb",
        },
    },
}

# What ships beside the fonts. The licences travel WITH the bytes they cover - a bundle that carries a
# font and not its licence is a bundle nobody may redistribute.
SHIPPED_LICENCES = {
    "LICENSE-SymbolsNerdFont-MIT.txt": ("symbols", "licence_member"),
    "OFL-JetBrainsMono.txt": ("jetbrains", "licence_member"),
}

# ---- the glyphs wa draws -------------------------------------------------------------------------
#
# The code points lua/core/cli_view.lua's GLYPH table names, and ONLY those. tests/test-wa-fonts.mjs
# reads that table out of the Lua source and refuses a committed font whose set has drifted from it, so
# this list cannot quietly become a second opinion about what wa draws.
GLYPHS = [
    (0xF0DFA, "the run's steps"),
    (0xF051B, "the run's elapsed clock"),
    (0xF0450, "the session's turns"),
    (0xF01BC, "the cache-hit rate"),
    (0xF0766, "the empty context ball"),
    (0xF012C, "the finish stamp check (Victor, 19/11 ~10:50)"),
    # The prototype's list also carried md-check_circle (U+F05E0), its outline (U+F05E1) and
    # md-check_bold (U+F0E1E). No row draws them: the finish stamp is md-check, above. They are NOT
    # shipped - "only the glyphs wa draws" is the decision, and three unused outlines are dead weight in
    # every bundle - and tests/test-wa-fonts.mjs fails if the font and the GLYPH table ever disagree.
    (0xF0A9E, "context ball, 1 eighth"),
    (0xF0A9F, "context ball, 2 eighths"),
    (0xF0AA0, "context ball, 3 eighths"),
    (0xF0AA1, "context ball, 4 eighths"),
    (0xF0AA2, "context ball, 5 eighths"),
    (0xF0AA3, "context ball, 6 eighths"),
    (0xF0AA4, "context ball, 7 eighths"),
    (0xF0AA5, "context ball, 8 eighths (full)"),
]
CODEPOINTS = [cp for cp, _ in GLYPHS]

# ---- the cell, and THE BOX inside it, in JetBrains Mono's own units -------------------------------
#
# Measured from JetBrainsMono-Regular.ttf (not assumed): upm 1000, advance 600, cap height 730, hhea
# ascender 1020, descender -300. A terminal cell at size 9 is 600 units = 7.2 px wide, so 1 px is
# 600/7.2 = 83.33 units, rounded to 83 - the scale a reader needs to turn a share of the cell into
# pixels (18% of the cell is 1.3 px at size 9).
ADV_EM = 600
CELL_PX_AT_9 = 7.2
PX_UNITS = round(ADV_EM / CELL_PX_AT_9)   # 83 units = about 1 px at the terminal's size

# THE BOX (Victor, 22/11: "i thought i would wake up today and see icons correctly as i asked").
#
# WHAT WAS WRONG, measured on the A2 font this replaces (scripts/test-status-icon-metrics.py, main
# 57551064): A2 scaled each glyph by its LONGER side to 517 units (86.2% of the cell) and pinned its
# RIGHT edge 1 px inside the cell, so the RIGHT bearing was 13.8% for every icon while the LEFT bearing
# was whatever the aspect ratio left over - 0% for the check, the turns arrow and the ball, 17.7% for
# the steps - and a glyph's SIZE therefore depended on its shape (the ball was 86.2% of the cell in both
# directions, the check 86.2% wide and 66% tall, in a different vertical box: 27.8%..93.8% against
# 17.7%..103.9%). The digit that follows an icon leaves 11..13% of its own cell empty (JetBrains Mono's
# own left bearing), so at 13.8% icon and number were about a quarter of a cell apart, and the gap
# MOVED from icon to icon.
#
# THE RULE NOW: an icon advances ONE cell (the value stays glued); its drawing is fitted by ONE scale
# for both axes into a square BOX inside that cell; the box's RIGHT edge leaves RIGHT_BEARING_PCT of the
# cell empty, so the gap a following digit sees is now the same 18% for every icon; its LEFT edge leaves
# at least LEFT_BEARING_PCT (foot clips a glyph that starts before its cell - Victor, 19/11: shrink
# inwards only); and the box is centred on YMID, the capitals' centre, which is where the digits sit.
# A square glyph fills the box, a wide one (the check) is correctly SHORTER, a tall one (the steps) is
# correctly NARROWER: a glyph is never squashed, so "same vertical box" becomes "same CENTRE, inside the
# box" - a correction of the rule, not a loosening of it.
LEFT_BEARING_PCT = 6.0     # of the cell: the empty strip on the drawing's LEFT, at least
RIGHT_BEARING_PCT = 18.0   # of the cell: the empty strip on its RIGHT - THE SHIPPED NUMBER
CAP_HEIGHT = 730
X_HEIGHT = 550
YMID = CAP_HEIGHT / 2                     # 365: the visual middle of the capitals, where a digit sits
ASCENDER, DESCENDER = 1020, -300

# Written in the source font's own 2048-unit em, scaled once by K: re-quantising a 2048-unit outline
# into a 1000-unit em would spend rounding on every point for nothing.
UPEM_OUT = 2048
K = UPEM_OUT / 1000.0
ADVANCE = round(ADV_EM * K)               # 1229: ONE cell, which is what "glued" means
YMID_OUT = YMID * K                       # 747.5: the box's vertical centre


def geometry(right_bearing_pct=None):
    """THE BOX as numbers, derived from the two shares of the cell above.

    `right_bearing_pct` is the one knob and it exists for ONE reason: the eye test
    (scripts/render-status-rows.py) draws the rows at 14%, 18% and 24% from FONTS THIS FUNCTION CAN
    BUILD, so the pictures Victor judges are fonts the builder really made and not a drawing of what it
    would have made. Nothing in the shipped path passes it, and --check refuses it."""
    right_pct = RIGHT_BEARING_PCT if right_bearing_pct is None else float(right_bearing_pct)
    left = round(ADV_EM * LEFT_BEARING_PCT / 100)          # 36
    right = round(ADV_EM * right_pct / 100)                # 108 at 18%
    side = ADV_EM - left - right                           # 456: the square, at 18%
    right_edge = ADV_EM - right                            # 492: 82% of the cell
    if side <= 0:
        sys.exit("refused: left %d%% + right %d%% of a %d-unit cell leaves no box"
                 % (LEFT_BEARING_PCT, right_pct, ADV_EM))
    return {
        "left_bearing_pct": LEFT_BEARING_PCT,
        "right_bearing_pct": right_pct,
        "left_bearing_units_1000": left,
        "right_bearing_units_1000": right,
        "right_edge_units_1000": right_edge,
        "box_side_units_1000": side,
        "left_edge": left * K,                             # 2048-em units the outlines are written in
        "right_edge": right_edge * K,                      # 1007.6
        "box_side": side * K,                              # 934.0
        "box_bottom": YMID_OUT - side * K / 2,             # 280.5
        "box_top": YMID_OUT + side * K / 2,                # 1214.5
    }


GEOMETRY = geometry()                     # the shipped box

# The faces that ship: the text font in both weights, and our icons. Named once, because the builder
# writes them, the web page loads them and wa setup fonts installs them.
SERVED_FONTS = ("waIcons-Regular.ttf", "JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf")

FAMILY = "wa Icons"
MAC_EPOCH = 2082844800                    # 1904-01-01 -> 1970-01-01: fontTools counts from the former
FIXED_EPOCH = 1732051200 + MAC_EPOCH      # 2024-11-19T00:00:00Z, the decision's date: fixed = reproducible


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def archive(name, cache):
    """The pinned zip, downloaded once into the cache and re-hashed on EVERY use."""
    spec = SOURCES[name]
    path = os.path.join(cache, os.path.basename(spec["url"]))
    if not os.path.exists(path) or sha256_file(path) != spec["zip_sha256"]:
        os.makedirs(cache, exist_ok=True)
        subprocess.run(["curl", "-sSL", "--fail", "-o", path + ".part", spec["url"]], check=True)
        os.replace(path + ".part", path)
    got = sha256_file(path)
    if got != spec["zip_sha256"]:
        sys.exit("refused: %s has sha256 %s, the build pins %s" % (spec["url"], got, spec["zip_sha256"]))
    return path


def extract(name, member, cache):
    """The bytes of one pinned member, hashed against its own pin. Never trusts the cache."""
    spec = SOURCES[name]
    want = spec["members"].get(member)
    if want is None:
        sys.exit("refused: %s is not a pinned member of %s" % (member, spec["version"]))
    with zipfile.ZipFile(archive(name, cache)) as bundle:
        data = bundle.read(member)
    got = sha256_bytes(data)
    if got != want:
        sys.exit("refused: %s in %s has sha256 %s, the build pins %s" % (member, spec["version"], got, want))
    return data


def licence(name, cache):
    spec = SOURCES[name]
    with zipfile.ZipFile(archive(name, cache)) as bundle:
        data = bundle.read(spec["licence_member"])
    got = sha256_bytes(data)
    if got != spec["licence_sha256"]:
        sys.exit("refused: %s in %s has sha256 %s, the build pins %s"
                 % (spec["licence_member"], spec["version"], got, spec["licence_sha256"]))
    return data


def fit(font, box=None):
    """Every glyph into THE BOX: one advance for all, one right edge for all, one scale per glyph.

    The scale is min(box / width, box / height) - ONE number for both axes, so a glyph is never
    squashed - and the outline is then placed with its right edge ON the box's right edge and its
    centre ON the capitals' centre. Because the box is inside the cell and the scale never exceeds it,
    the drawing can only ever shrink INWARDS: GROW-LEFT IS FORBIDDEN (Victor, 19/11), foot clips an
    icon that starts before its cell."""
    from fontTools import subset

    box = box or GEOMETRY
    options = subset.Options()
    options.name_IDs = ["*"]
    options.notdef_outline = True
    options.glyph_names = True
    options.layout_features = []           # one glyph per code point, no shaping
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=CODEPOINTS)
    subsetter.subset(font)

    cmap = font.getBestCmap()
    missing = [cp for cp in CODEPOINTS if cp not in cmap]
    if missing:
        sys.exit("refused: the source font has no glyph for %s" % ", ".join("U+%04X" % cp for cp in missing))

    glyf, hmtx = font["glyf"], font["hmtx"]
    kept = set()
    for cp, _ in GLYPHS:
        glyph_name = cmap[cp]
        kept.add(glyph_name)
        glyph = glyf[glyph_name]
        glyph.recalcBounds(glyf)
        width, height = glyph.xMax - glyph.xMin, glyph.yMax - glyph.yMin
        if width <= 0 or height <= 0:
            sys.exit("refused: %s (U+%04X) has an empty bounding box" % (glyph_name, cp))
        scale = min(box["box_side"] / width, box["box_side"] / height)
        x0 = box["right_edge"] - width * scale
        y0 = YMID_OUT - height * scale / 2
        coordinates = glyph.coordinates
        for index, (x, y) in enumerate(coordinates):
            coordinates[index] = (round((x - glyph.xMin) * scale + x0), round((y - glyph.yMin) * scale + y0))
        glyph.recalcBounds(glyf)
        hmtx[glyph_name] = (ADVANCE, glyph.xMin)

    # A glyph the subset kept that wa does not draw still gets one cell of advance: a stale glyph
    # cannot become a wider cell if it is ever reached.
    for glyph_name in font.getGlyphOrder():
        if glyph_name not in kept:
            hmtx[glyph_name] = (ADVANCE, hmtx[glyph_name][1])
    return font


def build(symbols_path, out_path, box=None):
    from fontTools.ttLib import TTFont

    # recalcTimestamp=False: TTFont stamps head.modified with the WALL CLOCK as it saves unless told
    # otherwise, which is exactly how "two builds are byte-identical" was believed on 21/11 when the two
    # builds happened to land in the same second (head times have one-second resolution). The font is a
    # committed artifact; its bytes may not depend on when it was built.
    font = TTFont(symbols_path, recalcTimestamp=False)
    fit(font, box)

    # JetBrains Mono's vertical grid, scaled: a terminal that asks the icon font for a line height gets
    # the line the text font beside it asks for.
    hhea = font["hhea"]
    hhea.ascent, hhea.descent, hhea.lineGap = round(ASCENDER * K), round(DESCENDER * K), 0
    os2 = font["OS/2"]
    os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap = round(ASCENDER * K), round(DESCENDER * K), 0
    os2.usWinAscent, os2.usWinDescent = round(ASCENDER * K), round(-DESCENDER * K)
    os2.xAvgCharWidth = ADVANCE
    os2.sCapHeight, os2.sxHeight = round(CAP_HEIGHT * K), round(X_HEIGHT * K)
    font["post"].isFixedPitch = 1

    # The foundry's comment table and the shaping tables say nothing about this subset and only make
    # the bytes differ between fontTools versions.
    for table in ("PfEd", "GDEF", "DSIG"):
        if table in font:
            del font[table]
    font["head"].created = FIXED_EPOCH
    font["head"].modified = FIXED_EPOCH

    name = font["name"]
    for record in list(name.names):
        if record.nameID in (1, 2, 3, 4, 5, 6, 13, 14, 16, 17):
            name.removeNames(nameID=record.nameID)
    for platform, encoding, language in ((3, 1, 0x409), (1, 0, 0)):
        name.setName(FAMILY, 1, platform, encoding, language)
        name.setName("Regular", 2, platform, encoding, language)
        name.setName("2.0;waIcons-Regular", 3, platform, encoding, language)
        name.setName(FAMILY + " Regular", 4, platform, encoding, language)
        name.setName("Version 2.0", 5, platform, encoding, language)
        name.setName("waIcons-Regular", 6, platform, encoding, language)
        name.setName("Licences: " + SOURCES["symbols"]["licence"] + "; " + SOURCES["jetbrains"]["licence"],
                     13, platform, encoding, language)
        name.setName("https://github.com/ryanoasis/nerd-fonts", 14, platform, encoding, language)

    font.save(out_path)
    return font


def verify(font_path, box=None):
    """Assert THE BOX, from the font's own tables - no sources, no network.

    This is what a test runs: the same bytes a terminal reads, checked against the same numbers the
    builder used. Unknown is not a pass, so a missing code point, an empty outline or a table that
    cannot be read is a problem, never a skip."""
    from fontTools.ttLib import TTFont

    box = box or GEOMETRY
    problems = []
    font = TTFont(font_path)
    if font["head"].unitsPerEm != UPEM_OUT:
        problems.append("upm %d, the box is written in %d" % (font["head"].unitsPerEm, UPEM_OUT))
    if font["hhea"].ascent != round(ASCENDER * K):
        problems.append("hhea ascent %d, JetBrains Mono's is %d" % (font["hhea"].ascent, round(ASCENDER * K)))
    if font["hhea"].descent != round(DESCENDER * K):
        problems.append("hhea descent %d, JetBrains Mono's is %d" % (font["hhea"].descent, round(DESCENDER * K)))
    cell = ADV_EM * K                                  # one cell, in the outlines' own units
    cmap = font.getBestCmap()
    glyf, hmtx = font["glyf"], font["hmtx"]
    for cp, _ in GLYPHS:
        glyph_name = cmap.get(cp)
        if glyph_name is None:
            problems.append("U+%04X missing" % cp)
            continue
        advance, lsb = hmtx[glyph_name]
        glyph = glyf[glyph_name]
        glyph.recalcBounds(glyf)
        if advance != ADVANCE:
            problems.append("U+%04X %s advance %d, one cell is %d" % (cp, glyph_name, advance, ADVANCE))
        if lsb != glyph.xMin:
            problems.append("U+%04X %s lsb %d != xMin %d" % (cp, glyph_name, lsb, glyph.xMin))
        width, height = glyph.xMax - glyph.xMin, glyph.yMax - glyph.yMin
        if width <= 0 or height <= 0:
            problems.append("U+%04X %s has an empty outline" % (cp, glyph_name))
            continue
        # ONE RIGHT EDGE for every icon, so the gap a digit sees is identical: +-1 unit is the
        # coordinate rounding of a scaled outline, nothing else.
        if abs(glyph.xMax - box["right_edge"]) > 1:
            problems.append("U+%04X %s right bearing %.1f%% of the cell, the box says %.1f%%"
                            % (cp, glyph_name, 100 * (cell - glyph.xMax) / cell, box["right_bearing_pct"]))
        if glyph.xMin < box["left_edge"] - 1:
            problems.append("U+%04X %s starts at %d, left of the %.0f%% bearing - foot clips it"
                            % (cp, glyph_name, glyph.xMin, box["left_bearing_pct"]))
        if width > box["box_side"] + 1 or height > box["box_side"] + 1:
            problems.append("U+%04X %s is %dx%d, outside its %.0f-unit square box"
                            % (cp, glyph_name, width, height, box["box_side"]))
        if glyph.yMin < box["box_bottom"] - 1 or glyph.yMax > box["box_top"] + 1:
            problems.append("U+%04X %s spans y %d..%d, outside the box %d..%d"
                            % (cp, glyph_name, glyph.yMin, glyph.yMax, round(box["box_bottom"]), round(box["box_top"])))
        centre = (glyph.yMax + glyph.yMin) / 2
        if abs(centre - YMID_OUT) > 1.5:
            problems.append("U+%04X %s centred at %.1f, the capitals are at %.1f"
                            % (cp, glyph_name, centre, YMID_OUT))
    return problems


def ship(out_dir, cache):
    """Everything the release bundle carries, from the pinned archives: the two JetBrains Mono weights
    the terminal uses and the Symbols Nerd Font notice."""
    written = {}
    for member, out_name in (("fonts/ttf/JetBrainsMono-Regular.ttf", "JetBrainsMono-Regular.ttf"),
                             ("fonts/ttf/JetBrainsMono-Bold.ttf", "JetBrainsMono-Bold.ttf")):
        path = os.path.join(out_dir, out_name)
        with open(path, "wb") as handle:
            handle.write(extract("jetbrains", member, cache))
        written[out_name] = path
    for out_name, (source, _field) in SHIPPED_LICENCES.items():
        path = os.path.join(out_dir, out_name)
        with open(path, "wb") as handle:
            handle.write(licence(source, cache))
        written[out_name] = path
    return written


def manifest(out_dir, built, box=None):
    """What the repo commits, stated as bytes: every file with its sha256, the box the font was built
    to, the glyph set, and the pinned provenance. tests/test-wa-fonts.mjs compares this against the
    files on disk and against its own copy of the numbers, so a font swapped by hand is a failing test
    and not a silent change of look."""
    from fontTools.ttLib import TTFont

    box = box or GEOMETRY
    entries = {}
    for name in sorted(os.listdir(out_dir)):
        path = os.path.join(out_dir, name)
        if os.path.isfile(path) and name != "waIcons.json":
            entries[name] = sha256_file(path)
    cmap = TTFont(built).getBestCmap()
    document = {
        "family": FAMILY,
        "file": os.path.basename(built),
        # The derived lengths are rounded to two units: this file is read by an operator, and a float
        # with sixteen decimals in a committed artifact is noise, not precision (a unit is 1/2048 em).
        "box": dict({key: (round(value, 2) if isinstance(value, float) else value)
                      for key, value in box.items()},
                     advance_em=ADV_EM, advance=ADVANCE, units_per_em=UPEM_OUT,
                    cap_height=CAP_HEIGHT, ymid_units_1000=YMID, px_units_1000=PX_UNITS, gap=""),
        "glyphs": [{"codepoint": "U+%04X" % cp, "means": means, "source_glyph": cmap.get(cp)}
                   for cp, means in GLYPHS],
        "sources": {key: {"url": spec["url"], "version": spec["version"], "licence": spec["licence"],
                          "zip_sha256": spec["zip_sha256"], "members": spec["members"]}
                    for key, spec in SOURCES.items()},
        "files": entries,
    }
    path = os.path.join(out_dir, "waIcons.json")
    with open(path, "w") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return path


def check(out_dir, sources_too, cache, box=None):
    """The committed tree, checked: the font's metrics, then every sha256 the manifest states."""
    built = os.path.join(out_dir, "waIcons-Regular.ttf")
    problems = verify(built, box)
    manifest_path = os.path.join(out_dir, "waIcons.json")
    try:
        with open(manifest_path) as handle:
            document = json.load(handle)
    except (OSError, ValueError) as error:
        problems.append("manifest %s unreadable: %s" % (manifest_path, error))
        document = None
    if document is not None:
        stated = document.get("files", {})
        for name, want in sorted(stated.items()):
            path = os.path.join(out_dir, name)
            if not os.path.exists(path):
                problems.append("%s is in the manifest and not on disk" % name)
                continue
            got = sha256_file(path)
            if got != want:
                problems.append("%s sha256 %s, the manifest says %s" % (name, got, want))
        on_disk = {name for name in os.listdir(out_dir)
                   if os.path.isfile(os.path.join(out_dir, name)) and name != "waIcons.json"}
        for name in sorted(on_disk - set(stated)):
            problems.append("%s is on disk and not in the manifest" % name)
    if sources_too:
        for name in SOURCES:
            archive(name, cache)
            for member in SOURCES[name]["members"]:
                extract(name, member, cache)
            licence(name, cache)
        print("sources: both archives and every member re-hashed to their pinned sha256")
    return problems


def main():
    parser = argparse.ArgumentParser(description="Build and ship wa Icons (A2) + JetBrains Mono.")
    parser.add_argument("--out", default="assets/fonts", help="directory the fonts and their manifest live in")
    parser.add_argument("--cache", default=os.path.join(os.path.expanduser("~"), ".cache", "wa-icons"),
                        help="where the pinned archives are kept (re-hashed on every use)")
    parser.add_argument("--check", action="store_true", help="verify the committed fonts, manifest and hashes")
    parser.add_argument("--sources", action="store_true", help="with --check: re-download and re-hash the archives")
    parser.add_argument("--verify-font", default=None, help="verify ONE font file and exit")
    parser.add_argument("--right-bearing", type=float, default=None,
                        help="EYE TEST ONLY: build with another right bearing, in percent of the cell "
                             "(the shipped number is RIGHT_BEARING_PCT). Pair it with --out <scratch dir>")
    parser.add_argument("--web-out", default="ui/fonts", help="where the served font copies are written")
    # The browser cannot reach assets/: the node serves ONE directory (the ui dir), so the faces the page
    # embeds live under ui/fonts in the served tree - and they are the SAME files wa setup fonts installs.
    # tests/test-wa-fonts.mjs compares the two copies, so a stale one cannot sit in the served tree.
    args = parser.parse_args()
    if args.right_bearing is not None and (args.check or args.verify_font):
        parser.error("--right-bearing BUILDS a font; it cannot check or verify one")

    built = os.path.join(args.out, "waIcons-Regular.ttf")
    box = geometry(args.right_bearing)
    if args.verify_font:
        problems = verify(args.verify_font, box)
    elif args.check:
        problems = check(args.out, args.sources, args.cache, box)
    else:
        os.makedirs(args.out, exist_ok=True)
        staging = os.path.join(args.out, "symbols-source.ttf")
        with open(staging, "wb") as handle:
            handle.write(extract("symbols", "SymbolsNerdFontMono-Regular.ttf", args.cache))
        # Built from the bytes just extracted AND hashed, never from a path that might have been
        # rewritten between the check and the read.
        try:
            build(staging, built, box)
        finally:
            os.remove(staging)
        written = ship(args.out, args.cache)
        # The copies the node actually SERVES, and the copies wa setup fonts INSTALLS: the .ttf files
        # themselves. One file, two uses - a browser loads TrueType webfonts as readily as woff2, and the
        # installer has to copy a real font anyway, so serving anything else would ship each face twice.
        os.makedirs(args.web_out, exist_ok=True)
        # The LICENCES travel with the served copies too: a bundle that carries a font and not its licence
        # is a bundle nobody may redistribute, and the installer reads these faces from here.
        for name in SERVED_FONTS + tuple(SHIPPED_LICENCES):
            with open(os.path.join(args.out, name), "rb") as handle:
                data = handle.read()
            with open(os.path.join(args.web_out, name), "wb") as handle:
                handle.write(data)
        # The claim, measured where it is made: build the SAME bytes a second time, from the same
        # extracted source, and refuse if the two files differ. A comment cannot notice a wall-clock
        # stamp; this can. (It is also why the stamps above are pinned at all.)
        import tempfile
        with tempfile.TemporaryDirectory() as scratch:
            again = os.path.join(scratch, "waIcons-Regular.ttf")
            with open(os.path.join(scratch, "symbols-source.ttf"), "wb") as handle:
                handle.write(extract("symbols", "SymbolsNerdFontMono-Regular.ttf", args.cache))
            build(os.path.join(scratch, "symbols-source.ttf"), again, box)
            if sha256_file(again) != sha256_file(built):
                sys.exit("refused: two builds of the same source differ (%s vs %s), so the committed "
                         "bytes are not reproducible" % (sha256_file(again)[:12], sha256_file(built)[:12]))
        print("reproducible: a second build of the same source is byte-identical")
        manifest_path = manifest(args.out, built, box)
        problems = check(args.out, False, args.cache, box)
        print("built %s (%d glyphs, advance %d of %d units, square box %.0f, right edge %.1f = %.0f%% right bearing)"
              % (built, len(GLYPHS), ADVANCE, UPEM_OUT, box["box_side"], box["right_edge"], box["right_bearing_pct"]))
        print("manifest %s" % manifest_path)
    for problem in problems:
        print("FAIL " + problem)
    print("wa icons: %s" % ("ok" if not problems else "%d problem(s)" % len(problems)))
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
