/*
 * quickjs_dart: implementation of the Dart FFI surface declared in
 * quickjs_dart.h. See that header for the ownership rules.
 */
#include "quickjs_dart.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__)
#include <pthread.h>
#include <sys/sysctl.h>
#include <time.h>
#else
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#endif

#define V(p) (*(JSValue *)(p))

struct QjsdToken {
  atomic_int refs;
  atomic_int requested;
};

struct QjsdRuntime {
  JSRuntime *rt;
  QjsdToken *token;
  qjsd_host_dispatch dispatch;
  int64_t deadline_ns;
  int32_t reason;
  /* Nesting depth of engine entries; the stack top is captured only at the
     outermost entry so nested host callbacks cannot extend the JS stack. */
  int32_t depth;
};

/* --- Helpers ------------------------------------------------------------ */

static QjsdValue *box(JSContext *ctx, JSValue v) {
  JSValue *p = (JSValue *)malloc(sizeof(JSValue));
  if (p == NULL) {
    JS_FreeValue(ctx, v);
    return NULL;
  }
  *p = v;
  return (QjsdValue *)p;
}

static QjsdRuntime *runtime_of(JSContext *ctx) {
  return (QjsdRuntime *)JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
}

static void enter(QjsdRuntime *r) {
  if (r->depth++ == 0) JS_UpdateStackTop(r->rt);
}

static void leave(QjsdRuntime *r) { r->depth--; }

#define ENTER(ctx) QjsdRuntime *qr_ = runtime_of(ctx); enter(qr_)
#define LEAVE() leave(qr_)

static void clear_exception(JSContext *ctx) {
  JS_FreeValue(ctx, JS_GetException(ctx));
}

/* --- Engine and platform information ------------------------------------ */

const char *qjsd_version(void) { return JS_GetVersion(); }

int64_t qjsd_now_ns(void) {
#if defined(_WIN32)
  static LARGE_INTEGER freq;
  LARGE_INTEGER counter;
  if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&counter);
  int64_t secs = counter.QuadPart / freq.QuadPart;
  int64_t rem = counter.QuadPart % freq.QuadPart;
  return secs * 1000000000LL + rem * 1000000000LL / freq.QuadPart;
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
#endif
}

int32_t qjsd_value_size(void) { return (int32_t)sizeof(JSValue); }

int64_t qjsd_thread_stack_available(void) {
  volatile char marker = 0;
  uintptr_t here = (uintptr_t)&marker;
#if defined(_WIN32)
  ULONG_PTR low = 0, high = 0;
  GetCurrentThreadStackLimits(&low, &high);
  if (low == 0 || here < low) return -1;
  return (int64_t)(here - low);
#elif defined(__APPLE__)
  pthread_t self = pthread_self();
  uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(self);
  size_t size = pthread_get_stacksize_np(self);
  uintptr_t low = top - size;
  if (here < low || here > top) return -1;
  return (int64_t)(here - low);
#else
  pthread_attr_t attr;
  void *addr = NULL;
  size_t size = 0;
  if (pthread_getattr_np(pthread_self(), &attr) != 0) return -1;
  int rc = pthread_attr_getstack(&attr, &addr, &size);
  pthread_attr_destroy(&attr);
  if (rc != 0 || addr == NULL) return -1;
  uintptr_t low = (uintptr_t)addr;
  if (here < low || here > low + size) return -1;
  return (int64_t)(here - low);
#endif
}

int64_t qjsd_physical_memory(void) {
#if defined(_WIN32)
  MEMORYSTATUSEX status;
  status.dwLength = sizeof(status);
  if (!GlobalMemoryStatusEx(&status)) return -1;
  return (int64_t)status.ullTotalPhys;
#elif defined(__APPLE__)
  int64_t mem = 0;
  size_t len = sizeof(mem);
  if (sysctlbyname("hw.memsize", &mem, &len, NULL, 0) != 0) return -1;
  return mem;
#else
  long pages = sysconf(_SC_PHYS_PAGES);
  long page_size = sysconf(_SC_PAGESIZE);
  if (pages <= 0 || page_size <= 0) return -1;
  return (int64_t)pages * (int64_t)page_size;
#endif
}

/* --- Interrupt token ---------------------------------------------------- */

QjsdToken *qjsd_token_new(void) {
  QjsdToken *t = (QjsdToken *)malloc(sizeof(QjsdToken));
  if (t == NULL) return NULL;
  atomic_init(&t->refs, 1);
  atomic_init(&t->requested, 0);
  return t;
}

void qjsd_token_retain(QjsdToken *token) {
  if (token != NULL) atomic_fetch_add(&token->refs, 1);
}

void qjsd_token_release(QjsdToken *token) {
  if (token != NULL && atomic_fetch_sub(&token->refs, 1) == 1) free(token);
}

void qjsd_token_request(QjsdToken *token) {
  if (token != NULL) atomic_store(&token->requested, 1);
}

void qjsd_token_reset(QjsdToken *token) {
  if (token != NULL) atomic_store(&token->requested, 0);
}

int32_t qjsd_token_is_requested(QjsdToken *token) {
  return token != NULL ? atomic_load(&token->requested) : 0;
}

/* --- Runtime ------------------------------------------------------------ */

static int interrupt_handler(JSContext *ctx, void *opaque) {
  (void)ctx;
  QjsdRuntime *r = (QjsdRuntime *)opaque;
  if (r->token != NULL && atomic_load(&r->token->requested)) {
    r->reason = QJSD_INTERRUPT_REQUESTED;
    return 1;
  }
  if (r->deadline_ns > 0 && qjsd_now_ns() >= r->deadline_ns) {
    r->reason = QJSD_INTERRUPT_DEADLINE;
    return 1;
  }
  return 0;
}

QjsdRuntime *qjsd_runtime_new(QjsdToken *token, qjsd_host_dispatch dispatch) {
  QjsdRuntime *r = (QjsdRuntime *)calloc(1, sizeof(QjsdRuntime));
  if (r == NULL) return NULL;
  r->rt = JS_NewRuntime();
  if (r->rt == NULL) {
    free(r);
    return NULL;
  }
  r->dispatch = dispatch;
  if (token != NULL) {
    qjsd_token_retain(token);
    r->token = token;
  }
  JS_SetRuntimeOpaque(r->rt, r);
  JS_SetInterruptHandler(r->rt, interrupt_handler, r);
  return r;
}

void qjsd_runtime_free(QjsdRuntime *rt) {
  if (rt == NULL) return;
  JS_SetInterruptHandler(rt->rt, NULL, NULL);
  JS_FreeRuntime(rt->rt);
  qjsd_token_release(rt->token);
  free(rt);
}

void qjsd_runtime_set_memory_limit(QjsdRuntime *rt, int64_t bytes) {
  /* QuickJS-ng treats 0 as unlimited. */
  JS_SetMemoryLimit(rt->rt, bytes < 0 ? 0 : (size_t)bytes);
}

void qjsd_runtime_set_max_stack_size(QjsdRuntime *rt, int64_t bytes) {
  JS_SetMaxStackSize(rt->rt, bytes <= 0 ? 0 : (size_t)bytes);
}

void qjsd_runtime_set_deadline(QjsdRuntime *rt, int64_t deadline_ns) {
  rt->deadline_ns = deadline_ns;
}

int32_t qjsd_runtime_interrupt_reason(QjsdRuntime *rt) { return rt->reason; }

void qjsd_runtime_clear_interrupt(QjsdRuntime *rt) {
  rt->reason = QJSD_INTERRUPT_NONE;
}

void qjsd_runtime_run_gc(QjsdRuntime *rt) { JS_RunGC(rt->rt); }

void qjsd_runtime_memory_usage(QjsdRuntime *rt, int64_t *out) {
  JSMemoryUsage usage;
  JS_ComputeMemoryUsage(rt->rt, &usage);
  out[0] = usage.malloc_size;
  out[1] = usage.malloc_limit;
  out[2] = usage.memory_used_size;
  out[3] = usage.malloc_count;
}

int32_t qjsd_runtime_is_job_pending(QjsdRuntime *rt) {
  return JS_IsJobPending(rt->rt) ? 1 : 0;
}

int32_t qjsd_runtime_execute_pending_job(QjsdRuntime *rt, JSContext **out_ctx) {
  JSContext *ctx = NULL;
  enter(rt);
  int rc = JS_ExecutePendingJob(rt->rt, &ctx);
  leave(rt);
  if (out_ctx != NULL) *out_ctx = ctx;
  return rc < 0 ? -1 : (rc > 0 ? 1 : 0);
}

/* --- Context ------------------------------------------------------------ */

JSContext *qjsd_context_new(QjsdRuntime *rt) { return JS_NewContext(rt->rt); }

void qjsd_context_free(JSContext *ctx) { JS_FreeContext(ctx); }

QjsdValue *qjsd_eval(JSContext *ctx, const char *code, size_t len,
                     const char *filename, int32_t flags) {
  ENTER(ctx);
  JSValue v = JS_Eval(ctx, code, len, filename != NULL ? filename : "<eval>",
                      flags);
  LEAVE();
  return box(ctx, v);
}

QjsdValue *qjsd_get_global(JSContext *ctx) {
  return box(ctx, JS_GetGlobalObject(ctx));
}

QjsdValue *qjsd_get_exception(JSContext *ctx) {
  return box(ctx, JS_GetException(ctx));
}

int32_t qjsd_is_uncatchable(QjsdValue *v) {
  return JS_IsUncatchableError(V(v)) ? 1 : 0;
}

/* --- Values ------------------------------------------------------------- */

void qjsd_value_free(JSContext *ctx, QjsdValue *v) {
  if (v == NULL) return;
  JS_FreeValue(ctx, V(v));
  free(v);
}

QjsdValue *qjsd_value_dup(JSContext *ctx, QjsdValue *v) {
  return box(ctx, JS_DupValue(ctx, V(v)));
}

int32_t qjsd_value_kind(JSContext *ctx, QjsdValue *p) {
  JSValue v = V(p);
  switch (JS_VALUE_GET_NORM_TAG(v)) {
    case JS_TAG_UNDEFINED: return QJSD_KIND_UNDEFINED;
    case JS_TAG_NULL: return QJSD_KIND_NULL;
    case JS_TAG_BOOL: return QJSD_KIND_BOOL;
    case JS_TAG_INT: return QJSD_KIND_INT;
    case JS_TAG_FLOAT64: return QJSD_KIND_FLOAT;
    case JS_TAG_STRING:
    case JS_TAG_STRING_ROPE: return QJSD_KIND_STRING;
    case JS_TAG_SYMBOL: return QJSD_KIND_SYMBOL;
    case JS_TAG_BIG_INT:
    case JS_TAG_SHORT_BIG_INT: return QJSD_KIND_BIGINT;
    case JS_TAG_EXCEPTION: return QJSD_KIND_EXCEPTION;
    case JS_TAG_OBJECT:
      if (JS_IsFunction(ctx, v)) return QJSD_KIND_FUNCTION;
      if (JS_IsArray(v)) return QJSD_KIND_ARRAY;
      if (JS_IsArrayBuffer(v)) return QJSD_KIND_ARRAY_BUFFER;
      if (JS_GetTypedArrayType(v) >= 0) return QJSD_KIND_TYPED_ARRAY;
      if (JS_IsPromise(v)) return QJSD_KIND_PROMISE;
      if (JS_IsError(v)) return QJSD_KIND_ERROR;
      return QJSD_KIND_OBJECT;
    default: return QJSD_KIND_OTHER;
  }
}

QjsdValue *qjsd_new_undefined(JSContext *ctx) { return box(ctx, JS_UNDEFINED); }

QjsdValue *qjsd_new_null(JSContext *ctx) { return box(ctx, JS_NULL); }

QjsdValue *qjsd_new_bool(JSContext *ctx, int32_t value) {
  return box(ctx, JS_NewBool(ctx, value != 0));
}

QjsdValue *qjsd_new_float64(JSContext *ctx, double value) {
  return box(ctx, JS_NewFloat64(ctx, value));
}

QjsdValue *qjsd_new_int64(JSContext *ctx, int64_t value) {
  return box(ctx, JS_NewInt64(ctx, value));
}

QjsdValue *qjsd_new_string(JSContext *ctx, const char *utf8, size_t len) {
  return box(ctx, JS_NewStringLen(ctx, utf8, len));
}

QjsdValue *qjsd_new_object(JSContext *ctx) { return box(ctx, JS_NewObject(ctx)); }

QjsdValue *qjsd_new_array(JSContext *ctx) { return box(ctx, JS_NewArray(ctx)); }

QjsdValue *qjsd_new_array_buffer_copy(JSContext *ctx, const uint8_t *data,
                                      size_t len) {
  return box(ctx, JS_NewArrayBufferCopy(ctx, data, len));
}

QjsdValue *qjsd_new_uint8_array_copy(JSContext *ctx, const uint8_t *data,
                                     size_t len) {
  return box(ctx, JS_NewUint8ArrayCopy(ctx, data, len));
}

static JSValue make_error(JSContext *ctx, const char *name,
                          const char *message) {
  JSValue err = JS_NewError(ctx);
  if (JS_IsException(err)) return err;
  if (message != NULL)
    JS_SetPropertyStr(ctx, err, "message", JS_NewString(ctx, message));
  if (name != NULL)
    JS_SetPropertyStr(ctx, err, "name", JS_NewString(ctx, name));
  return err;
}

QjsdValue *qjsd_new_error(JSContext *ctx, const char *name,
                          const char *message) {
  return box(ctx, make_error(ctx, name, message));
}

const char *qjsd_to_cstring(JSContext *ctx, QjsdValue *v, size_t *out_len) {
  ENTER(ctx);
  const char *s = JS_ToCStringLen2(ctx, out_len, V(v), false);
  LEAVE();
  return s;
}

void qjsd_free_cstring(JSContext *ctx, const char *s) {
  if (s != NULL) JS_FreeCString(ctx, s);
}

int32_t qjsd_to_float64(JSContext *ctx, QjsdValue *v, double *out) {
  ENTER(ctx);
  int rc = JS_ToFloat64(ctx, out, V(v));
  LEAVE();
  return rc < 0 ? -1 : 0;
}

int32_t qjsd_to_bool(JSContext *ctx, QjsdValue *v) {
  ENTER(ctx);
  int rc = JS_ToBool(ctx, V(v));
  LEAVE();
  return rc;
}

uint8_t *qjsd_get_bytes(JSContext *ctx, QjsdValue *p, size_t *out_len) {
  JSValue v = V(p);
  *out_len = 0;
  if (JS_IsArrayBuffer(v)) {
    size_t len = 0;
    uint8_t *data = JS_GetArrayBuffer(ctx, &len, v);
    if (data == NULL) {
      clear_exception(ctx);
      return NULL;
    }
    *out_len = len;
    return data;
  }
  if (JS_GetTypedArrayType(v) >= 0) {
    size_t offset = 0, length = 0, per_element = 0;
    JSValue buffer = JS_GetTypedArrayBuffer(ctx, v, &offset, &length,
                                            &per_element);
    if (JS_IsException(buffer)) {
      clear_exception(ctx);
      return NULL;
    }
    size_t buffer_len = 0;
    uint8_t *data = JS_GetArrayBuffer(ctx, &buffer_len, buffer);
    /* The view keeps the buffer alive. */
    JS_FreeValue(ctx, buffer);
    if (data == NULL || offset + length > buffer_len) {
      clear_exception(ctx);
      return NULL;
    }
    *out_len = length;
    return data + offset;
  }
  return NULL;
}

QjsdValue *qjsd_get_property(JSContext *ctx, QjsdValue *obj, const char *name) {
  ENTER(ctx);
  JSValue v = JS_GetPropertyStr(ctx, V(obj), name);
  LEAVE();
  return box(ctx, v);
}

QjsdValue *qjsd_get_index(JSContext *ctx, QjsdValue *obj, uint32_t index) {
  ENTER(ctx);
  JSValue v = JS_GetPropertyUint32(ctx, V(obj), index);
  LEAVE();
  return box(ctx, v);
}

int32_t qjsd_set_property(JSContext *ctx, QjsdValue *obj, const char *name,
                          QjsdValue *value) {
  JSValue v = V(value);
  free(value);
  ENTER(ctx);
  int rc = JS_SetPropertyStr(ctx, V(obj), name, v);
  LEAVE();
  return rc < 0 ? -1 : 0;
}

int32_t qjsd_set_index(JSContext *ctx, QjsdValue *obj, uint32_t index,
                       QjsdValue *value) {
  JSValue v = V(value);
  free(value);
  ENTER(ctx);
  int rc = JS_SetPropertyUint32(ctx, V(obj), index, v);
  LEAVE();
  return rc < 0 ? -1 : 0;
}

int64_t qjsd_get_length(JSContext *ctx, QjsdValue *obj) {
  int64_t len = 0;
  ENTER(ctx);
  int rc = JS_GetLength(ctx, V(obj), &len);
  LEAVE();
  return rc < 0 ? -1 : len;
}

QjsdValue *qjsd_object_keys(JSContext *ctx, QjsdValue *obj) {
  JSPropertyEnum *tab = NULL;
  uint32_t len = 0;
  ENTER(ctx);
  int rc = JS_GetOwnPropertyNames(ctx, &tab, &len, V(obj),
                                  JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY);
  LEAVE();
  if (rc < 0) return box(ctx, JS_EXCEPTION);
  JSValue arr = JS_NewArray(ctx);
  if (!JS_IsException(arr)) {
    for (uint32_t i = 0; i < len; i++) {
      if (JS_SetPropertyUint32(ctx, arr, i,
                               JS_AtomToString(ctx, tab[i].atom)) < 0) {
        JS_FreeValue(ctx, arr);
        arr = JS_EXCEPTION;
        break;
      }
    }
  }
  JS_FreePropertyEnum(ctx, tab, len);
  return box(ctx, arr);
}

QjsdValue *qjsd_call(JSContext *ctx, QjsdValue *fn, QjsdValue *this_val,
                     int32_t argc, QjsdValue **argv) {
  JSValue stack_args[8];
  JSValue *args = stack_args;
  if (argc > 8) {
    args = (JSValue *)malloc(sizeof(JSValue) * (size_t)argc);
    if (args == NULL) return box(ctx, JS_ThrowOutOfMemory(ctx));
  }
  for (int32_t i = 0; i < argc; i++) args[i] = V(argv[i]);
  JSValue self = this_val != NULL ? V(this_val) : JS_UNDEFINED;
  ENTER(ctx);
  JSValue result = JS_Call(ctx, V(fn), self, argc, args);
  LEAVE();
  if (args != stack_args) free(args);
  return box(ctx, result);
}

QjsdValue *qjsd_json_parse(JSContext *ctx, const char *utf8, size_t len) {
  ENTER(ctx);
  JSValue v = JS_ParseJSON(ctx, utf8, len, "<json>");
  LEAVE();
  return box(ctx, v);
}

QjsdValue *qjsd_json_stringify(JSContext *ctx, QjsdValue *v) {
  ENTER(ctx);
  JSValue s = JS_JSONStringify(ctx, V(v), JS_UNDEFINED, JS_UNDEFINED);
  LEAVE();
  return box(ctx, s);
}

QjsdValue *qjsd_new_promise(JSContext *ctx, QjsdValue **out_resolve,
                            QjsdValue **out_reject) {
  JSValue funcs[2];
  *out_resolve = NULL;
  *out_reject = NULL;
  JSValue promise = JS_NewPromiseCapability(ctx, funcs);
  if (JS_IsException(promise)) return box(ctx, promise);
  QjsdValue *resolve = box(ctx, funcs[0]);
  QjsdValue *reject = box(ctx, funcs[1]);
  QjsdValue *boxed = box(ctx, promise);
  if (resolve == NULL || reject == NULL || boxed == NULL) {
    qjsd_value_free(ctx, resolve);
    qjsd_value_free(ctx, reject);
    qjsd_value_free(ctx, boxed);
    return NULL;
  }
  *out_resolve = resolve;
  *out_reject = reject;
  return boxed;
}

int32_t qjsd_promise_state(JSContext *ctx, QjsdValue *v) {
  return (int32_t)JS_PromiseState(ctx, V(v));
}

QjsdValue *qjsd_promise_result(JSContext *ctx, QjsdValue *v) {
  return box(ctx, JS_PromiseResult(ctx, V(v)));
}

static JSValue host_trampoline(JSContext *ctx, JSValueConst this_val, int argc,
                               JSValueConst *argv, int magic,
                               JSValueConst *func_data) {
  (void)magic;
  QjsdRuntime *r = runtime_of(ctx);
  int32_t fn_id = 0;
  if (r == NULL || r->dispatch == NULL)
    return JS_ThrowInternalError(ctx, "host dispatch unavailable");
  if (JS_ToInt32(ctx, &fn_id, func_data[0]) < 0) return JS_EXCEPTION;
  JSValue self = this_val;
  QjsdValue *result = r->dispatch(ctx, fn_id, (QjsdValue *)&self,
                                  (int32_t)argc, (QjsdValue *)argv);
  if (result == NULL) {
    if (JS_HasException(ctx)) return JS_EXCEPTION;
    return JS_ThrowInternalError(ctx, "host function failed");
  }
  JSValue v = V(result);
  free(result);
  return v;
}

QjsdValue *qjsd_new_host_function(JSContext *ctx, const char *name,
                                  int32_t length, int32_t fn_id) {
  JSValue data = JS_NewInt32(ctx, fn_id);
  JSValue fn = JS_NewCFunctionData(ctx, host_trampoline, length, 0, 1, &data);
  if (!JS_IsException(fn) && name != NULL) {
    JS_DefinePropertyValueStr(ctx, fn, "name", JS_NewString(ctx, name),
                              JS_PROP_CONFIGURABLE);
  }
  return box(ctx, fn);
}

QjsdValue *qjsd_argv_at(QjsdValue *argv, int32_t index) {
  return (QjsdValue *)(((JSValue *)argv) + index);
}

QjsdValue *qjsd_throw(JSContext *ctx, QjsdValue *value) {
  JSValue v = V(value);
  free(value);
  return box(ctx, JS_Throw(ctx, v));
}

QjsdValue *qjsd_throw_error(JSContext *ctx, const char *message) {
  JSValue err = make_error(ctx, NULL, message);
  if (JS_IsException(err)) return box(ctx, err);
  return box(ctx, JS_Throw(ctx, err));
}
