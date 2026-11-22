/*
 * quickjs_dart: a small C surface over the vendored QuickJS-ng engine for
 * Dart FFI (KTD24).
 *
 * Why a wrapper instead of binding quickjs.h directly:
 * - quickjs.h changes the JSValue representation per target (a 16-byte struct
 *   on 64-bit, a NaN-boxed uint64_t on 32-bit). One committed ffigen binding
 *   cannot pass JSValue by value correctly on both arm64 and armv7. Every
 *   value here crosses the boundary as a heap box (`JSValue *`), so the Dart
 *   bindings are identical on every target.
 * - Many engine helpers are `static inline` and have no symbol to bind.
 * - The interrupt handler, deadlines and the cross-isolate interrupt token
 *   are implemented in C so a busy JS loop is stopped without calling into
 *   Dart on every check.
 *
 * Ownership rules:
 * - Every `JSValue *` returned by a qjsd_* function is an owned box. Free it
 *   with qjsd_value_free. A NULL return means the box itself could not be
 *   allocated (the value has already been released).
 * - Functions documented as "consumes" take ownership of the box argument.
 * - `argv` pointers handed to the host dispatch callback are borrowed and
 *   valid only during the callback; read them with qjsd_argv_at.
 */
#ifndef QUICKJS_DART_H
#define QUICKJS_DART_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define QJSD_API __declspec(dllexport)
#else
#define QJSD_API __attribute__((visibility("default")))
#endif

typedef struct JSRuntime JSRuntime;
typedef struct JSContext JSContext;
/* Opaque to Dart: the size differs between targets. */
typedef struct QjsdValue QjsdValue;
typedef struct QjsdRuntime QjsdRuntime;
typedef struct QjsdToken QjsdToken;

/*
 * Host function dispatch. Called synchronously on the thread running JS.
 * Returns an owned box (ownership moves to C), or NULL, which C turns into a
 * thrown InternalError("host function failed").
 */
typedef QjsdValue *(*qjsd_host_dispatch)(JSContext *ctx, int32_t fn_id,
                                         QjsdValue *this_val, int32_t argc,
                                         QjsdValue *argv);

/* Value kinds returned by qjsd_value_kind. */
enum {
  QJSD_KIND_UNDEFINED = 0,
  QJSD_KIND_NULL = 1,
  QJSD_KIND_BOOL = 2,
  QJSD_KIND_INT = 3,
  QJSD_KIND_FLOAT = 4,
  QJSD_KIND_STRING = 5,
  QJSD_KIND_SYMBOL = 6,
  QJSD_KIND_BIGINT = 7,
  QJSD_KIND_OBJECT = 8,
  QJSD_KIND_ARRAY = 9,
  QJSD_KIND_FUNCTION = 10,
  QJSD_KIND_ARRAY_BUFFER = 11,
  QJSD_KIND_TYPED_ARRAY = 12,
  QJSD_KIND_PROMISE = 13,
  QJSD_KIND_ERROR = 14,
  QJSD_KIND_EXCEPTION = 15,
  QJSD_KIND_OTHER = 16
};

/* Interrupt reasons returned by qjsd_runtime_interrupt_reason. */
enum {
  QJSD_INTERRUPT_NONE = 0,
  QJSD_INTERRUPT_DEADLINE = 1,
  QJSD_INTERRUPT_REQUESTED = 2
};

/* --- Engine and platform information ------------------------------------ */

/* Engine version string, for example "0.18.0". */
QJSD_API const char *qjsd_version(void);
/* Monotonic clock in nanoseconds; the same clock the interrupt handler reads. */
QJSD_API int64_t qjsd_now_ns(void);
/* sizeof(JSValue) for this build (16 on 64-bit, 8 with NaN boxing). */
QJSD_API int32_t qjsd_value_size(void);
/*
 * Bytes of native stack left below the caller's frame on the current thread,
 * or -1 if the platform cannot report it.
 */
QJSD_API int64_t qjsd_thread_stack_available(void);
/* Physical memory of the device in bytes, or -1 if unknown. */
QJSD_API int64_t qjsd_physical_memory(void);

/* --- Interrupt token (shareable across isolates and threads) ------------ */

/* Creates a token with one reference. */
QJSD_API QjsdToken *qjsd_token_new(void);
QJSD_API void qjsd_token_retain(QjsdToken *token);
/* Drops one reference; the token is freed when the last one goes. */
QJSD_API void qjsd_token_release(QjsdToken *token);
/* Asks every runtime observing this token to stop at its next check. */
QJSD_API void qjsd_token_request(QjsdToken *token);
QJSD_API void qjsd_token_reset(QjsdToken *token);
QJSD_API int32_t qjsd_token_is_requested(QjsdToken *token);

/* --- Runtime ------------------------------------------------------------ */

/* Creates a runtime observing `token` (may be NULL; retained if not). */
QJSD_API QjsdRuntime *qjsd_runtime_new(QjsdToken *token,
                                       qjsd_host_dispatch dispatch);
/* Frees the runtime. All contexts and values must be freed first. */
QJSD_API void qjsd_runtime_free(QjsdRuntime *rt);
/*
 * Memory limit in bytes on what the engine holds from the system allocator
 * (headers included); 0 or negative removes it. Enforced by the wrapper's
 * allocator so a refusal is always recorded (qjsd_runtime_memory_limit_hit).
 */
QJSD_API void qjsd_runtime_set_memory_limit(QjsdRuntime *rt, int64_t bytes);
/* Bytes currently held by the engine, O(1). */
QJSD_API int64_t qjsd_runtime_allocated(QjsdRuntime *rt);
/* Highest qjsd_runtime_allocated since creation or the last reset. */
QJSD_API int64_t qjsd_runtime_peak_allocated(QjsdRuntime *rt);
QJSD_API void qjsd_runtime_reset_peak(QjsdRuntime *rt);
/* 1 if an allocation was refused since the last clear; cleared with the
   interrupt reason. */
QJSD_API int32_t qjsd_runtime_memory_limit_hit(QjsdRuntime *rt);
/* JS stack limit in bytes; 0 disables the check. */
QJSD_API void qjsd_runtime_set_max_stack_size(QjsdRuntime *rt, int64_t bytes);
/* Absolute qjsd_now_ns() deadline; 0 removes it. */
QJSD_API void qjsd_runtime_set_deadline(QjsdRuntime *rt, int64_t deadline_ns);
/* Why the last interrupt fired (QJSD_INTERRUPT_*); sticky until cleared. */
QJSD_API int32_t qjsd_runtime_interrupt_reason(QjsdRuntime *rt);
/* Clears the interrupt reason and the memory-limit flag. */
QJSD_API void qjsd_runtime_clear_interrupt(QjsdRuntime *rt);
QJSD_API void qjsd_runtime_run_gc(QjsdRuntime *rt);
/*
 * Writes 4 values to `out`: the engine's malloc_size, the configured limit,
 * memory_used_size and malloc_count (JS_ComputeMemoryUsage; walks the heap).
 */
QJSD_API void qjsd_runtime_memory_usage(QjsdRuntime *rt, int64_t *out);
QJSD_API int32_t qjsd_runtime_is_job_pending(QjsdRuntime *rt);
/*
 * Runs one pending job. Returns 1 if a job ran, 0 if none was pending, and -1
 * if the job threw; then `*out_ctx` names the context holding the exception.
 */
QJSD_API int32_t qjsd_runtime_execute_pending_job(QjsdRuntime *rt,
                                                  JSContext **out_ctx);

/* --- Context ------------------------------------------------------------ */

/* Standard intrinsics only: no std/os module, no file or process access. */
QJSD_API JSContext *qjsd_context_new(QjsdRuntime *rt);
QJSD_API void qjsd_context_free(JSContext *ctx);
/* Evaluates script code (JS_EVAL_* flags; 0 = global, non-strict). */
QJSD_API QjsdValue *qjsd_eval(JSContext *ctx, const char *code, size_t len,
                              const char *filename, int32_t flags);
QJSD_API QjsdValue *qjsd_get_global(JSContext *ctx);
/* Takes the pending exception (undefined if none). */
QJSD_API QjsdValue *qjsd_get_exception(JSContext *ctx);
/* Whether the value is an uncatchable error (interrupt, out of memory). */
QJSD_API int32_t qjsd_is_uncatchable(QjsdValue *v);

/* --- Values ------------------------------------------------------------- */

QJSD_API void qjsd_value_free(JSContext *ctx, QjsdValue *v);
QJSD_API QjsdValue *qjsd_value_dup(JSContext *ctx, QjsdValue *v);
QJSD_API int32_t qjsd_value_kind(JSContext *ctx, QjsdValue *v);
QJSD_API QjsdValue *qjsd_new_undefined(JSContext *ctx);
QJSD_API QjsdValue *qjsd_new_null(JSContext *ctx);
QJSD_API QjsdValue *qjsd_new_bool(JSContext *ctx, int32_t value);
QJSD_API QjsdValue *qjsd_new_float64(JSContext *ctx, double value);
QJSD_API QjsdValue *qjsd_new_int64(JSContext *ctx, int64_t value);
QJSD_API QjsdValue *qjsd_new_string(JSContext *ctx, const char *utf8,
                                    size_t len);
QJSD_API QjsdValue *qjsd_new_object(JSContext *ctx);
QJSD_API QjsdValue *qjsd_new_array(JSContext *ctx);
QJSD_API QjsdValue *qjsd_new_array_buffer_copy(JSContext *ctx,
                                               const uint8_t *data,
                                               size_t len);
QJSD_API QjsdValue *qjsd_new_uint8_array_copy(JSContext *ctx,
                                              const uint8_t *data, size_t len);
QJSD_API QjsdValue *qjsd_new_error(JSContext *ctx, const char *name,
                                   const char *message);

/* String conversion (JS ToString); NULL on exception. */
QJSD_API const char *qjsd_to_cstring(JSContext *ctx, QjsdValue *v,
                                     size_t *out_len);
QJSD_API void qjsd_free_cstring(JSContext *ctx, const char *s);
/* Writes the number to *out; returns 0, or -1 on exception. */
QJSD_API int32_t qjsd_to_float64(JSContext *ctx, QjsdValue *v, double *out);
/* JS ToBoolean; -1 on exception. */
QJSD_API int32_t qjsd_to_bool(JSContext *ctx, QjsdValue *v);
/*
 * Borrowed pointer to the bytes of an ArrayBuffer or typed-array view, valid
 * until JS runs again. NULL (with *out_len = 0) for anything else.
 */
QJSD_API uint8_t *qjsd_get_bytes(JSContext *ctx, QjsdValue *v,
                                 size_t *out_len);

QJSD_API QjsdValue *qjsd_get_property(JSContext *ctx, QjsdValue *obj,
                                      const char *name);
QJSD_API QjsdValue *qjsd_get_index(JSContext *ctx, QjsdValue *obj,
                                   uint32_t index);
/* Consumes `value`. Returns 0, or -1 on exception. */
QJSD_API int32_t qjsd_set_property(JSContext *ctx, QjsdValue *obj,
                                   const char *name, QjsdValue *value);
/* Consumes `value`. Returns 0, or -1 on exception. */
QJSD_API int32_t qjsd_set_index(JSContext *ctx, QjsdValue *obj, uint32_t index,
                                QjsdValue *value);
/* `length` property; -1 on exception. */
QJSD_API int64_t qjsd_get_length(JSContext *ctx, QjsdValue *obj);
/* Array of the object's own enumerable string keys. */
QJSD_API QjsdValue *qjsd_object_keys(JSContext *ctx, QjsdValue *obj);
/* Calls `fn` with `argc` borrowed boxes in `argv`; `this_val` may be NULL. */
QJSD_API QjsdValue *qjsd_call(JSContext *ctx, QjsdValue *fn,
                              QjsdValue *this_val, int32_t argc,
                              QjsdValue **argv);
QJSD_API QjsdValue *qjsd_json_parse(JSContext *ctx, const char *utf8,
                                    size_t len);
QJSD_API QjsdValue *qjsd_json_stringify(JSContext *ctx, QjsdValue *v);

/*
 * Creates a promise; writes owned resolve/reject function boxes to the out
 * parameters (both NULL on failure).
 */
QJSD_API QjsdValue *qjsd_new_promise(JSContext *ctx, QjsdValue **out_resolve,
                                     QjsdValue **out_reject);
/* -1 not a promise, 0 pending, 1 fulfilled, 2 rejected. */
QJSD_API int32_t qjsd_promise_state(JSContext *ctx, QjsdValue *v);
QJSD_API QjsdValue *qjsd_promise_result(JSContext *ctx, QjsdValue *v);

/* A JS function that calls the runtime's host dispatch with `fn_id`. */
QJSD_API QjsdValue *qjsd_new_host_function(JSContext *ctx, const char *name,
                                           int32_t length, int32_t fn_id);
/* Borrowed pointer to argv[index] inside a host dispatch callback. */
QJSD_API QjsdValue *qjsd_argv_at(QjsdValue *argv, int32_t index);
/* Throws `value` (consumed); returns the exception marker box. */
QJSD_API QjsdValue *qjsd_throw(JSContext *ctx, QjsdValue *value);
/* Throws an Error with `message`; returns the exception marker box. */
QJSD_API QjsdValue *qjsd_throw_error(JSContext *ctx, const char *message);

#ifdef __cplusplus
}
#endif

#endif /* QUICKJS_DART_H */
