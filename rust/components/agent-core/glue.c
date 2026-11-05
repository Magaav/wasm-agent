/* agent-core glue: the native interpreter's boot (rust/wa-host/src/main.rs) rebuilt inside wasm.
 *
 * - `host` is a table whose missing keys resolve, once, to a C closure that forwards the call
 *   through `wa:kernel/host.call` (rust_host_call in src/lib.rs). Only names the kernel's
 *   capability registry has resolve, so `if host.x then` reads exactly as it does natively.
 * - `EMBEDDED` resolves missing keys through the kernel too (`__embedded`): the kernel answers from
 *   the same table its native interpreter has (installed lua-core tree, else compiled in), and
 *   assignment still overrides, as tests rely on.
 * - `dofile` is the native bootstrap string, byte for byte.
 * - stdout is flushed before every host call, so guest prints and host output keep their order. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

typedef struct { int kind; long long i; double n; const char *p; size_t len; } Slot;

extern int rust_host_call(const char *name, size_t nlen, int argc, const Slot *argv,
                          const Slot **out, char **err, size_t *errlen);

static int forward(lua_State *L, const char *name, size_t nlen, int first, int argc) {
  Slot stack_slots[16];
  Slot *slots = argc <= 16 ? stack_slots : (Slot *)malloc(sizeof(Slot) * (size_t)argc);
  for (int k = 0; k < argc; k++) {
    int idx = first + k;
    Slot *s = &slots[k];
    memset(s, 0, sizeof *s);
    switch (lua_type(L, idx)) {
      case LUA_TNIL: case LUA_TNONE: s->kind = 0; break;
      case LUA_TBOOLEAN: s->kind = 1; s->i = lua_toboolean(L, idx); break;
      case LUA_TNUMBER:
        if (lua_isinteger(L, idx)) { s->kind = 2; s->i = lua_tointeger(L, idx); }
        else { s->kind = 3; s->n = lua_tonumber(L, idx); }
        break;
      case LUA_TSTRING: s->kind = 4; s->p = lua_tolstring(L, idx, &s->len); break;
      default:
        /* a callback, a table or a userdata cannot cross the v1 bridge */
        if (slots != stack_slots) free(slots);
        lua_pushfstring(L, "unsupported_in_component_v1:%s", name);
        return lua_error(L);
    }
  }
  fflush(stdout);
  const Slot *out = NULL; char *err = NULL; size_t errlen = 0;
  int n = rust_host_call(name, nlen, argc, slots, &out, &err, &errlen);
  if (slots != stack_slots) free(slots);
  if (n < 0) {
    lua_pushlstring(L, err, errlen);
    free(err);
    return lua_error(L);
  }
  luaL_checkstack(L, n, "host results");
  for (int k = 0; k < n; k++) {
    switch (out[k].kind) {
      case 1: lua_pushboolean(L, (int)out[k].i); break;
      case 2: lua_pushinteger(L, (lua_Integer)out[k].i); break;
      case 3: lua_pushnumber(L, out[k].n); break;
      case 4: lua_pushlstring(L, out[k].p, out[k].len); break;
      default: lua_pushnil(L);
    }
  }
  return n;
}

static int host_fn(lua_State *L) {
  size_t nlen;
  const char *name = lua_tolstring(L, lua_upvalueindex(1), &nlen);
  return forward(L, name, nlen, 1, lua_gettop(L));
}

/* host.__index(t, k): a closure for a registered capability, nil for anything else */
static int host_index(lua_State *L) {
  if (lua_type(L, 2) != LUA_TSTRING) return 0;
  lua_pushvalue(L, 2);
  if (lua_rawget(L, lua_upvalueindex(1)) == LUA_TNIL) return 0; /* not in the registry */
  lua_pop(L, 1);
  lua_pushvalue(L, 2);
  lua_pushcclosure(L, host_fn, 1);
  lua_pushvalue(L, 2);
  lua_pushvalue(L, -2);
  lua_rawset(L, 1);
  return 1;
}

/* EMBEDDED.__index(t, k): ask the kernel for module k, cache it */
static int embedded_index(lua_State *L) {
  if (lua_type(L, 2) != LUA_TSTRING) return 0;
  int base = lua_gettop(L);
  int n = forward(L, "__embedded", 10, 2, 1);
  if (n < 1 || lua_type(L, base + 1) != LUA_TSTRING) return 0;
  lua_settop(L, base + 1);
  lua_pushvalue(L, 2);
  lua_pushvalue(L, -2);
  lua_rawset(L, 1);
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

  /* host: the registry's names, then the lazy table */
  lua_newtable(L);                                     /* 1 host */
  lua_newtable(L);                                     /* 2 metatable */
  lua_newtable(L);                                     /* 3 names set */
  if (forward(L, "__names", 7, 0, 0) >= 1 && lua_type(L, 4) == LUA_TSTRING) {
    size_t len; const char *p = lua_tolstring(L, 4, &len); const char *end = p + len;
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
