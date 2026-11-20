@TestOn('vm')
@Tags(<String>['presubmit-only'])
@Timeout(Duration(seconds: 120))
library;

import 'package:build_verify/build_verify.dart';
import 'package:test/scaffolding.dart';

void main() {
  test('ensure_gen', () => expectBuildClean(packageRelativeDirectory: 'packages/manga_backup_core'));
}
