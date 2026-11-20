import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:quickjs/src/build/quickjs_build_spec.dart';

/// Compiles the vendored QuickJS-ng submodule and the Dart FFI wrapper into
/// one bundled dynamic library (KTD24). Nothing is downloaded.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final CodeConfig codeConfig = input.config.code;
    final QuickJsTargetConfig target = quickJsTargetConfig(codeConfig.targetOS, codeConfig.targetArchitecture);

    final Uri engine = input.packageRoot.resolve('vendor/quickjs/quickjs.c');
    if (!File.fromUri(engine).existsSync()) {
      throw StateError(
        'QuickJS source is missing at ${engine.toFilePath()}. '
        'Run `git submodule update --init --recursive`.',
      );
    }

    final cbuilder = CBuilder.library(
      name: 'quickjs',
      assetName: 'src/quickjs_bindings_generated.dart',
      sources: <String>[...quickJsEngineSources, ...quickJsWrapperSources],
      includes: quickJsIncludes,
      defines: target.defines,
      flags: target.flags,
      libraries: target.libraries,
      std: target.std,
    );
    await cbuilder.run(input: input, output: output);
  });
}
