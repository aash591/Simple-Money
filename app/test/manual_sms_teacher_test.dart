import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/manual_sms_teacher.dart';
import 'package:simple_money/data/user_sms_rules.dart';

BankSms _sms(String body, {String sender = 'VM-ZYXBNK-S'}) =>
    BankSms(sender: sender, body: body, receivedAt: DateTime(2026, 11, 22));

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory(), false));
  tearDown(() => db.close());

  const body =
      'Rs 2,476.00 debited from A/c XX1234 to ASIANET on 22-11-26. '
      'Not you? Call 1800. -Zyx Bank';

  test(
    'marked words become a saved rule, kept as an approved suggestion',
    () async {
      final read = await ManualSmsTeacher(db).teach(
        _sms(body),
        const SmsLabels(
          amount: '2,476.00',
          account: 'XX1234',
          payee: 'ASIANET',
          moneyOut: true,
          currency: 'INR',
        ),
        others: [
          _sms(
            body.replaceAll('2,476.00', '310.50').replaceAll('ASIANET', 'KSEB'),
          ),
          _sms('Your OTP is 123456. -Zyx Bank'),
        ],
      );
      // This one and the other payment of the same shape; not the OTP.
      expect(read, 2);
      final rules = await UserSmsRuleRepository(db).load();
      expect(rules, hasLength(1));
      expect(rules.single.senders, ['ZYXBNK']);

      // Kept with Undo in Suggestions, marked as taught by the person.
      final kept = await AgentSuggestionRepository(db).load();
      expect(kept.single.status, AgentSuggestionStatus.applied);
      expect(kept.single.source, ManualSmsTeacher.source);
      expect(kept.single.canUndo, isTrue);
    },
  );

  test('a mark that isn’t in the message says so plainly', () async {
    await expectLater(
      ManualSmsTeacher(db).teach(
        _sms(body),
        const SmsLabels(amount: '999', moneyOut: true, currency: 'INR'),
      ),
      throwsA(
        isA<SmsTeachException>().having(
          (e) => e.message,
          'message',
          contains('isn’t in the message'),
        ),
      ),
    );
    expect(await UserSmsRuleRepository(db).load(), isEmpty);
  });

  test('a biller’s payment message is taught', () async {
    final read = await ManualSmsTeacher(db).teach(
      _sms(
        'Dear Customer(1002088293),Pay Online Rs 2476/- to Asianet using '
        'https://myasianet.in/quick-pay',
        sender: 'AD-ASIANT-S',
      ),
      const SmsLabels(
        amount: '2476',
        payee: 'Asianet',
        moneyOut: true,
        currency: 'INR',
      ),
    );
    expect(read, 1);
  });

  test(
    'a message that says nothing about what it was for isn’t saved',
    () async {
      await expectLater(
        ManualSmsTeacher(db).teach(
          _sms(
            'Hi, Rs 300 sent to Raju via app. Thanks',
            sender: 'AD-RAJUXX-S',
          ),
          const SmsLabels(
            amount: '300',
            payee: 'Raju',
            moneyOut: true,
            currency: 'INR',
          ),
        ),
        throwsA(
          isA<SmsTeachException>().having(
            (e) => e.message,
            'message',
            contains('what the money was for'),
          ),
        ),
      );
      expect(await UserSmsRuleRepository(db).load(), isEmpty);
    },
  );

  test('a shop’s refund is taught, filed under Refunds in India', () async {
    // The rupee is also Bhutan's: the rule must still be India's.
    expect(ManualSmsTeacher.countryOfForTest('INR', region: 'US'), 'IN');
    expect(ManualSmsTeacher.countryOfForTest('INR', region: 'BT'), 'BT');
    final read = await ManualSmsTeacher(db).teach(
      _sms(
        'Refund for Ghee of Rs.216 is successfully processed to your '
        'Original Payment Source. Meesho',
        sender: 'JK-MESHO-S',
      ),
      const SmsLabels(
        amount: '216',
        payee: 'Meesho',
        moneyOut: false,
        currency: 'INR',
      ),
    );
    expect(read, 1);
    final rules = await UserSmsRuleRepository(db).load();
    expect(rules.single.format['country'], 'IN');
    expect(rules.single.bankName, 'Meesho');
  });

  test('a message with line breaks and odd spaces is still taught', () async {
    // As real phone SMS often arrive: a line break, a double space, and a
    // non-breaking space. The engine reads each of these as one space.
    final read = await ManualSmsTeacher(db).teach(
      _sms(
        'Refund for Ghee of Rs.216 is successfully\nprocessed  to your '
        'Original\u00a0Payment Source. Meesho',
        sender: 'JK-MESHO-S',
      ),
      const SmsLabels(
        amount: '216',
        payee: 'Meesho',
        moneyOut: false,
        currency: 'INR',
      ),
    );
    expect(read, 1);
  });

  test('a payee marked across a line break is found', () async {
    final read = await ManualSmsTeacher(db).teach(
      _sms(
        'Rs 2,476.00 debited from A/c XX1234 to ASIANET\nBROADBAND on '
        '22-11-26. -Zyx Bank',
      ),
      const SmsLabels(
        amount: '2,476.00',
        account: 'XX1234',
        // The sheet joins marked words with whatever separated them.
        payee: 'ASIANET\nBROADBAND',
        moneyOut: true,
        currency: 'INR',
      ),
    );
    expect(read, 1);
  });
}
