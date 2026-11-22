/// Test and tooling support: the in-process worker launcher and a yes/no
/// trust adapter. Not for production composition roots.
library;

import 'package:paperback_plugin_loader/src/provider.dart';
import 'package:source_runtime/source_contracts.dart';

export 'src/in_process_worker.dart';

/// A [PaperbackTrustCheck] from a yes/no decision (pinned digests in tests
/// and capture tools). A refusal cannot say whether the bundle was new or
/// changed, so it is reported as refused.
PaperbackTrustCheck yesNoTrust(Future<bool> Function(Uri trustKey, String fingerprint) decide) =>
    (Uri key, String fingerprint) async =>
        await decide(key, fingerprint) ? null : const TrustFailure(TrustFailureReason.refused, 'not trusted');
