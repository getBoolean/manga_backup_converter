// Listener blocks for WebKit completion handlers whose object arguments may
// be nil.
//
// FFIgen's generated listeners for `void (^)(id, NSError *)` and
// `void (^)(WKContentRuleList *, NSError *)` wrap the first argument without
// a nil check, and `objc.ObjCObject` asserts a valid pointer in debug
// builds. WebKit passes nil on every failure path (a script that cannot
// return, a navigation that ends an evaluation, a rule list that fails to
// compile). This file builds the same listener block, through the same
// generated native wrapper (`_NativeLibrary_wrapListenerBlock_pfv6jd` in
// `src/webkit_bindings.g.m`), with both arguments nullable.
import 'dart:ffi' as ffi;

import 'package:objective_c/objective_c.dart' as objc;

@ffi.Native<ffi.Pointer<objc.ObjCBlockImpl> Function(ffi.Pointer<objc.ObjCBlockImpl>)>(
  symbol: '_NativeLibrary_wrapListenerBlock_pfv6jd',
  assetId: 'package:source_runtime_ios/source_runtime_ios',
  isLeaf: true,
)
external ffi.Pointer<objc.ObjCBlockImpl> _wrapListenerBlock(ffi.Pointer<objc.ObjCBlockImpl> block);

typedef _Trampoline = ffi.Void Function(
  ffi.Pointer<objc.ObjCBlockImpl>,
  ffi.Pointer<objc.ObjCObjectImpl>,
  ffi.Pointer<objc.ObjCObjectImpl>,
);

void _trampoline(
  ffi.Pointer<objc.ObjCBlockImpl> block,
  ffi.Pointer<objc.ObjCObjectImpl> arg0,
  ffi.Pointer<objc.ObjCObjectImpl> arg1,
) {
  (objc.getBlockClosure(block) as void Function(ffi.Pointer<objc.ObjCObjectImpl>, ffi.Pointer<objc.ObjCObjectImpl>))(
    arg0,
    arg1,
  );
  objc.objectRelease(block.cast());
}

final ffi.NativeCallable<_Trampoline> _callable = ffi.NativeCallable<_Trampoline>.listener(_trampoline)
  ..keepIsolateAlive = false;

/// A listener block `void (^)(id _Nullable, id _Nullable)` calling [fn] on
/// this isolate. The native wrapper retains both arguments; this releases
/// them when the Dart wrappers are collected.
///
/// The static type is chosen by the caller to match the method it is passed
/// to; every such method takes a block with two object arguments.
objc.ObjCBlock<T> nullableObjectPairListener<T extends Function>(
  void Function(objc.ObjCObject? first, objc.ObjCObject? second) fn,
) {
  final ffi.Pointer<objc.ObjCBlockImpl> raw = objc.newClosureBlock(
    _callable.nativeFunction.cast(),
    (ffi.Pointer<objc.ObjCObjectImpl> a0, ffi.Pointer<objc.ObjCObjectImpl> a1) => fn(
      a0.address == 0 ? null : objc.ObjCObject(a0, retain: false, release: true),
      a1.address == 0 ? null : objc.ObjCObject(a1, retain: false, release: true),
    ),
    false,
  );
  final ffi.Pointer<objc.ObjCBlockImpl> wrapper = _wrapListenerBlock(raw);
  objc.objectRelease(raw.cast());
  return objc.ObjCBlock<T>(wrapper, retain: false, release: true);
}
