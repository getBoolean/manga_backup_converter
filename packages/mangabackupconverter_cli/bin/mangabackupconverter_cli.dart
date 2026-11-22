import 'dart:io';

import 'package:mangabackupconverter_cli/src/commands/runtime_check.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_paperback.dart' show paperbackWorkerCommand;
import 'package:mangabackupconverter_cli/src/runner.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart' show runPaperbackWorker;

Future<void> main(List<String> arguments) async {
  // The desktop conversion re-launches this executable as its Paperback
  // worker; stdout then carries protocol frames only.
  if (arguments.isNotEmpty && arguments.first == paperbackWorkerCommand) {
    return runPaperbackWorker(arguments.sublist(1));
  }
  // Packaging smoke test: start every bundled runtime offline, then close.
  if (arguments.isNotEmpty && arguments.first == runtimeCheckCommand) {
    return runRuntimeCheck(arguments.sublist(1));
  }
  stdout.write('Starting...\r');
  try {
    await runApp(arguments);
  } on Exception catch (e, stack) {
    stderr.writeln('Unexpected error: $e');
    stderr.writeln(stack);
    exitCode = 1;
  }
}
