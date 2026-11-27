#!/usr/bin/env python3
"""Carry exactly the ffmpeg one configured build compiled, plus everything those files include.

WHY PYTHON AND NOT A SHELL LOOP. The first version of this did the include closure in bash: for every file,
run sed, then try candidates, repeat until nothing new appears. On ~1500 files that ran for minutes and was
still running when the operation's owner went away - and it was patched five times, each patch slower to
reason about than the last. The closure is one breadth-first walk over a queue.

WHAT IS COPIED, and why each part was learned by a build failing:
  * the .c behind every .o  - the compiled set, recorded in compiled.txt, because some of the .c in the tree
    are INCLUDED textually (aacdec_dsp_template.c) and compiling one of those on its own is a page of
    nonsense errors;
  * every header of the five libraries - the include graph is a web, and a missing header fails far from its
    cause;
  * the generated registry sources and the two generated config headers - nothing is named after them, so
    an object-to-source mapping cannot see them (codec_list.c, parser_list.c, bsf_list.c, demuxer_list.c,
    muxer_list.c, protocol_list.c, config.h, config_components.h);
  * the include closure - a quoted include WITHOUT a slash is relative to the including file (or to one of
    the library roots, which is where adts_header.h lives when bsf/ asks for it); one WITH a slash is
    relative to the tree root. Mixing the two is how a vendored tree grows directories like
    libavcodec/aac/libavutil/libavcodec/.

    usage: vendor-ffmpeg-source.py <built-ffmpeg-tree> <destination>
"""
import os
import re
import shutil
import sys
from pathlib import Path

LIBRARIES = ["libavcodec", "libavformat", "libavutil", "libswscale", "libswresample"]
GENERATED = [
    "libavcodec/codec_list.c",
    "libavcodec/parser_list.c",
    "libavcodec/bsf_list.c",
    "libavformat/demuxer_list.c",
    "libavformat/muxer_list.c",
    "libavformat/protocol_list.c",
    "config.h",
    "config_components.h",
]
INCLUDE = re.compile(r'^\s*#\s*include\s*"([^"]+)"', re.MULTILINE)


def copy(src: Path, dest: Path) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_file():
        return False
    shutil.copy2(src, dest)
    return True


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    src_root = Path(sys.argv[1])
    dest_root = Path(sys.argv[2])
    if not (src_root / "libavcodec").is_dir():
        print(f"vendor-ffmpeg-source: {src_root} is not a configured ffmpeg tree", file=sys.stderr)
        return 2
    dest_root.mkdir(parents=True, exist_ok=True)

    # 1. the compiled set, and the list the component's build.rs reads.
    compiled = []
    for library in LIBRARIES:
        for obj in sorted((src_root / library).rglob("*.o")):
            source = obj.with_suffix(".c")
            if not source.is_file():
                continue
            rel = source.relative_to(src_root)
            copy(source, dest_root / rel)
            compiled.append(str(rel))
    (dest_root / "compiled.txt").write_text("\n".join(compiled) + "\n", encoding="utf-8")

    # 2. every header of the five libraries.
    for library in LIBRARIES:
        for head in (src_root / library).rglob("*.h"):
            copy(head, dest_root / head.relative_to(src_root))

    # 3. the generated sources and config headers, by name.
    for name in GENERATED:
        source = src_root / name
        if not source.is_file():
            print(f"vendor-ffmpeg-source: {name} is missing from the build; refusing to ship a tree that cannot link", file=sys.stderr)
            return 2
        copy(source, dest_root / name)

    # 4. the include closure: one queue, one visit per file.
    queue = [p for p in dest_root.rglob("*") if p.is_file() and p.suffix in (".c", ".h")]
    seen = {p.resolve() for p in queue}
    added = 0
    while queue:
        current = queue.pop()
        try:
            text = current.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        rel_dir = current.parent.relative_to(dest_root)
        for name in set(INCLUDE.findall(text)):
            if "/" in name:
                candidates = [(src_root / name, dest_root / name)]
            else:
                # Same directory first, then the SAME RELATIVE DIRECTORY IN THE SOURCE TREE (a compiled file
                # under libavcodec/aac/ includes a template that lives only there), then the library roots.
                candidates = [(current.parent / name, current.parent / name)]
                candidates += [(src_root / rel_dir / name, dest_root / rel_dir / name)]
                candidates += [
                    (src_root / library / name, dest_root / library / name) for library in LIBRARIES
                ]
                candidates += [(src_root / name, dest_root / name)]
            for source, dest in candidates:
                if source.is_file() and not dest.is_file():
                    copy(source, dest)
                    added += 1
                    if dest.resolve() not in seen:
                        seen.add(dest.resolve())
                        queue.append(dest)
                    break

    # The two files that call strftime get an include for the shim beside the component (wasi/strftime.c).
    # This is the ONLY edit the vendored tree carries, it is re-applied every time the tree is regenerated,
    # and it is visible in the copy itself.
    for caller in ("libavutil/bprint.c", "libavutil/dict.c"):
        path = dest_root / caller
        if path.is_file():
            text = path.read_text(encoding="utf-8")
            if "time_compat.h" not in text:
                marker = text.index("#include")
                note = "/* wasi-libc has no strftime; the component's shim declares it */\n#include \"../../../wasi/time_compat.h\"\n"
                path.write_text(text[:marker] + note + text[marker:], encoding="utf-8")

    for notice in ("LICENSE.md", "COPYING.LGPLv2.1", "COPYING.LGPLv3"):
        if (src_root / notice).is_file():
            copy(src_root / notice, dest_root / notice)

    if len(compiled) < 100:
        print("vendor-ffmpeg-source: too few objects to have been a real build", file=sys.stderr)
        return 2
    print(f"vendor-ffmpeg-source: {len(compiled)} compiled C, {added} included files -> {dest_root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
