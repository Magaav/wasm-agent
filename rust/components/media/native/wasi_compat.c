/* The two libc symbols this build needs and wasi-libc on wasm32-wasip2 does not provide.
 *
 * `clock` is what the linker asked for first: libavutil/random_seed.c calls it for entropy, wasi-snapshot's libc
 * has it, and a component does not. It is implemented on the clock a component does have, so ffmpeg gets a
 * real, moving value instead of a constant that would make every "random" seed the same.
 */
#include <time.h>

clock_t clock(void) {
    struct timespec now;
    if (timespec_get(&now, TIME_UTC) != TIME_UTC) return (clock_t)-1;
    return (clock_t)((long long)now.tv_sec * CLOCKS_PER_SEC + now.tv_nsec / (1000000000 / CLOCKS_PER_SEC));
}
