/* wasi-libc has no strftime, and ffmpeg's libavutil calls it (bprint.c's av_bprint_strftime, and dict.c's
 * "%Y-%m-%dT%H:%M:%S"). This header is force-included into every vendored source so the declaration exists
 * where ffmpeg expects it; the implementation is strftime.c beside this file. Keeping the declaration and the
 * body apart is deliberate: the declaration is what the compiler needs, the body is what a reader needs to
 * see is small.
 */
#ifndef WA_MEDIA_TIME_COMPAT_H
#define WA_MEDIA_TIME_COMPAT_H

#include <stddef.h>
#include <time.h>

/* The same signature as C99's, restricted to the directives strftime.c implements; anything else answers 0,
 * which is strftime's own way of saying "not formatted" - never a wrong string. */
/* No `restrict` on the parameters: ffmpeg passes plain pointers, and clang calls the mismatch an
 * incompatible type at the call site rather than at the declaration. */
/* The time argument is `const void *` on purpose. Declared as `const struct tm *` it clashes with the
 * one ffmpeg sees - two struct tm identities reachable from different include paths - and clang reports
 * "incompatible pointer types passing const struct tm * to parameter of type const struct tm *", which
 * reads like nonsense until you know why. A void pointer cannot clash, and the body casts it back. */
size_t strftime(char *buffer, size_t size, const char *format, const void *time);

#endif
