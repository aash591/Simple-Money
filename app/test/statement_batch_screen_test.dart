import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/statement_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/statements/statement_table.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/ui/more/statements/statement_ai_help.dart';
import 'package:simple_money/ui/more/statements/statement_batch_screen.dart';
import 'package:simple_money/ui/more/statements/statement_review_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

const _export =
    'Date,Time,Transaction Details,UTR,Your Account,Credit/debit instrument,Amount\n'
    '2024-06-01,20:11,Paid to Sakkeer P M,415300000001,State Bank Of India - 99,UPI,10\n'
    '2024-06-01,22:01,Received from Insam P S,415300000002,State Bank Of India - 99,UPI,60\n'
    '2024-06-02,13:19,Paid to Kiran,415300000003,State Bank Of India - 99,UPI,500\n';

const _newLayout =
    'Dt,Remarks,Out,In,Bal\n'
    '01/10/26,UPI-SWIGGY,250.00,,9750.00\n'
    '02/10/26,SALARY,,50000.00,59750.00\n';

StatementPick _file(String name, String text) =>
    (name: name, read: () async => Uint8List.fromList(utf8.encode(text)));

void main() {
  testWidgets('several statements are read, then imported one after another', (
    tester,
  ) async {
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
    await tester.runAsync(() async {
      await AccountRepository(db).save(
        name: 'SBI',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
        lastDigits: '2199',
        institution: 'State Bank of India',
      );
      // This layout was set up before, so it reads straight away.
      await StatementImportRepository(db).saveColumnMapping(
        tableSignature(rows.first),
        guessMapping(rows).toJson(),
      );
    });

    StatementImportResult? done;
    var aiOpened = false;
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
                            builder: (_) => StatementBatchScreen(
                              sync: sync,
                              files: [
                                _file('paytm_june.csv', _export),
                                _file('empty.csv', ''),
                                _file('kavr_oct.csv', _newLayout),
                                // The same payments again, as another file
                                // of the same months would have them.
                                _file('paytm_copy.csv', _export),
                              ],
                              onOpenAi: () => aiOpened = true,
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
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }
    }

    await tester.tap(find.text('Open'));
    await settle();

    // What each file is, before anything is imported.
    expect(
      find.text('3 transactions · 1 Jun 2024 – 2 Jun 2024'),
      findsNWidgets(2),
    );
    expect(find.text('New layout · set it up once'), findsOneWidget);
    expect(find.text('This file is empty.'), findsOneWidget);
    expect(find.text('Let AI set up the new layout'), findsOneWidget);
    // What to ask, and what the AI gets to see, are said up front.
    expect(find.text(statementLayoutPrompt), findsOneWidget);
    expect(find.textContaining('Never the whole file'), findsOneWidget);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.text(statementLayoutPrompt));
    await tester.pump();
    expect(copied, statementLayoutPrompt);
    await tester.tap(find.text('Go to AI session'));
    expect(aiOpened, isTrue);

    await tester.tap(find.text('Import 3 files'));
    await settle();
    expect(find.text('CSV · 1 of 3'), findsOneWidget);
    await tester.tap(find.text('Add 3 transactions'));
    await settle();

    // The copy follows straight on, and has nothing new.
    expect(find.text('CSV · 2 of 3'), findsOneWidget);
    await tester.tap(find.text('All here already · continue'));
    await settle();

    // The new layout opens its columns; stepping back leaves it waiting.
    expect(find.text('CSV columns · 3 of 3'), findsOneWidget);
    await tester.pageBack();
    await settle();
    expect(find.text('Added 3 transactions'), findsOneWidget);
    expect(find.text('3 already here'), findsOneWidget);
    expect(find.text('Not imported yet · tap to open'), findsOneWidget);
    expect(find.text('Continue · 1 left'), findsOneWidget);

    // Set up there and then, it imports and the list is done.
    await tester.tap(find.text('Continue · 1 left'));
    await settle();
    await tester.tap(find.text('Continue'));
    await settle();
    // Its file doesn't say which account it is.
    expect(find.text('CSV · 3 of 3'), findsOneWidget);
    await tester.tap(find.text('Choose account'));
    await settle();
    await tester.tap(find.text('SBI').last);
    await settle();
    await tester.tap(find.text('Add 2 transactions'));
    await settle();
    expect(find.text('Done'), findsOneWidget);
    expect(
      find.text('All done. Added 5 transactions · 3 already here.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await settle();
    expect(done, (added: 5, linked: 0, already: 3));
    final saved = (await tester.runAsync(
      () => TransactionRepository(db).load(),
    ))!;
    expect(saved, hasLength(5));
  });
}
