// Native dispatcher for the embedded iOS JVM (U16, KTD11/KTD23).
//
// Owns every thread that touches the VM: one runtime thread creates the VM
// and then serves as the deadline watchdog, and each operation runs on its
// own attached thread. Dart never calls JNI on an isolate thread.
//
// Built with SRT_HAS_JVM=0 when the runtime archive has not been built; in
// that case every entry point reports SRT_ERR_NOT_LINKED (there is no
// placeholder success path).

#include "source_runtime_ios.h"

#include <stdlib.h>

#if SRT_HAS_JVM

#include <errno.h>
#include <inttypes.h>
#include <jni.h>
#include <jvmti.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <os/log.h>

// Patch 0004 (Zero back-edge poll switch), defined in libjvm.
extern volatile int source_runner_zero_backedge_poll;

#define RUNTIME_STACK_BYTES (16u * 1024u * 1024u)
#define JOB_STACK_BYTES (8u * 1024u * 1024u)
#define STOP_THREAD_REISSUE_NS (2u * 1000u * 1000u)

typedef struct srt_job {
  int64_t id;
  char *class_name;
  char *method_name;
  char *argument;
  int64_t deadline_ms;
  int32_t mechanism;

  uint64_t start_ns;
  uint64_t deadline_at_ns;
  uint64_t first_fire_ns;
  uint64_t last_fire_ns;
  uint64_t end_ns;
  int32_t deliveries;
  int32_t fire_errors;
  bool fired;
  bool finished;
  bool firing;  // guarded by g_mu; watchdog is using thread_ref
  int refs;  // guarded by g_mu; the job thread holds one

  jobject thread_ref;  // global ref to the job's java.lang.Thread

  // Native latch used by gate.host.HostNatives.await.
  pthread_mutex_t latch_mu;
  pthread_cond_t latch_cv;
  bool cancelled;

  struct srt_job *next;
} srt_job;

static _Atomic int32_t g_state = 0;
static srt_event_callback g_callback = NULL;
static JavaVM *g_vm = NULL;
static jvmtiEnv *g_jvmti = NULL;
static _Atomic int64_t g_global_refs = 0;
static _Atomic int64_t g_active_jobs = 0;

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static srt_job *g_jobs = NULL;  // jobs with a deadline that have not finished

static __thread srt_job *t_job = NULL;

// Cached classes and members (global refs).
static jclass g_deadline_cls;
static jmethodID g_deadline_expire;
static jmethodID g_deadline_clear;
static jclass g_error_cls;
static jmethodID g_error_ctor;
static jclass g_thread_cls;
static jmethodID g_thread_current;
static jmethodID g_thread_interrupt;
static jmethodID g_object_to_string;

typedef struct {
  char *java_home;
  char **options;
  int32_t option_count;
} start_args;

// ---------------------------------------------------------------------------
// Utilities

static uint64_t now_ns(void) {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static char *dup_str(const char *s) {
  if (s == NULL) return NULL;
  size_t n = strlen(s) + 1;
  char *d = malloc(n);
  if (d != NULL) memcpy(d, s, n);
  return d;
}

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} sbuf;

static void sb_append(sbuf *b, const char *s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 256;
    while (b->len + n + 1 > cap) cap *= 2;
    char *d = realloc(b->data, cap);
    if (d == NULL) return;
    b->data = d;
    b->cap = cap;
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = '\0';
}

static void sb_printf(sbuf *b, const char *fmt, ...) {
  char tmp[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);
  if (n > 0) sb_append(b, tmp, (size_t)(n < (int)sizeof tmp ? n : (int)sizeof tmp - 1));
}

static void sb_json_string(sbuf *b, const char *s) {
  sb_append(b, "\"", 1);
  for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
    switch (*p) {
      case '"': sb_append(b, "\\\"", 2); break;
      case '\\': sb_append(b, "\\\\", 2); break;
      case '\n': sb_append(b, "\\n", 2); break;
      case '\r': sb_append(b, "\\r", 2); break;
      case '\t': sb_append(b, "\\t", 2); break;
      default:
        if (*p < 0x20) {
          sb_printf(b, "\\u%04x", *p);
        } else {
          sb_append(b, (const char *)p, 1);
        }
    }
  }
  sb_append(b, "\"", 1);
}

static void emit(int64_t job_id, int32_t status, sbuf *payload) {
  char *data = payload->data ? payload->data : dup_str("{}");
  payload->data = NULL;
  if (g_callback != NULL) {
    g_callback(job_id, status, data);
  } else {
    free(data);
  }
}

static jobject new_global(JNIEnv *env, jobject local) {
  jobject g = (*env)->NewGlobalRef(env, local);
  if (g != NULL) atomic_fetch_add(&g_global_refs, 1);
  return g;
}

static void delete_global(JNIEnv *env, jobject g) {
  if (g == NULL) return;
  (*env)->DeleteGlobalRef(env, g);
  atomic_fetch_sub(&g_global_refs, 1);
}

// Describes and clears the pending exception. Returns a heap string.
static char *take_exception(JNIEnv *env, bool *is_deadline) {
  jthrowable exc = (*env)->ExceptionOccurred(env);
  if (exc == NULL) return NULL;
  (*env)->ExceptionClear(env);
  if (is_deadline != NULL) {
    *is_deadline = (*env)->IsInstanceOf(env, exc, g_error_cls) == JNI_TRUE;
  }
  char *out = NULL;
  jstring s = (jstring)(*env)->CallObjectMethod(env, exc, g_object_to_string);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
  } else if (s != NULL) {
    const char *utf = (*env)->GetStringUTFChars(env, s, NULL);
    out = dup_str(utf);
    (*env)->ReleaseStringUTFChars(env, s, utf);
    (*env)->DeleteLocalRef(env, s);
  }
  (*env)->DeleteLocalRef(env, exc);
  return out ? out : dup_str("<exception>");
}

static jclass find_global_class(JNIEnv *env, const char *name) {
  jclass local = (*env)->FindClass(env, name);
  if (local == NULL) {
    (*env)->ExceptionClear(env);
    return NULL;
  }
  jclass g = (jclass)new_global(env, local);
  (*env)->DeleteLocalRef(env, local);
  return g;
}

// ---------------------------------------------------------------------------
// Host natives (registered on gate.host.HostNatives when present)

static jboolean JNICALL host_await(JNIEnv *env, jclass cls, jlong millis) {
  (void)cls;
  srt_job *job = t_job;
  if (job == NULL) return JNI_FALSE;
  struct timespec until;
  clock_gettime(CLOCK_REALTIME, &until);
  int64_t ns = (int64_t)until.tv_nsec + (int64_t)(millis % 1000) * 1000000;
  until.tv_sec += (time_t)(millis / 1000) + (time_t)(ns / 1000000000);
  until.tv_nsec = (long)(ns % 1000000000);
  bool cancelled;
  pthread_mutex_lock(&job->latch_mu);
  while (!job->cancelled) {
    if (pthread_cond_timedwait(&job->latch_cv, &job->latch_mu, &until) == ETIMEDOUT) break;
  }
  cancelled = job->cancelled;
  pthread_mutex_unlock(&job->latch_mu);
  if (cancelled) {
    jobject err = (*env)->NewObject(env, g_error_cls, g_error_ctor);
    if (err != NULL) (*env)->Throw(env, (jthrowable)err);
    return JNI_TRUE;
  }
  return JNI_FALSE;
}

static void register_host_natives(JNIEnv *env) {
  jclass cls = (*env)->FindClass(env, "gate/host/HostNatives");
  if (cls == NULL) {
    (*env)->ExceptionClear(env);
    return;
  }
  JNINativeMethod methods[] = {
      {"await", "(J)Z", (void *)host_await},
  };
  if ((*env)->RegisterNatives(env, cls, methods, 1) != JNI_OK) {
    (*env)->ExceptionClear(env);
  }
  (*env)->DeleteLocalRef(env, cls);
}

// ---------------------------------------------------------------------------
// Watchdog (runs on the runtime thread after VM creation)

static void job_release_locked(srt_job *job);

static void fire(JNIEnv *env, srt_job *job, uint64_t now) {
  pthread_mutex_lock(&job->latch_mu);
  job->cancelled = true;
  pthread_cond_broadcast(&job->latch_cv);
  pthread_mutex_unlock(&job->latch_mu);

  bool first = !job->fired;
  switch (job->mechanism) {
    case SRT_MECHANISM_INJECTED:
      if (first) {
        (*env)->CallStaticBooleanMethod(env, g_deadline_cls, g_deadline_expire, job->thread_ref);
        if ((*env)->ExceptionCheck(env)) {
          (*env)->ExceptionClear(env);
          job->fire_errors++;
        }
        (*env)->CallVoidMethod(env, job->thread_ref, g_thread_interrupt);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        job->deliveries++;
      }
      break;
    case SRT_MECHANISM_STOP_THREAD: {
      jobject err = (*env)->NewObject(env, g_error_cls, g_error_ctor);
      if (err != NULL && g_jvmti != NULL) {
        jvmtiError e = (*g_jvmti)->StopThread(g_jvmti, job->thread_ref, err);
        if (e == JVMTI_ERROR_NONE) {
          job->deliveries++;
        } else {
          job->fire_errors++;
        }
      } else {
        (*env)->ExceptionClear(env);
        job->fire_errors++;
      }
      if (err != NULL) (*env)->DeleteLocalRef(env, err);
      if (first) {
        (*env)->CallVoidMethod(env, job->thread_ref, g_thread_interrupt);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
      }
      break;
    }
    default:
      break;
  }
  if (first) job->first_fire_ns = now;
  job->last_fire_ns = now;
  job->fired = true;
}

static void watchdog_loop(JNIEnv *env) {
  pthread_mutex_lock(&g_mu);
  for (;;) {
    uint64_t now = now_ns();
    uint64_t next = UINT64_MAX;
    srt_job *due = NULL;
    for (srt_job *j = g_jobs; j != NULL; j = j->next) {
      if (j->finished) continue;
      bool should_fire = false;
      if (now >= j->deadline_at_ns) {
        if (!j->fired) {
          should_fire = true;
        } else if (j->mechanism == SRT_MECHANISM_STOP_THREAD &&
                   now - j->last_fire_ns >= STOP_THREAD_REISSUE_NS) {
          should_fire = true;
        }
        if (j->mechanism == SRT_MECHANISM_STOP_THREAD) {
          uint64_t t = (should_fire ? now : j->last_fire_ns) + STOP_THREAD_REISSUE_NS;
          if (t < next) next = t;
        }
      } else if (j->deadline_at_ns < next) {
        next = j->deadline_at_ns;
      }
      if (should_fire && due == NULL) {
        due = j;
      }
    }
    if (due != NULL) {
      due->refs++;
      due->firing = true;
      pthread_mutex_unlock(&g_mu);
      fire(env, due, now);
      pthread_mutex_lock(&g_mu);
      due->firing = false;
      pthread_cond_broadcast(&g_cv);  // a finishing job may wait for this
      job_release_locked(due);
      continue;  // rescan: other jobs may be due as well
    }
    if (next == UINT64_MAX) {
      pthread_cond_wait(&g_cv, &g_mu);
    } else {
      uint64_t wait_ns = next > now ? next - now : 0;
      struct timespec rel = {(time_t)(wait_ns / 1000000000u), (long)(wait_ns % 1000000000u)};
      pthread_cond_timedwait_relative_np(&g_cv, &g_mu, &rel);
    }
  }
}

// ---------------------------------------------------------------------------
// VM output hooks: HotSpot's console output goes to os_log (subsystem
// dev.mangabackup.sourceruntime) so start-up failures are diagnosable on a
// device, where stdout/stderr are not collected.

static os_log_t vm_log(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ log = os_log_create("dev.mangabackup.sourceruntime", "vm"); });
  return log;
}

static jint JNICALL vm_vfprintf(FILE *stream, const char *format, va_list args) {
  (void)stream;
  char line[1024];
  int n = vsnprintf(line, sizeof line, format, args);
  os_log(vm_log(), "%{public}s", line);
  return n;
}

static void JNICALL vm_exit(jint code) {
  os_log_error(vm_log(), "VM requested process exit with code %d", (int)code);
}

static void JNICALL vm_abort(void) {
  os_log_fault(vm_log(), "VM aborted");
}

// ---------------------------------------------------------------------------
// Runtime start

static void *runtime_main(void *arg) {
  start_args *sa = arg;
  sbuf payload = {0};
  uint64_t t0 = now_ns();
  setenv("JAVA_HOME", sa->java_home, 1);

  JavaVMOption *opts = calloc((size_t)sa->option_count + 3, sizeof(JavaVMOption));
  for (int32_t i = 0; i < sa->option_count; i++) {
    opts[i].optionString = sa->options[i];
  }
  opts[sa->option_count + 0] = (JavaVMOption){"vfprintf", (void *)vm_vfprintf};
  opts[sa->option_count + 1] = (JavaVMOption){"exit", (void *)vm_exit};
  opts[sa->option_count + 2] = (JavaVMOption){"abort", (void *)vm_abort};
  os_log(vm_log(), "creating VM, JAVA_HOME=%{public}s", sa->java_home);
  JavaVMInitArgs vm_args = {
      .version = JNI_VERSION_21,
      .nOptions = sa->option_count + 3,
      .options = opts,
      .ignoreUnrecognized = JNI_FALSE,
  };
  JNIEnv *env = NULL;
  jint rc = JNI_CreateJavaVM(&g_vm, (void **)&env, &vm_args);
  uint64_t created_ns = now_ns();
  free(opts);
  for (int32_t i = 0; i < sa->option_count; i++) free(sa->options[i]);
  free(sa->options);
  free(sa->java_home);
  free(sa);

  if (rc != JNI_OK) {
    atomic_store(&g_state, 3);
    sb_printf(&payload, "{\"error\":\"JNI_CreateJavaVM failed\",\"code\":%d}", (int)rc);
    emit(0, SRT_STATUS_RUNTIME_ERROR, &payload);
    return NULL;
  }

  jclass object_cls = (*env)->FindClass(env, "java/lang/Object");
  g_object_to_string = (*env)->GetMethodID(env, object_cls, "toString", "()Ljava/lang/String;");
  (*env)->DeleteLocalRef(env, object_cls);
  g_thread_cls = find_global_class(env, "java/lang/Thread");
  g_thread_current = (*env)->GetStaticMethodID(env, g_thread_cls, "currentThread", "()Ljava/lang/Thread;");
  g_thread_interrupt = (*env)->GetMethodID(env, g_thread_cls, "interrupt", "()V");
  g_deadline_cls = find_global_class(env, "jdk/internal/misc/SourceRunnerDeadline");
  g_error_cls = find_global_class(env, "jdk/internal/misc/SourceRunnerDeadlineError");
  if (g_deadline_cls == NULL || g_error_cls == NULL) {
    atomic_store(&g_state, 3);
    sb_printf(&payload, "{\"error\":\"runtime image lacks jdk.internal.misc.SourceRunnerDeadline (patch 0005)\"}");
    emit(0, SRT_STATUS_RUNTIME_ERROR, &payload);
    return NULL;
  }
  g_deadline_expire = (*env)->GetStaticMethodID(env, g_deadline_cls, "expire", "(Ljava/lang/Thread;)Z");
  g_deadline_clear = (*env)->GetStaticMethodID(env, g_deadline_cls, "clear", "(Ljava/lang/Thread;)V");
  g_error_ctor = (*env)->GetMethodID(env, g_error_cls, "<init>", "()V");

  // JVMTI for StopThread (mechanism B). can_signal_thread is an always-
  // available capability, so it can be added in the live phase.
  bool jvmti_ok = false;
  if ((*g_vm)->GetEnv(g_vm, (void **)&g_jvmti, JVMTI_VERSION) == JNI_OK && g_jvmti != NULL) {
    jvmtiCapabilities caps;
    memset(&caps, 0, sizeof caps);
    caps.can_signal_thread = 1;
    jvmti_ok = (*g_jvmti)->AddCapabilities(g_jvmti, &caps) == JVMTI_ERROR_NONE;
  }
  register_host_natives(env);

  atomic_store(&g_state, 2);
  sb_printf(&payload,
            "{\"createVmMs\":%.3f,\"jvmtiSignalThread\":%s,\"backedgePoll\":%d}",
            (double)(created_ns - t0) / 1e6, jvmti_ok ? "true" : "false",
            (int)source_runner_zero_backedge_poll);
  emit(0, SRT_STATUS_OK, &payload);

  watchdog_loop(env);  // never returns
  return NULL;
}

static int spawn(void *(*fn)(void *), void *arg, size_t stack) {
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, stack);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_t t;
  int rc = pthread_create(&t, &attr, fn, arg);
  pthread_attr_destroy(&attr);
  return rc;
}

// ---------------------------------------------------------------------------
// Jobs

static void job_free(srt_job *job) {
  pthread_mutex_destroy(&job->latch_mu);
  pthread_cond_destroy(&job->latch_cv);
  free(job->class_name);
  free(job->method_name);
  free(job->argument);
  free(job);
}

static void job_release_locked(srt_job *job) {
  if (--job->refs == 0) job_free(job);
}

static void job_unlink_locked(srt_job *job) {
  for (srt_job **p = &g_jobs; *p != NULL; p = &(*p)->next) {
    if (*p == job) {
      *p = job->next;
      break;
    }
  }
}

static void *job_main(void *arg) {
  srt_job *job = arg;
  t_job = job;
  sbuf payload = {0};
  JNIEnv *env = NULL;
  char thread_name[48];
  snprintf(thread_name, sizeof thread_name, "srt-job-%" PRId64, job->id);
  JavaVMAttachArgs attach = {JNI_VERSION_21, thread_name, NULL};
  if ((*g_vm)->AttachCurrentThreadAsDaemon(g_vm, (void **)&env, &attach) != JNI_OK) {
    sb_printf(&payload, "{\"error\":\"AttachCurrentThread failed\"}");
    emit(job->id, SRT_STATUS_RUNTIME_ERROR, &payload);
    pthread_mutex_lock(&g_mu);
    job_release_locked(job);
    pthread_mutex_unlock(&g_mu);
    atomic_fetch_sub(&g_active_jobs, 1);
    return NULL;
  }

  jobject thread = (*env)->CallStaticObjectMethod(env, g_thread_cls, g_thread_current);
  job->thread_ref = new_global(env, thread);
  (*env)->DeleteLocalRef(env, thread);

  jclass cls = (*env)->FindClass(env, job->class_name);
  jmethodID mid = NULL;
  char *error = NULL;
  if (cls == NULL) {
    error = take_exception(env, NULL);
  } else {
    mid = (*env)->GetStaticMethodID(env, cls, job->method_name, "(Ljava/lang/String;)Ljava/lang/String;");
    if (mid == NULL) error = take_exception(env, NULL);
  }

  char *result = NULL;
  char *exception = NULL;
  bool exception_is_deadline = false;
  if (error == NULL) {
    jstring jarg = (*env)->NewStringUTF(env, job->argument ? job->argument : "");
    // Arm the deadline immediately before entering Java.
    pthread_mutex_lock(&g_mu);
    job->start_ns = now_ns();
    if (job->deadline_ms > 0) {
      job->deadline_at_ns = job->start_ns + (uint64_t)job->deadline_ms * 1000000u;
      job->refs++;
      job->next = g_jobs;
      g_jobs = job;
      pthread_cond_signal(&g_cv);
    }
    pthread_mutex_unlock(&g_mu);

    jstring jres = (jstring)(*env)->CallStaticObjectMethod(env, cls, mid, jarg);
    job->end_ns = now_ns();

    pthread_mutex_lock(&g_mu);
    job->finished = true;
    if (job->deadline_ms > 0) {
      job_unlink_locked(job);
      job_release_locked(job);  // the list's reference
    }
    // The watchdog may be delivering right now; wait so thread_ref stays
    // valid and `fired` is final before the expired mark is cleared.
    while (job->firing) pthread_cond_wait(&g_cv, &g_mu);
    pthread_mutex_unlock(&g_mu);

    exception = take_exception(env, &exception_is_deadline);
    if (jres != NULL) {
      const char *utf = (*env)->GetStringUTFChars(env, jres, NULL);
      result = dup_str(utf);
      (*env)->ReleaseStringUTFChars(env, jres, utf);
      (*env)->DeleteLocalRef(env, jres);
    }
    if (jarg != NULL) (*env)->DeleteLocalRef(env, jarg);
  }
  if (cls != NULL) (*env)->DeleteLocalRef(env, cls);

  // Clear the expired mark and any late-delivered async exception.
  if (job->mechanism == SRT_MECHANISM_INJECTED && job->fired) {
    (*env)->CallStaticVoidMethod(env, g_deadline_cls, g_deadline_clear, job->thread_ref);
  }
  if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
  delete_global(env, job->thread_ref);
  job->thread_ref = NULL;

  int32_t status;
  if (error != NULL) {
    status = SRT_STATUS_RUNTIME_ERROR;
  } else if (exception != NULL) {
    status = (job->fired && exception_is_deadline) ? SRT_STATUS_DEADLINE : SRT_STATUS_JAVA_EXCEPTION;
  } else {
    status = SRT_STATUS_OK;
  }

  sb_append(&payload, "{", 1);
  sb_printf(&payload, "\"mechanism\":%d,\"deadlineMs\":%" PRId64 ",", job->mechanism, job->deadline_ms);
  sb_printf(&payload, "\"elapsedUs\":%.1f,", (double)(job->end_ns - job->start_ns) / 1e3);
  sb_printf(&payload, "\"fired\":%s,\"deliveries\":%d,\"fireErrors\":%d,", job->fired ? "true" : "false",
            job->deliveries, job->fire_errors);
  if (job->fired) {
    sb_printf(&payload, "\"firedAfterUs\":%.1f,", (double)(job->first_fire_ns - job->start_ns) / 1e3);
    sb_printf(&payload, "\"stopLatencyUs\":%.1f,", (double)(job->end_ns - job->first_fire_ns) / 1e3);
  }
  sb_append(&payload, "\"result\":", 9);
  if (result != NULL) sb_json_string(&payload, result); else sb_append(&payload, "null", 4);
  sb_append(&payload, ",\"exception\":", 13);
  if (exception != NULL) sb_json_string(&payload, exception); else sb_append(&payload, "null", 4);
  sb_append(&payload, ",\"error\":", 9);
  if (error != NULL) sb_json_string(&payload, error); else sb_append(&payload, "null", 4);
  sb_append(&payload, "}", 1);
  free(result);
  free(exception);
  free(error);

  int64_t id = job->id;
  t_job = NULL;
  (*g_vm)->DetachCurrentThread(g_vm);
  pthread_mutex_lock(&g_mu);
  job_release_locked(job);
  pthread_mutex_unlock(&g_mu);
  atomic_fetch_sub(&g_active_jobs, 1);
  emit(id, status, &payload);
  return NULL;
}

// ---------------------------------------------------------------------------
// Public API

int32_t srt_runtime_linked(void) { return 1; }

int32_t srt_runtime_state(void) { return atomic_load(&g_state); }

int32_t srt_runtime_start(const char *java_home, const char *const *options, int32_t option_count,
                          srt_event_callback callback) {
  if (java_home == NULL || option_count < 0 || (option_count > 0 && options == NULL)) return SRT_ERR_ARGUMENT;
  int32_t expected = 0;
  if (!atomic_compare_exchange_strong(&g_state, &expected, 1)) return SRT_ERR_STATE;
  g_callback = callback;
  start_args *sa = calloc(1, sizeof *sa);
  sa->java_home = dup_str(java_home);
  sa->option_count = option_count;
  sa->options = calloc((size_t)(option_count > 0 ? option_count : 1), sizeof(char *));
  for (int32_t i = 0; i < option_count; i++) sa->options[i] = dup_str(options[i]);
  if (spawn(runtime_main, sa, RUNTIME_STACK_BYTES) != 0) {
    atomic_store(&g_state, 3);
    return SRT_ERR_THREAD;
  }
  return SRT_OK;
}

int32_t srt_call(int64_t job_id, const char *class_name, const char *method_name, const char *argument,
                 int64_t deadline_ms, int32_t mechanism) {
  if (atomic_load(&g_state) != 2) return SRT_ERR_STATE;
  if (class_name == NULL || method_name == NULL || job_id <= 0) return SRT_ERR_ARGUMENT;
  if (mechanism < SRT_MECHANISM_NONE || mechanism > SRT_MECHANISM_STOP_THREAD) return SRT_ERR_ARGUMENT;
  srt_job *job = calloc(1, sizeof *job);
  job->id = job_id;
  job->class_name = dup_str(class_name);
  job->method_name = dup_str(method_name);
  job->argument = dup_str(argument);
  job->deadline_ms = deadline_ms;
  job->mechanism = mechanism;
  job->refs = 1;
  pthread_mutex_init(&job->latch_mu, NULL);
  pthread_cond_init(&job->latch_cv, NULL);
  atomic_fetch_add(&g_active_jobs, 1);
  if (spawn(job_main, job, JOB_STACK_BYTES) != 0) {
    atomic_fetch_sub(&g_active_jobs, 1);
    job_free(job);
    return SRT_ERR_THREAD;
  }
  return SRT_OK;
}

int32_t srt_set_backedge_poll(int32_t enabled) {
  int32_t previous = source_runner_zero_backedge_poll;
  source_runner_zero_backedge_poll = enabled ? 1 : 0;
  return previous;
}

int64_t srt_global_ref_count(void) { return atomic_load(&g_global_refs); }

int64_t srt_active_jobs(void) { return atomic_load(&g_active_jobs); }

#else  // !SRT_HAS_JVM

int32_t srt_runtime_linked(void) { return 0; }
int32_t srt_runtime_state(void) { return 0; }
int32_t srt_runtime_start(const char *java_home, const char *const *options, int32_t option_count,
                          srt_event_callback callback) {
  (void)java_home; (void)options; (void)option_count; (void)callback;
  return SRT_ERR_NOT_LINKED;
}
int32_t srt_call(int64_t job_id, const char *class_name, const char *method_name, const char *argument,
                 int64_t deadline_ms, int32_t mechanism) {
  (void)job_id; (void)class_name; (void)method_name; (void)argument; (void)deadline_ms; (void)mechanism;
  return SRT_ERR_NOT_LINKED;
}
int32_t srt_set_backedge_poll(int32_t enabled) { (void)enabled; return SRT_ERR_NOT_LINKED; }
int64_t srt_global_ref_count(void) { return 0; }
int64_t srt_active_jobs(void) { return 0; }

#endif  // SRT_HAS_JVM

void srt_free(void *pointer) { free(pointer); }
