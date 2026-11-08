import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/statement_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/statements/pending_statement_files.dart';
import 'package:simple_money/data/statements/statement_table.dart';
import 'package:simple_money/data/statements/upi_statement.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/ui/more/statements/statement_file.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

const _export =
    'Date,Time,Transaction Details,UTR,Your Account,Credit/debit instrument,Amount\n'
    '2024-06-01,20:11,Paid to Sakkeer P M,415300000001,State Bank Of India - 99,UPI,10\n'
    '2024-06-01,22:01,Received from Insam P S,415300000002,State Bank Of India - 99,UPI,60\n'
    '2024-06-02,13:19,Paid to Kiran,415300000003,State Bank Of India - 99,UPI,500\n';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pending');
    SharedPreferences.setMockInitialValues({});
    PendingStatementFiles.defaultDirectory = () async => dir;
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'a waiting file is ready once its layout is saved, newest few kept',
    () async {
      final rows = readCsvRows(_export);
      final store = PendingStatementFiles(directory: () async => dir);
      await store.save('june.csv', rows, UpiStatementSource.csv);
      expect(await store.ready({}), isEmpty);

      final signature = tableSignature(rows.first);
      final ready = await store.ready({signature: guessMapping(rows).toJson()});
      expect(ready.single.$1.fileName, 'june.csv');
      expect(ready.single.$1.rows, rows);

      for (var i = 0; i < 6; i++) {
        await store.save('other$i.csv', [
          ['Day', 'Note $i', 'Value'],
          ['2024-06-01', 'x', '1'],
        ], UpiStatementSource.csv);
      }
      expect(await store.load(), hasLength(5));

      await store.remove(signature);
      expect(
        (await store.load()).map((f) => f.signature),
        isNot(contains(signature)),
      );
    },
  );

  testWidgets('an approved layout offers its file, which imports in one tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    final sync = SyncController(SyncRepository(db));
    addTearDown(() async {
      sync.dispose();
      await db.close();
    });
    final rows = readCsvRows(_export);
    final signature = tableSignature(rows.first);
    await tester.runAsync(() async {
      await AccountRepository(db).save(
        name: 'SBI',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
        lastDigits: '2199',
        institution: 'State Bank of India',
      );
      // The file the app couldn't read waits on the phone...
      await PendingStatementFiles().save(
        'PhonePe.csv',
        rows,
        UpiStatementSource.csv,
      );
      // ...until the AI's layout is approved.
      await StatementImportRepository(db)
          .saveColumnMapping(signature, guessMapping(rows).toJson());
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => offerPendingImport(context, sync, signature),
              child: const Text('Approved'),
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      // Real file reads finish between pumps, a step at a time.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }
    }

    await tester.tap(find.text('Approved'));
    await settle();
    expect(find.text('Layout saved'), findsOneWidget);
    expect(find.textContaining('PhonePe.csv'), findsOneWidget);
    await tester.tap(find.text('Import now'));
    await settle();
    await tester.tap(find.text('Add 3 transactions'));
    await settle();

    final saved = (await tester.runAsync(
      () => TransactionRepository(db).load(),
    ))!;
    expect(saved, hasLength(3));
    // Imported, so it no longer waits.
    final left = (await tester.runAsync(() => PendingStatementFiles().load()))!;
    expect(left, isEmpty);
  });
}
