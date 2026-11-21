import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

void main() {
  final Uri repo = Uri.parse('https://example.org/repo');

  RepositoryTrustGate gate(TrustStore store, TrustDecision answer) =>
      RepositoryTrustGate(store: store, decide: (_) async => answer);

  group('RepositoryTrustGate.check', () {
    test('a remembered fingerprint is admitted without asking', () async {
      final store = InMemoryTrustStore();
      await store.remember('tachi', repo, 'aa');
      final RepositoryTrustGate g = gate(store, TrustDecision.reject);
      check(await g.check('tachi', repo, 'aa')).isNull();
      check(g.decisions).isEmpty();
    });

    test('nobody answering a first-seen fingerprint is first-seen', () async {
      final RepositoryTrustGate g = gate(InMemoryTrustStore(), TrustDecision.unanswered);
      check(await g.check('tachi', repo, 'aa'))
          .isNotNull()
          .has((TrustFailure f) => f.reason, 'reason')
          .equals(TrustFailureReason.firstSeen);
      check(await g.admit('tachi', repo, 'aa')).isFalse();
    });

    test('nobody answering a changed fingerprint is changed', () async {
      final store = InMemoryTrustStore();
      await store.remember('tachi', repo, 'aa');
      final RepositoryTrustGate g = gate(store, TrustDecision.unanswered);
      check(await g.check('tachi', repo, 'bb'))
          .isNotNull()
          .has((TrustFailure f) => f.reason, 'reason')
          .equals(TrustFailureReason.changed);
    });

    test('a user saying no is refused, for a new and a changed fingerprint', () async {
      final store = InMemoryTrustStore();
      final RepositoryTrustGate g = gate(store, TrustDecision.reject);
      check(
        await g.check('tachi', repo, 'aa'),
      ).isNotNull().has((TrustFailure f) => f.reason, 'reason').equals(TrustFailureReason.refused);
      await store.remember('tachi', repo, 'aa');
      check(
        await g.check('tachi', repo, 'bb'),
      ).isNotNull().has((TrustFailure f) => f.reason, 'reason').equals(TrustFailureReason.refused);
    });

    test('trust once admits for the run; trust and remember stores it', () async {
      final store = InMemoryTrustStore();
      check(await gate(store, TrustDecision.trustOnce).check('tachi', repo, 'aa')).isNull();
      check(await store.fingerprintFor('tachi', repo)).isNull();
      check(await gate(store, TrustDecision.trustAndRemember).check('tachi', repo, 'aa')).isNull();
      check(await store.fingerprintFor('tachi', repo)).equals('aa');
    });

    test('an unattended selection port leaves trust unanswered', () async {
      final port = CallbackSelectionPort(
        onSelectExtensions: (_) async => const <ExtensionEntry>[],
        onConfirmMatches: (_, _, _, _) async => const <MangaMatchConfirmation>[],
      );
      check(
        await port.decideRepositoryTrust(
          RepositoryTrustRequest(ecosystem: 'tachi', repository: repo, fingerprint: 'aa'),
        ),
      ).equals(TrustDecision.unanswered);
    });
  });
}
