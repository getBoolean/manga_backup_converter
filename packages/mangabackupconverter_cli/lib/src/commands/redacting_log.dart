import 'package:source_runtime/source_runtime.dart';

/// The CLI log sink. Every line — zone-captured `print`s from plugins and
/// the pipeline, worker/helper stderr, and HTTP/browser traces — passes
/// through one session [Redactor] before it is written (KTD9).
class RedactingLog {
  RedactingLog(this._sink, {Redactor? redactor}) : redactor = redactor ?? Redactor();

  final StringSink? _sink;
  final Redactor redactor;

  /// Whether lines are written anywhere.
  bool get isMounted => _sink != null && !_closed;
  bool _closed = false;

  /// Writes one redacted line.
  void writeln(String line) {
    if (!isMounted) return;
    _sink!.writeln(redactor.redact(line));
  }

  /// A byte-stream sink (for worker or helper stderr) that splits complete
  /// lines, redacts them, and writes them here.
  RedactingLineSink lineSink() => RedactingLineSink(redactor, writeln);

  /// Registers the secret values of a source's settings.
  void addSecrets(SettingsSnapshot settings) => settings.secrets.values.forEach(redactor.addSecret);

  /// Stops writing (the underlying sink is closed by its owner).
  void unmount() => _closed = true;
}
