// Teaching an app's notification: its account is optional. Chosen, it shows as
// a card with a cross on its corner; tapping the card opens the choice again.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/ui/more/smart_tracking/sms/teach_sms_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  testWidgets('a chosen account is a card: ✕ takes it back, tap changes it', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(420, 1800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    await tester.runAsync(
      () => AccountRepository(db).save(
        name: 'Kotak Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 12500,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTeachSmsSheet(
                context,
                database: db,
                appName: 'Example Pay',
                message: BankSms(
                  sender: 'APP_TEST000001',
                  body: '₹10.00 sent to ASHIQUE M\nLow balance!',
                  receivedAt: DateTime(2026, 11, 23),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The accounts load from the database: real work the test clock skips.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();

    // Optional: none chosen, one button to choose.
    expect(find.text('Choose account'), findsOneWidget);
    expect(find.byKey(const Key('teach-account-clear')), findsNothing);

    Future<void> choose() async {
      await tester.tap(find.byKey(const Key('teach-account-line')));
      await tester.pumpAndSettle();
      expect(find.text('Paid from'), findsOneWidget); // the picker is open
      await tester.tap(find.text('Kotak Bank'));
      await tester.pumpAndSettle();
    }

    await choose();
    // A card now: the account's name, and a cross on it.
    expect(find.text('Kotak Bank'), findsOneWidget);
    expect(find.byKey(const Key('teach-account-clear')), findsOneWidget);
    expect(find.text('Choose account'), findsNothing);
    expect(find.text('Paid from'), findsNothing);
    // Just the name: no balance on the card (the account holds ₹125.00).
    expect(find.textContaining('125'), findsNothing);

    // The cross takes the account back.
    await tester.tap(find.byKey(const Key('teach-account-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Choose account'), findsOneWidget);
    expect(find.text('Kotak Bank'), findsNothing);

    // Choose again, then tap the card itself: the choice opens again.
    await choose();
    await tester.tap(find.byKey(const Key('teach-account-line')));
    await tester.pumpAndSettle();
    expect(find.text('Paid from'), findsOneWidget);
  });
}
