#!/usr/bin/env bash
# Copy the ffmpeg sources a CONFIGURED BUILD actually compiled, plus the headers they include, into a
# vendored tree the component's build.rs can compile hermetically.
#
# WHY. `scripts/build-components.sh` runs with no network, and a component pin is only worth anything if a
# clean build of the tree reproduces it. ffmpeg has no crate that ships libav* for wasip2 (ffmpeg.wasm
# targets emscripten), so the C has to live in the tree - the pattern rusqlite uses, except that its C
# arrives inside a crates.io package. Copying the whole 186 MB source tree would be absurd; the build that
# produced the measurements compiled 359 C files (7.2 MB), which is the part worth carrying.
#
#   bash scripts/vendor-ffmpeg-source.sh <built-ffmpeg-tree> <destination>
set -uo pipefail
SRC="${1:-}"
DEST="${2:-}"
if [ -z "$SRC" ] || [ -z "$DEST" ] || [ ! -d "$SRC/libavcodec" ]; then
  echo "usage: bash scripts/vendor-ffmpeg-source.sh <built-ffmpeg-tree> <destination>" >&2
  exit 2
fi
mkdir -p "$DEST" || exit 2
LIBRARIES="libavcodec libavformat libavutil libswscale libswresample"
copied=0
for obj in $(cd "$SRC" && find $LIBRARIES -name '*.o'); do
  src="$SRC/${obj%.o}.c"
  [ -f "$src" ] || continue
  out="$DEST/${obj%.o}.c"
  mkdir -p "$(dirname "$out")"
  cp "$src" "$out"
  copied=$((copied+1))
done
headers=0
for h in $(cd "$SRC" && find $LIBRARIES -name '*.h'); do
  out="$DEST/$h"
  mkdir -p "$(dirname "$out")"
  cp "$SRC/$h" "$out"
  headers=$((headers+1))
done
# The registry files ffmpeg GENERATES for a configuration (they name the codecs/demuxers/muxers this
# build has). They are compiled but have no object named after them, so the .o pass above cannot find
# them, and a vendored tree without them fails where it is hardest to read: at link time.
for generated in libavcodec/codec_list.c libavcodec/parser_list.c libavcodec/bsf_list.c \
                 libavformat/demuxer_list.c libavformat/muxer_list.c libavformat/protocol_list.c; do
  [ -f "$SRC/$generated" ] || { echo "vendor-ffmpeg-source: $generated is missing from the build" >&2; exit 2; }
  mkdir -p "$DEST/$(dirname "$generated")"
  cp "$SRC/$generated" "$DEST/$generated"
done

# config_components.h is the second generated config header (it sits beside config.h and libavcodec's
# decoders include it directly); a tree without it compiles until the first decoder and then stops.
for extra in config.h config_components.h LICENSE.md COPYING.LGPLv2.1 COPYING.LGPLv3; do
  [ -f "$SRC/$extra" ] && cp "$SRC/$extra" "$DEST/$extra"
done
echo "vendor-ffmpeg-source: $copied C files, $headers headers -> $DEST"
[ "$copied" -gt 100 ] || { echo "vendor-ffmpeg-source: too few objects to have been a real build" >&2; exit 2; }
