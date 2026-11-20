import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:source_runtime/source_contracts.dart';

/// What kind of input record a [ReportEntry] accounts for (KTD8).
enum RecordKind {
  /// A selected library manga.
  manga,

  /// A source chapter carrying reading state.
  chapterState,

  /// A history entry that could not be tied to a chapter.
  history,

  /// A tracking record.
  tracking,

  /// A field the destination format cannot carry (for example a bookmark).
  field,
}

/// How a record was accounted for. Every input record ends in exactly one.
enum RecordDisposition {
  /// Carried into the destination backup.
  transferred,

  /// Left out by an explicit user decision.
  excluded,

  /// The destination format cannot represent it.
  unrepresentable,

  /// No defensible destination exists (no match, ambiguity, collision, or a
  /// runtime failure); nothing was guessed.
  unresolved,
}

/// One accounted-for input record.
final class ReportEntry {
  const ReportEntry({
    required this.kind,
    required this.disposition,
    required this.manga,
    required this.subject,
    this.reason,
  });

  factory ReportEntry.fromJson(Map<String, Object?> json) => ReportEntry(
    kind: RecordKind.values.byName(json['kind']! as String),
    disposition: RecordDisposition.values.byName(json['disposition']! as String),
    manga: json['manga']! as String,
    subject: json['subject']! as String,
    reason: json['reason'] as String?,
  );

  final RecordKind kind;
  final RecordDisposition disposition;

  /// Title of the manga the record belongs to.
  final String manga;

  /// Human-readable label of the record (chapter label, tracker, field name).
  final String subject;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'disposition': disposition.name,
    'manga': manga,
    'subject': subject,
    'reason': reason,
  };
}

/// [failure] with its message passed through [redact]; the code and, for a
/// capability failure, the named operation are kept.
SourceFailure redactFailure(SourceFailure failure, String Function(String) redact) => SourceFailure.fromWire(
  failure.code,
  redact(failure.message),
  operation: failure is CapabilityUnavailableFailure ? failure.operation : null,
);

/// Where in the conversion a source failure happened.
enum FailureStage { load, search, details }

/// A load, search, or detail failure from one source, kept until the final
/// report even when another source succeeded (U1 step 6).
final class SourceFailureRecord {
  const SourceFailureRecord({
    required this.stage,
    required this.sourceId,
    required this.code,
    required this.message,
    this.manga,
  });

  factory SourceFailureRecord.fromFailure(
    FailureStage stage,
    String sourceId,
    SourceFailure failure, {
    String? manga,
    String Function(String)? redact,
  }) => SourceFailureRecord(
    stage: stage,
    sourceId: sourceId,
    code: failure.code,
    message: redact == null ? failure.message : redact(failure.message),
    manga: manga,
  );

  factory SourceFailureRecord.fromJson(Map<String, Object?> json) => SourceFailureRecord(
    stage: FailureStage.values.byName(json['stage']! as String),
    sourceId: json['sourceId']! as String,
    code: json['code']! as String,
    message: json['message']! as String,
    manga: json['manga'] as String?,
  );

  final FailureStage stage;
  final String sourceId;

  /// Stable [SourceFailure.code].
  final String code;
  final String message;

  /// Title of the manga being searched or fetched, when there is one.
  final String? manga;

  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage.name,
    'sourceId': sourceId,
    'code': code,
    'message': message,
    'manga': manga,
  };

  @override
  String toString() => '${stage.name} $sourceId${manga == null ? '' : ' ($manga)'}: $code: $message';
}

/// Complete accounting of a conversion (KTD8): every selected manga, every
/// state-bearing source chapter, history entry, tracking record, and
/// unsupported field ends as transferred, excluded, unrepresentable, or
/// unresolved; plus every source failure and user decision.
class ConversionReport {
  final List<ReportEntry> entries = <ReportEntry>[];
  final List<SourceFailureRecord> failures = <SourceFailureRecord>[];

  /// User decisions taken during the conversion (chapter assignments,
  /// exclusions, partial acceptance), in order.
  final List<String> decisions = <String>[];

  /// Output-format constraints that changed how data is written without
  /// losing a record (for example several scanlators joined into one field).
  final List<String> notes = <String>[];

  void add(RecordKind kind, RecordDisposition disposition, String manga, String subject, {String? reason}) =>
      entries.add(ReportEntry(kind: kind, disposition: disposition, manga: manga, subject: subject, reason: reason));

  /// Whether anything was not transferred for a reason other than an
  /// explicit user exclusion. A partial conversion needs explicit acceptance.
  bool get isPartial => entries.any(
    (ReportEntry e) =>
        e.disposition == RecordDisposition.unresolved || e.disposition == RecordDisposition.unrepresentable,
  );

  /// Entry counts per kind and disposition.
  Map<RecordKind, Map<RecordDisposition, int>> get counts {
    final result = <RecordKind, Map<RecordDisposition, int>>{
      for (final RecordKind k in RecordKind.values)
        k: <RecordDisposition, int>{for (final RecordDisposition d in RecordDisposition.values) d: 0},
    };
    for (final ReportEntry e in entries) {
      result[e.kind]![e.disposition] = result[e.kind]![e.disposition]! + 1;
    }
    return result;
  }

  int count(RecordKind kind, [RecordDisposition? disposition]) =>
      entries.where((ReportEntry e) => e.kind == kind && (disposition == null || e.disposition == disposition)).length;

  Iterable<ReportEntry> where(RecordKind kind, RecordDisposition disposition) =>
      entries.where((ReportEntry e) => e.kind == kind && e.disposition == disposition);

  Map<String, Object?> toJson() => <String, Object?>{
    'entries': <Map<String, Object?>>[for (final ReportEntry e in entries) e.toJson()],
    'failures': <Map<String, Object?>>[for (final SourceFailureRecord f in failures) f.toJson()],
    'decisions': decisions,
    'notes': notes,
  };

  /// Digest of the accounting (entries and failures), used to tie a journaled
  /// partial-conversion acceptance to the exact report that was accepted.
  String get digest => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'entries': <Map<String, Object?>>[for (final ReportEntry e in entries) e.toJson()],
            'failures': <Map<String, Object?>>[for (final SourceFailureRecord f in failures) f.toJson()],
          }),
        ),
      )
      .toString();

  /// Human-readable lines (no trailing newlines, no ANSI).
  List<String> describe() {
    if (entries.isEmpty && failures.isEmpty && notes.isEmpty) return const <String>[];
    final lines = <String>['Conversion report:'];
    final Map<RecordKind, Map<RecordDisposition, int>> c = counts;
    for (final RecordKind kind in RecordKind.values) {
      final Map<RecordDisposition, int> byDisposition = c[kind]!;
      final int total = byDisposition.values.fold(0, (int a, int b) => a + b);
      if (total == 0) continue;
      final String parts = <String>[
        for (final RecordDisposition d in RecordDisposition.values)
          if (byDisposition[d]! > 0) '${byDisposition[d]} ${d.name}',
      ].join(', ');
      lines.add('  ${_kindLabel(kind)}: $parts');
    }
    final List<ReportEntry> notTransferred = entries
        .where((ReportEntry e) => e.disposition != RecordDisposition.transferred)
        .toList();
    String? currentManga;
    for (final e in notTransferred) {
      if (e.manga != currentManga) {
        currentManga = e.manga;
        lines.add('  ${e.manga}:');
      }
      lines.add('    - [${e.disposition.name}] ${e.subject}${e.reason == null ? '' : ': ${e.reason}'}');
    }
    if (failures.isNotEmpty) {
      lines.add('  Source failures:');
      for (final SourceFailureRecord f in failures) {
        lines.add('    - $f');
      }
    }
    if (decisions.isNotEmpty) {
      lines.add('  Decisions:');
      for (final String d in decisions) {
        lines.add('    - $d');
      }
    }
    if (notes.isNotEmpty) {
      lines.add('  Format notes:');
      for (final String n in notes) {
        lines.add('    - $n');
      }
    }
    return lines;
  }

  static String _kindLabel(RecordKind kind) => switch (kind) {
    RecordKind.manga => 'Manga',
    RecordKind.chapterState => 'Chapters with reading state',
    RecordKind.history => 'Unlinked history entries',
    RecordKind.tracking => 'Tracking records',
    RecordKind.field => 'Unsupported fields',
  };
}
