import 'dart:convert';
import 'dart:io';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'project_data.dart';

/// dart run tool/compile_rules.dart OUTPUT_DIRECTORY RULES_DIRECTORY
/// Reproducible output: no timestamps, network, signatures, or host paths.
void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/compile_rules.dart OUTPUT_DIRECTORY RULES_DIRECTORY',
    );
    exitCode = 64;
    return;
  }
  try {
    final countries =
        Directory(args[1]).listSync().whereType<Directory>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    var count = 0;
    for (final country in countries) {
      if (!File.fromUri(country.uri.resolve('country.json')).existsSync()) {
        continue;
      }
      final source = readCountrySources(country.path).single;
      for (final bank in source['banks'] as List) {
        final pack = const RuleCompiler().compileSources([
          {
            ...source,
            'banks': [bank],
          },
        ]);
        final countryName = country.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;
        final bankName = (bank['id'] as String).split('.').last;
        if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(bankName)) {
          throw const FormatException(
            'Bank ID needs a filesystem-safe final segment',
          );
        }
        final output = File('${args[0]}/$countryName/$bankName.json');
        output.parent.createSync(recursive: true);
        output.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(pack.toJson())}\n',
        );
        count++;
      }
    }
    if (count == 0) throw const FormatException('No bank sources found');
    stdout.writeln('Compiled $count country/bank runtime packs.');
  } on RuleValidationException catch (error) {
    stderr.writeln(error);
    exitCode = 65;
  } on FormatException catch (error) {
    stderr.writeln(error);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 74;
  }
}
