/* The strftime wasi-libc does not have.
 *
 * WHY A SHIM AND NOT A PATCH TO FFMPEG. ffmpeg calls strftime in exactly two places - `libavutil/dict.c` with
 * "%Y-%m-%dT%H:%M:%S" and `libavutil/bprint.c`'s av_bprint_strftime with a format the CALLER supplies - and
 * neither is on the media path this component takes; but the file that calls it compiles unconditionally, so
 * the symbol has to exist. Editing ffmpeg's source would make the vendored tree a fork; a shim beside it
 * keeps the tree a faithful copy and puts the difference in one place a reader can find.
 *
 * WHAT IT SUPPORTS: %Y %m %d %H %M %S %T %e %b %j %H:%M:%S and %%, which is every directive this codebase
 * uses. Anything else answers 0 - strftime's own way of saying "not formatted" - so a caller sees a failure
 * rather than a wrong timestamp.
 */
#include <stdio.h>
#include <string.h>
#include <time.h>

static const char *const MONTHS[12] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

size_t strftime(char *buffer, size_t size, const char *format, const void *time_void) {
    const struct tm *time = (const struct tm *)time_void;
    if (!buffer || !size || !format || !time) return 0;
    size_t used = 0;
    for (const char *at = format; *at; at++) {
        char piece[32];
        const char *emit = piece;
        if (*at != '%') {
            piece[0] = *at;
            piece[1] = 0;
        } else {
            at++;
            switch (*at) {
                case 'Y': snprintf(piece, sizeof piece, "%04d", time->tm_year + 1900); break;
                case 'm': snprintf(piece, sizeof piece, "%02d", time->tm_mon + 1); break;
                case 'd': snprintf(piece, sizeof piece, "%02d", time->tm_mday); break;
                case 'H': snprintf(piece, sizeof piece, "%02d", time->tm_hour); break;
                case 'M': snprintf(piece, sizeof piece, "%02d", time->tm_min); break;
                case 'S': snprintf(piece, sizeof piece, "%02d", time->tm_sec); break;
                case 'j': snprintf(piece, sizeof piece, "%03d", time->tm_yday + 1); break;
                case 'e': snprintf(piece, sizeof piece, "%2d", time->tm_mday); break;
                case 'b': emit = MONTHS[(time->tm_mon >= 0 && time->tm_mon < 12) ? time->tm_mon : 0]; break;
                case 'T':
                    snprintf(piece, sizeof piece, "%02d:%02d:%02d", time->tm_hour, time->tm_min, time->tm_sec);
                    break;
                case '%': piece[0] = '%'; piece[1] = 0; break;
                case 0: return 0;             /* a trailing lone % is not a format */
                default: return 0;            /* unsupported: say so, never invent a value */
            }
        }
        size_t need = strlen(emit);
        if (used + need + 1 > size) return 0;   /* strftime's contract: 0 when it does not fit */
        memcpy(buffer + used, emit, need);
        used += need;
    }
    buffer[used] = 0;
    return used;
}
