import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:test/scaffolding.dart';

const _a = StubExtensionEntry(id: 'a', name: 'A', contentRating: ContentRatingLevel.safe);
const _b = StubExtensionEntry(id: 'b', name: 'B', contentRating: ContentRatingLevel.safe);

SourceSelectionRequest _offer(List<ExtensionEntry> available, {List<ExtensionEntry> previous = const []}) =>
    SourceSelectionRequest(available: available, hiddenByRating: 0, previousSelection: previous);

ExtensionResolution _resolve(
  SourceSelectionRequest request, {
  Set<String> extensions = const <String>{},
  Set<String> sources = const <String>{},
  bool canAskUser = false,
}) => resolveExtensions(request, extensionIds: extensions, sourceIds: sources, canAskUser: canAskUser);

void main() {
  test('nothing offered fails before anything else', () {
    check(_resolve(_offer(const <ExtensionEntry>[]), extensions: <String>{'a'}))
        .isA<Fail>()
        .has((Fail f) => f.reason, 'reason')
        .equals(ExtensionResolutionFailure.nothingOffered);
  });

  test('a resumed selection is reused only when the user named nothing', () {
    check(_resolve(_offer(const <ExtensionEntry>[_a, _b], previous: const <ExtensionEntry>[_b])))
        .isA<Picked>()
        .has((Picked p) => p.extensions, 'extensions')
        .deepEquals(<ExtensionEntry>[_b]);
    check(
      _resolve(_offer(const <ExtensionEntry>[_a, _b], previous: const <ExtensionEntry>[_b]), extensions: <String>{'a'}),
    ).isA<Picked>().has((Picked p) => p.extensions, 'extensions').deepEquals(<ExtensionEntry>[_a]);
  });

  test('named sources pick the extensions hosting them, or fail', () {
    check(_resolve(_offer(const <ExtensionEntry>[_a, _b]), sources: <String>{'b'}))
        .isA<Picked>()
        .has((Picked p) => p.extensions, 'extensions')
        .deepEquals(<ExtensionEntry>[_b]);
    check(_resolve(_offer(const <ExtensionEntry>[_a]), sources: <String>{'zz'}))
        .isA<Fail>()
        .has((Fail f) => f.reason, 'reason')
        .equals(ExtensionResolutionFailure.sourcesNotHosted);
  });

  test('named extensions match by ID and report the rest; none matched asks the user or fails', () {
    final ExtensionResolution some = _resolve(_offer(const <ExtensionEntry>[_a, _b]), extensions: <String>{'a', 'x'});
    check(some).isA<Picked>().has((Picked p) => p.extensions, 'extensions').deepEquals(<ExtensionEntry>[_a]);
    check(some.unmatched).deepEquals(<String>{'x'});
    check(_resolve(_offer(const <ExtensionEntry>[_a]), extensions: <String>{'x'}, canAskUser: true))
        .isA<NeedsUser>()
        .has((NeedsUser n) => n.unmatched, 'unmatched')
        .deepEquals(<String>{'x'});
    check(_resolve(_offer(const <ExtensionEntry>[_a]), extensions: <String>{'x'}))
        .isA<Fail>()
        .has((Fail f) => f.reason, 'reason')
        .equals(ExtensionResolutionFailure.extensionsNotFound);
  });

  test('with nothing named the user picks; an unattended run is never auto-picked', () {
    check(_resolve(_offer(const <ExtensionEntry>[_a]), canAskUser: true)).isA<NeedsUser>();
    check(_resolve(_offer(const <ExtensionEntry>[_a])))
        .isA<Fail>()
        .has((Fail f) => f.reason, 'reason')
        .equals(ExtensionResolutionFailure.nothingNamed);
  });
}
