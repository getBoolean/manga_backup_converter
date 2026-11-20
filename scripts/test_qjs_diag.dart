// ignore_for_file: avoid_print
import 'package:quickjs/quickjs.dart';

/// Smoke-checks the vendored QuickJS-ng build: loads it, evaluates code and
/// frees everything.
void main() {
  try {
    print(
      'QuickJS-ng ${QuickJs.engineVersion} (JSValue ${QuickJs.valueSize} bytes)',
    );
    final runtime = JsRuntime();
    final int? stack = QuickJs.threadStackAvailable();
    if (stack != null) runtime.maxStackSize = stack ~/ 2;
    final JsContext context = runtime.newContext();
    print('eval result: ${context.eval('1 + 1').toDartString()}');
    runtime.dispose();
    print('Done');
  } on Object catch (e, st) {
    print('ERROR: $e');
    print(st);
  }
}
