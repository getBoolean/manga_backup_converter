import 'package:aidoku_plugin_loader/src/aidoku/libs/host_store.dart';
import 'package:aidoku_plugin_loader/src/aidoku/libs/import_context.dart';
import 'package:quickjs/quickjs.dart';

/// `js` module host imports — native implementation using the vendored
/// QuickJS-ng package.
///
/// One [JsRuntime] is shared by every live context of this plugin instance
/// and freed when the last context is disposed. Evaluation is synchronous.
Map<String, Function> buildJsImports(ImportContext ctx) {
  JsRuntime? runtime;
  var liveContexts = 0;
  return <String, Function>{
    'context_create': () {
      try {
        final JsRuntime rt = runtime ??= _newRuntime();
        final JsContext context = rt.newContext();
        _installConsole(context, ctx);
        liveContexts++;
        return ctx.store.add(
          JsContextResource(
            context: context,
            onDispose: () {
              context.dispose();
              liveContexts--;
              // Dispose the runtime when all contexts are gone.
              if (liveContexts == 0 && identical(runtime, rt)) {
                rt.dispose();
                runtime = null;
              }
            },
          ),
        );
      } on Object catch (e) {
        ctx.onLog?.call('[CB] js::context_create failed: $e');
        return -1;
      }
    },
    'context_eval': (int ctxRid, int strPtr, int len) {
      final JsContextResource? res = ctx.store.get<JsContextResource>(ctxRid);
      if (res == null) return -2; // InvalidContext
      try {
        final String code = ctx.readString(strPtr, len);
        final String? value = _evalToString(res.context as JsContext, code);
        if (value == null) return -1; // MissingResult
        return ctx.storeString(value);
      } on Object catch (e) {
        ctx.onLog?.call('[CB] js::context_eval failed: $e');
        return -1;
      }
    },
    'context_get': (int ctxRid, int namePtr, int nameLen) {
      final JsContextResource? res = ctx.store.get<JsContextResource>(ctxRid);
      if (res == null) return -2; // InvalidContext
      try {
        final String name = ctx.readString(namePtr, nameLen);
        // Evaluating the name preserves the former engine's behaviour; a
        // ReferenceError maps to MissingResult.
        final String? value = _evalToString(res.context as JsContext, name);
        if (value == null) return -1; // MissingResult
        return ctx.storeString(value);
      } on Object catch (e) {
        ctx.onLog?.call('[CB] js::context_get failed: $e');
        return -1;
      }
    },
    // Webview functions remain stubbed — no native webview support.
    'webview_create': () => -1,
    'webview_load': (int webview, int request) => -1,
    'webview_load_html': (
      int webview,
      int htmlPtr,
      int htmlLen,
      int basePtr,
      int baseLen,
    ) => -1,
    'webview_wait_for_load': (int webview) => -1,
    'webview_eval': (int webview, int strPtr, int len) => -1,
  };
}

JsRuntime _newRuntime() {
  final runtime = JsRuntime();
  // Crash guard, not a tuned limit: QuickJS's default 1 MiB JS stack can be
  // larger than the isolate thread's real stack (about 1 MiB on Windows), so
  // deep recursion would crash the process instead of throwing RangeError.
  final int? available = QuickJs.threadStackAvailable();
  if (available != null) runtime.maxStackSize = available ~/ 2;
  return runtime;
}

/// Evaluates [code] and returns `String(result)`, or `null` when it throws or
/// yields `undefined`/`null` (including the strings "undefined" and "null",
/// matching the former engine).
String? _evalToString(JsContext context, String code) {
  final JsValue result;
  try {
    result = context.eval(code);
  } on JsException {
    return null;
  }
  try {
    final String value = result.toDartString();
    if (value == 'undefined' || value == 'null') return null;
    return value;
  } on JsException {
    return null;
  } finally {
    result.dispose();
  }
}

/// Installs `console.log/info/warn/error/debug`. The former engine buffered
/// console output and discarded it; this forwards it to the plugin log.
void _installConsole(JsContext context, ImportContext ctx) {
  final JsValue global = context.global;
  final JsValue console = context.object();
  try {
    for (final level in const <String>['log', 'info', 'warn', 'error', 'debug']) {
      console.setProperty(
        level,
        context.newHostFunction(level, (JsContext c, JsValue self, List<JsValue> args) {
          final String line = args.map(_safeString).join(' ');
          ctx.onLog?.call('[js:${ctx.sourceId}] console.$level: $line');
          return null;
        }),
      );
    }
    global.setProperty('console', console);
  } finally {
    global.dispose();
  }
}

String _safeString(JsValue value) {
  try {
    return value.toDartString();
  } on JsException {
    return '<unprintable>';
  }
}
