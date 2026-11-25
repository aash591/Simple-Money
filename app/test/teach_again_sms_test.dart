// Teaching an SMS a rule already reads: the new marks replace that rule,
// they don't fail against it.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/manual_sms_teacher.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  test(
    'marking a message again replaces the rule that already reads it',
    () async {
      final db = AppDatabase(NativeDatabase.memory(), false);
      addTearDown(db.close);
      final sms = BankSms(
        sender: 'JD-UNIONB-S',
        body:
            'Union Bank of India A/c*3225 Dr Rs10.00 on 23-11-26 16:40 by MB '
            '632713749490 Fv.ASHIQ, Bal Rs19949.27 Not U?Call 18002333/SMS '
            'BLOCK 3225 to 8879635472',
        receivedAt: DateTime(2026, 11, 23, 16, 40),
      );
      // Taught before, with the amount and account only.
      await ManualSmsTeacher(db).teach(
        sms,
        const SmsLabels(
          amount: '10.00',
          account: '3225',
          moneyOut: true,
          currency: 'INR',
        ),
      );
      final rules = UserSmsRuleRepository(db);
      final first = (await rules.load()).single;

      // Now with the name too: that rule already reads this message.
      await ManualSmsTeacher(db).teach(
        sms,
        const SmsLabels(
          amount: '10.00',
          account: '3225',
          payee: 'ASHIQ',
          moneyOut: true,
          currency: 'INR',
        ),
      );
      final after = await rules.load();
      expect(after, hasLength(1));
      expect(after.single.id, isNot(first.id));
    },
  );

  test(
    'the rule that reads a taught message is found, for reporting it',
    () async {
      final db = AppDatabase(NativeDatabase.memory(), false);
      addTearDown(db.close);
      final sms = BankSms(
        sender: 'JD-UNIONB-S',
        body:
            'Union Bank of India A/c*3225 Dr Rs10.00 on 23-11-26 16:40 by MB '
            '632713749490 Fv.ASHIQ, Bal Rs19949.27 Not U?Call 18002333/SMS '
            'BLOCK 3225 to 8879635472',
        receivedAt: DateTime(2026, 11, 23, 16, 40),
      );
      final teacher = ManualSmsTeacher(db);
      // Nothing taught yet: nothing to report.
      expect(await teacher.ruleReading(sms), isNull);
      await teacher.teach(
        sms,
        const SmsLabels(
          amount: '10.00',
          account: '3225',
          payee: 'ASHIQ',
          moneyOut: true,
          currency: 'INR',
        ),
      );
      final rule = await teacher.ruleReading(sms);
      expect(rule, isNotNull);
      expect(rule!.senders, ['UNIONB']);
      // What gets shared is the format, never the message.
      expect(rule.format.toString(), isNot(contains('632713749490')));
    },
  );

  test('a message leaving the phone has its balance hidden, nothing else', () {
    const body =
        'Union Bank of India A/c*3225 Dr Rs10.00 on 23-11-26 16:40 by MB '
        '632713749490 Fv.ASHIQ, Bal Rs19949.27 Not U?Call 18002333/SMS '
        'BLOCK 3225 to 8879635472';
    expect(
      maskBalance(body),
      'Union Bank of India A/c*3225 Dr Rs10.00 on 23-11-26 16:40 by MB '
      '632713749490 Fv.ASHIQ, Bal RsXXXXX Not U?Call 18002333/SMS '
      'BLOCK 3225 to 8879635472',
    );
    expect(
      maskBalance('Rs 500 debited. Avl Bal: INR 1,234.50'),
      'Rs 500 debited. Avl Bal: INR XXXXX',
    );
    expect(maskBalance('No balance here Rs 10'), 'No balance here Rs 10');
  });
}
