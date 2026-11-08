import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/statements/statement_table.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/ui/more/statements/statement_review_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

const _export =
    'Date,Time,Transaction Details,UTR,Your Account,Credit/debit instrument,Amount\n'
    '2024-06-01,20:11,Paid to Sakkeer P M,415300000001,State Bank Of India - 99,UPI,10\n'
    '2024-06-01,22:01,Received from Insam P S,415300000002,State Bank Of India - 99,UPI,60\n';

void main() {
  testWidgets(
    'a statement account the user lacks can be added from the picker',
    (tester) async {
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory(), false);
      final sync = SyncController(SyncRepository(db));
      addTearDown(() async {
        sync.dispose();
        await db.close();
      });
      final rows = readCsvRows(_export);
      final statement = parseStatementTable(rows, guessMapping(rows)).statement;

      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: StatementReviewScreen(sync: sync, statement: statement),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
        }
      }

      await settle();
      // No account yet: the picker still opens, with a way to add one.
      await tester.tap(find.text('Choose account').first);
      await settle();
      expect(find.text('Add account'), findsOneWidget);
      await tester.tap(find.text('Add account'));
      await settle();

      // The account screen starts from what the statement says.
      expect(find.text('Add account'), findsWidgets);
      expect(
        find.widgetWithText(TextField, 'State Bank Of India'),
        findsOneWidget,
      );
      // The account's balance is the one thing the statement can't say.
      await tester.enterText(find.byKey(const Key('opening-balance')), '1000');
      await tester.pump();
      final addButton = find.widgetWithText(GlassButton, 'Add account');
      expect(tester.widget<GlassButton>(addButton).onPressed, isNotNull);
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      await tester.tap(addButton);
      await settle();

      // Back on the review, the new account is linked.
      expect(find.text('State Bank Of India'), findsWidgets);
      expect(find.text('Choose account'), findsNothing);
      final saved = (await tester.runAsync(
        () => AccountRepository(db).load(),
      ))!;
      expect(saved.where((a) => a.name == 'State Bank Of India'), hasLength(1));
    },
  );
}
