// Native dispatcher for the embedded iOS JVM (U16, KTD11/KTD23).
//
// Dart calls these functions through FFIgen bindings. Every call returns
// promptly: VM creation and Java operations run on threads owned by this
// dispatcher and report completion through the event callback, which Dart
// registers as a NativeCallable.listener. No platform channel is involved.

#ifndef SOURCE_RUNTIME_IOS_H
#define SOURCE_RUNTIME_IOS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SRT_EXPORT __attribute__((visibility("default"))) __attribute__((used))

// Event status codes.
#define SRT_STATUS_OK 0              // operation returned normally
#define SRT_STATUS_JAVA_EXCEPTION 1  // operation threw (deadline not involved)
#define SRT_STATUS_DEADLINE 2        // operation was stopped by its deadline
#define SRT_STATUS_RUNTIME_ERROR 3   // VM or dispatcher failure

// Deadline delivery mechanisms (KTD11).
#define SRT_MECHANISM_NONE 0         // only signal native latches (no Java interruption)
#define SRT_MECHANISM_INJECTED 1     // mark the thread expired for rewritten back-edge polls
#define SRT_MECHANISM_STOP_THREAD 2  // JVMTI StopThread, re-issued until the call returns

// Return codes for synchronous calls.
#define SRT_OK 0
#define SRT_ERR_NOT_LINKED -1        // built without the JVM archive
#define SRT_ERR_STATE -2             // wrong runtime state for this call
#define SRT_ERR_THREAD -3            // could not create an owned thread
#define SRT_ERR_ARGUMENT -4

// Event callback. `payload` is a heap-allocated UTF-8 JSON object owned by
// the receiver, who must release it with srt_free. Job id 0 is the runtime
// start event.
typedef void (*srt_event_callback)(int64_t job_id, int32_t status, char *payload);

// 1 when the JVM archive is linked into this library, 0 otherwise.
SRT_EXPORT int32_t srt_runtime_linked(void);

// 0 not started, 1 starting, 2 ready, 3 failed.
SRT_EXPORT int32_t srt_runtime_state(void);

// Creates the single process-lifetime VM on an owned thread. `java_home` is
// the bundled modular runtime image; `options` are JavaVMOption strings.
// Completion is reported as job 0. May be called once per process.
SRT_EXPORT int32_t srt_runtime_start(const char *java_home,
                                     const char *const *options,
                                     int32_t option_count,
                                     srt_event_callback callback);

// Runs `static String method(String)` of `class_name` (binary name with '/'
// separators) on a new owned thread attached to the VM. A positive
// `deadline_ms` arms the watchdog with the given mechanism.
SRT_EXPORT int32_t srt_call(int64_t job_id, const char *class_name,
                            const char *method_name, const char *argument,
                            int64_t deadline_ms, int32_t mechanism);

// Sets the Zero back-edge safepoint poll switch (patch 0004). Returns the
// previous value, or SRT_ERR_NOT_LINKED.
SRT_EXPORT int32_t srt_set_backedge_poll(int32_t enabled);

// Live JNI global references created by the dispatcher.
SRT_EXPORT int64_t srt_global_ref_count(void);

// Owned job threads currently running.
SRT_EXPORT int64_t srt_active_jobs(void);

SRT_EXPORT void srt_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif  // SOURCE_RUNTIME_IOS_H
