// Bank SMS from any country: spotted as missed so an AI can teach them,
// taught with the country's currency and number style, and read in one
// engine beside the user's banks elsewhere.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/agent/sms_labeler.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/reportable_sms.dart';
import 'package:simple_money/data/sms_amounts.dart';
import 'package:simple_money/domain/currency_digits.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

const _uae =
    'Your Cr.Card XXX1234 was used for AED 120.50 at CARREFOUR MOE on '
    '03/11/2026. Avl limit AED 9,879.50';
const _uaeAgain =
    'Your Cr.Card XXX1234 was used for AED 45.00 at ENOC on 04/11/2026. '
    'Avl limit AED 9,834.50';
const _colombia =
    'Bancolombia le informa Compra por \$50.000 en EXITO COLOMBIA 03/11/2026 '
    'T.Cred *4321';
const _colombiaAgain =
    'Bancolombia le informa Compra por \$1.250.000 en FALABELLA 04/11/2026 '
    'T.Cred *4321';

PortableParseResult _unread() => const PortableParseResult(
  classification: RuleClassification.unknown,
  decision: SmsDecision.ignored,
  reason: 'unregisteredSender',
  packVersion: 1,
);

bool _missed(String sender, String body) => looksLikeMissedTransaction(
  BankSms(sender: sender, body: body, receivedAt: DateTime(2026, 11)),
  _unread(),
);

void main() {
  test('The currency table is the asset’s', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final rows = jsonDecode(
      await rootBundle.loadString('assets/data/currencies.json'),
    ) as List;
    for (final row in rows) {
      expect(
        currencyDigits(row['code'] as String),
        row['digits'],
        reason: '${row['code']}',
      );
      expect(knownCurrencyCodes, contains(row['code']));
      expect(currencyTerritories[row['code']], contains(row['territory']));
    }
  });

  group('Number style from a copied amount', () {
    test('dot or comma decimals, and grouping', () {
      expect(numberStyle('1,250.00', 'INR'), containsPair('decimalMark', '.'));
      expect(numberStyle('1.250,00', 'EUR'), containsPair('decimalMark', ','));
      expect(numberStyle('50.000', 'COP'), containsPair('decimalMark', ','));
      expect(numberStyle('1.250', 'KWD'), containsPair('decimalMark', '.'));
      expect(
        numberStyle('1,25,000.00', 'INR'),
        containsPair('grouping', 'indian'),
      );
      expect(
        numberStyle('125,000.00', 'USD'),
        containsPair('grouping', 'western'),
      );
    });

    test('digits in other scripts', () {
      expect(
        numberStyle('۱۲۵۰۰۰', 'IRR')['digits'],
        containsAll(['ascii', 'persian']),
      );
      expect(
        numberStyle('๑,๒๕๐.๐๐', 'THB')['digits'],
        containsAll(['ascii', 'thai']),
      );
    });
  });

  test('Rule amounts become the app’s', () {
    // ¥1,200.00 reads as 120000 at two decimals; the app keeps yen whole.
    expect(smsAmountToApp(120000, 'JPY'), 1200);
    expect(smsAmountToApp(120050, 'JPY'), 1201);
    expect(smsAmountToApp(1250, 'KWD'), 1250);
    expect(smsAmountToApp(12050, 'INR'), 12050);
    expect(smsRuleAmountText(1250, 'KWD'), '1.250');
    expect(smsRuleAmountText(12050, 'AED'), '120.50');
  });

  group('A missed bank SMS from', () {
    test('the UAE, Colombia, Kenya and the US is listed', () {
      expect(_missed('AD-ADCBNK', _uae), isTrue);
      expect(_missed('85540', _colombia), isTrue);
      expect(
        _missed(
          'MPESA',
          'QK12AB34 Confirmed. Ksh1,000.00 sent to JOHN DOE on 3/11/26.',
        ),
        isTrue,
      );
      expect(
        _missed('33789', 'Chase: You made a \$45.20 transaction with AMAZON.'),
        isTrue,
      );
      expect(
        _missed('AD-HDFCBK', 'Rs.500.00 debited from A/c XX1234 to SWIGGY.'),
        isTrue,
      );
    });

    test('a person, an OTP or an offer is not', () {
      expect(_missed('+971501234567', _uae), isFalse);
      expect(
        _missed('AD-ADCBNK', 'Your OTP for AED 120.50 at CARREFOUR is 4411.'),
        isFalse,
      );
      expect(
        _missed('AD-ADCBNK', 'Apply now and get AED 500 cashback offer.'),
        isFalse,
      );
    });
  });

  group('Teaching banks in several countries', () {
    late AppDatabase db;
    late AgentTools tools;
    var inbox = <(String, String)>[];

    Future<Map<String, Object?>> call(
      String name, [
      Map<String, Object?> args = const {},
    ]) async {
      final result = await tools.call(name, args);
      final text =
          ((result['content'] as List).single as Map)['text'] as String;
      if (result['isError'] == true) return {'error': text};
      return Map<String, Object?>.from(jsonDecode(text) as Map);
    }

    Future<String> idOf(String body) async {
      final listed = await call('list_missed_sms');
      return ((listed['messages'] as List).cast<Map>().firstWhere(
            (m) => m['text'] == body,
          ))['id']
          as String;
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase(NativeDatabase.memory());
      tools = AgentTools(
        db,
        missedSms: (window) async => [
          for (final (i, (sender, body)) in inbox.indexed)
            ReportableSms(
              '$i',
              BankSms(
                sender: sender,
                body: body,
                receivedAt: DateTime(2026, 10, 20 + i),
              ),
              ReportableKind.missed,
              'unregisteredSender',
              null,
            ),
        ],
      );
    });
    tearDown(() => db.close());

    Future<void> approveAll() async {
      final repo = AgentSuggestionRepository(db);
      for (final s in await repo.load()) {
        expect(await repo.apply(s.id), isNull);
      }
    }

    test('a UAE card reads dirhams for the UAE', () async {
      inbox = [('AD-ADCBNK', _uae), ('AD-ADCBNK', _uaeAgain)];
      final taught = await call('label_sms', {
        'sms_id': await idOf(_uae),
        'amount': '120.50',
        'account': 'XXX1234',
        'payee': 'CARREFOUR MOE',
        'direction': 'debit',
        'channel': 'card',
        'sender_type': 'card',
        'country': 'AE',
        'currency': 'AED',
        'bank_name': 'ADCB',
      });
      expect(taught['suggested'], isTrue, reason: '$taught');
      expect(taught['read_by_this_rule'], 2);
      expect(
        taught['read_from_this_sms'],
        allOf(
          containsPair('amount', '120.50'),
          containsPair('currency', 'AED'),
        ),
      );
      await approveAll();
      final read = (await loadSmsEngine(db)).parse(
        BankSms(
          sender: 'AD-ADCBNK',
          body: _uaeAgain,
          receivedAt: DateTime(2026),
        ),
      );
      expect(read.candidate?.currencyCode, 'AED');
      expect(read.candidate?.countryCode, 'AE');
      expect(read.candidate?.amountMinor, 4500);
    });

    test('a Colombian card with dot grouping, beside an Indian bank', () async {
      inbox = [
        ('85540', _colombia),
        ('85540', _colombiaAgain),
        (
          'AD-ZETAPY',
          'Paid Rs.89.00 to Metro Rail from Zeta card XX4321. -Zeta',
        ),
      ];
      final colombia = await call('label_sms', {
        'sms_id': await idOf(_colombia),
        'amount': '50.000',
        'account': '4321',
        'payee': 'EXITO COLOMBIA',
        'direction': 'debit',
        'channel': 'card',
        'sender_type': 'card',
        'country': 'CO',
        'currency': 'COP',
        'bank_name': 'Bancolombia',
      });
      expect(colombia['suggested'], isTrue, reason: '$colombia');
      expect(colombia['read_by_this_rule'], 2);
      final india = await call('label_sms', {
        'sms_id': await idOf(
          'Paid Rs.89.00 to Metro Rail from Zeta card XX4321. -Zeta',
        ),
        'amount': '89.00',
        'account': 'XX4321',
        'payee': 'Metro Rail',
        'direction': 'debit',
        'channel': 'card',
        'sender_type': 'card',
        'country': 'IN',
        'currency': 'INR',
        'bank_name': 'Zeta',
      });
      expect(india['suggested'], isTrue, reason: '$india');
      await approveAll();

      final engine = await loadSmsEngine(db);
      final big = engine.parse(
        BankSms(
          sender: '85540',
          body: _colombiaAgain,
          receivedAt: DateTime(2026),
        ),
      );
      expect(big.candidate?.currencyCode, 'COP');
      expect(big.candidate?.countryCode, 'CO');
      // 1.250.000 pesos at two rule decimals; the app keeps pesos whole.
      expect(smsAmountToApp(big.candidate!.amountMinor, 'COP'), 1250000);
      final zeta = engine.parse(
        BankSms(
          sender: 'AD-ZETAPY',
          body: 'Paid Rs.1,250.00 to Blue Tokai from Zeta card XX4321. -Zeta',
          receivedAt: DateTime(2026),
        ),
      );
      expect(zeta.candidate?.currencyCode, 'INR');
      expect(zeta.candidate?.amountMinor, 125000);
    });

    test('needs the country and currency', () async {
      inbox = [('AD-ADCBNK', _uae)];
      final taught = await call('label_sms', {
        'sms_id': await idOf(_uae),
        'amount': '120.50',
        'direction': 'debit',
        'channel': 'card',
        'sender_type': 'card',
      });
      expect(taught['error'], contains('country'));
    });
  });
}
