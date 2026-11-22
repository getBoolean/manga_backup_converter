// The app's one lifecycle signal on Android (KTD18, KTD23).
//
// The Kotlin `ActivityTracker` counts the process's started Activities and
// reports "background" only after none has been started for 700 ms (the
// `ProcessLifecycleOwner` delay, so recreation gaps do not count). A visible
// Activity of another process of this app — the `:source_runtime` Cloudflare
// challenge — keeps the app in the foreground. The browser port's WebView
// host and this class follow the same tracker; the composition root feeds
// this class to both the background gate and the port, gate first, so a
// backgrounded call ends as `cancelled: app-backgrounded` before the port
// reacts. No platform channel carries the signal: the Kotlin listener is an
// asynchronous JNIgen listener.
import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_android/src/bindings/source_runtime_bindings.g.dart' as jni;

/// The native side of [AndroidAppForeground].
abstract interface class AppForegroundNative {
  /// Whether the app is in the foreground now.
  bool get isForeground;

  /// Stops listening.
  void dispose();
}

/// Builds the native side; [onChange] hears every foreground change.
typedef AppForegroundNativeFactory = AppForegroundNative Function(void Function(bool foreground) onChange);

/// The JNIgen-backed native side: the Kotlin `AppForegroundMonitor`.
final class JniAppForegroundNative implements AppForegroundNative {
  JniAppForegroundNative._(this._monitor, this._listener);

  /// Creates the monitor over the application context.
  static AppForegroundNative create(void Function(bool foreground) onChange) {
    final listener = jni.AppForegroundListener.implement(
      jni.$AppForegroundListener(onForegroundChanged: onChange, onForegroundChanged$async: true),
    );
    final JObject context = androidApplicationContext;
    try {
      return JniAppForegroundNative._(jni.AppForegroundMonitor(context, listener), listener);
    } finally {
      context.release();
    }
  }

  final jni.AppForegroundMonitor _monitor;
  final jni.AppForegroundListener _listener;
  bool _disposed = false;

  @override
  bool get isForeground => !_disposed && _monitor.isForeground;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _monitor
      ..dispose()
      ..release();
    _listener.release();
  }
}

/// Whether the app is backgrounded, followed by the background gate and the
/// app-process browser port.
///
/// Listeners run synchronously, in the order they were added, on every
/// change of [isBackgrounded].
final class AndroidAppForeground {
  AndroidAppForeground._(this._native);

  /// Starts following the app's Activities. [native] is injectable for host
  /// tests; it defaults to the Kotlin monitor. Fails with a named reason
  /// when the monitor cannot be created.
  static SourceOutcome<AndroidAppForeground> start({AppForegroundNativeFactory? native}) {
    final foreground = AndroidAppForeground._(null);
    try {
      foreground._native = (native ?? JniAppForegroundNative.create)(foreground._onNative);
    } on Object catch (e) {
      return SourceFailed<AndroidAppForeground>(
        RuntimeUnavailableFailure('The app foreground monitor did not start: $e'),
      );
    }
    foreground._foreground = foreground._native!.isForeground;
    foreground._last = foreground.isBackgrounded;
    return SourceSuccess<AndroidAppForeground>(foreground);
  }

  AppForegroundNative? _native;
  bool _foreground = true;
  bool? _override;
  bool _last = false;
  final List<void Function(bool backgrounded)> _listeners = <void Function(bool backgrounded)>[];

  /// Whether the app is treated as backgrounded.
  bool get isBackgrounded => _override ?? !_foreground;

  /// Adds [listener], called with the new state on every change.
  void addListener(void Function(bool backgrounded) listener) => _listeners.add(listener);

  /// Removes [listener].
  void removeListener(void Function(bool backgrounded) listener) => _listeners.remove(listener);

  /// Test seam: forces the state (`null` follows the Activities again).
  void setBackgroundedOverride(bool? backgrounded) {
    _override = backgrounded;
    _changed();
  }

  void _onNative(bool foreground) {
    _foreground = foreground;
    _changed();
  }

  void _changed() {
    final bool now = isBackgrounded;
    if (now == _last) return;
    _last = now;
    for (final void Function(bool) listener in _listeners.toList()) {
      listener(now);
    }
  }

  /// Stops following the Activities and drops every listener.
  void dispose() {
    _listeners.clear();
    _native?.dispose();
    _native = null;
  }
}
