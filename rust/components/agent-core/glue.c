/* agent-core glue: the native interpreter's boot (rust/wa-host/src/main.rs) rebuilt inside wasm.
 *
 * - `host` is a table whose missing keys resolve, once, to a C closure that forwards the call
 *   through `wa:kernel/host` (rust_host_call in src/lib.rs). Only names the kernel's capability
 *   registry has resolve, so `if host.x then` reads exactly as it does natively.
 * - `EMBEDDED` resolves missing keys through the kernel too (`__embedded`): the kernel answers from
 *   the same table its native interpreter has (installed lua-core tree, else compiled in), and
 *   assignment still overrides, as tests rely on.
 * - `dofile` is the native bootstrap string, byte for byte.
 * - the two answers above are the immutable part of a boot, so they are cached for the life of the
 *   **instance** (`snapshot_*`, A2.3): a pooled instance answers many runs, and run 2 of a script
 *   must not pay again for what run 1 asked the kernel. Every run still gets a fresh `lua_State`, so
 *   globals, `package.loaded` and the stack are exactly as fresh as a one-shot `--core-component`
 *   run promises; only the kernel's own constants survive.
 * - stdout is flushed before every host call, so guest prints and host output keep their order.
 * - a **table** argument crosses as JSON (`slot_from`, `json_value`), so a capability receives a
 *   table rather than a refusal; a function argument still cannot cross, except the one place a
 *   native capability calls back into Lua: `http_sse`, whose line callback this file drives itself
 *   over the kernel's stream handle (`sse_call`) with the signature the core already uses. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <errno.h>

/* wasi-libc declares tmpfile() but does not define it; io.tmpfile then fails like any open error. */
FILE *tmpfile(void) { errno = ENOTSUP; return NULL; }

/* kind: 0 nil, 1 boolean (i 0/1), 2 integer, 3 number, 4 bytes (p/len), 5 string map (i entries
 * follow as key/value byte slots, results only), 6 JSON text of a Lua table (p/len). */
typedef struct { int kind; long long i; double n; const char *p; size_t len; } Slot;

extern int rust_host_call(const char *name, size_t nlen, int argc, const Slot *argv,
                          const Slot **out, char **err, size_t *errlen);
extern long long rust_host_open(const char *name, size_t nlen, int argc, const Slot *argv,
                                char **err, size_t *errlen);
extern int rust_host_next(long long handle, int verdict, const char *msg, size_t mlen,
                          const Slot **out, int *has, char **err, size_t *errlen);
extern int rust_host_close(long long handle, int verdict, const char *msg, size_t mlen,
                           const Slot **out, int *count, char **err, size_t *errlen);

/* The verdict a `next`/`close` carries: what the guest decided about the item it was last handed. */
#define VERDICT_CONTINUE 0
#define VERDICT_STOP 1
#define VERDICT_FAIL 2

/* ---- a table argument as JSON ---------------------------------------------------------------
 *
 * The kernel pushes the JSON back as the Lua table it stands for, so this is the whole argument
 * contract for tables: values JSON can carry travel unchanged, and anything JSON cannot carry is
 * refused by name with the reason, instead of arriving as a string the capability would misread. */

typedef struct { char *p; size_t len, cap; int failed; } Buf;

static const char *json_reason(int code) {
  switch (code) {
    case 1: return "the table nests too deeply";
    case 2: return "a string in the table is not valid UTF-8";
    case 3: return "the table holds a function, thread or userdata";
    case 4: return "the table has a key that is not a string or an array index";
    case 5: return "a number in the table is not finite";
    default: return "out of memory while encoding the table";
  }
}

static void buf_need(Buf *b, size_t extra) {
  if (b->failed) return;
  if (b->len + extra + 1 <= b->cap) return;
  size_t cap = b->cap ? b->cap : 64;
  while (cap < b->len + extra + 1) cap *= 2;
  char *grown = (char *)realloc(b->p, cap);
  if (!grown) { b->failed = 6; return; }
  b->p = grown;
  b->cap = cap;
}

static void buf_put(Buf *b, const char *data, size_t n) {
  if (b->failed) return;
  buf_need(b, n);
  if (b->failed) return;
  memcpy(b->p + b->len, data, n);
  b->len += n;
  b->p[b->len] = 0;
}

static void buf_lit(Buf *b, const char *text) { buf_put(b, text, strlen(text)); }

/* One well-formed UTF-8 sequence starting at s; 0 when the bytes are not valid UTF-8. */
static size_t utf8_one(const unsigned char *s, size_t n) {
  if (n == 0) return 0;
  unsigned char c = s[0];
  if (c < 0x80) return 1;
  size_t need;
  unsigned int code;
  if (c >= 0xc2 && c <= 0xdf) { need = 1; code = c & 0x1f; }
  else if (c >= 0xe0 && c <= 0xef) { need = 2; code = c & 0x0f; }
  else if (c >= 0xf0 && c <= 0xf4) { need = 3; code = c & 0x07; }
  else return 0;
  if (n < need + 1) return 0;
  for (size_t k = 1; k <= need; k++) {
    if ((s[k] & 0xc0) != 0x80) return 0;
    code = (code << 6) | (s[k] & 0x3f);
  }
  if (need == 2 && (code < 0x800 || (code >= 0xd800 && code <= 0xdfff))) return 0;
  if (need == 3 && (code < 0x10000 || code > 0x10ffff)) return 0;
  return need + 1;
}

static void json_string(Buf *b, const char *text, size_t n) {
  static const char hex[] = "0123456789abcdef";
  buf_lit(b, "\"");
  size_t at = 0;
  while (at < n && !b->failed) {
    unsigned char c = (unsigned char)text[at];
    if (c == '"' || c == '\\') { char pair[2] = { '\\', (char)c }; buf_put(b, pair, 2); at++; }
    else if (c == '\n') { buf_lit(b, "\\n"); at++; }
    else if (c == '\r') { buf_lit(b, "\\r"); at++; }
    else if (c == '\t') { buf_lit(b, "\\t"); at++; }
    else if (c < 0x20) {
      char escape[6] = { '\\', 'u', '0', '0', hex[(c >> 4) & 0xf], hex[c & 0xf] };
      buf_put(b, escape, 6);
      at++;
    } else {
      size_t width = utf8_one((const unsigned char *)text + at, n - at);
      if (width == 0) { b->failed = 2; return; }
      buf_put(b, text + at, width);
      at += width;
    }
  }
  buf_lit(b, "\"");
}

static void json_value(lua_State *L, int idx, Buf *b, int depth);

static void json_table(lua_State *L, int idx, Buf *b, int depth) {
  if (b->failed) return;
  if (depth > 24) { b->failed = 1; return; }
  if (idx < 0 && idx > LUA_REGISTRYINDEX) idx = lua_gettop(L) + idx + 1;
  /* An array is every key an integer and the keys exactly 1..n; `lua_rawlen` is the border, so a
   * table with a hole ({[1]=a,[3]=b}) is an object and is refused by the key rule below rather than
   * silently compacted. */
  size_t count = 0;
  int array = 1;
  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    count++;
    if (lua_type(L, -2) != LUA_TNUMBER || !lua_isinteger(L, -2)) array = 0;
    lua_pop(L, 1);
  }
  if (array && count > 0 && lua_rawlen(L, idx) != count) array = 0;
  if (array) {
    buf_lit(b, "[");
    for (size_t i = 1; i <= count && !b->failed; i++) {
      if (i > 1) buf_lit(b, ",");
      lua_rawgeti(L, idx, (lua_Integer)i);
      json_value(L, -1, b, depth + 1);
      lua_pop(L, 1);
    }
    buf_lit(b, "]");
    return;
  }
  buf_lit(b, "{");
  int first = 1;
  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    if (lua_type(L, -2) != LUA_TSTRING) { lua_pop(L, 2); b->failed = 4; return; }
    size_t klen = 0;
    const char *key = lua_tolstring(L, -2, &klen);
    if (!first) buf_lit(b, ",");
    first = 0;
    json_string(b, key, klen);
    buf_lit(b, ":");
    json_value(L, -1, b, depth + 1);
    lua_pop(L, 1);
  }
  buf_lit(b, "}");
}

static void json_value(lua_State *L, int idx, Buf *b, int depth) {
  if (b->failed) return;
  switch (lua_type(L, idx)) {
    case LUA_TNIL: buf_lit(b, "null"); break;
    case LUA_TBOOLEAN: buf_lit(b, lua_toboolean(L, idx) ? "true" : "false"); break;
    case LUA_TNUMBER:
      if (lua_isinteger(L, idx)) {
        char text[32];
        snprintf(text, sizeof text, "%lld", (long long)lua_tointeger(L, idx));
        buf_lit(b, text);
      } else {
        double value = lua_tonumber(L, idx);
        if (!isfinite(value)) { b->failed = 5; return; }
        /* `.0` keeps 1.0 a float: the kernel pushes a JSON integer as an integer, and Lua prints
         * the two differently, so dropping the marker would change what a capability sees. */
        char text[40];
        snprintf(text, sizeof text, "%.17g", value);
        if (!strpbrk(text, ".eE")) strncat(text, ".0", sizeof text - strlen(text) - 1);
        buf_lit(b, text);
      }
      break;
    case LUA_TSTRING: {
      size_t n = 0;
      const char *text = lua_tolstring(L, idx, &n);
      json_string(b, text, n);
      break;
    }
    case LUA_TTABLE: json_table(L, idx, b, depth); break;
    default: b->failed = 3; break;
  }
}

/* One argument as a Slot. 0 on failure, with the refusal pushed on the stack. */
static int slot_from(lua_State *L, int idx, const char *name, Slot *s, char **owned) {
  memset(s, 0, sizeof *s);
  switch (lua_type(L, idx)) {
    case LUA_TNONE: case LUA_TNIL: s->kind = 0; return 1;
    case LUA_TBOOLEAN: s->kind = 1; s->i = lua_toboolean(L, idx); return 1;
    case LUA_TNUMBER:
      if (lua_isinteger(L, idx)) { s->kind = 2; s->i = (long long)lua_tointeger(L, idx); }
      else { s->kind = 3; s->n = lua_tonumber(L, idx); }
      return 1;
    case LUA_TSTRING: s->kind = 4; s->p = lua_tolstring(L, idx, &s->len); return 1;
    case LUA_TTABLE: {
      Buf b = { 0, 0, 0, 0 };
      json_value(L, idx, &b, 0);
      if (b.failed) {
        lua_pushfstring(L, "unsupported_in_component_v1:%s (%s)", name, json_reason(b.failed));
        free(b.p);
        return 0;
      }
      s->kind = 6; s->p = b.p; s->len = b.len;
      *owned = b.p;
      return 1;
    }
    default:
      lua_pushfstring(L, "unsupported_in_component_v1:%s (a Lua %s cannot cross the bridge)", name,
                      lua_typename(L, lua_type(L, idx)));
      return 0;
  }
}

static void free_owned(char **owned, int argc) {
  if (!owned) return;
  for (int k = 0; k < argc; k++) free(owned[k]);
}

/* Push `n` results the kernel returned. */
static int push_slots(lua_State *L, const Slot *out, int n) {
  luaL_checkstack(L, n + 2, "host results");
  const Slot *s = out;
  for (int k = 0; k < n; k++, s++) {
    switch (s->kind) {
      case 1: lua_pushboolean(L, (int)s->i); break;
      case 2: lua_pushinteger(L, (lua_Integer)s->i); break;
      case 3: lua_pushnumber(L, s->n); break;
      case 4: lua_pushlstring(L, s->p, s->len); break;
      case 5: { /* string map: 2 * entries key/value byte slots follow */
        int entries = (int)s->i;
        lua_createtable(L, 0, entries);
        for (int e = 0; e < entries; e++) {
          s++; lua_pushlstring(L, s->p, s->len);
          s++; lua_pushlstring(L, s->p, s->len);
          lua_rawset(L, -3);
        }
        break;
      }
      case 6:
        /* No version of this bridge defines a table result the kernel has to encode: a call's answer
         * is a scalar or a flat string map, and a stream's answer is the capability's JSON text. */
        return luaL_error(L, "unsupported_in_component_v1 (the kernel sent a table result the bridge does not define)");
      default: lua_pushnil(L);
    }
  }
  return n;
}

static int forward(lua_State *L, const char *name, size_t nlen, int first, int argc) {
  Slot stack_slots[16];
  Slot *slots = argc <= 16 ? stack_slots : (Slot *)calloc((size_t)argc, sizeof(Slot));
  char **owned = argc > 0 ? (char **)calloc((size_t)argc, sizeof(char *)) : NULL;
  if (!slots || (argc > 0 && !owned)) {
    free(owned);
    if (slots != stack_slots) free(slots);
    return luaL_error(L, "out of memory storing host arguments");
  }
  for (int k = 0; k < argc; k++) {
    if (!slot_from(L, first + k, name, &slots[k], &owned[k])) {
      free_owned(owned, argc);
      free(owned);
      if (slots != stack_slots) free(slots);
      return lua_error(L);
    }
  }
  fflush(stdout);
  const Slot *out = NULL; char *err = NULL; size_t errlen = 0;
  int n = rust_host_call(name, nlen, argc, slots, &out, &err, &errlen);
  free_owned(owned, argc);
  free(owned);
  if (slots != stack_slots) free(slots);
  if (n < 0) {
    lua_pushlstring(L, err, errlen);
    free(err);
    return lua_error(L);
  }
  return push_slots(L, out, n);
}

static int host_fn(lua_State *L) {
  size_t nlen;
  const char *name = lua_tolstring(L, lua_upvalueindex(1), &nlen);
  return forward(L, name, nlen, 1, lua_gettop(L));
}

/* ---- the instance snapshot (A2.3) ------------------------------------------------------------
 *
 * A pooled instance answers many runs (rust/wa-capabilities/src/core_component.rs). Each run still
 * gets a fresh `lua_State`, so nothing one script set can be seen by the next - that is the promise a
 * one-shot `--core-component` run makes and it is kept. What is *not* per-run is what the kernel
 * answers once and never changes for the life of this instance:
 *
 *   - `__names`: the capability registry's names, a process constant;
 *   - `__embedded`: the shipping module sources, which the native interpreter reads into its
 *     `EMBEDDED` table once at boot.
 *
 * Both are cached here, so run 2 of the same script asks the kernel for neither. That is the whole
 * snapshot: the guest's immutable boot, reused; the guest's mutable state, discarded per run. The
 * cache lives in the guest instance, so a new instance starts empty and a retired one takes it with
 * it. Nothing here can go stale: the registry cannot change inside a process, and the kernel's
 * `EMBEDDED` is built at boot from the installed tree or the compiled-in copy. */
typedef struct SnapMod { char *path; size_t plen; char *src; size_t slen; struct SnapMod *next; } SnapMod;

static SnapMod *SNAPSHOT_MODULES = NULL;
static char *SNAPSHOT_NAMES = NULL;
static size_t SNAPSHOT_NAMES_LEN = 0;
static int SNAPSHOT_NAMES_READY = 0;

/* The registry's names, asked of the kernel once per instance; NULL when the kernel refused (the next
 * run asks again rather than remembering a failure). */
static const char *snapshot_names(lua_State *L, size_t *len) {
  if (!SNAPSHOT_NAMES_READY) {
    int base = lua_gettop(L);
    int n = forward(L, "__names", 7, 0, 0);
    if (n >= 1 && lua_type(L, base + 1) == LUA_TSTRING) {
      size_t got = 0;
      const char *p = lua_tolstring(L, base + 1, &got);
      SNAPSHOT_NAMES = (char *)malloc(got + 1);
      if (SNAPSHOT_NAMES) {
        memcpy(SNAPSHOT_NAMES, p, got);
        SNAPSHOT_NAMES[got] = 0;
        SNAPSHOT_NAMES_LEN = got;
        SNAPSHOT_NAMES_READY = 1;
      }
    }
    lua_settop(L, base);
    if (!SNAPSHOT_NAMES_READY) return NULL;
  }
  *len = SNAPSHOT_NAMES_LEN;
  return SNAPSHOT_NAMES;
}

/* EMBEDDED[k] from the instance snapshot: the first read of a module asks the kernel, every later
 * read - from this run or any other - pushes the bytes already held. 1 with the string on the stack,
 * or 0 with nothing pushed (the kernel does not know the module, exactly as before). */
static int snapshot_embedded(lua_State *L, int idx) {
  size_t plen = 0;
  const char *path = lua_tolstring(L, idx, &plen);
  if (!path) return 0;
  for (SnapMod *m = SNAPSHOT_MODULES; m; m = m->next) {
    if (m->plen == plen && memcmp(m->path, path, plen) == 0) {
      lua_pushlstring(L, m->src, m->slen);
      return 1;
    }
  }
  int base = lua_gettop(L);
  lua_pushvalue(L, idx);                                  /* argument at base + 1 */
  int n = forward(L, "__embedded", 10, base + 1, 1);      /* answer at base + 2 */
  if (n < 1 || lua_type(L, base + 2) != LUA_TSTRING) { lua_settop(L, base); return 0; }
  size_t slen = 0;
  const char *src = lua_tolstring(L, base + 2, &slen);
  SnapMod *m = (SnapMod *)calloc(1, sizeof *m);
  char *copy = (char *)malloc(slen + 1);
  char *key = (char *)malloc(plen + 1);
  if (m && copy && key) {
    memcpy(copy, src, slen); copy[slen] = 0;
    memcpy(key, path, plen); key[plen] = 0;
    m->path = key; m->plen = plen; m->src = copy; m->slen = slen;
    m->next = SNAPSHOT_MODULES;
    SNAPSHOT_MODULES = m;
    lua_settop(L, base);
    lua_pushlstring(L, m->src, m->slen);
    return 1;
  }
  /* Out of memory is not a cache miss to hide: hand the caller what the kernel said, uncached. */
  free(m); free(copy); free(key);
  lua_settop(L, base + 2);
  return 1;
}

/* ---- http_sse: the one capability that calls back into Lua ---------------------------------
 *
 * Native, `host.http_sse(method, url, headers, body, on_line, timeout?)` keeps the socket open and
 * calls `on_line(line)` per line, and the answer reports how the read ended. The guest cannot be
 * re-entered from inside a host call, so the kernel runs the *same* native `http_sse` on a thread and
 * hands this file one line per `next`; this loop is the caller the native callback would have been,
 * which is why the answer - including `callback_stopped` and `line_callback_failed` - is the JSON a
 * native call returns, byte for byte. */

/* End the stream and return the capability's own answer (the JSON a native call returns). */
static int sse_finish(lua_State *L, long long handle, int verdict, const char *message, size_t msglen) {
  const Slot *out = NULL; int count = 0; char *err = NULL; size_t errlen = 0;
  if (rust_host_close(handle, verdict, message, msglen, &out, &count, &err, &errlen) < 0) {
    lua_pushlstring(L, err, errlen);
    free(err);
    return lua_error(L);
  }
  return push_slots(L, out, count);
}

static int sse_call(lua_State *L) {
  int nargs = lua_gettop(L);
  int cbtype = lua_type(L, 5);
  if (cbtype != LUA_TFUNCTION && cbtype != LUA_TNIL && cbtype != LUA_TNONE)
    return luaL_error(L, "unsupported_in_component_v1:http_sse (the callback must be a function)");
  /* Six slots: the caller's arguments in the positions the native capability reads them from, with
   * slot 5 a marker saying whether a callback was passed (the kernel puts its own there) so every
   * validation - including `http_sse_requires_on_line` - happens in the native code, in its order. */
  Slot slots[6];
  char *owned[6] = { 0 };
  for (int k = 1; k <= 6; k++) {
    memset(&slots[k - 1], 0, sizeof slots[0]);
    if (k == 5) {
      if (cbtype == LUA_TFUNCTION) { slots[4].kind = 1; slots[4].i = 1; }
      continue;
    }
    if (k > nargs) continue;
    if (!slot_from(L, k, "http_sse", &slots[k - 1], &owned[k - 1])) {
      free_owned(owned, 6);
      return lua_error(L);
    }
  }
  fflush(stdout);
  char *err = NULL; size_t errlen = 0;
  long long handle = rust_host_open("http_sse", 8, 6, slots, &err, &errlen);
  free_owned(owned, 6);
  if (handle < 0) {
    lua_pushlstring(L, err, errlen);
    free(err);
    return lua_error(L);
  }
  int verdict = -1; /* no verdict yet: there is no previous line on the first call */
  char *failed = NULL;
  size_t failedlen = 0;
  for (;;) {
    const Slot *out = NULL; int has = 0; char *next_err = NULL; size_t next_errlen = 0;
    fflush(stdout);
    /* The verdict travels with the ask for the next line, so the reader learns what became of the
     * line it handed over *before* it reads another one - that is what makes a `stop` end the read
     * at that line and not one past it. */
    if (rust_host_next(handle, verdict, failed, failedlen, &out, &has, &next_err, &next_errlen) < 0) {
      lua_pushlstring(L, next_err, next_errlen);
      free(next_err);
      free(failed);
      rust_host_close(handle, VERDICT_STOP, NULL, 0, &out, &has, &next_err, &next_errlen);
      return lua_error(L);
    }
    free(failed);
    failed = NULL;
    failedlen = 0;
    if (!has) break;
    if (cbtype != LUA_TFUNCTION) break;
    lua_pushvalue(L, 5);
    lua_pushlstring(L, out->p, out->len);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
      /* A Lua error in the callback ends the read at that line, as native: the kernel redacts the
       * text and reports `line_callback_failed`. The text is copied out of the interpreter so it
       * cannot move before the kernel is told about it. */
      size_t mlen = 0;
      const char *message = lua_tolstring(L, -1, &mlen);
      if (!message) { message = "lua error"; mlen = 9; }
      failed = (char *)malloc(mlen + 1);
      if (!failed) { lua_pop(L, 1); break; }
      memcpy(failed, message, mlen);
      failed[mlen] = 0;
      failedlen = mlen;
      verdict = VERDICT_FAIL;
      lua_pop(L, 1);
      continue;
    }
    verdict = (lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1) == 0) ? VERDICT_STOP : VERDICT_CONTINUE;
    lua_pop(L, 1);
  }
  return sse_finish(L, handle, VERDICT_CONTINUE, NULL, 0);
}

/* host.__index(t, k): a closure for a registered capability, nil for anything else */
static int host_index(lua_State *L) {
  if (lua_type(L, 2) != LUA_TSTRING) return 0;
  lua_pushvalue(L, 2);
  if (lua_rawget(L, lua_upvalueindex(1)) == LUA_TNIL) return 0; /* not in the registry */
  lua_pop(L, 1);
  size_t klen = 0;
  const char *key = lua_tolstring(L, 2, &klen);
  lua_pushvalue(L, 2);
  if (klen == 8 && memcmp(key, "http_sse", 8) == 0) {
    lua_pushcclosure(L, sse_call, 0);
  } else {
    lua_pushcclosure(L, host_fn, 1);
  }
  lua_pushvalue(L, 2);
  lua_pushvalue(L, -2);
  lua_rawset(L, 1);
  return 1;
}

/* EMBEDDED.__index(t, k): the instance snapshot, which asks the kernel for a module once */
static int embedded_index(lua_State *L) {
  if (lua_type(L, 2) != LUA_TSTRING) return 0;
  int base = lua_gettop(L);
  if (!snapshot_embedded(L, 2)) return 0;
  lua_pushvalue(L, 2);
  lua_pushvalue(L, -2);
  lua_rawset(L, 1);
  lua_settop(L, base + 1);
  return 1;
}

static const char *BOOTSTRAP =
  "LOADED_SOURCES = {}; function dofile(path) "
  "local root = host.getenv('WASM_AGENT_LUA_ROOT'); "
  "if root and root ~= '' then "
  "local text = host.read_file(root .. '/' .. path); "
  "if not text then error('lua_root_unreadable: ' .. root .. '/' .. path) end; "
  "LOADED_SOURCES[path] = host.sha256(text); "
  "return assert(load(text, '@' .. root .. '/' .. path))() "
  "end; "
  "local source = EMBEDDED[path]; "
  "if not source then error('embedded module missing: ' .. tostring(path)) end; "
  "LOADED_SOURCES[path] = host.sha256(source); "
  "return assert(load(source, '@' .. path))() end";

static int fail(lua_State *L, char **err, size_t *errlen) {
  size_t len = 0;
  const char *msg = lua_tolstring(L, -1, &len);
  if (!msg) { msg = "lua error"; len = strlen(msg); }
  *err = (char *)malloc(len + 1);
  memcpy(*err, msg, len);
  *errlen = len;
  fflush(stdout);
  lua_close(L);
  return 1;
}

typedef struct { const char *entry; size_t elen; int argc; const char **argv; const size_t *argl; } RunArgs;

/* Everything runs under one lua_pcall, so a refusal from the kernel during boot is an error, not an abort. */
static int boot(lua_State *L) {
  RunArgs *a = (RunArgs *)lua_touserdata(L, 1);
  lua_settop(L, 0);

  /* host: the registry's names (the instance snapshot), then the lazy table */
  lua_newtable(L);                                     /* 1 host */
  lua_newtable(L);                                     /* 2 metatable */
  lua_newtable(L);                                     /* 3 names set */
  size_t nameslen = 0;
  const char *names = snapshot_names(L, &nameslen);
  if (names) {
    size_t len = nameslen; const char *p = names; const char *end = p + len;
    while (p < end) {
      const char *nl = memchr(p, '\n', (size_t)(end - p)); if (!nl) nl = end;
      if (nl > p) { lua_pushlstring(L, p, (size_t)(nl - p)); lua_pushboolean(L, 1); lua_rawset(L, 3); }
      p = nl + 1;
    }
  }
  lua_settop(L, 3);
  lua_pushcclosure(L, host_index, 1);
  lua_setfield(L, 2, "__index");
  lua_setmetatable(L, 1);
  lua_setglobal(L, "host");

  lua_createtable(L, a->argc, 0);
  for (int k = 0; k < a->argc; k++) { lua_pushlstring(L, a->argv[k], a->argl[k]); lua_rawseti(L, -2, k + 1); }
  lua_setglobal(L, "args");

  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, embedded_index);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
  lua_setglobal(L, "EMBEDDED");

  if (luaL_loadbufferx(L, BOOTSTRAP, strlen(BOOTSTRAP), "bootstrap", NULL) != LUA_OK) return lua_error(L);
  lua_call(L, 0, 0);

  /* the script, read through the bridge as the native WA_SCRIPT run reads it from disk */
  lua_settop(L, 0);
  lua_pushlstring(L, a->entry, a->elen);              /* 1 entry */
  if (forward(L, "__script", 8, 1, 1) < 1 || lua_type(L, 2) != LUA_TSTRING)
    return luaL_error(L, "read %s: unreadable", lua_tostring(L, 1));
  size_t slen; const char *src = lua_tolstring(L, 2, &slen);
  if (luaL_loadbufferx(L, src, slen, lua_tostring(L, 1), NULL) != LUA_OK) return lua_error(L);
  lua_call(L, 0, 0);
  return 0;
}

int wa_core_run(const char *entry, size_t elen, int argc, const char **argv, const size_t *argl,
                char **err, size_t *errlen) {
  RunArgs a = { entry, elen, argc, argv, argl };
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  lua_pushcfunction(L, boot);
  lua_pushlightuserdata(L, &a);
  if (lua_pcall(L, 1, 0, 0) != LUA_OK) return fail(L, err, errlen);
  fflush(stdout);
  fflush(stderr);
  lua_close(L);
  return 0;
}
