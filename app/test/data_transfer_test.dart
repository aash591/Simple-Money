import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/backup/data_transfer.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/backup/sync_schema.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/state/main_currency_controller.dart';

void main() {
  late AppDatabase db;
  late SyncEngine engine;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory(), false);
    engine = SyncEngine(
      SyncRepository(db),
      openTransport: (_) => throw StateError('No Drive in these tests'),
    );
  });
  tearDown(() => db.close());

  Future<void> addAccount(String name) =>
      AccountRepository(db)
          .save(name: name, currency: 'INR', digits: 2, openingBalance: 100000);

  Future<List<Map<String, Object?>>> rows(
    AppDatabase d,
    String table,
  ) async => [
    for (final row
        in await d
            .customSelect(
              'SELECT * FROM $table ORDER BY ${syncTables[table]!.join(', ')}',
            )
            .get())
      row.data,
  ];

  Future<int> count(AppDatabase d, String table) async =>
      (await d.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .read<int>('n');

  test(
    'currency preference and rate cache are excluded from exports and sync',
    () async {
      SharedPreferences.setMockInitialValues({
        MainCurrencyController.preferenceKey:
            '{"code":"JPY","digits":0,"territory":"JP"}',
      });
      await addAccount('Cash');
      await db.customStatement(
        "INSERT INTO exchange_rates VALUES ('INR', 'USD', 0.0125, '2026-09-18', '2026-09-18')",
      );
      final exported = utf8.decode(await exportLedger(db));
      expect(exported, isNot(contains('exchange_rates')));
      expect(exported, isNot(contains(MainCurrencyController.preferenceKey)));
      expect(syncTables, isNot(contains('exchange_rates')));
      final queued = await db
          .customSelect(
            "SELECT * FROM sync_outbox WHERE table_name = 'exchange_rates'",
          )
          .get();
      expect(queued, isEmpty);
    },
  );

  test('An export imports into another phone exactly', () async {
    await addAccount('Cash');
    await addAccount('Bank');
    await TransactionRepository(db).addTransfer(
      amountMinor: 1200,
      fromAccountId: 1,
      toAccountId: 2,
      date: DateTime(2026, 9, 11),
    );
    final file = await exportLedger(db);

    final other = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(other.close);
    await AccountRepository(other)
        .save(name: 'Replaced', currency: 'USD', digits: 2, openingBalance: 1);
    final data = parseLedgerExport(file);
    expect(data.count('accounts'), 2);
    await SyncEngine(
      SyncRepository(other),
      openTransport: (_) => throw StateError('unused'),
    ).restore(data);
    for (final table in syncTables.keys) {
      expect(await rows(other, table), await rows(db, table), reason: table);
    }
    // Imported data is queued as the phone's new synced copy.
    expect((await SyncRepository(other).status()).pending, greaterThan(0));
  });

  test('Only SimpleMoney exports are accepted', () {
    for (final bytes in [
      utf8.encode('not json'),
      utf8.encode('{"format": "something-else", "tables": {}}'),
      Uint8List(0),
    ]) {
      expect(
        () => parseLedgerExport(Uint8List.fromList(bytes)),
        throwsFormatException,
      );
    }
    final data = parseLedgerExport(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'simple-money-export',
            'tables': {
              'accounts': [],
              'sqlite_master': [
                {'name': 'x'},
              ],
            },
          }),
        ),
      ),
    );
    expect(data.tables.keys, ['accounts']);
  });

  test('Transactions CSV has readable amounts and safe cells', () async {
    await addAccount('Cash, pocket');
    await addAccount('=Bank');
    await TransactionRepository(db).addTransfer(
      amountMinor: 1205,
      fromAccountId: 1,
      toAccountId: 2,
      date: DateTime(2026, 9, 11, 8, 30),
    );
    final lines = utf8
        .decode(await exportTransactionsCsv(db))
        .replaceFirst('﻿', '')
        .split('\r\n');
    expect(
      lines.first,
      'Date,Type,Amount,Currency,Account,To account,Category,Title,Note',
    );
    expect(
      lines[1],
      '2026-09-11 08:30,transfer,12.05,INR,"Cash, pocket",\'=Bank,,,',
    );
  });

  test('Deleting phone data restores default categories only', () async {
    final defaults = await count(db, 'categories');
    expect(defaults, greaterThan(0));
    await addAccount('Cash');
    await db.customStatement(
      "INSERT INTO categories (name, type, sort_order) VALUES ('Mine', 'expense', 99)",
    );
    await engine.eraseDevice();
    expect(await count(db, 'accounts'), 0);
    expect(await count(db, 'transactions'), 0);
    expect(await count(db, 'categories'), defaults);
    expect(await SyncRepository(db).hasLedgerData(), isFalse);
  });
}
