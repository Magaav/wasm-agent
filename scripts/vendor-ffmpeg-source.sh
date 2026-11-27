#!/usr/bin/env bash
# Carry exactly the ffmpeg one CONFIGURED BUILD compiled, plus everything those files include, so a component
# can build it hermetically (no network, a verifiable pin).
#
# WHY THE SET IS COMPUTED AND NOT COPIED WHOLESALE. Measured on ffmpeg 7.1 for this configuration: the
# compiled part is 335 C files and 7.2 MB inside a 186 MB source tree. Copying the tree would be absurd;
# copying only the .c behind each .o is not enough, and the two ways it is not enough are both real and both
# were hit while wiring rust/components/media:
#   * ffmpeg GENERATES registry files for a configuration (codec_list.c, parser_list.c, bsf_list.c,
#     demuxer_list.c, muxer_list.c, protocol_list.c) and two headers (config.h, config_components.h); they
#     compile, but nothing is named after them, so an object-to-source mapping cannot see them;
#   * some C is INCLUDED textually (libavcodec/aac/aacdec_float.c includes aacdec_dsp_template.c), so those
#     files have no object either.
# The first two are listed explicitly; the third is found by following `#include "..."` until nothing new
# appears.
#
#   bash scripts/vendor-ffmpeg-source.sh <built-ffmpeg-tree> <destination>
# Exit: 0 copied; 2 arguments, tree, or a required generated file missing.
set -uo pipefail
SRC="${1:-}"
DEST="${2:-}"
if [ -z "$SRC" ] || [ -z "$DEST" ] || [ ! -d "$SRC/libavcodec" ]; then
  echo "usage: bash scripts/vendor-ffmpeg-source.sh <built-ffmpeg-tree> <destination>" >&2
  exit 2
fi
LIBRARIES="libavcodec libavformat libavutil libswscale libswresample"
mkdir -p "$DEST" || exit 2

# 1. the source behind every object the build produced.
copied=0
: > "$DEST/compiled.txt"
for obj in $(cd "$SRC" && find $LIBRARIES -name '*.o'); do
  src="$SRC/${obj%.o}.c"
  [ -f "$src" ] || continue
  out="$DEST/${obj%.o}.c"
  mkdir -p "$(dirname "$out")"
  cp "$src" "$out"
  # The compiled set, by name: some vendored .c are INCLUDED textually (aacdec_dsp_template.c) and
  # compiling one of those on its own is a page of nonsense errors.
  printf '%s\n' "${obj%.o}.c" >> "$DEST/compiled.txt"
  copied=$((copied + 1))
done

# 2. every header under those libraries: the include graph is a web, and a missing header fails far from its
#    cause.
headers=0
for head in $(cd "$SRC" && find $LIBRARIES -name '*.h'); do
  out="$DEST/$head"
  mkdir -p "$(dirname "$out")"
  cp "$SRC/$head" "$out"
  headers=$((headers + 1))
done

# 3. the generated registry sources and config headers, by name: nothing is named after them.
for generated in libavcodec/codec_list.c libavcodec/parser_list.c libavcodec/bsf_list.c \
                 libavformat/demuxer_list.c libavformat/muxer_list.c libavformat/protocol_list.c \
                 config.h config_components.h; do
  if [ ! -f "$SRC/$generated" ]; then
    echo "vendor-ffmpeg-source: $generated is missing from the build; refusing to ship a tree that cannot link" >&2
    exit 2
  fi
  mkdir -p "$DEST/$(dirname "$generated")"
  cp "$SRC/$generated" "$DEST/$generated"
done

# 4. files that are #included textually, followed to a fixed point. `$SRC/<$relative dir from DEST>/<name>`
#    is where such a file lives: the vendored tree mirrors the source tree's paths.
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  for file in $(find "$DEST" -type f -name '*.c' -o -type f -name '*.h'); do
    dir=$(dirname "$file")
    rel=${dir#"$DEST"/}
    [ "$rel" = "$dir" ] && rel="."
    while IFS= read -r inc; do
      [ -n "$inc" ] || continue
      # An include with a path in it (`libavutil/attributes.h`) is relative to the TREE ROOT; one without
      # (`aacdec_dsp_template.c`) is relative to the including file. Mixing the two is how a vendored tree
      # grows directories like libavcodec/aac/libavutil/libavcodec/...
      case "$inc" in
        */*) out="$DEST/$inc" ;;
        *)   out="$DEST/$rel/$inc" ;;
      esac
      [ -f "$out" ] && continue
      for candidate in "$dir/$inc" "$SRC/$rel/$inc" "$SRC/libavcodec/$inc" "$SRC/libavformat/$inc"                        "$SRC/libavutil/$inc" "$SRC/libswscale/$inc" "$SRC/libswresample/$inc" "$SRC/$inc"; do
        if [ -f "$candidate" ]; then
          # Where it lands mirrors where it was found (a bare include found in libavcodec/ belongs in
          # libavcodec/), so the compiler's own search order still finds it from anywhere in the tree.
          case "$candidate" in
            "$dir"/*) target="$out" ;;
            "$SRC"/*) target="$DEST/${candidate#"$SRC"/}" ;;
            *) target="$out" ;;
          esac
          mkdir -p "$(dirname "$target")"
          cp "$candidate" "$target"
          changed=1
          break
        fi
      done
    done <<< "$(sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | sort -u)"
  done
done

for notice in LICENSE.md COPYING.LGPLv2.1 COPYING.LGPLv3; do
  [ -f "$SRC/$notice" ] && cp "$SRC/$notice" "$DEST/$notice"
done

echo "vendor-ffmpeg-source: $copied C files, $headers headers, plus includes -> $DEST"
[ "$copied" -gt 100 ] || { echo "vendor-ffmpeg-source: too few objects to have been a real build" >&2; exit 2; }
