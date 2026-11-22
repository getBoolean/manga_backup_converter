// Build hook: links the native dispatcher, the FFIgen Objective-C trampolines
// and (when built) the embedded Zero JVM into one dynamic library code asset
// for iOS.
//
// The JVM archive comes from tools/tachi-source-runner/ios (build/out/<sdk>/
// lib/libsourcejvm.a, git-ignored). When it is absent, or for an
// architecture it was not built for, the dispatcher is compiled with
// SRT_HAS_JVM=0 and every runtime entry point reports "not linked".
// Other target OSes get no asset.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _assetName = 'source_runtime_ios';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final CodeConfig code = input.config.code;
    if (code.targetOS != OS.iOS) return;

    final simulator = code.iOS.targetSdk == IOSSdk.iPhoneSimulator;
    final sdk = simulator ? 'iphonesimulator' : 'iphoneos';
    final String arch = switch (code.targetArchitecture) {
      Architecture.arm64 => 'arm64',
      Architecture.x64 => 'x86_64',
      final Architecture other => throw UnsupportedError('source_runtime_ios: unsupported architecture $other'),
    };
    final triple = 'arm64' == arch
        ? 'arm64-apple-ios${code.iOS.targetVersion}${simulator ? '-simulator' : ''}'
        : 'x86_64-apple-ios${code.iOS.targetVersion}-simulator';

    final Uri pkg = input.packageRoot;
    final Uri runtimeArchive = pkg.resolve('../../tools/tachi-source-runner/ios/build/out/$sdk/lib/libsourcejvm.a');
    final bool hasJvm = arch == 'arm64' && File.fromUri(runtimeArchive).existsSync();

    final List<Uri> sources = [pkg.resolve('src/source_runtime_ios.c'), pkg.resolve('src/webkit_bindings.g.m')];
    final Uri outDir = input.outputDirectory;
    final Uri dylib = outDir.resolve('lib$_assetName.dylib');

    final String sdkPath = (await _run('xcrun', ['--sdk', sdk, '--show-sdk-path'])).trim();
    final String clang = (await _run('xcrun', ['--sdk', sdk, '-f', 'clang'])).trim();

    final List<String> clangArgs = [
      '-target',
      triple,
      '-isysroot',
      sdkPath,
      '-dynamiclib',
      '-O2',
      '-fobjc-arc',
      '-fvisibility=hidden',
      '-I${pkg.resolve('src/include/').toFilePath()}',
      '-I${pkg.resolve('src/').toFilePath()}',
      '-DSRT_HAS_JVM=${hasJvm ? 1 : 0}',
      for (final Uri s in sources) s.toFilePath(),
      '-framework',
      'Foundation',
      '-framework',
      'WebKit',
      if (hasJvm) ...[
        // Keep every JVM and JDK-native symbol: the VM resolves JNI natives
        // and JNI_OnLoad_<lib> with dlsym (patch 0002), so they must be
        // present and exported from this image.
        '-Wl,-force_load,${runtimeArchive.toFilePath()}',
        '-lc++',
        '-lz',
        '-framework', 'CoreFoundation',
        '-framework', 'Security',
        '-framework', 'SystemConfiguration',
      ],
      '-install_name',
      '@rpath/lib$_assetName.dylib',
      '-o',
      dylib.toFilePath(),
    ];
    await _run(clang, clangArgs);

    output.assets.code.add(
      CodeAsset(package: input.packageName, name: _assetName, linkMode: DynamicLoadingBundled(), file: dylib),
    );
    output.dependencies.addAll([
      ...sources,
      pkg.resolve('src/source_runtime_ios.h'),
      // Directory dependency: reruns the hook when build/out appears.
      pkg.resolve('../../tools/tachi-source-runner/ios/'),
      if (hasJvm) runtimeArchive,
    ]);
  });
}

Future<String> _run(String executable, List<String> args) async {
  final ProcessResult r = await Process.run(executable, args);
  if (r.exitCode != 0) {
    throw StateError(
      'source_runtime_ios: `$executable ${args.join(' ')}` failed (${r.exitCode}):\n${r.stdout}\n${r.stderr}',
    );
  }
  return r.stdout as String;
}
