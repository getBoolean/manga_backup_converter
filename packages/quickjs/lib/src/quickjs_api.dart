import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:quickjs/src/quickjs_bindings_generated.dart' as b;

/// Engine and device information from the vendored build.
abstract final class QuickJs {
  /// The QuickJS-ng version compiled from the pinned submodule.
  static String get engineVersion => b.qjsd_version().cast<Utf8>().toDartString();

  /// `sizeof(JSValue)` in this build: 16 on 64-bit targets, 8 with NaN boxing.
  static int get valueSize => b.qjsd_value_size();

  /// The monotonic clock the interrupt handler reads, in nanoseconds.
  static int nowNanoseconds() => b.qjsd_now_ns();

  /// Native stack left on the calling thread, or `null` if unknown.
  ///
  /// A JS stack limit at or above this value turns deep recursion into a
  /// process crash instead of a `RangeError`.
  static int? threadStackAvailable() {
    final int value = b.qjsd_thread_stack_available();
    return value < 0 ? null : value;
  }

  /// Physical memory of the device in bytes, or `null` if unknown.
  static int? physicalMemory() {
    final int value = b.qjsd_physical_memory();
    return value < 0 ? null : value;
  }
}

/// Why the engine interrupted running code.
enum JsInterruptReason {
  none,

  /// The runtime's deadline passed.
  deadline,

  /// A [JsInterruptToken] was requested.
  requested,
}

/// A cancellation flag that native code checks while JS runs.
///
/// The token is reference counted in native memory, so it outlives the
/// runtime and can be shared with another isolate through [address] and
/// [JsInterruptToken.fromAddress]. Each Dart instance holds one reference;
/// call [release] when done with it.
final class JsInterruptToken {
  JsInterruptToken() : _ptr = b.qjsd_token_new() {
    if (_ptr == nullptr) throw const JsAllocationError('interrupt token');
  }

  /// Adopts a token created elsewhere (for example in another isolate),
  /// taking a new reference.
  JsInterruptToken.fromAddress(int address) : _ptr = Pointer<b.QjsdToken>.fromAddress(address) {
    if (address == 0) throw ArgumentError.value(address, 'address');
    b.qjsd_token_retain(_ptr);
  }

  Pointer<b.QjsdToken> _ptr;

  /// Native address, valid while any reference is held.
  int get address => _ptr.address;

  /// Asks every runtime observing this token to stop at its next check.
  /// Safe to call from any isolate.
  void request() => b.qjsd_token_request(_checked);

  void reset() => b.qjsd_token_reset(_checked);

  bool get isRequested => b.qjsd_token_is_requested(_checked) != 0;

  bool get isReleased => _ptr == nullptr;

  /// Drops this instance's reference.
  void release() {
    if (_ptr == nullptr) return;
    b.qjsd_token_release(_ptr);
    _ptr = nullptr;
  }

  Pointer<b.QjsdToken> get _checked {
    if (_ptr == nullptr) throw StateError('JsInterruptToken has been released');
    return _ptr;
  }
}

/// Engine memory accounting (`JS_ComputeMemoryUsage`).
final class JsMemoryUsage {
  const JsMemoryUsage({
    required this.mallocSize,
    required this.mallocLimit,
    required this.memoryUsedSize,
    required this.mallocCount,
  });

  /// Bytes currently allocated by the engine allocator.
  final int mallocSize;

  /// The configured limit (0 = none).
  final int mallocLimit;
  final int memoryUsedSize;
  final int mallocCount;

  @override
  String toString() => 'JsMemoryUsage(malloc=$mallocSize, limit=$mallocLimit, used=$memoryUsedSize)';
}

/// The result of draining pending jobs.
final class JsJobDrain {
  const JsJobDrain({required this.executed, required this.morePending, this.error});

  /// Jobs run in this call.
  final int executed;

  /// Whether jobs remain queued.
  final bool morePending;

  /// The exception a job threw, which stopped the drain.
  final JsException? error;
}

/// A host function callable from JS.
///
/// [args] and [thisValue] are borrowed and valid only during the call. Return
/// an owned value (ownership moves to the engine) or `null` for `undefined`.
/// A thrown Dart exception becomes a JS `Error` with its message.
typedef JsHostFunction = JsValue? Function(JsContext context, JsValue thisValue, List<JsValue> args);

/// One QuickJS runtime: a heap, a job queue, limits and an interrupt handler.
///
/// Every method must be called on the isolate that created the runtime. Not
/// thread-safe; only [JsInterruptToken.request] may come from elsewhere.
final class JsRuntime {
  /// Creates a runtime with the engine's defaults. Set limits explicitly:
  /// QuickJS's default 1 MiB stack limit can exceed the thread's real stack.
  JsRuntime({JsInterruptToken? interruptToken}) {
    _callable = NativeCallable<b.qjsd_host_dispatchFunction>.isolateLocal(_dispatch);
    _ptr = b.qjsd_runtime_new(interruptToken?._checked ?? nullptr, _callable.nativeFunction);
    if (_ptr == nullptr) {
      _callable.close();
      throw const JsAllocationError('runtime');
    }
  }

  late Pointer<b.QjsdRuntime> _ptr;
  late final NativeCallable<b.qjsd_host_dispatchFunction> _callable;
  final Map<int, JsContext> _contexts = <int, JsContext>{};
  int? _memoryLimit;
  // QuickJS-ng's built-in default (JS_DEFAULT_STACK_SIZE).
  int _maxStackSize = 1024 * 1024;
  int _deadline = 0;

  bool get isDisposed => _ptr == nullptr;

  /// Limit on [allocatedBytes], or `null` for none. Allocations past it fail
  /// with an out-of-memory error and set [memoryLimitHit].
  int? get memoryLimit => _memoryLimit;
  set memoryLimit(int? bytes) {
    if (bytes != null && bytes <= 0) throw ArgumentError.value(bytes, 'bytes', 'must be positive');
    _memoryLimit = bytes;
    b.qjsd_runtime_set_memory_limit(_checked, bytes ?? -1);
  }

  /// JS stack limit in bytes, measured from the outermost engine entry; 0
  /// disables the check. Must stay below [QuickJs.threadStackAvailable].
  int get maxStackSize => _maxStackSize;
  set maxStackSize(int bytes) {
    if (bytes < 0) throw ArgumentError.value(bytes, 'bytes', 'must not be negative');
    _maxStackSize = bytes;
    b.qjsd_runtime_set_max_stack_size(_checked, bytes);
  }

  /// Absolute [QuickJs.nowNanoseconds] deadline for running JS, or `null`.
  int? get deadlineNanoseconds => _deadline == 0 ? null : _deadline;
  set deadlineNanoseconds(int? value) {
    _deadline = value ?? 0;
    b.qjsd_runtime_set_deadline(_checked, _deadline);
  }

  /// Why the last interrupt fired; sticky until [clearInterrupt].
  JsInterruptReason get interruptReason => JsInterruptReason.values[b.qjsd_runtime_interrupt_reason(_checked)];

  /// Whether an allocation was refused by [memoryLimit] since the last
  /// [clearInterrupt]. Authoritative even when the engine could not allocate
  /// an error and threw `null` instead.
  bool get memoryLimitHit => b.qjsd_runtime_memory_limit_hit(_checked) != 0;

  /// Clears [interruptReason] and [memoryLimitHit].
  void clearInterrupt() => b.qjsd_runtime_clear_interrupt(_checked);

  /// Bytes the engine currently holds from the system allocator (O(1)). This
  /// is what [memoryLimit] bounds.
  int get allocatedBytes => b.qjsd_runtime_allocated(_checked);

  /// Highest [allocatedBytes] since creation or [resetPeakAllocated].
  int get peakAllocatedBytes => b.qjsd_runtime_peak_allocated(_checked);

  void resetPeakAllocated() => b.qjsd_runtime_reset_peak(_checked);

  bool get isJobPending => b.qjsd_runtime_is_job_pending(_checked) != 0;

  /// Runs pending jobs (promise reactions) until the queue is empty, [maxJobs]
  /// have run, or the clock passes [untilNanoseconds]. Stops at the first
  /// job that throws and returns its exception.
  JsJobDrain executePendingJobs({int? maxJobs, int? untilNanoseconds}) {
    final Pointer<b.QjsdRuntime> rt = _checked;
    var executed = 0;
    final Pointer<Pointer<b.JSContext>> out = calloc<Pointer<b.JSContext>>();
    try {
      while (true) {
        if (maxJobs != null && executed >= maxJobs) break;
        if (untilNanoseconds != null && executed > 0 && b.qjsd_now_ns() >= untilNanoseconds) break;
        final int rc = b.qjsd_runtime_execute_pending_job(rt, out);
        if (rc == 0) break;
        executed++;
        if (rc < 0) {
          final JsContext? ctx = _contexts[out.value.address];
          final JsException error = ctx != null
              ? ctx.takeException()
              : JsException(name: 'InternalError', message: 'job failed in an unknown context');
          return JsJobDrain(executed: executed, morePending: isJobPending, error: error);
        }
      }
    } finally {
      calloc.free(out);
    }
    return JsJobDrain(executed: executed, morePending: isJobPending);
  }

  JsMemoryUsage memoryUsage() {
    final Pointer<Int64> out = calloc<Int64>(4);
    try {
      b.qjsd_runtime_memory_usage(_checked, out);
      return JsMemoryUsage(mallocSize: out[0], mallocLimit: out[1], memoryUsedSize: out[2], mallocCount: out[3]);
    } finally {
      calloc.free(out);
    }
  }

  void runGc() => b.qjsd_runtime_run_gc(_checked);

  /// A context with the standard intrinsics only: no `std`/`os` modules, no
  /// file, process or network access.
  JsContext newContext() {
    final Pointer<b.JSContext> ctx = b.qjsd_context_new(_checked);
    if (ctx == nullptr) throw const JsAllocationError('context');
    final context = JsContext._(this, ctx);
    _contexts[ctx.address] = context;
    return context;
  }

  /// Frees every context and value, then the runtime. Idempotent.
  void dispose() {
    if (_ptr == nullptr) return;
    for (final JsContext context in _contexts.values.toList()) {
      context.dispose();
    }
    b.qjsd_runtime_free(_ptr);
    _ptr = nullptr;
    _callable.close();
  }

  Pointer<b.QjsdRuntime> get _checked {
    if (_ptr == nullptr) throw StateError('JsRuntime has been disposed');
    return _ptr;
  }

  Pointer<b.QjsdValue> _dispatch(
    Pointer<b.JSContext> ctxPtr,
    int fnId,
    Pointer<b.QjsdValue> thisPtr,
    int argc,
    Pointer<b.QjsdValue> argv,
  ) {
    final JsContext? context = _contexts[ctxPtr.address];
    if (context == null) return nullptr;
    final JsHostFunction? fn = context._hostFunctions[fnId];
    if (fn == null) return _throwError(ctxPtr, 'host function $fnId is not registered');
    final thisValue = JsValue._borrowed(context, thisPtr);
    final args = <JsValue>[for (var i = 0; i < argc; i++) JsValue._borrowed(context, b.qjsd_argv_at(argv, i))];
    try {
      final JsValue? result = fn(context, thisValue, args);
      if (result == null) return b.qjsd_new_undefined(ctxPtr);
      return result._detach();
    } on JsException catch (e) {
      if (e.isUncatchable) {
        // Re-raise an interrupt or out-of-memory condition as such.
        return _throwError(ctxPtr, e.message);
      }
      return _throwError(ctxPtr, e.toString());
    } on Object catch (e) {
      return _throwError(ctxPtr, e.toString());
    } finally {
      thisValue._invalidate();
      for (final a in args) {
        a._invalidate();
      }
    }
  }
}

/// Throws a JS `Error` with [message] in [ctx]; QuickJS copies the text.
Pointer<b.QjsdValue> _throwError(Pointer<b.JSContext> ctx, String message) {
  final Pointer<Utf8> text = message.toNativeUtf8();
  try {
    return b.qjsd_throw_error(ctx, text.cast());
  } finally {
    malloc.free(text);
  }
}

/// Promise states.
enum JsPromiseState { notAPromise, pending, fulfilled, rejected }

/// A promise and its resolving functions.
final class JsPromiseCapability {
  const JsPromiseCapability(this.promise, this.resolve, this.reject);

  final JsValue promise;
  final JsValue resolve;
  final JsValue reject;

  void dispose() {
    promise.dispose();
    resolve.dispose();
    reject.dispose();
  }
}

/// A JS realm (global object) inside a [JsRuntime].
final class JsContext {
  JsContext._(this.runtime, this._ptr);

  final JsRuntime runtime;
  Pointer<b.JSContext> _ptr;
  final Set<JsValue> _owned = <JsValue>{};
  final Map<int, JsHostFunction> _hostFunctions = <int, JsHostFunction>{};
  int _nextHostId = 1;

  bool get isDisposed => _ptr == nullptr;

  /// Number of live owned values, for leak checks in tests.
  @visibleForTesting
  int get liveValueCount => _owned.length;

  /// Evaluates global script code. Throws [JsException] if it throws.
  JsValue eval(String code, {String filename = '<eval>', bool strict = false}) {
    return using((Arena arena) {
      final Pointer<Utf8> src = code.toNativeUtf8(allocator: arena);
      final int len = src.length;
      final Pointer<Utf8> name = filename.toNativeUtf8(allocator: arena);
      // JS_EVAL_TYPE_GLOBAL = 0, JS_EVAL_FLAG_STRICT = 1 << 3.
      return _wrap(b.qjsd_eval(_checked, src.cast(), len, name.cast(), strict ? 8 : 0));
    });
  }

  /// A new reference to the global object.
  JsValue get global => _wrap(b.qjsd_get_global(_checked));

  JsValue undefined() => _wrap(b.qjsd_new_undefined(_checked));
  JsValue nullValue() => _wrap(b.qjsd_new_null(_checked));
  JsValue boolean(bool value) => _wrap(b.qjsd_new_bool(_checked, value ? 1 : 0));
  JsValue number(num value) =>
      value is int ? _wrap(b.qjsd_new_int64(_checked, value)) : _wrap(b.qjsd_new_float64(_checked, value.toDouble()));
  JsValue string(String value) => using((Arena arena) {
    final Uint8List bytes = utf8.encode(value);
    final Pointer<Uint8> data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    return _wrap(b.qjsd_new_string(_checked, data.cast(), bytes.length));
  });
  JsValue object() => _wrap(b.qjsd_new_object(_checked));
  JsValue array() => _wrap(b.qjsd_new_array(_checked));

  /// A copy of [bytes] as an `ArrayBuffer`.
  JsValue arrayBuffer(Uint8List bytes) => _bytes(bytes, b.qjsd_new_array_buffer_copy);

  /// A copy of [bytes] as a `Uint8Array`.
  JsValue uint8Array(Uint8List bytes) => _bytes(bytes, b.qjsd_new_uint8_array_copy);

  /// An `Error` object (not thrown).
  JsValue error(String message, {String? name}) => using((Arena arena) {
    final Pointer<Char> n = name == null ? nullptr : name.toNativeUtf8(allocator: arena).cast();
    return _wrap(b.qjsd_new_error(_checked, n, message.toNativeUtf8(allocator: arena).cast()));
  });

  JsValue _bytes(
    Uint8List bytes,
    Pointer<b.QjsdValue> Function(Pointer<b.JSContext>, Pointer<Uint8>, int) create,
  ) => using((Arena arena) {
    final Pointer<Uint8> data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    return _wrap(create(_checked, data, bytes.length));
  });

  /// Converts a JSON-like Dart value: `null`, [bool], [num], [String],
  /// [Uint8List] (as `Uint8Array`), [List], `Map<String, Object?>`, or a
  /// [JsValue] (a new reference).
  JsValue fromDart(Object? value) {
    switch (value) {
      case null:
        return nullValue();
      case final JsValue v:
        return v.dup();
      case final bool v:
        return boolean(v);
      case final num v:
        return number(v);
      case final String v:
        return string(v);
      case final Uint8List v:
        return uint8Array(v);
      case final List<Object?> list:
        final JsValue arr = array();
        try {
          for (var i = 0; i < list.length; i++) {
            arr.setIndex(i, fromDart(list[i]));
          }
        } on Object {
          arr.dispose();
          rethrow;
        }
        return arr;
      case final Map<Object?, Object?> map:
        final JsValue obj = object();
        try {
          for (final MapEntry<Object?, Object?> e in map.entries) {
            obj.setProperty(e.key! as String, fromDart(e.value));
          }
        } on Object {
          obj.dispose();
          rethrow;
        }
        return obj;
      default:
        throw ArgumentError.value(value, 'value', 'cannot be converted to JS');
    }
  }

  /// Converts a JS value to JSON-like Dart data. `undefined` and `null` map
  /// to `null`, `ArrayBuffer` and typed arrays to a [Uint8List] copy, errors
  /// to `{name, message, stack}`. Functions, symbols and promises throw
  /// [JsConversionException], as does nesting deeper than [maxDepth].
  Object? toDart(JsValue value, {int maxDepth = 64}) {
    if (maxDepth < 0) throw const JsConversionException('JS value nests too deeply to convert');
    switch (value.kind) {
      case JsValueKind.undefined || JsValueKind.nullValue:
        return null;
      case JsValueKind.boolean:
        return b.qjsd_to_bool(_checked, value._ptr) == 1;
      case JsValueKind.integer:
        return value.toDouble().toInt();
      case JsValueKind.float:
        return value.toDouble();
      case JsValueKind.string:
      case JsValueKind.bigInt:
        final String s = value.toDartString();
        return value.kind == JsValueKind.bigInt ? BigInt.parse(s) : s;
      case JsValueKind.arrayBuffer || JsValueKind.typedArray:
        return value.bytes();
      case JsValueKind.array:
        final int length = value.length;
        return <Object?>[
          for (var i = 0; i < length; i++)
            _withValue(value.getIndex(i), (JsValue v) => toDart(v, maxDepth: maxDepth - 1)),
        ];
      case JsValueKind.error:
        return <String, Object?>{
          'name': _withValue(value.getProperty('name'), _stringOrNull),
          'message': _withValue(value.getProperty('message'), _stringOrNull),
          'stack': _withValue(value.getProperty('stack'), _stringOrNull),
        };
      case JsValueKind.object:
        final List<String> keys = _withValue(
          _wrap(b.qjsd_object_keys(_checked, value._ptr)),
          (JsValue k) => <String>[for (var i = 0; i < k.length; i++) _withValue(k.getIndex(i), _string)],
        );
        return <String, Object?>{
          for (final String key in keys)
            key: _withValue(value.getProperty(key), (JsValue v) => toDart(v, maxDepth: maxDepth - 1)),
        };
      case JsValueKind.function ||
          JsValueKind.symbol ||
          JsValueKind.promise ||
          JsValueKind.exception ||
          JsValueKind.other:
        throw JsConversionException('A JS ${value.kind.name} cannot be converted to Dart');
    }
  }

  static String _string(JsValue v) => v.toDartString();

  static String? _stringOrNull(JsValue v) =>
      v.kind == JsValueKind.undefined || v.kind == JsValueKind.nullValue ? null : v.toDartString();

  T _withValue<T>(JsValue v, T Function(JsValue) body) {
    try {
      return body(v);
    } finally {
      v.dispose();
    }
  }

  /// Parses JSON text. Throws [JsException] on a syntax error.
  JsValue parseJson(String json) => using((Arena arena) {
    final Pointer<Utf8> src = json.toNativeUtf8(allocator: arena);
    return _wrap(b.qjsd_json_parse(_checked, src.cast(), src.length));
  });

  /// `JSON.stringify`; `null` when the value serializes to `undefined`.
  String? stringifyJson(JsValue value) => _withValue(_wrap(b.qjsd_json_stringify(_checked, value._ptr)), _stringOrNull);

  /// Calls [function] with [args] (borrowed; not consumed).
  JsValue call(JsValue function, {JsValue? thisValue, List<JsValue> args = const <JsValue>[]}) {
    return using((Arena arena) {
      final Pointer<Pointer<b.QjsdValue>> argv = arena<Pointer<b.QjsdValue>>(args.isEmpty ? 1 : args.length);
      for (var i = 0; i < args.length; i++) {
        argv[i] = args[i]._live;
      }
      return _wrap(b.qjsd_call(_checked, function._live, thisValue?._live ?? nullptr, args.length, argv));
    });
  }

  /// A JS function that calls [function] on this isolate.
  JsValue newHostFunction(String name, JsHostFunction function, {int length = 0}) {
    final int id = _nextHostId++;
    _hostFunctions[id] = function;
    return using((Arena arena) {
      try {
        return _wrap(b.qjsd_new_host_function(_checked, name.toNativeUtf8(allocator: arena).cast(), length, id));
      } on Object {
        _hostFunctions.remove(id);
        rethrow;
      }
    });
  }

  /// A new pending promise with its resolving functions.
  JsPromiseCapability newPromise() {
    return using((Arena arena) {
      final Pointer<Pointer<b.QjsdValue>> resolve = arena<Pointer<b.QjsdValue>>();
      final Pointer<Pointer<b.QjsdValue>> reject = arena<Pointer<b.QjsdValue>>();
      final JsValue promise = _wrap(b.qjsd_new_promise(_checked, resolve, reject));
      return JsPromiseCapability(promise, JsValue._owned(this, resolve.value), JsValue._owned(this, reject.value));
    });
  }

  JsPromiseState promiseState(JsValue value) => JsPromiseState.values[b.qjsd_promise_state(_checked, value._live) + 1];

  /// The settled value or rejection reason of a promise.
  JsValue promiseResult(JsValue value) => _wrap(b.qjsd_promise_result(_checked, value._live));

  /// Takes the pending exception as a [JsException].
  JsException takeException() {
    final Pointer<b.JSContext> ctx = _checked;
    final Pointer<b.QjsdValue> raw = b.qjsd_get_exception(ctx);
    if (raw == nullptr) {
      return JsException(name: 'InternalError', message: 'out of memory', kind: JsErrorKind.outOfMemory);
    }
    final JsInterruptReason reason = runtime.interruptReason;
    final bool memoryLimitHit = runtime.memoryLimitHit;
    final uncatchable = b.qjsd_is_uncatchable(raw) != 0;
    // Describing the error allocates and may run getters: lift the memory
    // limit and deadline for the duration, then restore them.
    final int? limit = runtime._memoryLimit;
    final int deadline = runtime._deadline;
    b.qjsd_runtime_set_memory_limit(runtime._ptr, -1);
    b.qjsd_runtime_set_deadline(runtime._ptr, 0);
    final exception = JsValue._owned(this, raw);
    try {
      return JsException.describe(
        this,
        exception,
        interruptReason: reason,
        uncatchable: uncatchable,
        memoryLimitHit: memoryLimitHit,
      );
    } finally {
      exception.dispose();
      b.qjsd_runtime_set_memory_limit(runtime._ptr, limit ?? -1);
      b.qjsd_runtime_set_deadline(runtime._ptr, deadline);
    }
  }

  /// Frees every owned value, then the context. Idempotent.
  void dispose() {
    if (_ptr == nullptr) return;
    for (final JsValue v in _owned.toList()) {
      v.dispose();
    }
    _hostFunctions.clear();
    b.qjsd_context_free(_ptr);
    runtime._contexts.remove(_ptr.address);
    _ptr = nullptr;
  }

  Pointer<b.JSContext> get _checked {
    if (_ptr == nullptr) throw StateError('JsContext has been disposed');
    return _ptr;
  }

  /// Takes ownership of a returned box, throwing for exceptions.
  JsValue _wrap(Pointer<b.QjsdValue> raw) {
    if (raw == nullptr) {
      throw JsException(name: 'InternalError', message: 'out of memory', kind: JsErrorKind.outOfMemory);
    }
    if (b.qjsd_value_kind(_ptr, raw) == b.QJSD_KIND_EXCEPTION) {
      b.qjsd_value_free(_ptr, raw);
      throw takeException();
    }
    return JsValue._owned(this, raw);
  }
}

/// Kinds of JS value.
enum JsValueKind {
  undefined,
  nullValue,
  boolean,
  integer,
  float,
  string,
  symbol,
  bigInt,
  object,
  array,
  function,
  arrayBuffer,
  typedArray,
  promise,
  error,
  exception,
  other,
}

/// A reference to a JS value.
///
/// Owned values must be [dispose]d (or are freed with their context).
/// Borrowed values (host function arguments) are valid only during the call
/// and ignore [dispose].
final class JsValue {
  JsValue._owned(this.context, this._ptr) : _isOwned = true {
    context._owned.add(this);
  }

  JsValue._borrowed(this.context, this._ptr) : _isOwned = false;

  final JsContext context;
  Pointer<b.QjsdValue> _ptr;
  final bool _isOwned;

  bool get isDisposed => _ptr == nullptr;

  JsValueKind get kind => JsValueKind.values[b.qjsd_value_kind(context._checked, _live)];

  /// A new owned reference to the same value.
  JsValue dup() => context._wrap(b.qjsd_value_dup(context._checked, _live));

  /// JS `String(value)`. Throws [JsException] if conversion throws.
  String toDartString() {
    final Pointer<Size> len = calloc<Size>();
    try {
      final Pointer<Char> s = b.qjsd_to_cstring(context._checked, _live, len);
      if (s == nullptr) throw context.takeException();
      try {
        return utf8.decode(s.cast<Uint8>().asTypedList(len.value), allowMalformed: true);
      } finally {
        b.qjsd_free_cstring(context._ptr, s);
      }
    } finally {
      calloc.free(len);
    }
  }

  /// JS `Number(value)`.
  double toDouble() {
    final Pointer<Double> out = calloc<Double>();
    try {
      if (b.qjsd_to_float64(context._checked, _live, out) < 0) throw context.takeException();
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// A copy of an `ArrayBuffer`'s or typed array's bytes, or `null`.
  Uint8List? bytes() {
    final Pointer<Size> len = calloc<Size>();
    try {
      final Pointer<Uint8> data = b.qjsd_get_bytes(context._checked, _live, len);
      if (data == nullptr) {
        return kind == JsValueKind.arrayBuffer || kind == JsValueKind.typedArray ? Uint8List(0) : null;
      }
      return Uint8List.fromList(data.asTypedList(len.value));
    } finally {
      calloc.free(len);
    }
  }

  /// The `length` property.
  int get length {
    final int len = b.qjsd_get_length(context._checked, _live);
    if (len < 0) throw context.takeException();
    return len;
  }

  JsValue getProperty(String name) => using(
    (Arena a) => context._wrap(b.qjsd_get_property(context._checked, _live, name.toNativeUtf8(allocator: a).cast())),
  );

  JsValue getIndex(int index) => context._wrap(b.qjsd_get_index(context._checked, _live, index));

  /// Sets a property, consuming [value].
  void setProperty(String name, JsValue value) {
    final Pointer<b.QjsdValue> v = value._detach();
    final int rc = using(
      (Arena a) => b.qjsd_set_property(context._checked, _live, name.toNativeUtf8(allocator: a).cast(), v),
    );
    if (rc < 0) throw context.takeException();
  }

  /// Sets an element, consuming [value].
  void setIndex(int index, JsValue value) {
    final Pointer<b.QjsdValue> v = value._detach();
    if (b.qjsd_set_index(context._checked, _live, index, v) < 0) throw context.takeException();
  }

  /// Frees an owned value. Idempotent; a no-op for borrowed values.
  void dispose() {
    if (!_isOwned || _ptr == nullptr) return;
    if (!context.isDisposed) b.qjsd_value_free(context._ptr, _ptr);
    context._owned.remove(this);
    _ptr = nullptr;
  }

  Pointer<b.QjsdValue> get _live {
    if (_ptr == nullptr) throw StateError('JsValue has been disposed or is no longer borrowed');
    return _ptr;
  }

  /// Hands this value's box to the engine (borrowed values are duplicated).
  Pointer<b.QjsdValue> _detach() {
    if (!_isOwned) {
      final Pointer<b.QjsdValue> copy = b.qjsd_value_dup(context._checked, _live);
      if (copy == nullptr) {
        throw JsException(name: 'InternalError', message: 'out of memory', kind: JsErrorKind.outOfMemory);
      }
      return copy;
    }
    final Pointer<b.QjsdValue> p = _live;
    context._owned.remove(this);
    _ptr = nullptr;
    return p;
  }

  void _invalidate() => _ptr = nullptr;
}

/// How a JS exception arose.
enum JsErrorKind {
  /// Source code threw.
  thrown,

  /// The runtime's deadline or interrupt token stopped execution.
  interrupted,

  /// The memory limit was reached.
  outOfMemory,

  /// The JS stack limit was reached.
  stackOverflow,
}

/// A JS exception surfaced to Dart.
final class JsException implements Exception {
  JsException({
    required this.name,
    required this.message,
    this.stack,
    this.kind = JsErrorKind.thrown,
    this.interruptReason = JsInterruptReason.none,
    this.isUncatchable = false,
  });

  /// Describes [error] (an exception value) without consuming it.
  factory JsException.describe(
    JsContext context,
    JsValue error, {
    required JsInterruptReason interruptReason,
    required bool uncatchable,
    bool memoryLimitHit = false,
  }) {
    var name = 'Error';
    String message;
    String? stack;
    try {
      if (error.kind == JsValueKind.error || error.kind == JsValueKind.object) {
        final Object? described = context.toDart(error, maxDepth: 1);
        if (described is Map<String, Object?>) {
          name = described['name'] as String? ?? name;
          message = described['message']?.toString() ?? '';
          stack = described['stack'] as String?;
        } else {
          message = error.toDartString();
        }
      } else {
        name = 'Thrown';
        message = error.toDartString();
      }
    } on Object catch (e) {
      message = '<exception could not be described: $e>';
    }
    final JsErrorKind kind = switch ((name, message)) {
      _ when uncatchable && interruptReason != JsInterruptReason.none => JsErrorKind.interrupted,
      _ when memoryLimitHit => JsErrorKind.outOfMemory,
      (_, 'interrupted') when interruptReason != JsInterruptReason.none => JsErrorKind.interrupted,
      (_, 'out of memory') => JsErrorKind.outOfMemory,
      ('RangeError', 'Maximum call stack size exceeded') => JsErrorKind.stackOverflow,
      ('InternalError', final String m) when m.startsWith('stack overflow') => JsErrorKind.stackOverflow,
      _ => JsErrorKind.thrown,
    };
    return JsException(
      name: name,
      message: message,
      stack: stack,
      kind: kind,
      interruptReason: interruptReason,
      isUncatchable: uncatchable,
    );
  }

  final String name;
  final String message;
  final String? stack;
  final JsErrorKind kind;
  final JsInterruptReason interruptReason;
  final bool isUncatchable;

  @override
  String toString() => '$name: $message';
}

/// A native allocation failed outside the JS heap.
final class JsAllocationError implements Exception {
  const JsAllocationError(this.what);

  /// What could not be allocated.
  final String what;

  @override
  String toString() => 'JsAllocationError: could not allocate a QuickJS $what';
}

/// A JS value has no Dart data representation.
final class JsConversionException implements Exception {
  const JsConversionException(this.message);

  final String message;

  @override
  String toString() => 'JsConversionException: $message';
}
