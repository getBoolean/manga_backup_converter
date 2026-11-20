/// Vendored QuickJS-ng JavaScript engine (KTD24).
///
/// `JsRuntime` owns a heap, job queue, limits and interrupt handler;
/// `JsContext` is a realm with standard intrinsics only (no `std`/`os`
/// modules); `JsValue` is an owned or borrowed value reference.
library;

export 'src/quickjs_api.dart';
