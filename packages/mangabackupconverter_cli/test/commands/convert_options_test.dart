import 'package:checks/checks.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart';
import 'package:mangabackupconverter_cli/src/commands/convert_command.dart';
import 'package:mangabackupconverter_cli/src/commands/convert_options.dart';
import 'package:test/scaffolding.dart';

ConvertOptions _parse(List<String> args) => ConvertOptions.parse(ConvertCommand().argParser.parse(args));

void main() {
  test('parses the user choices without prompting or reading files', () {
    final ConvertOptions o = _parse(<String>[
      '--backup=in.tachibk',
      '--output-format=aidoku',
      '--repos=https://repo.invalid/index.json',
      '--extensions=a,b',
      '--sources=1',
      '--languages=en',
      '--tachi-handshake-deadline-ms=4000',
      '--confirm-adult',
      '--accept-partial',
    ]);
    check(o.backup).equals('in.tachibk');
    check(o.outputFormat).equals(const Aidoku());
    check(o.inputFormat).isNull();
    check(o.output).isNull();
    check(o.repos).deepEquals(<String>['https://repo.invalid/index.json']);
    check(o.extensionIds).deepEquals(<String>['a', 'b']);
    check(o.sourceIds).deepEquals(<String>{'1'});
    check(o.languagePolicy).isNotNull();
    check(o.tachiHandshakeDeadline).equals(const Duration(seconds: 4));
    check(o.ratingPolicy.allows(ContentRatingLevel.nsfw)).isTrue();
    check(o.acceptPartial).isTrue();
    check(o.fresh).isFalse();
  });

  test('malformed or contradictory values are format errors', () {
    check(() => _parse(<String>['--max-rating=nsfw'])).throws<FormatException>();
    check(() => _parse(<String>['--tachi-handshake-deadline-ms=0'])).throws<FormatException>();
    check(() => _parse(<String>['--trust-tachi-repo=not-a-pin'])).throws<FormatException>();
  });
}
