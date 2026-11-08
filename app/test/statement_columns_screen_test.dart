import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/statements/statement_table.dart';
import 'package:simple_money/data/statements/upi_statement.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/ui/more/statements/statement_columns_screen.dart';
import 'package:simple_money/ui/more/statements/statement_review_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

const _export =
    'Date,Time,Transaction Details,UTR,Your Account,Credit/debit instrument,Amount\n'
    '2024-06-01,20:11,Paid to Sakkeer P M,415300000001,State Bank Of India - 99,UPI,10\n'
    '2024-06-01,22:01,Received from Insam P S,415300000002,State Bank Of India - 99,UPI,60\n'
    '2024-06-02,13:19,Kiran,415300000003,State Bank Of India - 99,UPI,500\n';

void main() {
  testWidgets('a CSV is read, previewed and added with the right directions', (
    tester,
  ) async {
    // Tall enough that every card of the screen is built.
    tester.view.physicalSize = const Size(500, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    final sync = SyncController(SyncRepository(db));
    addTearDown(() async {
      sync.dispose();
      await db.close();
    });
    await tester.runAsync(
      () => AccountRepository(db).save(
        name: 'SBI',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
        lastDigits: '2199',
        institution: 'State Bank of India',
      ),
    );

    final rows = readCsvRows(_export);
    StatementImportResult? done;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async =>
                    done = await Navigator.of(context)
                        .push<StatementImportResult>(
                          MaterialPageRoute(
                            builder: (_) => StatementColumnsScreen(
                              sync: sync,
                              rows: rows,
                              fileName: 'paytm.csv',
                              initial: guessMapping(rows),
                            ),
                          ),
                        ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('3 transactions found'), findsOneWidget);
    expect(find.text('Sakkeer P M'), findsOneWidget);
    expect(find.text('−₹10'), findsOneWidget);
    expect(find.text('+₹60'), findsOneWidget);
    // "Kiran" says nothing about its direction.
    expect(find.textContaining('1 row has no direction'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.text('NEW · 3'), findsOneWidget);

    // A row opens in the shared review sheet; a corrected title is kept on
    // the row and imported with it.
    await tester.tap(find.text('Sakkeer P M').hitTestable().last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Statement row'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('^Edit title')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Sakkeer rent');
    await tester.tap(find.widgetWithText(GlassButton, 'Save').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GlassButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.text('Sakkeer rent'), findsOneWidget);

    // "State Bank Of India •• 99" is the SBI account ending 2199.
    await tester.tap(find.text('Add 3 transactions'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(done, (added: 3, linked: 0, already: 0));

    final saved = (await tester.runAsync(
      () => TransactionRepository(db).load(),
    ))!;
    expect(
      {for (final t in saved) t.amountMinor: t.type},
      {
        1000: TransactionType.expense,
        6000: TransactionType.income,
        50000: TransactionType.expense,
      },
    );
    expect(
      saved.singleWhere((t) => t.amountMinor == 1000).date,
      DateTime(2024, 6, 1, 20, 11),
    );
    expect(saved.where((t) => t.title == 'Sakkeer rent'), hasLength(1));
  });

  testWidgets('a bank PDF shows its account, holder and balance check', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    final sync = SyncController(SyncRepository(db));
    addTearDown(() async {
      sync.dispose();
      await db.close();
    });
    // As a PDF's rebuilt table: letterhead lines, then the table.
    Future<void> open(List<List<String>> rows) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: StatementColumnsScreen(
            key: ObjectKey(rows),
            sync: sync,
            rows: rows,
            fileName: 'statement.pdf',
            source: UpiStatementSource.bank,
            initial: guessMapping(rows),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    const top = [
      ['Mr. RAVI KUMAR'],
      ['Account Number : 67333060000  IFSC : SBIN0070773'],
      ['Date', 'Description', 'Debit', 'Credit', 'Balance'],
      [
        '01/01/2026',
        'UPI/DR/600000000005/ANITHA/UPI',
        '300.90',
        '',
        '1,699.10',
      ],
    ];
    await open([
      ...top,
      [
        '02/01/2026',
        'UPI/CR/600000000006/GOPU/UPI',
        '',
        '2,000.00',
        '3,699.10',
      ],
    ]);
    expect(find.text('Bank PDF columns'), findsOneWidget);
    expect(find.text('State Bank of India •• 0000'), findsOneWidget);
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(
      find.text('Every row adds up to the balance beside it.'),
      findsOneWidget,
    );

    // Money in read as money out: the balance says so.
    await open([
      ...top,
      [
        '02/01/2026',
        'UPI/CR/600000000006/GOPU/UPI',
        '2,000.00',
        '',
        '3,699.10',
      ],
    ]);
    expect(
      find.textContaining('1 row doesn’t add up to the balance beside it.'),
      findsOneWidget,
    );
  });
}
