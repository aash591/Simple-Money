// Read SMS JSON lines from stdin. Prints sender family and parser decision only.
// Message text, amounts and account identifiers never leave this process.
import 'dart:convert';
import 'dart:io';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'package:simple_money/data/bank_sms_parser.dart';

Future<void> main(List<String> args) async {
  final perMessage = args.contains('--per-message');
  final categories = args.contains('--categories');
  const c = RuleCompiler();
  final dir = Directory(
    'packages/universal_bank_sms_parser/distribution/packs/india',
  );
  final packs = <RuntimeRulePack>[];
  for (final f in dir.listSync().whereType<File>()) {
    packs.add(
      c.loadRuntime(jsonDecode(await f.readAsString()) as Map<String, dynamic>),
    );
  }
  final pack = c.mergeRuntimePacks(packs);
  final engine = args.contains('--app-parser')
      ? BankSmsParser(pack)
      : PortableSmsEngine(pack);
  final counts = <String, int>{};
  var index = 0;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final input = jsonDecode(line) as Map<String, dynamic>;
    final sender = input['sender'] as String;
    final normalizedSender = normalizeRuleSender(sender);
    final family =
        normalizedSender != null &&
            RegExp(r'^[A-Z]{4,12}$').hasMatch(normalizedSender)
        ? normalizedSender
        : 'other';
    final result = engine.parse(
      BankSms(
        sender: sender,
        body: input['body'] as String,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          input['receivedAt'] as int,
        ),
      ),
    );
    if (perMessage) {
      stdout.writeln(
        jsonEncode({
          'index': index++,
          'family': family,
          'reason': result.reason,
          'ruleId': result.ruleId,
          if (categories) ...{
            'hasCandidate': result.candidate != null,
            'categoryId': result.candidate?.category?.id,
            'categoryName': result.candidate?.category?.name,
            'isFallback': result.candidate?.category?.isFallback,
            'hasCounterparty':
                result.candidate?.counterparty?.isNotEmpty == true,
            'direction': result.candidate?.direction.name,
          },
        }),
      );
      continue;
    }
    final key = '$family | ${result.reason} | ${result.ruleId ?? ''}';
    counts[key] = (counts[key] ?? 0) + 1;
  }
  if (perMessage) return;
  for (final entry
      in counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
    stdout.writeln('${entry.value} ${entry.key}');
  }
}
