/* Lua state + a dynamic `host` table: any host.<name>(...) becomes rust_host_call(name, args). */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdlib.h>
#include <string.h>

extern int rust_host_call(const char *name, size_t nlen, int argc, const char **argv, const size_t *argl, char **out, size_t *outlen);

static int host_fn(lua_State *L) {
    size_t nlen;
    const char *name = lua_tolstring(L, lua_upvalueindex(1), &nlen);
    int argc = lua_gettop(L);
    const char **argv = malloc(sizeof(char *) * (argc + 1));
    size_t *argl = malloc(sizeof(size_t) * (argc + 1));
    for (int i = 1; i <= argc; i++) argv[i - 1] = luaL_tolstring(L, i, &argl[i - 1]);
    char *out = NULL;
    size_t outlen = 0;
    int rc = rust_host_call(name, nlen, argc, argv, argl, &out, &outlen);
    free(argv);
    free(argl);
    if (rc != 0) {
        lua_pushlstring(L, out ? out : "host call failed", out ? outlen : 16);
        free(out);
        return lua_error(L);
    }
    unsigned n = 0;
    size_t p = 4;
    if (out && outlen >= 4) memcpy(&n, out, 4);
    lua_settop(L, 0);
    for (unsigned i = 0; i < n; i++) {
        unsigned len;
        memcpy(&len, out + p, 4);
        p += 4;
        lua_pushlstring(L, out + p, len);
        p += len;
    }
    free(out);
    return (int)n;
}

static int host_index(lua_State *L) {
    lua_pushvalue(L, 2);
    lua_pushcclosure(L, host_fn, 1);
    lua_pushvalue(L, 2);
    lua_pushvalue(L, -2);
    lua_rawset(L, 1);
    return 1;
}

int wa_lua_run(const char *src, size_t len, const char *chunk, char **out, size_t *outlen) {
    lua_State *L = luaL_newstate();
    luaL_requiref(L, "_G", luaopen_base, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
    luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1);
    luaL_requiref(L, LUA_COLIBNAME, luaopen_coroutine, 1);
    lua_settop(L, 0);
    lua_newtable(L);
    lua_newtable(L);
    lua_pushcfunction(L, host_index);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);
    lua_setglobal(L, "host");
    int rc = luaL_loadbufferx(L, src, len, chunk, "t");
    if (rc == LUA_OK) rc = lua_pcall(L, 0, 1, 0);
    size_t l;
    const char *s = luaL_tolstring(L, -1, &l);
    *out = malloc(l + 1);
    memcpy(*out, s, l);
    *outlen = l;
    lua_close(L);
    return rc;
}
