/* agent-core glue: the native interpreter's boot (rust/wa-host/src/main.rs) rebuilt inside wasm.
 *
 * - `host` is a table whose missing keys resolve, once, to a C closure that forwards the call
 *   through `wa:kernel/host` (rust_host_call in src/lib.rs). Only names the kernel's capability
 *   registry has resolve, so `if host.x then` reads exactly as it does natively.
 * - `EMBEDDED` resolves missing keys through the kernel too (`__embedded`): the kernel answers from
 *   the same table its native interpreter has (installed lua-core tree, else compiled in), and
 *   assignment still overrides, as tests rely on.
 * - `dofile` is the native bootstrap: the same two answers (`LOADED_SOURCES[path]` and the module's
 *   chunk), resolved through `__load`, which answers them from the compiled-module cache when this
 *   instance already compiled those bytes (A2.7, below).
 * - the two answers above are the immutable part of a boot, so they are cached for the life of the
 *   **instance** (`snapshot_*`, A2.3): a pooled instance answers many runs, and run 2 of a script
 *   must not pay again for what run 1 asked the kernel. Every run still gets a fresh `lua_State`, so
 *   globals, `package.loaded` and the stack are exactly as fresh as a one-shot `--core-component`
 *   run promises; only the kernel's own constants survive — the registry's names, the shipping
 *   modules' sources, and each module's compiled chunk, which is the cache that makes a turn's ~205
 *   module loads cost one 64-byte digest each instead of a copy and a compile.
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
typedef struct SnapMod { char *path; size_t plen; char *src; size_t slen; char *digest; size_t dlen; struct SnapMod *next; } SnapMod;

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
  int n = forward(L, "__embedded", 10, base + 1, 1);      /* source at base + 2, digest at base + 3 */
  if (n < 1 || lua_type(L, base + 2) != LUA_TSTRING) { lua_settop(L, base); return 0; }
  size_t slen = 0, dlen = 0;
  const char *src = lua_tolstring(L, base + 2, &slen);
  const char *digest = n >= 2 && lua_type(L, base + 3) == LUA_TSTRING ? lua_tolstring(L, base + 3, &dlen) : NULL;
  SnapMod *m = (SnapMod *)calloc(1, sizeof *m);
  char *copy = (char *)malloc(slen + 1);
  char *key = (char *)malloc(plen + 1);
  char *hash = digest ? (char *)malloc(dlen + 1) : (char *)malloc(1);
  if (m && copy && key && hash) {
    memcpy(copy, src, slen); copy[slen] = 0;
    memcpy(key, path, plen); key[plen] = 0;
    if (digest) { memcpy(hash, digest, dlen); hash[dlen] = 0; }
    m->path = key; m->plen = plen; m->src = copy; m->slen = slen;
    m->digest = hash; m->dlen = digest ? dlen : 0;
    m->next = SNAPSHOT_MODULES;
    SNAPSHOT_MODULES = m;
    lua_settop(L, base);
    lua_pushlstring(L, m->src, m->slen);
    return 1;
  }
  /* Out of memory is not a cache miss to hide: hand the caller what the kernel said, uncached. */
  free(m); free(copy); free(key); free(hash);
  lua_settop(L, base + 2);
  return 1;
}

/* ---- the compiled-module cache (A2.7) --------------------------------------------------------
 *
 * A turn loads ~205 modules - `lua/core/server.lua` and everything a turn reaches through `dofile`,
 * which is the core's module system - and until now every one of those loads crossed as the module's
 * whole text and was then *compiled*: a turn moved 2.4 MB into the guest and paid the interpreter for
 * code it had already compiled 200 times. That is true of a boot and of a lazy load inside a live
 * state alike, which is why the cache sits at `dofile` rather than at instance creation.
 *
 * This is the module cache the job calls the pre-initialized boot: the compiled chunk of every module,
 * kept in the instance (it survives `wa_core_reset`, which drops the `lua_State` and not the cache),
 * keyed by the module's path **and its digest**. A boot asks the kernel one `__digest` (64 bytes) per
 * module - `__source`'s answer without the text - and loads the chunk when the digest is the one it
 * compiled. A changed file (a new `WASM_AGENT_LUA_ROOT`, a `/update`, a test that edits a module) has
 * a different digest, so its chunk is not used for it: the guest falls back to `__source`/`__embedded`
 * and compiles that text again, exactly as before. The digest is the kernel's, not a memory of the
 * file's mtime, and `LOADED_SOURCES` still carries it - so what the core reports about its own sources
 * is unchanged.
 *
 * Why not a Wizer-style pre-initialized image: the guest's boot calls `wa:kernel/host` (getenv,
 * `__names`, the module reads) and Wizer runs a guest to snapshot it, so it would need a real kernel
 * connected at build time, and this tree has no `wizer` offline. The chunk cache needs nothing but the
 * interpreter it already has. */
typedef struct ModChunk {
  char *key; size_t klen;
  char *digest; size_t dlen;
  char *chunk; size_t clen;
  struct ModChunk *next;
} ModChunk;

static ModChunk *MODULE_CHUNKS = NULL;
/* The `WASM_AGENT_LUA_ROOT` this boot resolves modules through, read once per boot: `dofile` used to
 * ask `host.getenv` per module (~200 crossings a boot) for a value nothing in the guest can change. */
static char *MODULE_ROOT = NULL;
static size_t MODULE_ROOT_LEN = 0;

static ModChunk *module_find(const char *key, size_t klen, const char *digest, size_t dlen) {
  for (ModChunk *m = MODULE_CHUNKS; m; m = m->next) {
    if (m->klen == klen && m->dlen == dlen && memcmp(m->key, key, klen) == 0 && memcmp(m->digest, digest, dlen) == 0)
      return m;
  }
  return NULL;
}

static void module_forget(ModChunk *entry) {
  for (ModChunk **link = &MODULE_CHUNKS; *link; link = &(*link)->next) {
    if (*link == entry) { *link = entry->next; break; }
  }
  free(entry->key); free(entry->digest); free(entry->chunk); free(entry);
}

/* Keep `chunk` as the compiled form of `key` at `digest`, replacing whatever this module had before:
 * one entry per module, so a tree that changes N times holds N versions of only the modules that
 * changed, never an unbounded pile of them. Out of memory is a miss, not a failure: the caller already
 * has the function it compiled. */
static void module_store(const char *key, size_t klen, const char *digest, size_t dlen,
                         const char *chunk, size_t clen) {
  if (!digest || dlen == 0 || !chunk || clen == 0) return;
  for (ModChunk *m = MODULE_CHUNKS; m; m = m->next) {
    if (m->klen == klen && memcmp(m->key, key, klen) == 0) {
      if (m->dlen == dlen && memcmp(m->digest, digest, dlen) == 0) {
        free(m->chunk);
        m->chunk = (char *)malloc(clen);
        if (!m->chunk) { m->clen = 0; return; }
        memcpy(m->chunk, chunk, clen);
        m->clen = clen;
        return;
      }
      module_forget(m);
      break;
    }
  }
  ModChunk *entry = (ModChunk *)calloc(1, sizeof *entry);
  if (!entry) return;
  entry->key = (char *)malloc(klen + 1);
  entry->digest = (char *)malloc(dlen + 1);
  entry->chunk = (char *)malloc(clen);
  if (!entry->key || !entry->digest || !entry->chunk) {
    free(entry->key); free(entry->digest); free(entry->chunk); free(entry);
    return;
  }
  memcpy(entry->key, key, klen); entry->key[klen] = 0; entry->klen = klen;
  memcpy(entry->digest, digest, dlen); entry->digest[dlen] = 0; entry->dlen = dlen;
  memcpy(entry->chunk, chunk, clen); entry->clen = clen;
  entry->next = MODULE_CHUNKS;
  MODULE_CHUNKS = entry;
}

/* `lua_dump`'s sink: the bytecode of one chunk, in the same `Buf` the table encoder uses. */
static int dump_writer(lua_State *L, const void *bytes, size_t size, void *data) {
  (void)L;
  Buf *out = (Buf *)data;
  buf_put(out, (const char *)bytes, size);
  return out->failed ? 1 : 0;
}

/* `__source(path)` - a module's text and its digest, from the kernel, in ONE crossing.
 *
 * The boot reads a module and digests it (`LOADED_SOURCES`), and native that is two C calls on the
 * same bytes. Across the bridge it was two crossings with the whole module text going in each
 * direction, which is the sort of chatty pair a profile should not have to show twice: the kernel
 * digests the bytes it just read (`__source` in core_component.rs) and answers both. Same values, half
 * the crossings, one copy instead of two - and the digest is computed on exactly the bytes
 * `host.sha256(host.read_file(path))` would have hashed. */
static int source_fn(lua_State *L) {
  if (lua_type(L, 1) != LUA_TSTRING) return luaL_error(L, "internal: __source(path) needs a path");
  return forward(L, "__source", 8, 1, 1);
}

/* `__module(path)` - a shipping module's text and digest from the instance snapshot (EMBEDDED). The
 * snapshot caches both, so the second read of a module in this instance crosses nothing at all. */
static int module_fn(lua_State *L) {
  size_t plen = 0;
  const char *path = lua_tolstring(L, 1, &plen);
  if (!path) return luaL_error(L, "internal: __module(path) needs a path");
  int base = lua_gettop(L);
  lua_pushvalue(L, 1);
  if (!snapshot_embedded(L, base + 1)) { lua_settop(L, base); lua_pushnil(L); lua_pushnil(L); return 2; }
  /* The snapshot holds malloc'd copies, not Lua strings, so dropping what it pushed loses nothing: the
   * entry is in the cache now, and both halves are pushed from there. */
  lua_settop(L, base);
  for (SnapMod *m = SNAPSHOT_MODULES; m; m = m->next) {
    if (m->plen == plen && memcmp(m->path, path, plen) == 0) {
      lua_pushlstring(L, m->src, m->slen);
      lua_pushlstring(L, m->digest ? m->digest : "", m->dlen);
      return 2;
    }
  }
  lua_pushnil(L);
  lua_pushnil(L);
  return 2;
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

/* `__load(path)` - a module as the function its `dofile` calls, from the compiled-module cache when
 * this instance already compiled these bytes.
 *
 * Answers `(function, digest)`; `(nil, nil)` for a module the kernel does not have, which the caller
 * turns into the same words as before (`lua_root_unreadable: ...` / `embedded module missing: ...`);
 * and raises the compile error `assert(load(text))` would have raised, so a broken module keeps its
 * own message. The chunk name is the one the source path used (`@<path>`), so a runtime error inside a
 * module still names the file and line it came from: the chunk is dumped with its debug information,
 * and line numbers are part of it. */
static int load_fn(lua_State *L) {
  size_t plen = 0;
  const char *path = lua_type(L, 1) == LUA_TSTRING ? lua_tolstring(L, 1, &plen) : NULL;
  if (!path) return luaL_error(L, "internal: __load(path) needs a path");
  int rooted = MODULE_ROOT && MODULE_ROOT_LEN > 0;
  size_t klen = plen + (rooted ? MODULE_ROOT_LEN + 1 : 0);
  char *key = (char *)malloc(klen + 2);
  if (!key) return luaL_error(L, "out of memory loading %s", path);
  if (rooted) {
    memcpy(key, MODULE_ROOT, MODULE_ROOT_LEN);
    key[MODULE_ROOT_LEN] = '/';
    memcpy(key + MODULE_ROOT_LEN + 1, path, plen);
  } else {
    memcpy(key, path, plen);
  }
  key[klen] = 0;
  key[klen + 1] = 0;
  char *chunkname = (char *)malloc(klen + 2);   /* '@' + key, as `load(text, '@' .. path)` */
  if (!chunkname) { free(key); return luaL_error(L, "out of memory loading %s", path); }
  chunkname[0] = '@';
  memcpy(chunkname + 1, key, klen + 1);

  /* 1. has this module changed? One crossing, 64 bytes, no text. */
  int base = lua_gettop(L);
  lua_pushlstring(L, key, klen);
  int n = rooted ? forward(L, "__digest", 8, base + 1, 1) : forward(L, "__edigest", 9, base + 1, 1);
  char *known = NULL;
  size_t knownlen = 0;
  if (n >= 1 && lua_type(L, base + 2) == LUA_TSTRING) {
    const char *digest = lua_tolstring(L, base + 2, &knownlen);
    known = (char *)malloc(knownlen + 1);
    if (known) { memcpy(known, digest, knownlen); known[knownlen] = 0; } else { knownlen = 0; }
  }
  lua_settop(L, base);

  /* 2. the chunk compiled for exactly these bytes, if this instance has it */
  if (known) {
    ModChunk *hit = module_find(key, klen, known, knownlen);
    if (hit) {
      if (luaL_loadbufferx(L, hit->chunk, hit->clen, chunkname, "b") == LUA_OK) {
        lua_pushlstring(L, known, knownlen);
        free(key); free(chunkname); free(known);
        return 2;                                 /* the function, then its digest */
      }
      /* A chunk that will not load is a miss, never the caller's error: drop it and compile the text. */
      lua_pop(L, 1);
      module_forget(hit);
    }
  }

  /* 3. the text, as every boot before this one asked for it */
  lua_pushlstring(L, key, klen);
  n = rooted ? forward(L, "__source", 8, base + 1, 1) : forward(L, "__embedded", 10, base + 1, 1);
  if (n < 1 || lua_type(L, base + 2) != LUA_TSTRING) {
    lua_settop(L, base);
    free(key); free(chunkname); free(known);
    lua_pushnil(L);
    lua_pushnil(L);
    return 2;
  }
  size_t slen = 0;
  const char *text = lua_tolstring(L, base + 2, &slen);
  const char *digest = n >= 2 && lua_type(L, base + 3) == LUA_TSTRING ? lua_tolstring(L, base + 3, &knownlen) : NULL;
  if (luaL_loadbufferx(L, text, slen, chunkname, "bt") != LUA_OK) {
    free(key); free(chunkname); free(known);
    return lua_error(L);                          /* assert(load(text)) raised the same text */
  }
  /* 4. keep what was just compiled, keyed by the digest of the text it came from */
  {
    Buf dumped = { 0, 0, 0, 0 };
    lua_pushvalue(L, -1);
    lua_dump(L, dump_writer, &dumped, 0);
    if (!dumped.failed) module_store(key, klen, digest, digest ? knownlen : 0, dumped.p, dumped.len);
    free(dumped.p);
  }
  lua_pushlstring(L, digest ? digest : "", digest ? knownlen : 0);
  free(key); free(chunkname); free(known);
  return 2;                                       /* the function, then its digest */
}

/* The guest's `dofile`, the native one (rust/wa-host/src/main.rs) with its two boot questions - the
 * module's text and its digest - answered from the compiled-module cache when it can be, and in one
 * crossing (`__source`, `__module`, the kernel hashing the bytes it read) when it cannot. The values
 * are identical: the kernel hashes the same bytes it hands over, and `LOADED_SOURCES` carries that
 * digest, as native. */
static const char *BOOTSTRAP =
  "LOADED_SOURCES = {}; function dofile(path) "
  "local chunk, digest = __load(path); "
  "if not chunk then "
  "if __root and __root ~= '' then error('lua_root_unreadable: ' .. __root .. '/' .. path) end; "
  "error('embedded module missing: ' .. tostring(path)) end; "
  "LOADED_SOURCES[path] = digest; "
  "return chunk() end";

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

/* The tables every entry point installs: `host` (the registry's names from the instance snapshot, then
 * a lazy closure per name), `args`, `EMBEDDED` (the instance snapshot of the shipping modules) and
 * `dofile` (the native bootstrap, byte for byte). A non-zero return leaves the error on the stack for
 * the caller's pcall; on success the stack is as it was found. */
static int install_globals(lua_State *L, int argc, const char **argv, const size_t *argl) {
  int base = lua_gettop(L);

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
  /* relative to `base`: index 1 host, 2 metatable, 3 names set */
  lua_settop(L, base + 3);
  lua_pushcclosure(L, host_index, 1);
  lua_setfield(L, 2, "__index");
  lua_setmetatable(L, 1);
  lua_setglobal(L, "host");

  lua_createtable(L, argc, 0);
  for (int k = 0; k < argc; k++) { lua_pushlstring(L, argv[k], argl[k]); lua_rawseti(L, -2, k + 1); }
  lua_setglobal(L, "args");

  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, embedded_index);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
  lua_setglobal(L, "EMBEDDED");

  /* The boot's two combined asks (see BOOTSTRAP): one crossing each, both kernel calls the host
   * answers from the bytes it reads. Not on `host`: the guest's `host.*` surface is the registry's,
   * and a script that lists it must see exactly what a native run sees. */
  lua_pushcfunction(L, source_fn);
  lua_setglobal(L, "__source");
  lua_pushcfunction(L, module_fn);
  lua_setglobal(L, "__module");
  lua_pushcfunction(L, load_fn);
  lua_setglobal(L, "__load");

  /* The module root this boot resolves modules through, read once (`load_fn`), and published as
   * `__root` so `dofile`'s own error text keeps naming it. Reading it here is the same crossing at the
   * same point in the boot: it is a global this file installs, like `__source`, not a `host.*` name, so
   * `host` still lists exactly what the registry has. */
  free(MODULE_ROOT);
  MODULE_ROOT = NULL;
  MODULE_ROOT_LEN = 0;
  {
    int mark = lua_gettop(L);
    lua_pushliteral(L, "WASM_AGENT_LUA_ROOT");
    if (forward(L, "getenv", 6, mark + 1, 1) >= 1 && lua_type(L, mark + 2) == LUA_TSTRING) {
      size_t len = 0;
      const char *root = lua_tolstring(L, mark + 2, &len);
      MODULE_ROOT = (char *)malloc(len + 1);
      if (MODULE_ROOT) { memcpy(MODULE_ROOT, root, len); MODULE_ROOT[len] = 0; MODULE_ROOT_LEN = len; }
    }
    lua_settop(L, mark);
  }
  lua_pushlstring(L, MODULE_ROOT ? MODULE_ROOT : "", MODULE_ROOT_LEN);
  lua_setglobal(L, "__root");
  if (luaL_loadbufferx(L, BOOTSTRAP, strlen(BOOTSTRAP), "bootstrap", NULL) != LUA_OK) return 1;
  if (lua_pcall(L, 0, 0, 0) != LUA_OK) return 1;
  lua_settop(L, base);
  return 0;
}

/* Everything runs under one lua_pcall, so a refusal from the kernel during boot is an error, not an abort. */
static int boot(lua_State *L) {
  RunArgs *a = (RunArgs *)lua_touserdata(L, 1);
  lua_settop(L, 0);
  if (install_globals(L, a->argc, a->argv, a->argl)) return lua_error(L);

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

/* ---- the long-lived core (A2.5) ---------------------------------------------------------------
 *
 * A node thread answers its work items on one instance (`serve`'s node-thread loop leases once, the
 * control and placement interpreters once each), so the guest keeps ONE `lua_State` for the life of
 * the instance instead of building one per request: `lua/core/server.lua`'s module bodies and
 * `memory.setup()` run once per node thread, and the core's own `local agent` and in-Lua tables
 * survive between items exactly as they do in the native interpreter. Nothing of the *run* lives
 * here: a work item's arguments are copied in and its answer copied out, and the sink, cancel flag
 * and run id stay on the host, where the capability layer keeps them per item.
 *
 * A lease that changes hands is reset (`wa_core_reset`, called by the pool on release), so an
 * instance never hands one caller's Lua state to the next.
 *
 * Status: 0 answered, 1 the item raised (the script's own text), 2 no such function,
 * 3 the core could not boot (sticky: reported on every later call rather than silently retried). */
static lua_State *LOOP_L = NULL;
static char *LOOP_FAILED = NULL;
static size_t LOOP_FAILED_LEN = 0;
static int LOOP_SUBAGENTS = 0;      /* 0 not asked for yet, 1 loaded, 2 tried and failed */

static void copy_out(const char *text, size_t len, char **out, size_t *outlen) {
  char *buffer = (char *)malloc(len + 1);
  if (!buffer) { *out = NULL; *outlen = 0; return; }
  if (len) memcpy(buffer, text, len);
  buffer[len] = 0;
  *out = buffer;
  *outlen = len;
}

/* The loader/entry modules the binary's interpreter factory boots, in the same order: server.lua at
 * boot, subagents.lua by the first item that needs it. */
static void loop_dofile(lua_State *L, const char *path) {
  lua_getglobal(L, "dofile");
  lua_pushstring(L, path);
  lua_call(L, 1, 0);
}

static int loop_boot(lua_State *L) {
  lua_settop(L, 0);
  if (install_globals(L, 0, NULL, NULL)) return lua_error(L);
  loop_dofile(L, "lua/core/server.lua");
  return 0;
}

static int loop_load_subagents(lua_State *L) {
  loop_dofile(L, "lua/core/subagents.lua");
  return 0;
}

/* `_G[name]` with a byte-exact name (a Lua global name need not be a C string). */
static void push_global(lua_State *L, const char *name, size_t nlen) {
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  lua_pushlstring(L, name, nlen);
  lua_gettable(L, -2);
  lua_remove(L, -2);
}

typedef struct {
  const char *name; size_t nlen;
  int argc; const char **argv; const size_t *argl;
  char **out; size_t *outlen;
  char **err; size_t *errlen;
} CallArgs;

/* One work item, under its own pcall so that a structural failure (a stack too small to push the
 * arguments, a global whose name is not readable) is this item's error and not an unprotected throw.
 * Pushes the status and returns it as the one result: 0 answered, 1 raised or refused with a message,
 * 2 no such function (the name in *out). */
static int loop_item(lua_State *L) {
  CallArgs *a = (CallArgs *)lua_touserdata(L, 1);
  lua_settop(L, 0);
  luaL_checkstack(L, a->argc + 4, "core loop call");

  /* the item's arguments, where a native run has the script's `args` */
  lua_createtable(L, a->argc, 0);
  for (int k = 0; k < a->argc; k++) { lua_pushlstring(L, a->argv[k], a->argl[k]); lua_rawseti(L, -2, k + 1); }
  lua_setglobal(L, "args");

  push_global(L, a->name, a->nlen);
  if (lua_type(L, -1) != LUA_TFUNCTION) {
    lua_pop(L, 1);
    /* subagents.lua defines the placement tick and the subagent entry. A read never needs it, so a
     * node thread's read path does not pay for it; the first item that does loads it once. */
    if (LOOP_SUBAGENTS == 0) {
      LOOP_SUBAGENTS = 2;
      lua_pushcfunction(L, loop_load_subagents);
      if (lua_pcall(L, 0, 0, 0) == LUA_OK) LOOP_SUBAGENTS = 1;
      else lua_pop(L, 1);   /* the item's own "not a function" answer is the useful one */
    }
    push_global(L, a->name, a->nlen);
    if (lua_type(L, -1) != LUA_TFUNCTION) {
      lua_settop(L, 0);
      copy_out(a->name, a->nlen, a->out, a->outlen);
      lua_pushinteger(L, 2);
      return 1;
    }
  }

  for (int k = 0; k < a->argc; k++) lua_pushlstring(L, a->argv[k], a->argl[k]);
  fflush(stdout);
  if (lua_pcall(L, a->argc, 1, 0) != LUA_OK) {
    size_t len = 0;
    const char *msg = lua_tolstring(L, -1, &len);
    if (!msg) { msg = "lua error"; len = 9; }
    copy_out(msg, len, a->err, a->errlen);
    lua_settop(L, 0);
    lua_pushinteger(L, 1);
    fflush(stdout);
    return 1;
  }
  if (lua_type(L, -1) == LUA_TNIL) {
    copy_out("", 0, a->out, a->outlen);
  } else {
    size_t len = 0;
    const char *value = lua_tolstring(L, -1, &len);
    if (value) copy_out(value, len, a->out, a->outlen);
    else copy_out("", 0, a->out, a->outlen);
  }
  lua_settop(L, 0);
  lua_pushinteger(L, 0);
  fflush(stdout);
  return 1;
}

int wa_core_call(const char *name, size_t nlen, int argc, const char **argv, const size_t *argl,
                 char **out, size_t *outlen, char **err, size_t *errlen) {
  *out = NULL; *outlen = 0; *err = NULL; *errlen = 0;
  if (!LOOP_L) {
    if (LOOP_FAILED) { copy_out(LOOP_FAILED, LOOP_FAILED_LEN, err, errlen); return 3; }
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    lua_pushcfunction(L, loop_boot);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
      size_t len = 0;
      const char *msg = lua_tolstring(L, -1, &len);
      if (!msg) { msg = "lua error"; len = 9; }
      char *kept = NULL; size_t keptlen = 0;
      copy_out(msg, len, &kept, &keptlen);
      LOOP_FAILED = kept;
      LOOP_FAILED_LEN = keptlen;
      copy_out(msg, len, err, errlen);
      lua_close(L);
      return 3;
    }
    LOOP_L = L;
  }
  lua_State *L = LOOP_L;
  CallArgs a = { name, nlen, argc, argv, argl, out, outlen, err, errlen };
  lua_pushcfunction(L, loop_item);
  lua_pushlightuserdata(L, &a);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    size_t len = 0;
    const char *msg = lua_tolstring(L, -1, &len);
    if (!msg) { msg = "lua error"; len = 9; }
    copy_out(msg, len, err, errlen);
    lua_settop(L, 0);
    return 1;
  }
  int status = (int)lua_tointegerx(L, -1, NULL);
  lua_settop(L, 0);
  return status;
}

void wa_core_reset(void) {
  if (LOOP_L) { lua_close(LOOP_L); LOOP_L = NULL; }
  free(LOOP_FAILED);
  LOOP_FAILED = NULL;
  LOOP_FAILED_LEN = 0;
  LOOP_SUBAGENTS = 0;
}

void wa_core_free(void *p) { free(p); }

