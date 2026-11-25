import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:simple_money/ui/more/smart_tracking/sms/teach_sms_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  testWidgets('tap the amount, payee and account, then Teach saves a rule', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final message = BankSms(
      sender: 'VM-ZYXBNK-S',
      // Words: 0 Rs · 1 2,476.00 · 2 debited · 3 from · 4 A/c · 5 XX1234 ·
      // 6 to · 7 ASIANET …
      body:
          'Rs 2,476.00 debited from A/c XX1234 to ASIANET on 22-11-26. '
          'Not you? Call 1800. -Zyx Bank',
      receivedAt: DateTime(2026, 11, 22),
    );
    int? taught;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => taught = await showTeachSmsSheet(
                  context,
                  database: db,
                  message: message,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Teach this message'), findsOneWidget);
    // Which way the money went comes first, and words the rest.
    expect(find.text('Choose money out or in'), findsOneWidget);
    expect(find.text('Paid to'), findsNothing);
    await tester.tap(find.text('Money in'));
    await tester.pump();
    expect(find.text('Received from'), findsWidgets);
    await tester.tap(find.text('Money out'));
    await tester.pump();
    expect(find.text('Paid to'), findsWidgets);
    expect(find.text('Received from'), findsNothing);
    expect(find.text('Tap the amount'), findsWidgets);

    // The amount: only the number is taken from the word.
    await tester.tap(find.byKey(const Key('teach-word-1')));
    await tester.pump();
    expect(find.text('₹2,476.00'), findsOneWidget);
    // Marking moves on to who was paid.
    await tester.tap(find.byKey(const Key('teach-word-7')));
    await tester.pump();
    expect(find.text('ASIANET'), findsWidgets);
    // The mark pill, above the summary's Account line.
    await tester.tap(find.text('Account').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-5')));
    await tester.pump();
    expect(find.text('XX1234'), findsWidgets);

    await tester.tap(find.text('Teach'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();

    expect(taught, 1);
    final rules = await tester.runAsync(() => UserSmsRuleRepository(db).load());
    expect(rules, hasLength(1));
    expect(rules!.single.bankName, 'Zyx Bank');
  });

  testWidgets('a name of several words, even a one-letter last word, can be '
      'marked whole', (tester) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final message = BankSms(
      sender: 'APP_BC1EBE2844',
      // 0 ₹10.00 · 1 sent · 2 to · 3 ASHIQUE · 4 M · 5 Low · 6 balance! …
      body:
          '₹10.00 sent to ASHIQUE M\nLow balance! Add funds for seamless '
          'payment',
      receivedAt: DateTime(2026, 11, 23),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showTeachSmsSheet(context, database: db, message: message),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Words flow along the line, each as wide as it is: only a one-letter
    // word gets a little extra to be easy to hit.
    Size size(int i) => tester.getSize(find.byKey(Key('teach-word-$i')));
    expect(size(1).width, lessThan(80)); // "sent"
    expect(size(3).width, lessThan(120)); // "ASHIQUE"
    expect(size(4).width, greaterThanOrEqualTo(28)); // "M"
    expect(size(4).width, lessThan(40));
    await tester.tap(find.text('Money out'));
    await tester.pump();
    // Values sit right after their names: the gap is the widest name shown
    // ("Account") plus a small fixed space, not room for the longest name
    // there could be ("Received from"). (Pixels depend on the font, so this
    // compares with the name's own width.)
    final gap =
        tester.getTopLeft(find.byKey(const Key('teach-amount'))).dx -
        tester.getTopLeft(find.text('Amount')).dx;
    final widestName = tester.getSize(find.text('Account')).width;
    expect(gap - widestName, inInclusiveRange(8, 12));
    await tester.tap(find.byKey(const Key('teach-word-0')));
    await tester.pump();
    // The amount moves on to who was paid: first word, then the next.
    await tester.tap(find.byKey(const Key('teach-word-3')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-4')));
    await tester.pump();
    expect(find.text('ASHIQUE M'), findsWidgets);
  });
}
