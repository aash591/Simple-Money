// Local, aggregate-only verification; never prints message bodies or identifiers.
// flutter test tool/check_sms_snapshot_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  test('compare host parser with portable rules on all local device snapshots', () {
    const compiler = RuleCompiler();
    final pack = compiler.mergeRuntimePacks([
      for (final file in Directory(
        'packages/universal_bank_sms_parser/distribution/packs/india',
      ).listSync().whereType<File>())
        compiler.loadRuntime(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
        ),
    ]);
    final portable = PortableSmsEngine(pack);
    final host = BankSmsParser(pack);
    final sources =
        Directory('../artifacts/sms')
            .listSync()
            .whereType<Directory>()
            .map((d) {
              final all = File('${d.path}/all_sms.jsonl');
              return all.existsSync() ? all : File('${d.path}/inbox.jsonl');
            })
            .where((f) => f.existsSync())
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(sources, isNotEmpty);
    for (final source in sources) {
      var total = 0,
          baseline = 0,
          detected = 0,
          cards = 0,
          balances = 0,
          limits = 0;
      for (final line in source.readAsLinesSync()) {
        final row = jsonDecode(line) as Map<String, dynamic>;
        final sms = BankSms(
          sender: (row['address'] ?? row['sender']) as String,
          body: row['body'] as String,
          receivedAt: DateTime.fromMillisecondsSinceEpoch(
            (row['dateMs'] ?? row['receivedAtMs']) as int,
          ),
        );
        final original = portable.parse(sms);
        final result = host.parse(sms);
        total++;
        if (original.candidate != null) {
          baseline++;
          expect(
            result.candidate?.amountMinor,
            original.candidate!.amountMinor,
          );
        }
        if (result.candidate != null) {
          detected++;
          if (smsMetadata(sms.body, sender: sms.sender)['isCreditCard'] ==
              true) {
            cards++;
          }
        }
        final snapshot = host.balanceSnapshot(sms);
        if (snapshot?['balanceMinor'] != null) balances++;
        if (snapshot?['availableCreditLimitMinor'] != null) limits++;
      }
      expect(detected, greaterThanOrEqualTo(baseline));
      // ignore: avoid_print
      print(
        '${source.parent.path.split(Platform.pathSeparator).last}: SMS: $total; portable transactions: $baseline; host transactions: $detected; card transactions: $cards; balance reports: $balances; limit reports: $limits',
      );
    }
  });
}
