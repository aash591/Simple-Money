import 'dart:convert';
import 'dart:io';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:test/test.dart';

import '../tool/project_data.dart';

List<Map<String, dynamic>> sources() {
  final sources = readCountrySources('../../rules');
  // Tests that mutate one format use the original Bandhan pilot as their seed.
  final india = sources.firstWhere((s) => s['country'] == 'IN');
  final banks = india['banks'] as List;
  final bandhan = banks.firstWhere((b) => b['id'] == 'in.bandhan');
  banks.remove(bandhan);
  banks.insert(0, bandhan);
  // Tests that edit "the first source" mean India, whatever else is bundled.
  sources
    ..remove(india)
    ..insert(0, india);
  return sources;
}

void main() {
  const compiler = RuleCompiler();
  final pack = compiler.compileSources(sources());
  final engine = PortableSmsEngine(pack);
  test('Kotak A/c sent alert and Union credit with security footer', () {
    final debit = engine.parse(
      BankSms(
        sender: 'JX-KOTAKB-S',
        body:
            'Sent Rs.10.00 from Kotak Bank A/c X5678 to SAMPLE PERSON on '
            '26-10-26. UPI Ref 123456789012. Not done by you? Tap '
            'https://kotak.bank.in/KBANKT/Fraud',
        receivedAt: DateTime.utc(2026, 10, 26),
      ),
    );
    expect(debit.candidate, isNotNull);
    expect(debit.candidate!.amountMinor, 1000);
    expect(debit.candidate!.direction, SmsDirection.debit);
    expect(debit.candidate!.accountLast4, '5678');
    expect(debit.candidate!.counterparty, 'SAMPLE PERSON');
    expect(debit.candidate!.reference, '123456789012');
    final credit = engine.parse(
      BankSms(
        sender: 'JK-UNIONB-S',
        body:
            'A/c *1234 Credited for Rs:10.00 on 26-10-2026 18:32:18 by '
            'Mob Bk ref no 123456789012 Avl Bal Rs:1048.27.'
            'Never Share OTP/PIN/CVV-Union Bank of India',
        receivedAt: DateTime.utc(2026, 10, 26),
      ),
    );
    expect(credit.candidate, isNotNull);
    expect(credit.candidate!.amountMinor, 1000);
    expect(credit.candidate!.direction, SmsDirection.credit);
    expect(credit.candidate!.accountLast4, '1234');
    expect(credit.candidate!.counterparty, 'Mob Bk');
    expect(credit.candidate!.reference, '123456789012');
    expect(
      engine
          .parse(
            BankSms(
              sender: 'VK-KOTAKB-S',
              body:
                  'Request received for registering Kotak Bank a/c with Google Pay '
                  'on 26-10-26 18:31. Not you? Call on 18000000000. '
                  'Never share card details/OTP/Expiry.',
              receivedAt: DateTime.utc(2026, 10, 26),
            ),
          )
          .candidate,
      isNull,
    );
  });
  test(
    'Federal UPI alert identifies bank but leaves absent account unknown',
    () {
      final sms = BankSms(
        sender: 'VA-FEDBNK-S',
        body:
            'Rs 379.00 sent via UPI on 08-05-2026 at 10:49:44 to '
            'VODAFONE IDEA L.Ref:123456789012.Not you? Call '
            '18004251199/SMS BLOCKUPI to 98950 88888 -Federal Bank',
        receivedAt: DateTime.utc(2026, 5, 8),
      );
      final result = engine.parse(sms);
      expect(result.ruleId, 'in.federal.device002.sent');
      expect(result.candidate!.bankName, 'Federal Bank');
      expect(result.candidate!.accountLast4, isNull);
      expect(result.candidate!.amountMinor, 37900);
      expect(result.candidate!.direction, SmsDirection.debit);
    },
  );
  final cases = readConformanceCases('../../tests/conformance');
  final bankCase = cases.firstWhere((f) => f['id'] == 'bandhan-debit');
  test(
    'each distributed Indian bank pack parses its positive corpus alone',
    () {
      for (final file in Directory(
        '../../distribution/packs/india',
      ).listSync().whereType<File>()) {
        final runtime = compiler.loadRuntime(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
        );
        final bankId = runtime.toJson()['rules'][0]['bankId'];
        final bankEngine = PortableSmsEngine(runtime);
        final movements = cases.where(
          (f) => f['bankId'] == bankId && f['expected']['candidate'] != null,
        );
        expect(movements, isNotEmpty, reason: bankId);
        for (final fixture in movements) {
          final input = fixture['input'];
          expect(
            bankEngine
                .parse(
                  BankSms(
                    sender: input['sender'],
                    body: input['body'],
                    receivedAt: DateTime.parse(input['receivedAt']),
                  ),
                )
                .toJson(),
            fixture['expected'],
            reason: fixture['id'],
          );
        }
      }
    },
  );
  test(
    'split corpus preserves all cases and identifies each country and bank',
    () {
      expect(cases.where((f) => f['country'] == 'IN'), hasLength(1242));
      expect(cases.length, greaterThan(1249));
      expect(cases.map((f) => f['id']).toSet(), hasLength(cases.length));
      final banks = <String, String>{
        for (final source in sources())
          for (final bank in source['banks'] as List)
            bank['id'] as String: source['country'] as String,
      };
      expect(cases.map((f) => f['bankId']).toSet(), banks.keys.toSet());
      expect(banks.values.where((country) => country == 'IN'), hasLength(58));
      for (final fixture in cases) {
        expect(fixture['country'], banks[fixture['bankId']]);
      }
    },
  );
  test('merging packs rejects duplicate rules and mixed release versions', () {
    expect(
      () => compiler.mergeRuntimePacks([pack, pack]),
      throwsA(isA<RuleValidationException>()),
    );
    final nextSources = sources();
    for (final source in nextSources) {
      source['packVersion'] = 2;
    }
    final next = compiler.compileSources(nextSources);
    expect(
      () => compiler.mergeRuntimePacks([pack, next]),
      throwsA(isA<RuleValidationException>()),
    );
  });
  for (final fixture in cases) {
    test('portable conformance: ${fixture['id']}', () {
      final input = fixture['input'] as Map<String, dynamic>;
      final sms = BankSms(
        sender: input['sender'] as String,
        body: input['body'] as String,
        receivedAt: DateTime.parse(input['receivedAt'] as String),
      );
      final result = engine.parse(sms);
      expect(result.toJson(), fixture['expected']);
    });
  }
  test(
    'runtime compilation is deterministic and checked-in pack is current',
    () {
      expect(
        pack.toJson(),
        readRuntimePacks('../../distribution/packs').toJson(),
      );
      expect(
        compiler.compileSources(sources().reversed.toList()).toJson(),
        pack.toJson(),
      );
      expect(compiler.loadRuntime(pack.toJson()).toJson(), pack.toJson());
    },
  );
  test(
    'compiled snapshot cannot be mutated by its source or serialization',
    () {
      final input = sources();
      final snapshot = compiler.compileSources(input);
      input[0]['packVersion'] = 99;
      final exported = snapshot.toJson();
      exported['rules'].clear();
      expect(snapshot.packVersion, 1);
      expect(
        snapshot.toJson()['rules'],
        hasLength(pack.toJson()['rules'].length),
      );
    },
  );
  void invalid(String name, void Function(Map<String, dynamic>) mutate) {
    test('rejects $name before activation', () {
      final source = sources().first;
      mutate(source);
      expect(
        () => compiler.compileSources([source]),
        throwsA(isA<RuleValidationException>()),
      );
    });
  }

  Map<String, dynamic> firstFormat(Map<String, dynamic> s) =>
      s['banks'][0]['formats'][0] as Map<String, dynamic>;
  invalid('future schema', (s) => s['schemaVersion'] = '0.4');
  invalid('unsupported engine', (s) => s['minEngineVersion'] = '0.4.0');
  invalid(
    'sender override outside bank allowlist',
    (s) => firstFormat(s)['senders'] = ['UNKNOWN'],
  );
  invalid(
    'invalid account digit minimum',
    (s) => firstFormat(s)['tokens'][3]['minDigits'] = 0,
  );
  invalid(
    'nonterminal end operation',
    (s) => firstFormat(s)['tokens'][2] = {'op': 'match_end'},
  );
  invalid(
    'prefix on currency binding',
    (s) =>
        firstFormat(s)['output']['currency'] = {'value': 'INR', 'prefix': 'X'},
  );
  invalid(
    'short account flag with wrong type',
    (s) => firstFormat(s)['output']['accountLast4']['allowShort'] = 'true',
  );
  invalid(
    'metadata capture bound to transaction amount',
    (s) => firstFormat(s)['tokens'][1]['op'] = 'capture_number',
  );
  invalid('unrecognized source property', (s) => s['dartCode'] = 'print(1)');
  invalid(
    'unknown operation',
    (s) => firstFormat(s)['tokens'][1]['op'] = 'run_dart',
  );
  invalid(
    'unbounded capture',
    (s) => firstFormat(s)['tokens'][1]['maxLength'] = 0,
  );
  invalid(
    'undefined capture binding',
    (s) => firstFormat(s)['output']['amount']['capture'] = 'missing',
  );
  invalid(
    'invalid denomination multiplier',
    (s) => s['defaults']['denominations'] = {
      'bad': {'currency': 'INR', 'multiplier': 0},
    },
  );
  invalid('duplicate pattern', (s) {
    final copy = jsonDecode(jsonEncode(firstFormat(s))) as Map<String, dynamic>;
    copy['id'] = 'duplicate';
    s['banks'][0]['formats'].add(copy);
  });
  invalid(
    'duplicate rule ID',
    (s) => s['banks'][0]['formats'][1]['id'] = firstFormat(s)['id'],
  );
  invalid(
    'capture without a literal boundary',
    (s) => firstFormat(s)['tokens'][2] = {
      'op': 'capture_text',
      'name': 'extra',
      'maxLength': 20,
    },
  );
  test('downloaded sender indexes are validated', () {
    final data = pack.toJson();
    data['senderIndex']['UNTRUSTED'] = [0];
    expect(
      () => compiler.loadRuntime(data),
      throwsA(isA<RuleValidationException>()),
    );
  });
  test('runtime disagreement returns review without choosing an amount', () {
    final source = sources().first;
    final format = firstFormat(source);
    final copy = jsonDecode(jsonEncode(format)) as Map<String, dynamic>;
    copy['id'] = 'in.bandhan.other';
    copy['tokens'][0]['value'] = 'INR';
    copy['direction'] = 'credit';
    source['banks'][0]['formats'].add(copy);
    final conflict = PortableSmsEngine(compiler.compileSources([source]));
    final sms = bankCase['input'];
    final result = conflict.parse(
      BankSms(
        sender: sms['sender'],
        body: sms['body'],
        receivedAt: DateTime.utc(2026),
      ),
    );
    expect(result.reason, 'ambiguousMatches');
    expect(result.decision, SmsDecision.review);
    expect(result.candidate, isNull);
  });
  test('bank and format defaults override currency and number conventions', () {
    final source = sources().first;
    final format = firstFormat(source);
    source['banks'] = [source['banks'][0]];
    source['banks'][0]['formats'] = [format];
    source['banks'][0]['defaults'] = {
      'currency': 'USD',
      'exponents': {'USD': 2},
    };
    format['defaults'] = {
      'currency': 'EUR',
      'exponents': {'EUR': 2},
      'decimalMark': ',',
      'grouping': 'western',
    };
    final custom = PortableSmsEngine(compiler.compileSources([source]));
    final sms = bankCase['input'];
    final result = custom.parse(
      BankSms(
        sender: sms['sender'],
        body: (sms['body'] as String).replaceFirst('180.00', '1.234,50'),
        receivedAt: DateTime.utc(2026),
      ),
    );
    expect(result.candidate!.currencyCode, 'EUR');
    expect(result.candidate!.amountMinor, 123450);
  });
  test('safe integer overflow and work bounds never emit candidates', () {
    final body = bankCase['input']['body'] as String;
    for (final malformed in ['9007199254740992', '180.0000', '-180.00']) {
      final result = engine.parse(
        BankSms(
          sender: 'BDNSMS',
          body: body.replaceFirst('180.00', malformed),
          receivedAt: DateTime.utc(2026),
        ),
      );
      expect(result.candidate, isNull);
    }
    expect(
      engine
          .parse(
            BankSms(
              sender: 'BDNSMS',
              body: '${'INR ' * 17}$body',
              receivedAt: DateTime.utc(2026),
            ),
          )
          .reason,
      'workLimit',
    );
    expect(
      engine
          .parse(
            BankSms(
              sender: 'BDNSMS',
              body: 'x' * 4001,
              receivedAt: DateTime.utc(2026),
            ),
          )
          .reason,
      'invalidMessage',
    );
  });
  test('delimiter backtracking stops at the shared work budget', () {
    final source = sources().first;
    final bank = source['banks'][0] as Map<String, dynamic>;
    bank['formats'] = [
      <String, dynamic>{
        'id': 'in.bandhan.bounded',
        'classification': 'completed',
        'direction': 'debit',
        'channel': 'other',
        'tokens': [
          {'op': 'match_literal', 'value': 'Paid INR '},
          {'op': 'capture_money', 'name': 'amount', 'maxLength': 24},
          {'op': 'match_literal', 'value': ' at '},
          for (var i = 0; i < 6; i++) ...[
            {'op': 'capture_text', 'name': 'text$i', 'maxLength': 256},
            {'op': 'match_literal', 'value': i == 5 ? ' DONE' : ' '},
          ],
        ],
        'output': {
          'amount': {'capture': 'amount'},
        },
      },
    ];
    source['banks'] = [bank];
    final bounded = PortableSmsEngine(compiler.compileSources([source]));
    final result = bounded.parse(
      BankSms(
        sender: 'BDNSMS',
        body: 'Paid INR 321.09 at ${'word ' * 40}missing',
        receivedAt: DateTime.utc(2026),
      ),
    );
    expect(result.reason, 'workLimit');
    expect(result.candidate, isNull);
  });
  test('pack replacement can change a format without changing engine code', () {
    final input = sources();
    for (final source in input) {
      source['packVersion'] = 2;
    }
    firstFormat(input.first)['tokens'][2]['value'] = ' deducted from A/c ';
    final next = PortableSmsEngine(
      compiler.loadRuntime(compiler.compileSources(input).toJson()),
    );
    final body = (bankCase['input']['body'] as String).replaceFirst(
      'debited from',
      'deducted from',
    );
    final sms = BankSms(
      sender: 'BDNSMS',
      body: body,
      receivedAt: DateTime.utc(2026),
    );
    expect(engine.parse(sms).candidate, isNull);
    expect(next.parse(sms).candidate!.amountMinor, 18000);
    expect(next.parse(sms).packVersion, 2);
  });
}
