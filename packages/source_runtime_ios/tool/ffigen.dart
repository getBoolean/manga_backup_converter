// Generates the FFIgen bindings for source_runtime_ios.
//
//   dart run tool/ffigen.dart        (from packages/source_runtime_ios)
//
// 1. lib/src/runtime_bindings.g.dart: the JNI invocation interface (jni.h:
//    JNI_CreateJavaVM, JNI_GetCreatedJavaVMs, JavaVM's invoke table) and the
//    native dispatcher's C API (src/source_runtime_ios.h).
// 2. lib/src/webkit_bindings.g.dart + src/webkit_bindings.g.m: the WebKit
//    classes and protocols the WKWebView probe drives, against the iOS SDK.
//
// jni.h/jni_md.h are the headers produced by the pinned runtime build
// (tools/tachi-source-runner/ios), committed under src/include/.
import 'dart:io';

import 'package:ffigen/ffigen.dart';
import 'package:logging/logging.dart';

const _assetId = 'package:source_runtime_ios/source_runtime_ios';
const _preamble = '''
// AUTO GENERATED FILE, DO NOT EDIT. Regenerate with `dart run tool/ffigen.dart`.
// ignore_for_file: type=lint, unused_import, unused_element
''';

// The WebKit surface the WKWebView probe (and later U10's browser port) uses.
const _webkitMembers = <String, Set<String>>{
  'WKWebView': {
    'alloc',
    'initWithFrame:configuration:',
    'loadData:MIMEType:characterEncodingName:baseURL:',
    'loadHTMLString:baseURL:',
    'customUserAgent',
    'setCustomUserAgent:',
    'navigationDelegate',
    'setNavigationDelegate:',
    'evaluateJavaScript:completionHandler:',
    'stopLoading',
    'URL',
    'isLoading',
  },
  'WKWebViewConfiguration': {
    'alloc',
    'new',
    'init',
    'userContentController',
    'setUserContentController:',
    'websiteDataStore',
    'setWebsiteDataStore:',
  },
  'WKUserContentController': {
    'alloc',
    'new',
    'init',
    'addUserScript:',
    'addScriptMessageHandler:name:',
    'removeScriptMessageHandlerForName:',
    'removeAllUserScripts',
  },
  'WKUserScript': {'alloc', 'initWithSource:injectionTime:forMainFrameOnly:'},
  'WKWebsiteDataStore': {'nonPersistentDataStore', 'httpCookieStore', 'isPersistent'},
  'WKScriptMessage': {'body', 'name', 'frameInfo'},
  'WKHTTPCookieStore': {'getAllCookies:'},
  'WKFrameInfo': {'isMainFrame', 'securityOrigin'},
  'WKSecurityOrigin': {'protocol', 'host', 'port'},
  'WKNavigation': <String>{},
  'NSHTTPCookie': {'name', 'value', 'domain', 'path', 'isSecure'},
  // Superclasses of WKWebView: generated without members to keep the
  // bindings small.
  'UIView': <String>{},
  'UIResponder': <String>{},
};

const _protocolMembers = <String, Set<String>>{
  'WKScriptMessageHandler': {'userContentController:didReceiveScriptMessage:'},
  'WKNavigationDelegate': {
    'webView:didFinishNavigation:',
    'webView:didFailNavigation:withError:',
    'webView:didFailProvisionalNavigation:withError:',
  },
};

void main() {
  Logger.root
    ..level = Level.WARNING
    ..onRecord.listen((r) => stderr.writeln('${r.level.name}: ${r.message}'));
  final Uri root = Platform.script.resolve('../');
  const iosTarget = 'arm64-apple-ios15.0';

  FfiGenerator(
    headers: Headers(
      entryPoints: [root.resolve('src/include/jni.h'), root.resolve('src/source_runtime_ios.h')],
      compilerOptions: [
        '-isysroot',
        iosSdkPath,
        '-target',
        iosTarget,
        '-I${root.resolve('src/include/').toFilePath()}',
      ],
    ),
    functions: Functions.includeSet({
      'JNI_CreateJavaVM',
      'JNI_GetCreatedJavaVMs',
      'JNI_GetDefaultJavaVMInitArgs',
      'srt_runtime_linked',
      'srt_runtime_state',
      'srt_runtime_start',
      'srt_call',
      'srt_set_backedge_poll',
      'srt_global_ref_count',
      'srt_active_jobs',
      'srt_free',
      'srt_worker_set_callback',
      'srt_worker_start',
      'srt_worker_write',
      'srt_worker_close_input',
      'srt_worker_kill',
      'srt_worker_count',
      'srt_armed_deadlines',
      'srt_fired_deadlines',
      'srt_loaded_image_count',
    }),
    structs: Structs.includeSet({'JavaVMInitArgs', 'JavaVMOption', 'JNIInvokeInterface_', 'JavaVM_'}),
    typedefs: Typedefs.includeSet({'JavaVM', 'srt_event_callback', 'srt_stream_callback'}),
    macros: Macros.includeSet({
      'JNI_OK',
      'JNI_EDETACHED',
      'JNI_VERSION_21',
      'SRT_STATUS_OK',
      'SRT_STATUS_JAVA_EXCEPTION',
      'SRT_STATUS_DEADLINE',
      'SRT_STATUS_RUNTIME_ERROR',
      'SRT_MECHANISM_NONE',
      'SRT_MECHANISM_INJECTED',
      'SRT_MECHANISM_STOP_THREAD',
      'SRT_OK',
      'SRT_ERR_NOT_LINKED',
      'SRT_ERR_STATE',
      'SRT_ERR_THREAD',
      'SRT_ERR_ARGUMENT',
      'SRT_STREAM_STDOUT',
      'SRT_STREAM_STDERR',
      'SRT_STREAM_EXIT',
    }),
    output: Output(
      dartFile: root.resolve('lib/src/runtime_bindings.g.dart'),
      preamble: _preamble,
      style: const NativeExternalBindings(assetId: _assetId),
    ),
  ).generate(logger: Logger.root);

  FfiGenerator(
    headers: Headers(
      entryPoints: [root.resolve('src/webkit_probe.h')],
      compilerOptions: ['-isysroot', iosSdkPath, '-target', iosTarget, '-x', 'objective-c'],
    ),
    objectiveC: ObjectiveC(
      interfaces: Interfaces(
        include: (d) => _webkitMembers.containsKey(d.originalName),
        includeMember: (d, member) => _webkitMembers[d.originalName]?.contains(member) ?? false,
      ),
      protocols: Protocols(
        include: (d) => _protocolMembers.containsKey(d.originalName),
        includeMember: (d, member) => _protocolMembers[d.originalName]?.contains(member) ?? false,
      ),
    ),
    enums: Enums.includeSet({'WKUserScriptInjectionTime'}),
    output: Output(
      dartFile: root.resolve('lib/src/webkit_bindings.g.dart'),
      objectiveCFile: root.resolve('src/webkit_bindings.g.m'),
      preamble: _preamble,
      style: const NativeExternalBindings(assetId: _assetId),
    ),
  ).generate(logger: Logger.root);
}
