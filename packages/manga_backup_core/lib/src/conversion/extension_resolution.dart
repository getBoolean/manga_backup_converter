import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:manga_backup_core/src/conversion/extension_settings.dart';
import 'package:manga_backup_core/src/conversion/selection_port.dart';

/// How a host answers a [SourceSelectionRequest] from the user's named
/// extensions and sources (the rules every host shares; nothing is ever
/// picked automatically).
sealed class ExtensionResolution {
  const ExtensionResolution({this.unmatched = const <String>{}});

  /// Named extension IDs that were not offered (missing from the
  /// repositories, or hidden by the rating policy); hosts warn about them.
  final Set<String> unmatched;
}

/// Use [extensions].
final class Picked extends ExtensionResolution {
  const Picked(this.extensions, {super.unmatched});

  final List<ExtensionEntry> extensions;
}

/// The user must pick from the offered extensions (a selection screen).
final class NeedsUser extends ExtensionResolution {
  const NeedsUser({super.unmatched});
}

/// Why no extensions can be picked.
enum ExtensionResolutionFailure {
  /// The repositories offered nothing at the selected content rating.
  nothingOffered,

  /// The named sources are hosted by no offered extension.
  sourcesNotHosted,

  /// None of the named extensions is offered.
  extensionsNotFound,

  /// Nothing was named and there is no one to ask.
  nothingNamed,
}

/// No extensions can be picked, for [reason].
final class Fail extends ExtensionResolution {
  const Fail(this.reason, {super.unmatched});

  final ExtensionResolutionFailure reason;
}

/// Resolves [request] against the user's named [extensionIds] and
/// [sourceIds]. [canAskUser] says whether a selection screen exists.
///
/// In order: nothing offered fails; a resumed conversion reuses its
/// journaled selection unless the user named something; named sources alone
/// pick the extensions hosting them; named extensions are matched by ID
/// (matching runs on the offered, rating-filtered list, so a hidden source
/// cannot be named), falling back to the user when none matched; otherwise
/// the user picks, and an unattended run fails.
ExtensionResolution resolveExtensions(
  SourceSelectionRequest request, {
  required Set<String> extensionIds,
  required Set<String> sourceIds,
  required bool canAskUser,
}) {
  final List<ExtensionEntry> offered = request.available;
  if (offered.isEmpty) return const Fail(ExtensionResolutionFailure.nothingOffered);
  if (extensionIds.isEmpty && sourceIds.isEmpty && request.previousSelection.isNotEmpty) {
    return Picked(request.previousSelection);
  }
  if (extensionIds.isEmpty && sourceIds.isNotEmpty) {
    final List<ExtensionEntry> hosting = offered
        .where((ExtensionEntry e) => sourceIds.any((String id) => entryHostsSource(e, id)))
        .toList();
    return hosting.isEmpty ? const Fail(ExtensionResolutionFailure.sourcesNotHosted) : Picked(hosting);
  }
  if (extensionIds.isNotEmpty) {
    final List<ExtensionEntry> matched = offered.where((ExtensionEntry e) => extensionIds.contains(e.id)).toList();
    final Set<String> unmatched = extensionIds.difference(matched.map((ExtensionEntry e) => e.id).toSet());
    if (matched.isNotEmpty) return Picked(matched, unmatched: unmatched);
    return canAskUser
        ? NeedsUser(unmatched: unmatched)
        : Fail(ExtensionResolutionFailure.extensionsNotFound, unmatched: unmatched);
  }
  return canAskUser ? const NeedsUser() : const Fail(ExtensionResolutionFailure.nothingNamed);
}
