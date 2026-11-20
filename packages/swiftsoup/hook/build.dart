// Build hook that compiles the Swift SwiftSoupWrapper and registers the
// resulting dynamic library as a CodeAsset.
//
// On macOS: produces libSwiftSoupWrapper.dylib
// On iOS:   produces libSwiftSoupWrapper.dylib, cross-compiled for the SDK the
//           build config asks for (iphoneos for devices, iphonesimulator for
//           the simulator; arm64 or x86_64).
//
// Only runs on iOS and macOS — other platforms use Rust scraper or TeaVM.
//
// The Swift toolchain is resolved through `xcrun --sdk <sdk> swift` so the
// Xcode toolchain (which ships the iOS Swift runtime and SDK overlays) is used
// even when another toolchain (e.g. swiftly) is first on PATH.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Lowest iOS version the wrapper is compiled for. Matches the app's iOS
/// minimum (ios/Podfile) and Xcode 27's lowest supported deployment target.
const int _minIOSVersion = 15;

/// Lowest macOS version the wrapper is compiled for. Matches the app's macOS
/// minimum (macos/Podfile) and Xcode 27's lowest supported deployment target.
const int _minMacOSVersion = 12;

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final CodeConfig codeConfig = input.config.code;

    // Only build on iOS and macOS.
    if (codeConfig.targetOS != OS.iOS && codeConfig.targetOS != OS.macOS) {
      return;
    }

    final Uri swiftDir = input.packageRoot.resolve('swift/');
    final swiftDirFs = Directory.fromUri(swiftDir);
    if (!swiftDirFs.existsSync()) {
      throw StateError('Swift package not found at ${swiftDirFs.path}');
    }

    const libName = 'libSwiftSoupWrapper.dylib';

    final Uri libUri = await _swiftBuild(
      swiftDir: swiftDirFs,
      libName: libName,
      cacheDir: input.outputDirectoryShared,
      target: _AppleTarget.fromConfig(codeConfig),
    );

    output.assets.code.add(
      CodeAsset(
        package: 'swiftsoup',
        name: 'src/swiftsoup_bindings_generated.dart',
        linkMode: DynamicLoadingBundled(),
        file: libUri,
      ),
    );
  });
}

/// The architecture, SDK, and triple (which encodes the deployment target)
/// to compile the wrapper for.
final class _AppleTarget {
  const _AppleTarget({
    required this.cpu,
    required this.sdk,
    required this.triple,
  });

  factory _AppleTarget.fromConfig(CodeConfig config) {
    final Architecture arch = config.targetArchitecture;
    if (config.targetOS == OS.macOS) {
      final String cpu = switch (arch) {
        Architecture.arm64 => 'arm64',
        Architecture.x64 => 'x86_64',
        _ => throw UnsupportedError(
          'swiftsoup: unsupported macOS architecture $arch',
        ),
      };
      final version = '${max(_minMacOSVersion, config.macOS.targetVersion)}.0';
      return _AppleTarget(
        cpu: cpu,
        sdk: 'macosx',
        triple: '$cpu-apple-macosx$version',
      );
    }

    final String sdk = config.iOS.targetSdk.type;
    final bool simulator;
    if (sdk == IOSSdk.iPhoneOS.type) {
      simulator = false;
    } else if (sdk == IOSSdk.iPhoneSimulator.type) {
      simulator = true;
    } else {
      throw UnsupportedError('swiftsoup: unsupported iOS SDK "$sdk"');
    }
    final String cpu = switch (arch) {
      Architecture.arm64 => 'arm64',
      // Intel slices only exist for the simulator.
      Architecture.x64 when simulator => 'x86_64',
      _ => throw UnsupportedError(
        'swiftsoup: unsupported iOS architecture $arch for SDK $sdk',
      ),
    };
    final version = '${max(_minIOSVersion, config.iOS.targetVersion)}.0';
    return _AppleTarget(
      cpu: cpu,
      sdk: sdk,
      triple: '$cpu-apple-ios$version${simulator ? '-simulator' : ''}',
    );
  }

  /// Mach-O architecture name: arm64 or x86_64.
  final String cpu;

  /// Platform name as printed by `vtool -show-build`.
  String get machOPlatform => switch (sdk) {
    'macosx' => 'MACOS',
    'iphonesimulator' => 'IOSSIMULATOR',
    _ => 'IOS',
  };

  /// `xcrun` SDK name: macosx, iphoneos, or iphonesimulator.
  final String sdk;

  /// Swift target triple, including the deployment target (and the
  /// `-simulator` environment for simulator slices).
  final String triple;

  /// Distinguishes cached builds for different SDKs, architectures, and
  /// deployment targets. The triple already encodes arch and version.
  String get cacheKey => '$sdk-$triple';
}

Future<String> _xcrun(List<String> args) async {
  final ProcessResult result = await Process.run('xcrun', args);
  if (result.exitCode != 0) {
    throw StateError('xcrun ${args.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout.toString().trim();
}

Future<Uri> _swiftBuild({
  required Directory swiftDir,
  required String libName,
  required Uri cacheDir,
  required _AppleTarget target,
}) async {
  final String cacheKey = target.cacheKey;
  final buildCacheDir = Directory.fromUri(
    cacheDir.resolve('swiftsoup-$cacheKey/'),
  );
  final cachedLib = File(
    '${buildCacheDir.path}${Platform.pathSeparator}$libName',
  );
  if (cachedLib.existsSync()) {
    return cachedLib.uri;
  }

  print('swiftsoup: building SwiftSoupWrapper for $cacheKey ...');

  final String sdkPath = await _xcrun(['--sdk', target.sdk, '--show-sdk-path']);
  final String swift = await _xcrun(['--sdk', target.sdk, '--find', 'swift']);

  // Each target gets its own scratch directory: SwiftPM's default `.build`
  // shares one Products directory per SDK (e.g. Release-iphonesimulator), so
  // concurrent hook runs for arm64 and x86_64 would overwrite each other.
  final String scratchPath = Directory.fromUri(
    cacheDir.resolve('swiftsoup-$cacheKey-build/'),
  ).path;

  // `--sdk` (not `-Xswiftc -sdk`) is what selects the target platform: the
  // default `swiftbuild` build system (Xcode 27 / Swift 6.4) ignores the
  // `-Xswiftc -sdk` override and silently builds for macOS.
  final targetArgs = <String>[
    '-c',
    'release',
    '--scratch-path',
    scratchPath,
    '--triple',
    target.triple,
    '--sdk',
    sdkPath,
    // Flutter rewrites the dylib's install name when bundling it
    // (install_name_tool), which needs spare load-command space.
    '-Xlinker',
    '-headerpad_max_install_names',
  ];
  // SwiftPM compiles Package.swift for the host (macOS) using SDKROOT. When
  // the hook runs inside an Xcode iOS build, SDKROOT is inherited as the iOS
  // SDK and the manifest fails to compile ("unable to load standard library
  // for target 'arm64-apple-macosx...'"), so pin it to the macOS SDK.
  final env = <String, String>{
    'SDKROOT': target.sdk == 'macosx' ? sdkPath : await _xcrun(['--sdk', 'macosx', '--show-sdk-path']),
  };

  final ProcessResult result = await Process.run(
    swift,
    ['build', ...targetArgs],
    workingDirectory: swiftDir.path,
    environment: env,
  );

  if (result.exitCode != 0) {
    throw StateError(
      'swift build for ${target.triple} (SDK ${target.sdk}) failed:\n'
      '${result.stdout}\n${result.stderr}',
    );
  }

  // Ask SPM for the actual binary output directory (may differ across versions).
  final ProcessResult binPathResult = await Process.run(
    swift,
    ['build', '--show-bin-path', ...targetArgs],
    workingDirectory: swiftDir.path,
    environment: env,
  );
  if (binPathResult.exitCode != 0) {
    throw StateError(
      'swift build --show-bin-path failed:\n${binPathResult.stderr}',
    );
  }
  final String buildDir = binPathResult.stdout.toString().trim();

  final builtLib = File('$buildDir/$libName');
  if (!builtLib.existsSync()) {
    throw StateError('Built library not found at ${builtLib.path}');
  }

  // Guard against the toolchain silently building the wrong slice (e.g. a
  // macOS dylib when an iOS one was requested).
  final String archs = await _xcrun(['lipo', '-archs', builtLib.path]);
  final String buildVersion = await _xcrun([
    'vtool',
    '-show-build',
    builtLib.path,
  ]);
  final bool platformMatches = RegExp(
    '^\\s*platform\\s+${target.machOPlatform}\\s*\$',
    multiLine: true,
  ).hasMatch(buildVersion);
  if (archs != target.cpu || !platformMatches) {
    throw StateError(
      'swiftsoup: expected a ${target.machOPlatform} ${target.cpu} dylib for '
      '${target.triple}, but ${builtLib.path} is "$archs":\n$buildVersion',
    );
  }

  if (!buildCacheDir.existsSync()) {
    buildCacheDir.createSync(recursive: true);
  }
  builtLib.copySync(cachedLib.path);

  print('swiftsoup: built $libName for $cacheKey');
  return cachedLib.uri;
}
