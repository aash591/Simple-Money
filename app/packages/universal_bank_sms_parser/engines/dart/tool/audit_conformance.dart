import 'dart:convert';
import 'dart:io';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'project_data.dart';

/// Audit candidate parity before updating deterministic rule identities.
void main(List<String> args) {
  final engine = PortableSmsEngine(
    const RuleCompiler().compileSources(readCountrySources('../../rules')),
  );
  var errors = 0;
  var identities = 0;
  for (final file
      in Directory('../../tests/conformance')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))) {
    final rows = jsonDecode(file.readAsStringSync()) as List;
    for (final row in rows) {
      final input = row['input'];
      final actual = engine
          .parse(
            BankSms(
              sender: input['sender'],
              body: input['body'],
              receivedAt: DateTime.parse(input['receivedAt']),
            ),
          )
          .toJson();
      final expected = row['expected'] as Map;
      final differences = <dynamic, dynamic>{
        for (final key in expected.keys)
          if (key != 'ruleId' &&
              jsonEncode(expected[key]) != jsonEncode(actual[key]))
            key: [expected[key], actual[key]],
      };
      // Candidate object property order is not significant.
      if (differences.containsKey('candidate') &&
          expected['candidate'] != null &&
          actual['candidate'] != null) {
        final old = expected['candidate'] as Map;
        final now = actual['candidate'] as Map;
        final fields = {
          for (final key in old.keys)
            if (jsonEncode(old[key]) != jsonEncode(now[key]))
              key: [old[key], now[key]],
        };
        if (fields.isEmpty) {
          differences.remove('candidate');
        } else {
          differences['candidate'] = fields;
        }
      }
      if (differences.isNotEmpty) {
        errors++;
        stdout.writeln('${row['id']}: ${jsonEncode(differences)}');
        if (args.contains('--debug') &&
            actual['reason'] == 'ambiguousMatches') {
          for (final source in readCountrySources('../../rules')) {
            for (final bank in source['banks'] as List) {
              if (bank['id'] != row['bankId']) continue;
              for (final format in bank['formats'] as List) {
                final one = PortableSmsEngine(
                  const RuleCompiler().compileSources([
                    {
                      ...source,
                      'banks': [
                        <String, dynamic>{
                          ...bank,
                          'formats': [format],
                        },
                      ],
                    },
                  ]),
                );
                final found = one.parse(
                  BankSms(
                    sender: input['sender'],
                    body: input['body'],
                    receivedAt: DateTime.parse(input['receivedAt']),
                  ),
                );
                if (found.candidate != null) {
                  stdout.writeln(
                    '  ${format['id']}: ${jsonEncode(found.toJson()['candidate'])}',
                  );
                }
              }
            }
          }
        }
      } else if (expected['ruleId'] != actual['ruleId']) {
        identities++;
        if (args.contains('--update-identities')) {
          expected['ruleId'] = actual['ruleId'];
        }
      }
    }
    if (args.contains('--update-identities')) {
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(rows)}\n',
      );
    }
  }
  stdout.writeln('$errors mismatches; $identities rule identities.');
  if (errors > 0) exitCode = 1;
}
