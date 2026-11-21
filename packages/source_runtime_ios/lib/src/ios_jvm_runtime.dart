import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:source_runtime_ios/src/runtime_bindings.g.dart' as native;

typedef _EventFn = Void Function(Int64 jobId, Int32 status, Pointer<Char> payload);

/// How the dispatcher interrupts a Java operation whose deadline passed
/// (KTD11). Native latches are always signalled.
enum DeadlineMechanism {
  /// Only native latches; Java code is not interrupted.
  none(native.SRT_MECHANISM_NONE),

  /// Marks the thread expired; rewritten back-edge polls throw (mechanism A).
  injected(native.SRT_MECHANISM_INJECTED),

  /// JVMTI StopThread, re-issued until the call returns (mechanism B, needs
  /// the Zero back-edge poll patch to reach call-free loops).
  stopThread(native.SRT_MECHANISM_STOP_THREAD);

  const DeadlineMechanism(this.code);
  final int code;
}

enum RuntimeStatus { ok, javaException, deadline, runtimeError }

/// A completed runtime start or Java operation.
final class RuntimeEvent {
  RuntimeEvent(this.jobId, this.status, this.payload);

  final int jobId;
  final RuntimeStatus status;
  final Map<String, Object?> payload;

  String? get result => payload['result'] as String?;
  String? get exception => payload['exception'] as String?;
  bool get fired => payload['fired'] == true;
  double get elapsedMs => ((payload['elapsedUs'] as num?) ?? 0) / 1000;
  double? get stopLatencyMs {
    final us = payload['stopLatencyUs'] as num?;
    return us == null ? null : us / 1000;
  }

  @override
  String toString() => 'RuntimeEvent($jobId, $status, $payload)';
}

/// Thrown for synchronous dispatcher failures (not Java exceptions).
final class IosJvmRuntimeException implements Exception {
  IosJvmRuntimeException(this.message, [this.code]);
  final String message;
  final int? code;
  @override
  String toString() => 'IosJvmRuntimeException($message${code == null ? '' : ', code $code'})';
}

/// The single process-lifetime embedded JVM (KTD11 "VM lifetime").
///
/// All JNI work happens on dispatcher-owned native threads; results arrive
/// through a [NativeCallable.listener], so Dart never blocks on Java and no
/// platform channel is involved.
final class IosJvmRuntime {
  IosJvmRuntime._(this.startEvent, this._callback);

  static IosJvmRuntime? _instance;
  static final Map<int, Completer<RuntimeEvent>> _pending = {};
  static int _nextJobId = 1;

  /// The start event (job 0): VM creation time, JVMTI availability.
  final RuntimeEvent startEvent;
  // Kept open for the process lifetime: the VM outlives any one caller.
  // ignore: unused_field
  final NativeCallable<_EventFn> _callback;

  /// Whether the JVM archive was linked into the native asset.
  static bool get linked => native.srt_runtime_linked() == 1;

  static IosJvmRuntime? get instance => _instance;

  /// Creates the VM once. Later calls return the same runtime.
  static Future<IosJvmRuntime> start({required String javaHome, required List<String> options}) async {
    final IosJvmRuntime? existing = _instance;
    if (existing != null) return existing;
    if (!linked) {
      throw IosJvmRuntimeException('the embedded JVM is not linked into this build', native.SRT_ERR_NOT_LINKED);
    }
    final callback = NativeCallable<_EventFn>.listener(_onEvent);
    final startCompleter = Completer<RuntimeEvent>();
    _pending[0] = startCompleter;
    final int rc = using((arena) {
      final Pointer<Pointer<Char>> opts = arena<Pointer<Char>>(options.length);
      for (var i = 0; i < options.length; i++) {
        opts[i] = options[i].toNativeUtf8(allocator: arena).cast();
      }
      return native.srt_runtime_start(
        javaHome.toNativeUtf8(allocator: arena).cast(),
        opts,
        options.length,
        callback.nativeFunction,
      );
    });
    if (rc != native.SRT_OK) {
      _pending.remove(0);
      callback.close();
      throw IosJvmRuntimeException('srt_runtime_start failed', rc);
    }
    final RuntimeEvent event = await startCompleter.future;
    if (event.status != RuntimeStatus.ok) {
      throw IosJvmRuntimeException('VM creation failed: ${event.payload}');
    }
    return _instance = IosJvmRuntime._(event, callback);
  }

  static void _onEvent(int jobId, int status, Pointer<Char> payload) {
    final String json = payload.cast<Utf8>().toDartString();
    native.srt_free(payload.cast());
    final event = RuntimeEvent(
      jobId,
      RuntimeStatus.values[status],
      jsonDecode(json) as Map<String, Object?>,
    );
    _pending.remove(jobId)?.complete(event);
  }

  /// Runs `static String method(String)` of [className] (binary name with
  /// `/` or `.` separators) on a new owned thread.
  Future<RuntimeEvent> call(
    String className,
    String method,
    String argument, {
    Duration? deadline,
    DeadlineMechanism mechanism = DeadlineMechanism.none,
  }) {
    final int id = _nextJobId++;
    final completer = Completer<RuntimeEvent>();
    _pending[id] = completer;
    final int rc = using(
      (arena) => native.srt_call(
        id,
        className.replaceAll('.', '/').toNativeUtf8(allocator: arena).cast(),
        method.toNativeUtf8(allocator: arena).cast(),
        argument.toNativeUtf8(allocator: arena).cast(),
        deadline?.inMilliseconds ?? 0,
        mechanism.code,
      ),
    );
    if (rc != native.SRT_OK) {
      _pending.remove(id);
      return Future.error(IosJvmRuntimeException('srt_call failed', rc));
    }
    return completer.future;
  }

  /// Toggles the Zero back-edge safepoint poll (patch 0004). Returns the
  /// previous setting.
  bool setBackedgePoll({required bool enabled}) => native.srt_set_backedge_poll(enabled ? 1 : 0) == 1;

  int get globalRefCount => native.srt_global_ref_count();
  int get activeJobs => native.srt_active_jobs();

  /// Images loaded in the process (dyld). Unchanged across source calls when
  /// no native code was loaded (R18).
  static int get loadedImageCount => native.srt_loaded_image_count();

  /// Number of VMs reported by `JNI_GetCreatedJavaVMs`.
  int createdVmCount() => using((arena) {
    final Pointer<Pointer<native.JavaVM>> vms = arena<Pointer<native.JavaVM>>(4);
    final Pointer<Int> count = arena<Int>();
    final int rc = native.JNI_GetCreatedJavaVMs(vms, 4, count);
    if (rc != native.JNI_OK) throw IosJvmRuntimeException('JNI_GetCreatedJavaVMs failed', rc);
    return count.value;
  });

  /// Whether the calling (Dart) thread is attached to the VM, checked with
  /// the invocation interface's `GetEnv`. Dart threads are never attached.
  bool callingThreadAttached() => using((arena) {
    final Pointer<Pointer<native.JavaVM>> vms = arena<Pointer<native.JavaVM>>();
    final Pointer<Int> count = arena<Int>();
    native.JNI_GetCreatedJavaVMs(vms, 1, count);
    if (count.value == 0) return false;
    final Pointer<native.JavaVM> vm = vms.value;
    final Pointer<native.JNIInvokeInterface_> table = vm.value;
    final int Function(Pointer<native.JavaVM>, Pointer<Pointer<Void>>, int) getEnv = table.ref.GetEnv
        .asFunction<int Function(Pointer<native.JavaVM>, Pointer<Pointer<Void>>, int)>();
    final Pointer<Pointer<Void>> env = arena<Pointer<Void>>();
    return getEnv(vm, env, native.JNI_VERSION_21) != native.JNI_EDETACHED;
  });
}

/// The staged runtime image, host class path and (in gate or test payloads
/// only) fixtures, shipped as package assets.
final class BundledRuntime {
  BundledRuntime._(this.javaHome, this.fixtures, this.classPath, this.testData, this.stamp);

  /// Directory used as `java.home`.
  final String javaHome;

  /// Gate fixtures by name (for example `gate-ext-plain.jar`). Empty in a
  /// shipping payload.
  final Map<String, String> fixtures;

  /// The Tachi host class path in order (the shared worker's JARs, with the
  /// rewritten host libraries, and the iOS host). Empty in a gate-only payload.
  final List<String> classPath;

  /// Root of the test data tree (captures and qualification artifacts), or
  /// `null` in a shipping payload.
  final String? testData;

  /// Payload identity (image digest prefix and SDK).
  final String stamp;

  /// Options for the production VM (U9): interpreter only, the host class
  /// path, no JNI library search path, and foreign-function library lookups
  /// refused (R18). Heap bounds are provisional until the KTD25 device
  /// benchmark sizes them.
  ///
  /// [denyIllegalNativeAccess] is for diagnostics only; shipping builds keep it.
  List<String> productionOptions({
    required String tempDirectory,
    int maxHeapMiB = 384,
    bool denyIllegalNativeAccess = true,
  }) => <String>[
    '-Xint',
    '-Xshare:off',
    '-XX:+UseSerialGC',
    '-Xms32m',
    '-Xmx${maxHeapMiB}m',
    '-Djava.class.path=${classPath.join(':')}',
    '-Djava.library.path=',
    if (denyIllegalNativeAccess) '--illegal-native-access=deny',
    '-Djava.io.tmpdir=$tempDirectory',
    '-Dfile.encoding=UTF-8',
    '-Dstdout.encoding=UTF-8',
    '-Dstderr.encoding=UTF-8',
  ];

  static String get assetDirectory {
    final String bundle = File(Platform.resolvedExecutable).parent.path;
    return '$bundle/Frameworks/App.framework/flutter_assets/packages/source_runtime_ios/runtime';
  }

  /// Recreates `java.home` under the app's Library directory with symbolic
  /// links into the read-only bundle, following `layout.txt`.
  factory BundledRuntime.prepare() {
    final String assets = assetDirectory;
    final layout = File('$assets/layout.txt');
    if (!layout.existsSync()) {
      throw IosJvmRuntimeException('runtime payload is not staged (missing $assets/layout.txt)');
    }
    final List<String> lines = layout.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    final String stamp = lines
        .firstWhere((l) => l.startsWith('stamp\t'), orElse: () => 'stamp\tunknown')
        .split('\t')[1];
    // The app container is the parent of its tmp directory (HOME is not set
    // in the iOS Dart process).
    final String container = Directory.systemTemp.parent.path;
    final home = '$container/Library/Application Support/source_runtime/java-home-$stamp';
    final fixtures = <String, String>{};
    final classPath = <String>[];
    final data = '$container/Library/Application Support/source_runtime/testdata-$stamp';
    var hasData = false;
    for (final line in lines) {
      final List<String> parts = line.split('\t');
      switch (parts) {
        case ['home', final String flat, final String rel]:
          final link = Link('$home/$rel');
          final target = '$assets/$flat';
          if (link.existsSync() && link.targetSync() == target) continue;
          if (link.existsSync()) link.deleteSync();
          link.parent.createSync(recursive: true);
          link.createSync(target);
        case ['fixture', final String flat]:
          fixtures[flat] = '$assets/$flat';
        case ['classpath', final String flat]:
          classPath.add('$assets/$flat');
        case ['data', final String flat, final String rel]:
          hasData = true;
          final link = Link('$data/$rel');
          final target = '$assets/$flat';
          if (link.existsSync() && link.targetSync() == target) continue;
          if (link.existsSync()) link.deleteSync();
          link.parent.createSync(recursive: true);
          link.createSync(target);
        default:
          break;
      }
    }
    return BundledRuntime._(home, fixtures, classPath, hasData ? data : null, stamp);
  }
}
