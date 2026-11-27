/* Reading ffmpeg's structs from C, so the Rust side never guesses a field offset.
 *
 * WHY THIS FILE EXISTS. The bindings were to come from bindgen against the vendored headers, and on this node
 * they cannot: bindgen 0.70.1 with the wasi-sdk's libclang 23 emits the AV* types and NO extern functions at
 * all (measured on a two-line header: the struct comes out, `int foo(void)` does not), and its ABI assertion
 * fires with 4 != 8 because that libclang defaults to a wasm target while the build host is 64-bit. No other
 * libclang is installed. Copying AVFormatContext into Rust by hand would put the one thing nobody can check -
 * struct offsets - into the code. So the C compiler, which already knows the layout, reads the fields and hands
 * over plain values: the Rust side keeps opaque pointers and no offsets at all.
 */
#ifndef WA_MEDIA_FFMPEG_ACCESS_H
#define WA_MEDIA_FFMPEG_ACCESS_H

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>

/* AVMEDIA_TYPE_* as small integers, so Rust can name the three the contract has without importing an enum. */
#define WA_MEDIA_KIND_VIDEO 0
#define WA_MEDIA_KIND_AUDIO 1
#define WA_MEDIA_KIND_SUBTITLE 3
#define WA_MEDIA_KIND_OTHER 4

unsigned wa_stream_count(AVFormatContext *context);
int wa_stream_kind(AVFormatContext *context, unsigned index);
const char *wa_stream_codec(AVFormatContext *context, unsigned index);
int wa_stream_width(AVFormatContext *context, unsigned index);
int wa_stream_height(AVFormatContext *context, unsigned index);
const char *wa_format_name(AVFormatContext *context);
long long wa_duration_us(AVFormatContext *context);

#endif
