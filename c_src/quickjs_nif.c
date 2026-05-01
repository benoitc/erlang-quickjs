/*
 * QuickJS Erlang NIF - JavaScript engine for Erlang (powered by quickjs-ng)
 *
 * Copyright 2026 Benoit Chesneau
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
#include <time.h>
#include <math.h>

#include "erl_nif.h"
#include "quickjs.h"

/* ============================================================================
 * Atoms
 * ============================================================================ */

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_badarg;
static ERL_NIF_TERM atom_enomem;
static ERL_NIF_TERM atom_invalid_context;
static ERL_NIF_TERM atom_not_implemented;
static ERL_NIF_TERM atom_js_error;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;
static ERL_NIF_TERM atom_null;
static ERL_NIF_TERM atom_undefined;
static ERL_NIF_TERM atom_timeout;
static ERL_NIF_TERM atom_nan;
static ERL_NIF_TERM atom_infinity;
static ERL_NIF_TERM atom_neg_infinity;
static ERL_NIF_TERM atom_call_erlang;
static ERL_NIF_TERM atom_erlang_error;
static ERL_NIF_TERM atom_erlang_throw;
static ERL_NIF_TERM atom_erlang_exit;
static ERL_NIF_TERM atom_undefined_function;

/* ============================================================================
 * Context resource
 * ============================================================================ */

typedef struct {
    size_t alloc_count;
    size_t realloc_count;
    size_t free_count;
    size_t gc_runs;
    size_t heap_bytes;
    size_t heap_peak;
} quickjs_metrics_t;

struct quickjs_ctx_s {
    JSRuntime    *rt;
    JSContext    *ctx;
    ErlNifMutex  *lock;
    int           destroyed;
    quickjs_metrics_t metrics;
    /* placeholders, used in later phases */
    ErlNifPid     handler_pid;
    int           handler_enabled;
    /* Timeout */
    int           timeout_enabled;
    uint64_t      timeout_ms;
    uint64_t      exec_start_ns;
    int           timed_out;
    /* Trampoline state for Erlang function calls */
    int           call_index;
    int           pending_call;
    char          pending_func[256];
    ErlNifEnv    *pending_env;
    ERL_NIF_TERM  pending_args;
    /* Cached results from prior suspensions in the same eval/call cycle */
    int           n_results;
    int           cap_results;
    JSValue      *results;
    int          *result_is_error;
    /* Resume context for nif_eval_resume */
    int           resume_kind;
    char         *resume_code;
    size_t        resume_code_len;
    char         *resume_func;
    size_t        resume_func_len;
    int           resume_n_args;
    JSValue      *resume_args;
    uint64_t      resume_timeout_ms;
};

static ErlNifResourceType *quickjs_ctx_resource;

static int install_commonjs(JSContext *ctx);
typedef struct quickjs_ctx_s quickjs_ctx_t;
static void trampoline_clear_pending(quickjs_ctx_t *res);
static void trampoline_clear_results(quickjs_ctx_t *res);
static void trampoline_clear_resume(quickjs_ctx_t *res);
static int  trampoline_push_result(quickjs_ctx_t *res, JSValue v, int is_error);
static ERL_NIF_TERM make_call_erlang_term(ErlNifEnv *env, quickjs_ctx_t *res);
static JSValue js_error_from_erlang_error(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM error_tag, ERL_NIF_TERM reason);
static JSValue erlang_function_wrapper(JSContext *ctx, JSValueConst this_val,
                                       int argc, JSValueConst *argv,
                                       int magic, JSValue *func_data);
static ERL_NIF_TERM js_to_term(ErlNifEnv *env, JSContext *ctx, JSValueConst val);
static JSValue term_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term);

static void
quickjs_ctx_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    quickjs_ctx_t *res = (quickjs_ctx_t *)obj;
    if (!res->destroyed) {
        if (res->ctx) {
            trampoline_clear_results(res);
            trampoline_clear_resume(res);
            trampoline_clear_pending(res);
            JS_FreeContext(res->ctx);
            res->ctx = NULL;
        }
        if (res->rt)  { JS_FreeRuntime(res->rt);  res->rt  = NULL; }
        res->destroyed = 1;
    }
    if (res->lock) {
        enif_mutex_destroy(res->lock);
        res->lock = NULL;
    }
}

static int
get_ctx(ErlNifEnv *env, ERL_NIF_TERM term, quickjs_ctx_t **res)
{
    return enif_get_resource(env, term, quickjs_ctx_resource, (void **)res);
}

/* QuickJS captures the C stack base when JS_NewRuntime runs. NIF calls dispatch
 * across BEAM scheduler threads, each with its own stack, so the captured base
 * is wrong on every call after the first. Refresh it on entry. */
static inline void
refresh_stack_top(quickjs_ctx_t *res)
{
    if (res && res->rt) JS_UpdateStackTop(res->rt);
}

static ERL_NIF_TERM
make_error(ErlNifEnv *env, ERL_NIF_TERM reason)
{
    return enif_make_tuple2(env, atom_error, reason);
}

/* ============================================================================
 * Custom allocator with metrics
 * ============================================================================ */

#define QJS_ALLOC_HEADER 16

static void *qjs_malloc_cb(void *opaque, size_t size)
{
    quickjs_metrics_t *m = (quickjs_metrics_t *)opaque;
    void *p = malloc(size + QJS_ALLOC_HEADER);
    if (!p) return NULL;
    *(size_t *)p = size;
    m->alloc_count++;
    m->heap_bytes += size;
    if (m->heap_bytes > m->heap_peak) m->heap_peak = m->heap_bytes;
    return (char *)p + QJS_ALLOC_HEADER;
}

static void *qjs_calloc_cb(void *opaque, size_t count, size_t size)
{
    size_t total = count * size;
    void *p = qjs_malloc_cb(opaque, total);
    if (p) memset(p, 0, total);
    return p;
}

static void qjs_free_cb(void *opaque, void *ptr)
{
    if (!ptr) return;
    quickjs_metrics_t *m = (quickjs_metrics_t *)opaque;
    void *real = (char *)ptr - QJS_ALLOC_HEADER;
    size_t size = *(size_t *)real;
    if (m->heap_bytes >= size) m->heap_bytes -= size;
    m->free_count++;
    free(real);
}

static void *qjs_realloc_cb(void *opaque, void *ptr, size_t size)
{
    if (!ptr) return qjs_malloc_cb(opaque, size);
    if (size == 0) { qjs_free_cb(opaque, ptr); return NULL; }
    quickjs_metrics_t *m = (quickjs_metrics_t *)opaque;
    void *real = (char *)ptr - QJS_ALLOC_HEADER;
    size_t old_size = *(size_t *)real;
    void *new_real = realloc(real, size + QJS_ALLOC_HEADER);
    if (!new_real) return NULL;
    *(size_t *)new_real = size;
    if (size > old_size) {
        m->heap_bytes += size - old_size;
    } else {
        size_t diff = old_size - size;
        if (m->heap_bytes >= diff) m->heap_bytes -= diff;
    }
    if (m->heap_bytes > m->heap_peak) m->heap_peak = m->heap_bytes;
    m->realloc_count++;
    return (char *)new_real + QJS_ALLOC_HEADER;
}

static size_t qjs_malloc_usable_size_cb(const void *ptr)
{
    if (!ptr) return 0;
    return *(const size_t *)((const char *)ptr - QJS_ALLOC_HEADER);
}

static const JSMallocFunctions QJS_MALLOC_FUNCS = {
    .js_calloc             = qjs_calloc_cb,
    .js_malloc             = qjs_malloc_cb,
    .js_free               = qjs_free_cb,
    .js_realloc            = qjs_realloc_cb,
    .js_malloc_usable_size = qjs_malloc_usable_size_cb,
};

/* ============================================================================
 * Timeout support
 * ============================================================================ */

static uint64_t
monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int
interrupt_handler(JSRuntime *rt, void *opaque)
{
    (void)rt;
    quickjs_ctx_t *res = (quickjs_ctx_t *)opaque;
    if (res == NULL || !res->timeout_enabled) return 0;
    uint64_t elapsed = (monotonic_ns() - res->exec_start_ns) / 1000000ULL;
    if (elapsed > res->timeout_ms) {
        res->timed_out = 1;
        return 1;
    }
    return 0;
}

static void
arm_timeout(quickjs_ctx_t *res, uint64_t timeout_ms)
{
    res->timed_out = 0;
    if (timeout_ms == 0) {
        res->timeout_enabled = 0;
        JS_SetInterruptHandler(res->rt, NULL, NULL);
    } else {
        res->timeout_enabled = 1;
        res->timeout_ms = timeout_ms;
        res->exec_start_ns = monotonic_ns();
        JS_SetInterruptHandler(res->rt, interrupt_handler, res);
    }
}

static void
disarm_timeout(quickjs_ctx_t *res)
{
    res->timeout_enabled = 0;
    JS_SetInterruptHandler(res->rt, NULL, NULL);
}

static ERL_NIF_TERM
make_binary_copy(ErlNifEnv *env, const char *src, size_t len)
{
    ERL_NIF_TERM out;
    unsigned char *buf = enif_make_new_binary(env, len, &out);
    if (buf && len > 0) memcpy(buf, src, len);
    return out;
}

/* Read iodata (binary or iolist) into a heap-allocated null-terminated buffer.
 * Caller must enif_free() the buffer. Returns 1 on success, 0 on bad input. */
static int
iodata_to_cstr(ErlNifEnv *env, ERL_NIF_TERM term, char **out, size_t *out_len)
{
    ErlNifBinary bin;
    if (!enif_inspect_iolist_as_binary(env, term, &bin)) {
        return 0;
    }
    char *buf = enif_alloc(bin.size + 1);
    if (buf == NULL) return 0;
    if (bin.size > 0) memcpy(buf, bin.data, bin.size);
    buf[bin.size] = '\0';
    *out = buf;
    *out_len = bin.size;
    return 1;
}

/* ============================================================================
 * JSValue -> ERL_NIF_TERM
 * ============================================================================ */

static ERL_NIF_TERM js_to_term(ErlNifEnv *env, JSContext *ctx, JSValueConst val);

static ERL_NIF_TERM
js_string_to_binary(ErlNifEnv *env, JSContext *ctx, JSValueConst val)
{
    size_t len = 0;
    const char *s = JS_ToCStringLen(ctx, &len, val);
    if (s == NULL) {
        return make_binary_copy(env, "", 0);
    }
    ERL_NIF_TERM out = make_binary_copy(env, s, len);
    JS_FreeCString(ctx, s);
    return out;
}

static ERL_NIF_TERM
js_array_to_list(ErlNifEnv *env, JSContext *ctx, JSValueConst arr)
{
    int64_t len = 0;
    if (JS_GetLength(ctx, arr, &len) < 0 || len < 0) {
        return enif_make_list(env, 0);
    }

    ERL_NIF_TERM *items = NULL;
    if (len > 0) {
        items = enif_alloc(sizeof(ERL_NIF_TERM) * (size_t)len);
        if (items == NULL) {
            return enif_make_list(env, 0);
        }
        for (int64_t i = 0; i < len; i++) {
            JSValue elt = JS_GetPropertyUint32(ctx, arr, (uint32_t)i);
            items[i] = js_to_term(env, ctx, elt);
            JS_FreeValue(ctx, elt);
        }
    }
    ERL_NIF_TERM list = enif_make_list_from_array(env, items, (unsigned)len);
    if (items) enif_free(items);
    return list;
}

static ERL_NIF_TERM
js_object_to_map(ErlNifEnv *env, JSContext *ctx, JSValueConst obj)
{
    JSPropertyEnum *tab = NULL;
    uint32_t plen = 0;
    int flags = JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY;

    if (JS_GetOwnPropertyNames(ctx, &tab, &plen, obj, flags) < 0) {
        return enif_make_new_map(env);
    }

    ERL_NIF_TERM map = enif_make_new_map(env);
    for (uint32_t i = 0; i < plen; i++) {
        const char *key_str = JS_AtomToCString(ctx, tab[i].atom);
        if (key_str == NULL) continue;
        size_t klen = strlen(key_str);
        ERL_NIF_TERM key_bin = make_binary_copy(env, key_str, klen);
        JS_FreeCString(ctx, key_str);

        JSValue v = JS_GetProperty(ctx, obj, tab[i].atom);
        ERL_NIF_TERM val_term = js_to_term(env, ctx, v);
        JS_FreeValue(ctx, v);

        ERL_NIF_TERM new_map;
        if (enif_make_map_put(env, map, key_bin, val_term, &new_map)) {
            map = new_map;
        }
    }
    JS_FreePropertyEnum(ctx, tab, plen);
    return map;
}

/* Stringify a function (or any JS value JSON cannot represent) via JS_ToCString. */
static ERL_NIF_TERM
js_value_to_string_binary(ErlNifEnv *env, JSContext *ctx, JSValueConst val)
{
    return js_string_to_binary(env, ctx, val);
}

static ERL_NIF_TERM
js_to_term(ErlNifEnv *env, JSContext *ctx, JSValueConst val)
{
    int tag = JS_VALUE_GET_NORM_TAG(val);

    switch (tag) {
        case JS_TAG_INT: {
            int32_t i = 0;
            JS_ToInt32(ctx, &i, val);
            return enif_make_int(env, i);
        }
        case JS_TAG_FLOAT64: {
            double d = 0;
            JS_ToFloat64(ctx, &d, val);
            if (isnan(d)) return atom_nan;
            if (isinf(d)) return d > 0 ? atom_infinity : atom_neg_infinity;
            if (d >= -9.2233720368547758e18 && d <= 9.2233720368547758e18 && d == floor(d)) {
                int64_t i = (int64_t)d;
                if ((double)i == d) return enif_make_int64(env, i);
            }
            return enif_make_double(env, d);
        }
        case JS_TAG_BOOL: {
            int b = JS_ToBool(ctx, val);
            return b ? atom_true : atom_false;
        }
        case JS_TAG_NULL:
            return atom_null;
        case JS_TAG_UNDEFINED:
            return atom_undefined;
        case JS_TAG_STRING:
        case JS_TAG_STRING_ROPE:
            return js_string_to_binary(env, ctx, val);
        case JS_TAG_BIG_INT: {
            int64_t i = 0;
            if (JS_ToInt64Ext(ctx, &i, val) == 0) {
                return enif_make_int64(env, i);
            }
            /* Fall back to string representation. */
            return js_value_to_string_binary(env, ctx, val);
        }
        case JS_TAG_OBJECT: {
            if (JS_IsArray(val)) {
                return js_array_to_list(env, ctx, val);
            }
            if (JS_IsFunction(ctx, val)) {
                return js_value_to_string_binary(env, ctx, val);
            }
            return js_object_to_map(env, ctx, val);
        }
        default:
            /* Symbols, modules, and unknown values fall back to their stringification. */
            return js_value_to_string_binary(env, ctx, val);
    }
}

/* ============================================================================
 * ERL_NIF_TERM -> JSValue
 * ============================================================================ */

static JSValue term_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term);

static JSValue
atom_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term)
{
    char buf[256];
    int n = enif_get_atom(env, term, buf, sizeof(buf), ERL_NIF_LATIN1);
    if (n <= 0) return JS_UNDEFINED;
    /* enif_get_atom returns length including the trailing NUL */
    size_t len = (size_t)(n - 1);
    if (strcmp(buf, "true") == 0)      return JS_TRUE;
    if (strcmp(buf, "false") == 0)     return JS_FALSE;
    if (strcmp(buf, "null") == 0)      return JS_NULL;
    if (strcmp(buf, "undefined") == 0) return JS_UNDEFINED;
    return JS_NewStringLen(ctx, buf, len);
}

static JSValue
list_to_js_array(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM list)
{
    JSValue arr = JS_NewArray(ctx);
    uint32_t i = 0;
    ERL_NIF_TERM head;
    ERL_NIF_TERM tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        JSValue v = term_to_js(env, ctx, head);
        JS_SetPropertyUint32(ctx, arr, i++, v);
    }
    return arr;
}

static JSValue
tuple_to_js_array(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term)
{
    int arity = 0;
    const ERL_NIF_TERM *elts;
    if (!enif_get_tuple(env, term, &arity, &elts)) {
        return JS_UNDEFINED;
    }
    JSValue arr = JS_NewArray(ctx);
    for (int i = 0; i < arity; i++) {
        JSValue v = term_to_js(env, ctx, elts[i]);
        JS_SetPropertyUint32(ctx, arr, (uint32_t)i, v);
    }
    return arr;
}

static int
key_to_atom(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM key, JSAtom *out)
{
    ErlNifBinary kb;
    char buf[256];
    if (enif_inspect_binary(env, key, &kb)) {
        *out = JS_NewAtomLen(ctx, (const char *)kb.data, kb.size);
        return 1;
    }
    int n = enif_get_atom(env, key, buf, sizeof(buf), ERL_NIF_LATIN1);
    if (n > 0) {
        *out = JS_NewAtomLen(ctx, buf, (size_t)(n - 1));
        return 1;
    }
    return 0;
}

static JSValue
map_to_js_object(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term)
{
    JSValue obj = JS_NewObject(ctx);
    ErlNifMapIterator iter;
    if (!enif_map_iterator_create(env, term, &iter, ERL_NIF_MAP_ITERATOR_FIRST)) {
        return obj;
    }
    ERL_NIF_TERM key, val;
    while (enif_map_iterator_get_pair(env, &iter, &key, &val)) {
        JSAtom katom;
        if (key_to_atom(env, ctx, key, &katom)) {
            JSValue v = term_to_js(env, ctx, val);
            JS_SetProperty(ctx, obj, katom, v);
            JS_FreeAtom(ctx, katom);
        }
        enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);
    return obj;
}

static JSValue
term_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term)
{
    ErlNifSInt64 i64;
    double d;

    if (enif_is_atom(env, term)) {
        return atom_to_js(env, ctx, term);
    }
    if (enif_get_int64(env, term, &i64)) {
        if (i64 >= INT32_MIN && i64 <= INT32_MAX) return JS_NewInt32(ctx, (int32_t)i64);
        if (i64 >= -(int64_t)((1LL << 53) - 1) && i64 <= (int64_t)((1LL << 53) - 1)) {
            return JS_NewInt64(ctx, i64);
        }
        return JS_NewBigInt64(ctx, i64);
    }
    if (enif_get_double(env, term, &d)) {
        return JS_NewFloat64(ctx, d);
    }
    if (enif_is_binary(env, term)) {
        ErlNifBinary b;
        enif_inspect_binary(env, term, &b);
        return JS_NewStringLen(ctx, (const char *)b.data, b.size);
    }
    if (enif_is_list(env, term)) {
        ErlNifBinary iob;
        if (enif_inspect_iolist_as_binary(env, term, &iob)) {
            return JS_NewStringLen(ctx, (const char *)iob.data, iob.size);
        }
        return list_to_js_array(env, ctx, term);
    }
    if (enif_is_tuple(env, term)) {
        return tuple_to_js_array(env, ctx, term);
    }
    if (enif_is_map(env, term)) {
        return map_to_js_object(env, ctx, term);
    }
    return JS_UNDEFINED;
}

/* Set every entry of a map as a global property of the JS context. */
static void
apply_bindings(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM bindings)
{
    JSValue global = JS_GetGlobalObject(ctx);
    ErlNifMapIterator iter;
    if (!enif_map_iterator_create(env, bindings, &iter, ERL_NIF_MAP_ITERATOR_FIRST)) {
        JS_FreeValue(ctx, global);
        return;
    }
    ERL_NIF_TERM key, val;
    while (enif_map_iterator_get_pair(env, &iter, &key, &val)) {
        JSAtom katom;
        if (key_to_atom(env, ctx, key, &katom)) {
            JSValue v = term_to_js(env, ctx, val);
            JS_SetProperty(ctx, global, katom, v);
            JS_FreeAtom(ctx, katom);
        }
        enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);
    JS_FreeValue(ctx, global);
}

/* ============================================================================
 * Exception helpers
 * ============================================================================ */

static ERL_NIF_TERM
js_exception_to_term(ErlNifEnv *env, JSContext *ctx)
{
    JSValue exc = JS_GetException(ctx);
    ERL_NIF_TERM bin;
    if (JS_IsError(exc)) {
        JSValue name = JS_GetPropertyStr(ctx, exc, "name");
        JSValue msg  = JS_GetPropertyStr(ctx, exc, "message");
        size_t nlen = 0, mlen = 0;
        const char *ns = (!JS_IsUndefined(name) && !JS_IsNull(name)) ? JS_ToCStringLen(ctx, &nlen, name) : NULL;
        const char *ms = (!JS_IsUndefined(msg)  && !JS_IsNull(msg))  ? JS_ToCStringLen(ctx, &mlen, msg)  : NULL;

        if (ns && nlen > 0 && ms && mlen > 0) {
            ERL_NIF_TERM out;
            unsigned char *buf = enif_make_new_binary(env, nlen + 2 + mlen, &out);
            if (buf) {
                memcpy(buf, ns, nlen);
                buf[nlen] = ':';
                buf[nlen + 1] = ' ';
                memcpy(buf + nlen + 2, ms, mlen);
            }
            bin = out;
        } else if (ms && mlen > 0) {
            bin = make_binary_copy(env, ms, mlen);
        } else if (ns && nlen > 0) {
            bin = make_binary_copy(env, ns, nlen);
        } else {
            bin = js_value_to_string_binary(env, ctx, exc);
        }
        if (ns) JS_FreeCString(ctx, ns);
        if (ms) JS_FreeCString(ctx, ms);
        JS_FreeValue(ctx, name);
        JS_FreeValue(ctx, msg);
    } else {
        bin = js_value_to_string_binary(env, ctx, exc);
    }
    JS_FreeValue(ctx, exc);
    return make_error(env, enif_make_tuple2(env, atom_js_error, bin));
}

/* ============================================================================
 * Context lifecycle
 * ============================================================================ */

static ERL_NIF_TERM
do_new_context(ErlNifEnv *env)
{
    quickjs_ctx_t *res = enif_alloc_resource(quickjs_ctx_resource, sizeof(*res));
    if (res == NULL) {
        return make_error(env, atom_enomem);
    }
    memset(res, 0, sizeof(*res));

    res->lock = enif_mutex_create("quickjs_ctx");
    if (res->lock == NULL) {
        enif_release_resource(res);
        return make_error(env, atom_enomem);
    }

    res->rt = JS_NewRuntime2(&QJS_MALLOC_FUNCS, &res->metrics);
    if (res->rt == NULL) {
        enif_release_resource(res);
        return make_error(env, atom_enomem);
    }

    res->ctx = JS_NewContext(res->rt);
    if (res->ctx == NULL) {
        JS_FreeRuntime(res->rt);
        res->rt = NULL;
        enif_release_resource(res);
        return make_error(env, atom_enomem);
    }

    JS_SetRuntimeOpaque(res->rt, res);

    if (!install_commonjs(res->ctx)) {
        JS_FreeContext(res->ctx);
        JS_FreeRuntime(res->rt);
        res->ctx = NULL;
        res->rt = NULL;
        enif_release_resource(res);
        return make_error(env, atom_enomem);
    }

    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return enif_make_tuple2(env, atom_ok, term);
}

static ERL_NIF_TERM
nif_new_context(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return do_new_context(env);
}

static ERL_NIF_TERM
nif_new_context_opts(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    if (!enif_is_map(env, argv[0])) {
        return make_error(env, atom_badarg);
    }
    ERL_NIF_TERM ret = do_new_context(env);
    int arity;
    const ERL_NIF_TERM *elts;
    if (!enif_get_tuple(env, ret, &arity, &elts) || arity != 2 ||
        !enif_is_identical(elts[0], atom_ok)) {
        return ret;
    }
    quickjs_ctx_t *res;
    if (!get_ctx(env, elts[1], &res)) return ret;
    ERL_NIF_TERM handler_val;
    if (enif_get_map_value(env, argv[0], enif_make_atom(env, "handler"), &handler_val)) {
        if (enif_get_local_pid(env, handler_val, &res->handler_pid)) {
            res->handler_enabled = 1;
        }
    }
    return ret;
}

static ERL_NIF_TERM
nif_destroy_context(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_badarg);
    }
    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (!res->destroyed) {
        if (res->ctx) {
            trampoline_clear_results(res);
            trampoline_clear_resume(res);
            trampoline_clear_pending(res);
            JS_FreeContext(res->ctx);
            res->ctx = NULL;
        }
        if (res->rt)  { JS_FreeRuntime(res->rt);  res->rt  = NULL; }
        res->destroyed = 1;
    }
    enif_mutex_unlock(res->lock);
    return atom_ok;
}

/* ============================================================================
 * Eval
 * ============================================================================ */

static ERL_NIF_TERM
nif_eval(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }

    char *code = NULL;
    size_t code_len = 0;
    if (!iodata_to_cstr(env, argv[1], &code, &code_len)) {
        return make_error(env, atom_badarg);
    }

    ErlNifUInt64 timeout_ms_u = 0;
    if (!enif_get_uint64(env, argv[2], &timeout_ms_u)) {
        enif_free(code);
        return make_error(env, atom_badarg);
    }

    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        enif_free(code);
        return make_error(env, atom_invalid_context);
    }

    /* Reset trampoline state for a fresh eval cycle. */
    trampoline_clear_results(res);
    trampoline_clear_pending(res);

    arm_timeout(res, (uint64_t)timeout_ms_u);
    JSValue result = JS_Eval(res->ctx, code, code_len, "<eval>", JS_EVAL_TYPE_GLOBAL);
    int aborted = res->timed_out;
    disarm_timeout(res);

    ERL_NIF_TERM ret;
    if (res->pending_call) {
        /* Save resume context. */
        trampoline_clear_resume(res);
        res->resume_kind = 1;
        res->resume_code = enif_alloc(code_len + 1);
        if (res->resume_code) {
            memcpy(res->resume_code, code, code_len);
            res->resume_code[code_len] = '\0';
            res->resume_code_len = code_len;
        }
        res->resume_timeout_ms = (uint64_t)timeout_ms_u;
        ret = make_call_erlang_term(env, res);
        JS_FreeValue(res->ctx, result);
    } else if (JS_IsException(result)) {
        if (aborted) {
            JSValue exc = JS_GetException(res->ctx);
            JS_FreeValue(res->ctx, exc);
            ret = make_error(env, atom_timeout);
        } else {
            ret = js_exception_to_term(env, res->ctx);
        }
        JS_FreeValue(res->ctx, result);
    } else {
        ERL_NIF_TERM v = js_to_term(env, res->ctx, result);
        ret = enif_make_tuple2(env, atom_ok, v);
        JS_FreeValue(res->ctx, result);
    }
    enif_mutex_unlock(res->lock);
    enif_free(code);
    return ret;
}

static ERL_NIF_TERM
nif_eval_bindings(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }
    if (!enif_is_map(env, argv[2])) {
        return make_error(env, atom_badarg);
    }

    char *code = NULL;
    size_t code_len = 0;
    if (!iodata_to_cstr(env, argv[1], &code, &code_len)) {
        return make_error(env, atom_badarg);
    }

    ErlNifUInt64 timeout_ms_u = 0;
    if (!enif_get_uint64(env, argv[3], &timeout_ms_u)) {
        enif_free(code);
        return make_error(env, atom_badarg);
    }

    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        enif_free(code);
        return make_error(env, atom_invalid_context);
    }

    apply_bindings(env, res->ctx, argv[2]);

    trampoline_clear_results(res);
    trampoline_clear_pending(res);

    arm_timeout(res, (uint64_t)timeout_ms_u);
    JSValue result = JS_Eval(res->ctx, code, code_len, "<eval>", JS_EVAL_TYPE_GLOBAL);
    int aborted = res->timed_out;
    disarm_timeout(res);

    ERL_NIF_TERM ret;
    if (res->pending_call) {
        trampoline_clear_resume(res);
        res->resume_kind = 1;
        res->resume_code = enif_alloc(code_len + 1);
        if (res->resume_code) {
            memcpy(res->resume_code, code, code_len);
            res->resume_code[code_len] = '\0';
            res->resume_code_len = code_len;
        }
        res->resume_timeout_ms = (uint64_t)timeout_ms_u;
        ret = make_call_erlang_term(env, res);
        JS_FreeValue(res->ctx, result);
    } else if (JS_IsException(result)) {
        if (aborted) {
            JSValue exc = JS_GetException(res->ctx);
            JS_FreeValue(res->ctx, exc);
            ret = make_error(env, atom_timeout);
        } else {
            ret = js_exception_to_term(env, res->ctx);
        }
        JS_FreeValue(res->ctx, result);
    } else {
        ERL_NIF_TERM v = js_to_term(env, res->ctx, result);
        ret = enif_make_tuple2(env, atom_ok, v);
        JS_FreeValue(res->ctx, result);
    }
    enif_mutex_unlock(res->lock);
    enif_free(code);
    return ret;
}

static ERL_NIF_TERM
nif_call(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }

    /* Function name: atom or iodata */
    char fname_stack[1024];
    char *fname = NULL;
    size_t fname_len = 0;
    int fname_owned = 0;
    if (enif_is_atom(env, argv[1])) {
        int n = enif_get_atom(env, argv[1], fname_stack, sizeof(fname_stack), ERL_NIF_LATIN1);
        if (n <= 0) return make_error(env, atom_badarg);
        fname = fname_stack;
        fname_len = (size_t)(n - 1);
    } else if (iodata_to_cstr(env, argv[1], &fname, &fname_len)) {
        fname_owned = 1;
    } else {
        return make_error(env, atom_badarg);
    }

    if (!enif_is_list(env, argv[2])) {
        if (fname_owned) enif_free(fname);
        return make_error(env, atom_badarg);
    }

    ErlNifUInt64 timeout_ms_u = 0;
    if (!enif_get_uint64(env, argv[3], &timeout_ms_u)) {
        if (fname_owned) enif_free(fname);
        return make_error(env, atom_badarg);
    }

    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        if (fname_owned) enif_free(fname);
        return make_error(env, atom_invalid_context);
    }

    /* Build args array */
    unsigned alen = 0;
    enif_get_list_length(env, argv[2], &alen);
    JSValue *jargs = NULL;
    if (alen > 0) {
        jargs = enif_alloc(sizeof(JSValue) * alen);
        if (jargs == NULL) {
            enif_mutex_unlock(res->lock);
            if (fname_owned) enif_free(fname);
            return make_error(env, atom_enomem);
        }
        ERL_NIF_TERM head;
        ERL_NIF_TERM tail = argv[2];
        for (unsigned i = 0; i < alen; i++) {
            enif_get_list_cell(env, tail, &head, &tail);
            jargs[i] = term_to_js(env, res->ctx, head);
        }
    }

    JSValue global = JS_GetGlobalObject(res->ctx);
    JSAtom fatom = JS_NewAtomLen(res->ctx, fname, fname_len);
    JSValue fn = JS_GetProperty(res->ctx, global, fatom);
    JS_FreeAtom(res->ctx, fatom);

    ERL_NIF_TERM ret;
    if (!JS_IsFunction(res->ctx, fn)) {
        JS_FreeValue(res->ctx, fn);
        JS_FreeValue(res->ctx, global);
        for (unsigned i = 0; i < alen; i++) JS_FreeValue(res->ctx, jargs[i]);
        if (jargs) enif_free(jargs);
        enif_mutex_unlock(res->lock);
        if (fname_owned) enif_free(fname);
        ERL_NIF_TERM msg = make_binary_copy(env, "not a function", 14);
        return make_error(env, enif_make_tuple2(env, atom_js_error, msg));
    }

    trampoline_clear_results(res);
    trampoline_clear_pending(res);

    arm_timeout(res, (uint64_t)timeout_ms_u);
    JSValue result = JS_Call(res->ctx, fn, JS_UNDEFINED, (int)alen, jargs);
    int aborted = res->timed_out;
    disarm_timeout(res);

    JS_FreeValue(res->ctx, fn);
    JS_FreeValue(res->ctx, global);

    if (res->pending_call) {
        /* Save resume context for nif_eval_resume to redo this call. */
        trampoline_clear_resume(res);
        res->resume_kind = 2;
        res->resume_func = enif_alloc(fname_len + 1);
        if (res->resume_func) {
            memcpy(res->resume_func, fname, fname_len);
            res->resume_func[fname_len] = '\0';
            res->resume_func_len = fname_len;
        }
        res->resume_n_args = (int)alen;
        if (alen > 0) {
            res->resume_args = enif_alloc(sizeof(JSValue) * alen);
            for (unsigned i = 0; i < alen; i++) {
                res->resume_args[i] = JS_DupValue(res->ctx, jargs[i]);
            }
        }
        res->resume_timeout_ms = (uint64_t)timeout_ms_u;
        ret = make_call_erlang_term(env, res);
        JS_FreeValue(res->ctx, result);
    } else if (JS_IsException(result)) {
        if (aborted) {
            JSValue exc = JS_GetException(res->ctx);
            JS_FreeValue(res->ctx, exc);
            ret = make_error(env, atom_timeout);
        } else {
            ret = js_exception_to_term(env, res->ctx);
        }
        JS_FreeValue(res->ctx, result);
    } else {
        ERL_NIF_TERM v = js_to_term(env, res->ctx, result);
        ret = enif_make_tuple2(env, atom_ok, v);
        JS_FreeValue(res->ctx, result);
    }
    for (unsigned i = 0; i < alen; i++) JS_FreeValue(res->ctx, jargs[i]);
    if (jargs) enif_free(jargs);
    enif_mutex_unlock(res->lock);
    if (fname_owned) enif_free(fname);
    return ret;
}

static ERL_NIF_TERM
nif_register_erlang_function(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }

    char nbuf[256];
    char *name = NULL;
    size_t name_len = 0;
    int owned = 0;
    if (enif_is_atom(env, argv[1])) {
        int n = enif_get_atom(env, argv[1], nbuf, sizeof(nbuf), ERL_NIF_LATIN1);
        if (n <= 0) return make_error(env, atom_badarg);
        name = nbuf;
        name_len = (size_t)(n - 1);
    } else if (iodata_to_cstr(env, argv[1], &name, &name_len)) {
        owned = 1;
    } else {
        return make_error(env, atom_badarg);
    }

    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        if (owned) enif_free(name);
        return make_error(env, atom_invalid_context);
    }

    JSContext *ctx = res->ctx;
    JSValue name_str = JS_NewStringLen(ctx, name, name_len);
    JSValue data[1] = { name_str };
    JSValue fn = JS_NewCFunctionData(ctx, erlang_function_wrapper, 0, 0, 1, data);
    JS_FreeValue(ctx, name_str);

    JSValue global = JS_GetGlobalObject(ctx);
    JSAtom katom = JS_NewAtomLen(ctx, name, name_len);
    JS_SetProperty(ctx, global, katom, fn);  /* takes ownership of fn */
    JS_FreeAtom(ctx, katom);
    JS_FreeValue(ctx, global);

    enif_mutex_unlock(res->lock);
    if (owned) enif_free(name);
    return atom_ok;
}

/* Convert an Erlang term that may be a normal value or {error, {erlang_error, R}}
 * (etc.) into a JSValue. Sets *is_error if the value should be thrown. */
static JSValue
result_term_to_jsvalue(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term, int *is_error)
{
    *is_error = 0;
    int arity;
    const ERL_NIF_TERM *elts;
    if (enif_get_tuple(env, term, &arity, &elts) && arity == 2) {
        if (enif_is_identical(elts[0], atom_error) &&
            enif_get_tuple(env, elts[1], &arity, &elts) && arity == 2) {
            ERL_NIF_TERM tag = elts[0];
            ERL_NIF_TERM reason = elts[1];
            if (enif_is_identical(tag, atom_erlang_error) ||
                enif_is_identical(tag, atom_erlang_throw) ||
                enif_is_identical(tag, atom_erlang_exit) ||
                enif_is_identical(tag, atom_undefined_function)) {
                *is_error = 1;
                return js_error_from_erlang_error(env, ctx, tag, reason);
            }
        }
    }
    return term_to_js(env, ctx, term);
}

static ERL_NIF_TERM
nif_call_complete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }
    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        return make_error(env, atom_invalid_context);
    }
    int is_error = 0;
    JSValue jv = result_term_to_jsvalue(env, res->ctx, argv[1], &is_error);
    if (!trampoline_push_result(res, jv, is_error)) {
        JS_FreeValue(res->ctx, jv);
        enif_mutex_unlock(res->lock);
        return make_error(env, atom_enomem);
    }
    trampoline_clear_pending(res);
    enif_mutex_unlock(res->lock);
    return atom_ok;
}

static ERL_NIF_TERM
nif_eval_resume(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }
    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        return make_error(env, atom_invalid_context);
    }
    if (res->resume_kind == 0) {
        enif_mutex_unlock(res->lock);
        return make_error(env, atom_badarg);
    }

    res->call_index = 0;
    res->pending_call = 0;
    arm_timeout(res, res->resume_timeout_ms);

    JSValue result;
    if (res->resume_kind == 1) {
        result = JS_Eval(res->ctx, res->resume_code, res->resume_code_len,
                         "<eval>", JS_EVAL_TYPE_GLOBAL);
    } else {
        JSValue global = JS_GetGlobalObject(res->ctx);
        JSAtom fatom = JS_NewAtomLen(res->ctx, res->resume_func, res->resume_func_len);
        JSValue fn = JS_GetProperty(res->ctx, global, fatom);
        JS_FreeAtom(res->ctx, fatom);
        result = JS_Call(res->ctx, fn, JS_UNDEFINED, res->resume_n_args, res->resume_args);
        JS_FreeValue(res->ctx, fn);
        JS_FreeValue(res->ctx, global);
    }
    int aborted = res->timed_out;
    disarm_timeout(res);

    ERL_NIF_TERM ret;
    if (res->pending_call) {
        /* Another suspension. Keep resume context as-is (same code/func). */
        ret = make_call_erlang_term(env, res);
        JS_FreeValue(res->ctx, result);
    } else if (JS_IsException(result)) {
        if (aborted) {
            JSValue exc = JS_GetException(res->ctx);
            JS_FreeValue(res->ctx, exc);
            ret = make_error(env, atom_timeout);
        } else {
            ret = js_exception_to_term(env, res->ctx);
        }
        JS_FreeValue(res->ctx, result);
        trampoline_clear_resume(res);
        trampoline_clear_results(res);
    } else {
        ERL_NIF_TERM v = js_to_term(env, res->ctx, result);
        ret = enif_make_tuple2(env, atom_ok, v);
        JS_FreeValue(res->ctx, result);
        trampoline_clear_resume(res);
        trampoline_clear_results(res);
    }
    enif_mutex_unlock(res->lock);
    return ret;
}

/* ============================================================================
 * Native handlers for Erlang.log and Erlang.emit
 * ============================================================================ */

static ERL_NIF_TERM
log_level_to_term(ErlNifEnv *env, const char *s, size_t len)
{
    if (len == 4 && memcmp(s, "info", 4) == 0)        return enif_make_atom(env, "info");
    if (len == 7 && memcmp(s, "warning", 7) == 0)     return enif_make_atom(env, "warning");
    if (len == 5 && memcmp(s, "error", 5) == 0)       return enif_make_atom(env, "error");
    if (len == 5 && memcmp(s, "debug", 5) == 0)       return enif_make_atom(env, "debug");
    /* Unknown level: return as binary to avoid atom table exhaustion */
    ERL_NIF_TERM bin;
    unsigned char *buf = enif_make_new_binary(env, len, &bin);
    if (buf && len > 0) memcpy(buf, s, len);
    return bin;
}

static JSValue
js_erlang_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    (void)this_val;
    quickjs_ctx_t *res = (quickjs_ctx_t *)JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
    if (!res || !res->handler_enabled || argc < 1) return JS_UNDEFINED;

    size_t llen = 0;
    const char *level_str = JS_ToCStringLen(ctx, &llen, argv[0]);
    if (!level_str) return JS_UNDEFINED;

    /* Concatenate remaining arguments with a space separator. */
    char *buf = NULL;
    size_t blen = 0, bcap = 0;
    for (int i = 1; i < argc; i++) {
        size_t alen = 0;
        const char *as = JS_ToCStringLen(ctx, &alen, argv[i]);
        if (!as) continue;
        size_t need = blen + (i > 1 ? 1 : 0) + alen;
        if (need + 1 > bcap) {
            size_t ncap = bcap == 0 ? 64 : bcap;
            while (ncap < need + 1) ncap *= 2;
            char *nb = enif_realloc(buf, ncap);
            if (!nb) { JS_FreeCString(ctx, as); break; }
            buf = nb;
            bcap = ncap;
        }
        if (i > 1) buf[blen++] = ' ';
        memcpy(buf + blen, as, alen);
        blen += alen;
        JS_FreeCString(ctx, as);
    }

    ErlNifEnv *menv = enif_alloc_env();
    ERL_NIF_TERM level_term = log_level_to_term(menv, level_str, llen);
    JS_FreeCString(ctx, level_str);

    ERL_NIF_TERM msg_term;
    unsigned char *mbuf = enif_make_new_binary(menv, blen, &msg_term);
    if (mbuf && blen > 0) memcpy(mbuf, buf, blen);
    if (buf) enif_free(buf);

    ERL_NIF_TERM map = enif_make_new_map(menv);
    enif_make_map_put(menv, map, enif_make_atom(menv, "level"),   level_term, &map);
    enif_make_map_put(menv, map, enif_make_atom(menv, "message"), msg_term,   &map);

    ERL_NIF_TERM tag = enif_make_atom(menv, "quickjs");
    ERL_NIF_TERM kind = enif_make_atom(menv, "log");
    ERL_NIF_TERM tuple = enif_make_tuple3(menv, tag, kind, map);
    enif_send(NULL, &res->handler_pid, menv, tuple);
    enif_free_env(menv);
    return JS_UNDEFINED;
}

static JSValue
js_erlang_emit(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    (void)this_val;
    quickjs_ctx_t *res = (quickjs_ctx_t *)JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
    if (!res || !res->handler_enabled || argc < 1) return JS_UNDEFINED;

    size_t nlen = 0;
    const char *nstr = JS_ToCStringLen(ctx, &nlen, argv[0]);
    if (!nstr) return JS_UNDEFINED;

    ErlNifEnv *menv = enif_alloc_env();
    ERL_NIF_TERM name_bin;
    unsigned char *nb = enif_make_new_binary(menv, nlen, &name_bin);
    if (nb && nlen > 0) memcpy(nb, nstr, nlen);
    JS_FreeCString(ctx, nstr);

    ERL_NIF_TERM data_term = (argc >= 2)
        ? js_to_term(menv, ctx, argv[1])
        : enif_make_new_map(menv);

    ERL_NIF_TERM tag = enif_make_atom(menv, "quickjs");
    ERL_NIF_TERM tuple = enif_make_tuple3(menv, tag, name_bin, data_term);
    enif_send(NULL, &res->handler_pid, menv, tuple);
    enif_free_env(menv);
    return JS_UNDEFINED;
}

/* ============================================================================
 * Trampoline: Erlang functions callable from JS
 *
 * QuickJS evaluates synchronously. To let JS call into Erlang code, we use the
 * "re-eval" pattern: when JS hits a registered Erlang function, the C wrapper
 * either returns a cached result from a prior pass, or, if this is the next
 * unresolved call, it stashes the function name and args and throws an
 * exception to abort the eval. The Erlang side dispatches the call, stashes
 * the result, and asks the NIF to re-evaluate the same code. Each pass walks
 * one registered call further until the eval completes normally.
 *
 * The pattern was inherited from erlang-duktape; QuickJS lacks coroutines
 * exposed to embedders, so re-eval is the simplest correctness model.
 * ============================================================================ */

static void
trampoline_clear_pending(quickjs_ctx_t *res)
{
    res->pending_call = 0;
    res->pending_func[0] = '\0';
    if (res->pending_env) {
        enif_free_env(res->pending_env);
        res->pending_env = NULL;
    }
}

static void
trampoline_clear_results(quickjs_ctx_t *res)
{
    if (res->results) {
        for (int i = 0; i < res->n_results; i++) {
            JS_FreeValue(res->ctx, res->results[i]);
        }
        enif_free(res->results);
        res->results = NULL;
    }
    if (res->result_is_error) {
        enif_free(res->result_is_error);
        res->result_is_error = NULL;
    }
    res->n_results = 0;
    res->cap_results = 0;
    res->call_index = 0;
}

static void
trampoline_clear_resume(quickjs_ctx_t *res)
{
    if (res->resume_code) { enif_free(res->resume_code); res->resume_code = NULL; }
    res->resume_code_len = 0;
    if (res->resume_func) { enif_free(res->resume_func); res->resume_func = NULL; }
    res->resume_func_len = 0;
    if (res->resume_args) {
        for (int i = 0; i < res->resume_n_args; i++) {
            JS_FreeValue(res->ctx, res->resume_args[i]);
        }
        enif_free(res->resume_args);
        res->resume_args = NULL;
    }
    res->resume_n_args = 0;
    res->resume_kind = 0;
    res->resume_timeout_ms = 0;
}

static int
trampoline_push_result(quickjs_ctx_t *res, JSValue v, int is_error)
{
    if (res->n_results == res->cap_results) {
        int new_cap = res->cap_results == 0 ? 4 : res->cap_results * 2;
        JSValue *nr = enif_realloc(res->results, sizeof(JSValue) * new_cap);
        int *ne = enif_realloc(res->result_is_error, sizeof(int) * new_cap);
        if (!nr || !ne) {
            if (nr) res->results = nr;
            if (ne) res->result_is_error = ne;
            return 0;
        }
        res->results = nr;
        res->result_is_error = ne;
        res->cap_results = new_cap;
    }
    res->results[res->n_results] = v;
    res->result_is_error[res->n_results] = is_error;
    res->n_results++;
    return 1;
}

/* JSValue from a JS array of args -> ETERM list. */
static ERL_NIF_TERM
js_args_array_to_list(ErlNifEnv *env, JSContext *ctx, JSValueConst arr)
{
    int64_t len = 0;
    JS_GetLength(ctx, arr, &len);
    if (len <= 0) return enif_make_list(env, 0);
    ERL_NIF_TERM *items = enif_alloc(sizeof(ERL_NIF_TERM) * (size_t)len);
    if (!items) return enif_make_list(env, 0);
    for (int64_t i = 0; i < len; i++) {
        JSValue elt = JS_GetPropertyUint32(ctx, arr, (uint32_t)i);
        items[i] = js_to_term(env, ctx, elt);
        JS_FreeValue(ctx, elt);
    }
    ERL_NIF_TERM list = enif_make_list_from_array(env, items, (unsigned)len);
    enif_free(items);
    return list;
}

/* Build a JS Error value carrying the formatted reason from an Erlang error. */
static JSValue
js_error_from_erlang_error(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM error_tag, ERL_NIF_TERM reason)
{
    /* Format: "<tag>:<reason>" where reason is rendered with io_lib-like fallback.
     * We produce a stable "error:..." / "throw:..." / "exit:..." prefix so callers can
     * distinguish them. The reason term is rendered as its text representation. */
    const char *prefix = "error";
    if (enif_is_identical(error_tag, atom_erlang_throw)) prefix = "throw";
    else if (enif_is_identical(error_tag, atom_erlang_exit)) prefix = "exit";
    else if (enif_is_identical(error_tag, atom_undefined_function)) prefix = "undefined_function";

    /* enif_get_string-ish printing: render the reason as a binary using
     * io_lib via term_to_binary fallback. Keep it simple: try to grab atom or
     * binary text; otherwise fall back to a generic label. */
    char buf[1024];
    int n = 0;
    if (enif_is_atom(env, reason)) {
        n = enif_get_atom(env, reason, buf, sizeof(buf), ERL_NIF_LATIN1);
        if (n > 0) n--;  /* drop trailing NUL */
    } else {
        ErlNifBinary rb;
        if (enif_inspect_binary(env, reason, &rb)) {
            size_t take = rb.size < sizeof(buf) - 1 ? rb.size : sizeof(buf) - 1;
            memcpy(buf, rb.data, take);
            n = (int)take;
        } else {
            const char *fallback = "term";
            n = (int)strlen(fallback);
            memcpy(buf, fallback, (size_t)n);
        }
    }

    char msg[1280];
    int mlen = snprintf(msg, sizeof(msg), "%s:%.*s", prefix, n, buf);
    if (mlen < 0) mlen = 0;
    if (mlen >= (int)sizeof(msg)) mlen = (int)sizeof(msg) - 1;

    JSValue err = JS_NewError(ctx);
    JSValue m = JS_NewStringLen(ctx, msg, (size_t)mlen);
    JS_DefinePropertyValueStr(ctx, err, "message", m, JS_PROP_C_W_E);
    return err;
}

/* The C wrapper installed for each registered Erlang function. The function
 * name is held in func_data[0] as a JS string. */
static JSValue
erlang_function_wrapper(JSContext *ctx, JSValueConst this_val,
                        int argc, JSValueConst *argv,
                        int magic, JSValue *func_data)
{
    (void)this_val; (void)magic;
    JSRuntime *rt = JS_GetRuntime(ctx);
    quickjs_ctx_t *res = (quickjs_ctx_t *)JS_GetRuntimeOpaque(rt);
    if (res == NULL) return JS_UNDEFINED;

    /* Replay cached results before suspending on a new call. */
    if (res->call_index < res->n_results) {
        int idx = res->call_index;
        res->call_index++;
        if (res->result_is_error[idx]) {
            return JS_Throw(ctx, JS_DupValue(ctx, res->results[idx]));
        }
        return JS_DupValue(ctx, res->results[idx]);
    }

    /* New suspension. Read the function name from func_data[0]. */
    size_t fnlen = 0;
    const char *fn = JS_ToCStringLen(ctx, &fnlen, func_data[0]);
    if (fn == NULL) {
        return JS_ThrowInternalError(ctx, "registered function name lost");
    }

    if (res->pending_env) enif_free_env(res->pending_env);
    res->pending_env = enif_alloc_env();

    /* Convert JS args to ETERM list */
    ERL_NIF_TERM *items = NULL;
    if (argc > 0) {
        items = enif_alloc(sizeof(ERL_NIF_TERM) * (size_t)argc);
        for (int i = 0; i < argc; i++) {
            items[i] = js_to_term(res->pending_env, ctx, argv[i]);
        }
    }
    res->pending_args = enif_make_list_from_array(res->pending_env, items, (unsigned)argc);
    if (items) enif_free(items);

    size_t take = fnlen < sizeof(res->pending_func) - 1 ? fnlen : sizeof(res->pending_func) - 1;
    memcpy(res->pending_func, fn, take);
    res->pending_func[take] = '\0';
    JS_FreeCString(ctx, fn);

    res->pending_call = 1;
    res->call_index++;

    return JS_Throw(ctx, JS_NewString(ctx, "__quickjs_suspend"));
}

/* Build a {call_erlang, FunName, Args} tuple from pending state. */
static ERL_NIF_TERM
make_call_erlang_term(ErlNifEnv *env, quickjs_ctx_t *res)
{
    ERL_NIF_TERM fname_atom = enif_make_atom(env, res->pending_func);
    ERL_NIF_TERM args_copy = enif_make_copy(env, res->pending_args);
    return enif_make_tuple3(env, atom_call_erlang, fname_atom, args_copy);
}

/* ============================================================================
 * CommonJS module bootstrap
 *
 * On context init we install a tiny CommonJS-style module loader on the global
 * object. Sources are stored in __quickjs_modules__ and resolved exports are
 * cached in __quickjs_cache__.
 * ============================================================================ */

static const char *commonjs_bootstrap_src =
    "(function(){\n"
    "  var modules = {};\n"
    "  var cache = {};\n"
    "  globalThis.__quickjs_modules__ = modules;\n"
    "  globalThis.__quickjs_cache__ = cache;\n"
    "  globalThis.require = function(id) {\n"
    "    if (Object.prototype.hasOwnProperty.call(cache, id)) {\n"
    "      return cache[id].exports;\n"
    "    }\n"
    "    if (!Object.prototype.hasOwnProperty.call(modules, id)) {\n"
    "      throw new Error(\"Cannot find module '\" + id + \"'\");\n"
    "    }\n"
    "    var src = modules[id];\n"
    "    var mod = { exports: {} };\n"
    "    cache[id] = mod;\n"
    "    try {\n"
    "      var fn = new Function('exports', 'module', 'require', src);\n"
    "      fn(mod.exports, mod, globalThis.require);\n"
    "    } catch (e) {\n"
    "      delete cache[id];\n"
    "      throw e;\n"
    "    }\n"
    "    return mod.exports;\n"
    "  };\n"
    "  var callbacks = {};\n"
    "  globalThis.__qjs_callbacks__ = callbacks;\n"
    "  var Erlang = {};\n"
    "  globalThis.Erlang = Erlang;\n"
    "  Erlang.on = function(event, fn) { callbacks[event] = fn; };\n"
    "  Erlang.off = function(event) { delete callbacks[event]; };\n"
    "  function logArgs(level) {\n"
    "    return function() {\n"
    "      var a = ['info'];\n"
    "      a[0] = level;\n"
    "      for (var i = 0; i < arguments.length; i++) a.push(arguments[i]);\n"
    "      Erlang.log.apply(null, a);\n"
    "    };\n"
    "  }\n"
    "  globalThis.console = {\n"
    "    log: logArgs('info'),\n"
    "    info: logArgs('info'),\n"
    "    warn: logArgs('warning'),\n"
    "    error: logArgs('error'),\n"
    "    debug: logArgs('debug')\n"
    "  };\n"
    /* CBOR codec (RFC 7049 subset) */
    "  function pushHead(out, major, len) {\n"
    "    var t = major << 5;\n"
    "    if (len < 24) out.push(t|len);\n"
    "    else if (len < 0x100) out.push(t|24, len);\n"
    "    else if (len < 0x10000) out.push(t|25, (len>>8)&0xff, len&0xff);\n"
    "    else if (len < 0x100000000) out.push(t|26, (len>>>24)&0xff, (len>>16)&0xff, (len>>8)&0xff, len&0xff);\n"
    "    else { var hi=Math.floor(len/0x100000000), lo=len>>>0; out.push(t|27,(hi>>>24)&0xff,(hi>>16)&0xff,(hi>>8)&0xff,hi&0xff,(lo>>>24)&0xff,(lo>>16)&0xff,(lo>>8)&0xff,lo&0xff); }\n"
    "  }\n"
    "  function utf8(str) {\n"
    "    var b = [];\n"
    "    for (var i = 0; i < str.length; i++) {\n"
    "      var c = str.charCodeAt(i);\n"
    "      if (c < 0x80) b.push(c);\n"
    "      else if (c < 0x800) b.push(0xc0|(c>>6), 0x80|(c&0x3f));\n"
    "      else if (c >= 0xd800 && c < 0xdc00) {\n"
    "        var c2 = str.charCodeAt(++i);\n"
    "        var cp = 0x10000 + ((c-0xd800)<<10) + (c2-0xdc00);\n"
    "        b.push(0xf0|(cp>>18), 0x80|((cp>>12)&0x3f), 0x80|((cp>>6)&0x3f), 0x80|(cp&0x3f));\n"
    "      } else b.push(0xe0|(c>>12), 0x80|((c>>6)&0x3f), 0x80|(c&0x3f));\n"
    "    }\n"
    "    return b;\n"
    "  }\n"
    "  function cborEncode(value) {\n"
    "    var out = [];\n"
    "    var dv = new DataView(new ArrayBuffer(8));\n"
    "    function enc(v) {\n"
    "      if (v === null) { out.push(0xf6); return; }\n"
    "      if (v === undefined) { out.push(0xf7); return; }\n"
    "      if (v === true) { out.push(0xf5); return; }\n"
    "      if (v === false) { out.push(0xf4); return; }\n"
    "      if (typeof v === 'number') {\n"
    "        if (Number.isInteger(v)) {\n"
    "          if (v >= 0) pushHead(out, 0, v); else pushHead(out, 1, -1 - v);\n"
    "        } else {\n"
    "          dv.setFloat64(0, v); out.push(0xfb);\n"
    "          for (var i = 0; i < 8; i++) out.push(dv.getUint8(i));\n"
    "        }\n"
    "        return;\n"
    "      }\n"
    "      if (typeof v === 'string') {\n"
    "        var b = utf8(v); pushHead(out, 3, b.length);\n"
    "        for (var i = 0; i < b.length; i++) out.push(b[i]);\n"
    "        return;\n"
    "      }\n"
    "      if (Array.isArray(v)) { pushHead(out, 4, v.length); for (var i = 0; i < v.length; i++) enc(v[i]); return; }\n"
    "      if (typeof v === 'object') {\n"
    "        var keys = Object.keys(v);\n"
    "        pushHead(out, 5, keys.length);\n"
    "        for (var i = 0; i < keys.length; i++) { enc(keys[i]); enc(v[keys[i]]); }\n"
    "        return;\n"
    "      }\n"
    "      out.push(0xf7);\n"
    "    }\n"
    "    enc(value);\n"
    "    var u8 = new Uint8Array(out.length);\n"
    "    for (var i = 0; i < out.length; i++) u8[i] = out[i];\n"
    "    return u8.buffer;\n"
    "  }\n"
    "  function cborDecode(buf) {\n"
    "    var ab = buf instanceof ArrayBuffer ? buf : buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);\n"
    "    var view = new Uint8Array(ab);\n"
    "    var dv = new DataView(ab);\n"
    "    var pos = 0;\n"
    "    function readUint(extra) {\n"
    "      if (extra < 24) return extra;\n"
    "      if (extra === 24) return view[pos++];\n"
    "      if (extra === 25) { var v = (view[pos]<<8)|view[pos+1]; pos += 2; return v; }\n"
    "      if (extra === 26) { var v = view[pos]*0x1000000 + (view[pos+1]<<16) + (view[pos+2]<<8) + view[pos+3]; pos += 4; return v; }\n"
    "      if (extra === 27) {\n"
    "        var hi = view[pos]*0x1000000 + (view[pos+1]<<16) + (view[pos+2]<<8) + view[pos+3];\n"
    "        var lo = view[pos+4]*0x1000000 + (view[pos+5]<<16) + (view[pos+6]<<8) + view[pos+7];\n"
    "        pos += 8; return hi*0x100000000 + lo;\n"
    "      }\n"
    "      throw new Error('invalid CBOR length');\n"
    "    }\n"
    "    function dec() {\n"
    "      if (pos >= view.length) throw new Error('truncated CBOR');\n"
    "      var b = view[pos++], major = b>>5, extra = b&0x1f;\n"
    "      if (major === 0) return readUint(extra);\n"
    "      if (major === 1) return -1 - readUint(extra);\n"
    "      if (major === 2 || major === 3) {\n"
    "        var len = readUint(extra), bytes = view.subarray(pos, pos+len); pos += len;\n"
    "        if (major === 3) {\n"
    "          var s = '';\n"
    "          for (var i = 0; i < bytes.length;) {\n"
    "            var c = bytes[i++];\n"
    "            if (c < 0x80) s += String.fromCharCode(c);\n"
    "            else if (c < 0xc0) {}\n"
    "            else if (c < 0xe0) s += String.fromCharCode(((c&0x1f)<<6)|(bytes[i++]&0x3f));\n"
    "            else if (c < 0xf0) s += String.fromCharCode(((c&0x0f)<<12)|((bytes[i++]&0x3f)<<6)|(bytes[i++]&0x3f));\n"
    "            else { var cp = ((c&0x07)<<18)|((bytes[i++]&0x3f)<<12)|((bytes[i++]&0x3f)<<6)|(bytes[i++]&0x3f); cp -= 0x10000; s += String.fromCharCode(0xd800+(cp>>10), 0xdc00+(cp&0x3ff)); }\n"
    "          }\n"
    "          return s;\n"
    "        }\n"
    "        var s = '';\n"
    "        for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);\n"
    "        return s;\n"
    "      }\n"
    "      if (major === 4) { var len = readUint(extra), arr = []; for (var i = 0; i < len; i++) arr.push(dec()); return arr; }\n"
    "      if (major === 5) { var len = readUint(extra), o = {}; for (var i = 0; i < len; i++) { var k = dec(), v = dec(); o[k] = v; } return o; }\n"
    "      if (major === 7) {\n"
    "        if (extra === 20) return false;\n"
    "        if (extra === 21) return true;\n"
    "        if (extra === 22) return null;\n"
    "        if (extra === 23) return undefined;\n"
    "        if (extra === 26) { var v = dv.getFloat32(pos); pos += 4; return v; }\n"
    "        if (extra === 27) { var v = dv.getFloat64(pos); pos += 8; return v; }\n"
    "      }\n"
    "      throw new Error('unsupported CBOR tag ' + major + '/' + extra);\n"
    "    }\n"
    "    var r = dec();\n"
    "    if (pos !== view.length) throw new Error('trailing CBOR data');\n"
    "    return r;\n"
    "  }\n"
    "  globalThis.__quickjs_cbor__ = { encode: cborEncode, decode: cborDecode };\n"
    "})();\n";

static JSValue js_erlang_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
static JSValue js_erlang_emit(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);

static int
install_commonjs(JSContext *ctx)
{
    JSValue v = JS_Eval(ctx, commonjs_bootstrap_src, strlen(commonjs_bootstrap_src),
                        "<quickjs:bootstrap>", JS_EVAL_TYPE_GLOBAL);
    int ok = !JS_IsException(v);
    JS_FreeValue(ctx, v);
    if (!ok) return 0;

    /* Install Erlang.log and Erlang.emit as native functions on the existing object. */
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue erlang = JS_GetPropertyStr(ctx, global, "Erlang");
    JSValue log_fn  = JS_NewCFunction(ctx, js_erlang_log,  "log",  0);
    JSValue emit_fn = JS_NewCFunction(ctx, js_erlang_emit, "emit", 0);
    JS_SetPropertyStr(ctx, erlang, "log",  log_fn);
    JS_SetPropertyStr(ctx, erlang, "emit", emit_fn);
    JS_FreeValue(ctx, erlang);
    JS_FreeValue(ctx, global);
    return 1;
}

/* Read a module id (atom or iodata) into a heap buffer. */
static int
read_module_id(ErlNifEnv *env, ERL_NIF_TERM term, char **out, size_t *out_len)
{
    if (enif_is_atom(env, term)) {
        char tmp[1024];
        int n = enif_get_atom(env, term, tmp, sizeof(tmp), ERL_NIF_LATIN1);
        if (n <= 0) return 0;
        size_t len = (size_t)(n - 1);
        char *buf = enif_alloc(len + 1);
        if (!buf) return 0;
        memcpy(buf, tmp, len);
        buf[len] = '\0';
        *out = buf;
        *out_len = len;
        return 1;
    }
    return iodata_to_cstr(env, term, out, out_len);
}

static ERL_NIF_TERM
nif_register_module(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }

    char *id = NULL;
    size_t id_len = 0;
    if (!read_module_id(env, argv[1], &id, &id_len)) {
        return make_error(env, atom_badarg);
    }

    char *src = NULL;
    size_t src_len = 0;
    if (!iodata_to_cstr(env, argv[2], &src, &src_len)) {
        enif_free(id);
        return make_error(env, atom_badarg);
    }

    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        enif_free(id);
        enif_free(src);
        return make_error(env, atom_invalid_context);
    }

    JSContext *ctx = res->ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue mods = JS_GetPropertyStr(ctx, global, "__quickjs_modules__");
    JSAtom katom = JS_NewAtomLen(ctx, id, id_len);
    JSValue srcv = JS_NewStringLen(ctx, src, src_len);
    JS_SetProperty(ctx, mods, katom, srcv);
    JS_FreeAtom(ctx, katom);
    JS_FreeValue(ctx, mods);
    JS_FreeValue(ctx, global);

    enif_mutex_unlock(res->lock);
    enif_free(id);
    enif_free(src);
    return atom_ok;
}

static ERL_NIF_TERM
nif_require(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }

    char *id = NULL;
    size_t id_len = 0;
    if (!read_module_id(env, argv[1], &id, &id_len)) {
        return make_error(env, atom_badarg);
    }

    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        enif_free(id);
        return make_error(env, atom_invalid_context);
    }

    JSContext *ctx = res->ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue req = JS_GetPropertyStr(ctx, global, "require");
    JSValue idv = JS_NewStringLen(ctx, id, id_len);
    JSValue argv_v[1] = { idv };

    JSValue result = JS_Call(ctx, req, global, 1, argv_v);

    JS_FreeValue(ctx, idv);
    JS_FreeValue(ctx, req);
    JS_FreeValue(ctx, global);

    ERL_NIF_TERM ret;
    if (JS_IsException(result)) {
        ret = js_exception_to_term(env, ctx);
    } else {
        ERL_NIF_TERM v = js_to_term(env, ctx, result);
        ret = enif_make_tuple2(env, atom_ok, v);
    }
    JS_FreeValue(ctx, result);
    enif_mutex_unlock(res->lock);
    enif_free(id);
    return ret;
}

static ERL_NIF_TERM
nif_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }

    char nbuf[256];
    char *name = NULL;
    size_t name_len = 0;
    int owned = 0;
    if (enif_is_atom(env, argv[1])) {
        int n = enif_get_atom(env, argv[1], nbuf, sizeof(nbuf), ERL_NIF_LATIN1);
        if (n <= 0) return make_error(env, atom_badarg);
        name = nbuf;
        name_len = (size_t)(n - 1);
    } else if (iodata_to_cstr(env, argv[1], &name, &name_len)) {
        owned = 1;
    } else {
        return make_error(env, atom_badarg);
    }

    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        if (owned) enif_free(name);
        return make_error(env, atom_invalid_context);
    }

    JSContext *ctx = res->ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue cbs = JS_GetPropertyStr(ctx, global, "__qjs_callbacks__");
    JSAtom katom = JS_NewAtomLen(ctx, name, name_len);
    JSValue cb = JS_GetProperty(ctx, cbs, katom);
    JS_FreeAtom(ctx, katom);

    if (JS_IsUndefined(cb) || JS_IsNull(cb) || !JS_IsFunction(ctx, cb)) {
        JS_FreeValue(ctx, cb);
        JS_FreeValue(ctx, cbs);
        JS_FreeValue(ctx, global);
        enif_mutex_unlock(res->lock);
        if (owned) enif_free(name);
        return atom_ok;
    }

    JSValue jdata = term_to_js(env, ctx, argv[2]);
    JSValue jargs[1] = { jdata };
    JSValue result = JS_Call(ctx, cb, JS_UNDEFINED, 1, jargs);
    JS_FreeValue(ctx, jdata);
    JS_FreeValue(ctx, cb);
    JS_FreeValue(ctx, cbs);
    JS_FreeValue(ctx, global);

    ERL_NIF_TERM ret;
    if (JS_IsException(result)) {
        ret = js_exception_to_term(env, ctx);
    } else {
        ERL_NIF_TERM v = js_to_term(env, ctx, result);
        ret = enif_make_tuple2(env, atom_ok, v);
    }
    JS_FreeValue(ctx, result);
    enif_mutex_unlock(res->lock);
    if (owned) enif_free(name);
    return ret;
}

static ERL_NIF_TERM
nif_get_memory_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }
    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        return make_error(env, atom_invalid_context);
    }
    quickjs_metrics_t m = res->metrics;
    enif_mutex_unlock(res->lock);

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, enif_make_atom(env, "heap_bytes"),    enif_make_uint64(env, (uint64_t)m.heap_bytes),    &map);
    enif_make_map_put(env, map, enif_make_atom(env, "heap_peak"),     enif_make_uint64(env, (uint64_t)m.heap_peak),     &map);
    enif_make_map_put(env, map, enif_make_atom(env, "alloc_count"),   enif_make_uint64(env, (uint64_t)m.alloc_count),   &map);
    enif_make_map_put(env, map, enif_make_atom(env, "realloc_count"), enif_make_uint64(env, (uint64_t)m.realloc_count), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "free_count"),    enif_make_uint64(env, (uint64_t)m.free_count),    &map);
    enif_make_map_put(env, map, enif_make_atom(env, "gc_runs"),       enif_make_uint64(env, (uint64_t)m.gc_runs),       &map);
    return enif_make_tuple2(env, atom_ok, map);
}

static ERL_NIF_TERM
nif_gc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }
    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        return make_error(env, atom_invalid_context);
    }
    JS_RunGC(res->rt);
    res->metrics.gc_runs++;
    enif_mutex_unlock(res->lock);
    return atom_ok;
}

static ERL_NIF_TERM
nif_cbor_encode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }
    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        return make_error(env, atom_invalid_context);
    }

    JSContext *ctx = res->ctx;
    JSValue value = term_to_js(env, ctx, argv[1]);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue cbor = JS_GetPropertyStr(ctx, global, "__quickjs_cbor__");
    JSValue encode_fn = JS_GetPropertyStr(ctx, cbor, "encode");

    JSValue jargs[1] = { value };
    JSValue result = JS_Call(ctx, encode_fn, cbor, 1, jargs);

    JS_FreeValue(ctx, value);
    JS_FreeValue(ctx, encode_fn);
    JS_FreeValue(ctx, cbor);
    JS_FreeValue(ctx, global);

    ERL_NIF_TERM ret;
    if (JS_IsException(result)) {
        ret = js_exception_to_term(env, ctx);
    } else {
        size_t len = 0;
        uint8_t *buf = JS_GetArrayBuffer(ctx, &len, result);
        if (buf == NULL) {
            ret = make_error(env, enif_make_atom(env, "encode_failed"));
        } else {
            ERL_NIF_TERM bin;
            unsigned char *out = enif_make_new_binary(env, len, &bin);
            if (out && len > 0) memcpy(out, buf, len);
            ret = enif_make_tuple2(env, atom_ok, bin);
        }
    }
    JS_FreeValue(ctx, result);
    enif_mutex_unlock(res->lock);
    return ret;
}

static ERL_NIF_TERM
nif_cbor_decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    quickjs_ctx_t *res;
    if (!get_ctx(env, argv[0], &res)) {
        return make_error(env, atom_invalid_context);
    }
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[1], &bin)) {
        return make_error(env, atom_badarg);
    }
    enif_mutex_lock(res->lock);
    refresh_stack_top(res);
    if (res->destroyed) {
        enif_mutex_unlock(res->lock);
        return make_error(env, atom_invalid_context);
    }

    JSContext *ctx = res->ctx;
    JSValue ab = JS_NewArrayBufferCopy(ctx, bin.data, bin.size);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue cbor = JS_GetPropertyStr(ctx, global, "__quickjs_cbor__");
    JSValue decode_fn = JS_GetPropertyStr(ctx, cbor, "decode");

    JSValue jargs[1] = { ab };
    JSValue result = JS_Call(ctx, decode_fn, cbor, 1, jargs);

    JS_FreeValue(ctx, ab);
    JS_FreeValue(ctx, decode_fn);
    JS_FreeValue(ctx, cbor);
    JS_FreeValue(ctx, global);

    ERL_NIF_TERM ret;
    if (JS_IsException(result)) {
        ret = js_exception_to_term(env, ctx);
    } else {
        ERL_NIF_TERM v = js_to_term(env, ctx, result);
        ret = enif_make_tuple2(env, atom_ok, v);
    }
    JS_FreeValue(ctx, result);
    enif_mutex_unlock(res->lock);
    return ret;
}

/* ============================================================================
 * Stubs for later phases
 * ============================================================================ */

static ERL_NIF_TERM
nif_not_yet(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return make_error(env, atom_not_implemented);
}

/* ============================================================================
 * info
 * ============================================================================ */

static ERL_NIF_TERM
nif_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return enif_make_tuple2(env, atom_ok,
        enif_make_string(env, "quickjs nif loaded", ERL_NIF_LATIN1));
}

/* ============================================================================
 * Module load / upgrade
 * ============================================================================ */

static int
load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data; (void)load_info;

    atom_ok               = enif_make_atom(env, "ok");
    atom_error            = enif_make_atom(env, "error");
    atom_badarg           = enif_make_atom(env, "badarg");
    atom_enomem           = enif_make_atom(env, "enomem");
    atom_invalid_context  = enif_make_atom(env, "invalid_context");
    atom_not_implemented  = enif_make_atom(env, "not_implemented");
    atom_js_error         = enif_make_atom(env, "js_error");
    atom_true             = enif_make_atom(env, "true");
    atom_false            = enif_make_atom(env, "false");
    atom_null             = enif_make_atom(env, "null");
    atom_undefined        = enif_make_atom(env, "undefined");
    atom_timeout          = enif_make_atom(env, "timeout");
    atom_nan              = enif_make_atom(env, "nan");
    atom_infinity         = enif_make_atom(env, "infinity");
    atom_neg_infinity     = enif_make_atom(env, "neg_infinity");
    atom_call_erlang      = enif_make_atom(env, "call_erlang");
    atom_erlang_error     = enif_make_atom(env, "erlang_error");
    atom_erlang_throw     = enif_make_atom(env, "erlang_throw");
    atom_erlang_exit      = enif_make_atom(env, "erlang_exit");
    atom_undefined_function = enif_make_atom(env, "undefined_function");

    ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    quickjs_ctx_resource = enif_open_resource_type(
        env, NULL, "quickjs_ctx", quickjs_ctx_dtor, flags, NULL);
    if (quickjs_ctx_resource == NULL) {
        return -1;
    }
    return 0;
}

static int
upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info)
{
    (void)old_priv_data;
    return load(env, priv_data, load_info);
}

static ErlNifFunc nif_funcs[] = {
    {"nif_info",                       0, nif_info,                  0},
    {"nif_new_context",                0, nif_new_context,           0},
    {"nif_new_context_opts",           1, nif_new_context_opts,      0},
    {"nif_destroy_context",            1, nif_destroy_context,       0},
    {"nif_eval",                       3, nif_eval,                  0},
    {"nif_eval_bindings",              4, nif_eval_bindings,         0},
    {"nif_call",                       4, nif_call,                  0},
    {"nif_register_module",            3, nif_register_module,       0},
    {"nif_require",                    2, nif_require,               0},
    {"nif_send",                       3, nif_send,                  0},
    {"nif_register_erlang_function",   2, nif_register_erlang_function, 0},
    {"nif_call_complete",              2, nif_call_complete,         0},
    {"nif_eval_resume",                1, nif_eval_resume,           0},
    {"nif_cbor_encode",                2, nif_cbor_encode,           ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_cbor_decode",                2, nif_cbor_decode,           ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_get_memory_stats",           1, nif_get_memory_stats,      0},
    {"nif_gc",                         1, nif_gc,                    0}
};

ERL_NIF_INIT(quickjs, nif_funcs, load, NULL, upgrade, NULL)
