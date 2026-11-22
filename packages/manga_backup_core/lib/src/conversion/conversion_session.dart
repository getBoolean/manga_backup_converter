import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/conversion_journal.dart';
import 'package:manga_backup_core/src/conversion/extension_settings.dart';
import 'package:manga_backup_core/src/conversion/selection_port.dart';
import 'package:manga_backup_core/src/conversion/source_language_policy.dart';
import 'package:manga_backup_core/src/conversion/source_rating_policy.dart';

/// The collaborators of one conversion run: the user's decisions, the job's
/// journal, the run's policies and its progress reporting. The host-lifetime
/// parts (registries, trust store, redactor, runtime scope adoption) live on
/// the `ConversionJob`.
final class ConversionSession {
  const ConversionSession({
    required this.selection,
    this.onProgress = _noProgress,
    this.journalStore,
    this.ratingPolicy = const SourceRatingPolicy(),
    this.languagePolicy,
    this.settingsFor = noExtensionSettings,
    this.onResume,
    this.onDecoded,
  });

  /// The user's decisions (source selection, matches, trust, chapters,
  /// partial acceptance).
  final SelectionPort selection;
  final void Function(int current, int total, String message) onProgress;

  /// Persists the conversion journal; `null` disables journaling.
  final JournalStore? journalStore;
  final SourceRatingPolicy ratingPolicy;

  /// Narrows sources by language; `null` infers the languages from the input
  /// backup ([SourceLanguagePolicy.inferredFrom]).
  final SourceLanguagePolicy? languagePolicy;

  /// The user's extension settings, handed to the destination runtime.
  final ExtensionSettingsProvider settingsFor;

  /// Called when a journal for the same input is resumed, with the number of
  /// journaled manga decisions (hosts tell the user and offer a fresh start).
  final void Function(int decisions)? onResume;

  /// Called with the decoded input before conversion (diagnostics).
  final void Function(ConvertableBackup input)? onDecoded;

  static void _noProgress(int current, int total, String message) {}
}
