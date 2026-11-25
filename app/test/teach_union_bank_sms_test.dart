// A bank's own SMS: a name glued to a prefix ("Fv.ASHIQ,") marks alone, an
// account marks as its digits ("A/c*3225"), and the balance is found by
// itself. In its own file: a second teach in one file is slowed by the first.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:simple_money/ui/more/smart_tracking/sms/teach_sms_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  testWidgets('a name glued to a bank prefix marks alone; the account is its '
      'digits; the balance is shown', (tester) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final message = BankSms(
      sender: 'JD-UNIONB-S',
      // Words: 4 A/c*3225 · 6 Rs10.00 · 13 Fv. · 14 ASHIQ, · 16 Rs19949.27
      body:
          'Union Bank of India A/c*3225 Dr Rs10.00 on 23-11-26 16:40 by MB '
          '632713749490 Fv.ASHIQ, Bal Rs19949.27 Not U?Call 18002333/SMS '
          'BLOCK 3225 to 8879635472',
      receivedAt: DateTime(2026, 11, 23, 16, 40),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showTeachSmsSheet(context, database: db, message: message),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Money out'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-6')));
    await tester.pump();
    // The bank's "Fv." is a word of its own, apart from the name.
    expect(find.byKey(const Key('teach-word-13')), findsOneWidget);
    await tester.tap(find.byKey(const Key('teach-word-14')));
    await tester.pump();
    final payee = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const Key('teach-field-payee')),
            matching: find.byType(Text),
          )
          .last,
    );
    expect(payee.data, 'ASHIQ');
    await tester.tap(find.text('Account').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-4')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('teach-field-account')),
        matching: find.text('3225'),
      ),
      findsOneWidget,
    );
    // The balance in the message is found by itself.
    expect(
      find.descendant(
        of: find.byKey(const Key('teach-field-balance')),
        matching: find.text('₹19,949.27'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Teach'));
    // The rule is checked against every bundled pack: real time.
    List<UserSmsRule>? rules;
    for (var i = 0; i < 60 && (rules == null || rules.isEmpty); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      rules = await tester.runAsync(() => UserSmsRuleRepository(db).load());
    }
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    // The sender ID is what the rule is kept under.
    expect(rules!.single.senders, ['UNIONB']);
  });
}
