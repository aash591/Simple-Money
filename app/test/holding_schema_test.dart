import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simple_money/data/backup/sync_schema.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/prices/price_service.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/domain/holding.dart';

/// What an app must keep true so an update never costs anyone their data:
/// the v52 -> v53 upgrade keeps every row, and holdings written by a newer
/// app (a kind or price source this one lacks) load, survive edits and are
/// left alone by price refreshes.
void main() {
  test('v52 holdings upgrade keeps every row, trade and trigger', () async {
    final dir = await Directory.systemTemp.createTemp('holdings_v53_');
    final file = File('${dir.path}/ledger.sqlite');
    var disk = AppDatabase(NativeDatabase(file), false);
    try {
      await AccountRepository(disk).save(
        name: 'Zerodha',
        currency: 'INR',
        digits: 2,
        openingBalance: 777700,
        broker: true,
      );
      // Put the holdings table back the way v52 made it.
      await disk.customStatement('DROP TABLE holdings');
      await disk.customStatement('''CREATE TABLE holdings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('stock', 'etf', 'fund')),
        name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 60),
        symbol TEXT, exchange TEXT,
        last_price_e4 INTEGER, price_date TEXT,
        archived_at INTEGER
      )''');
      await disk.customStatement(
        'CREATE INDEX holdings_account ON holdings(account_id)',
      );
      await createSyncTriggers(disk, 'holdings');
      final account = (await AccountRepository(disk).load()).single.id;
      await disk.customStatement('''INSERT INTO holdings
          (id, account_id, kind, name, symbol, exchange, last_price_e4,
           price_date, archived_at)
        VALUES
          (11, $account, 'stock', 'TCS', 'TCS', 'NSE', 35502500,
           '2026-11-19', NULL),
          (12, $account, 'fund', 'PPFAS', '122639', NULL, 824567,
           '2026-11-18', 1700000000000),
          (13, $account, 'etf', 'Typed by hand', NULL, NULL, NULL, NULL, NULL)
        ''');
      await disk.customStatement('''INSERT INTO holding_trades
          (id, holding_id, type, date, units_e6, price_e4, amount_minor,
           fees_minor, pay_account_id, note)
        VALUES (21, 11, 'buy', 1760000000000, 10000000, 3500000, 35000, 50,
                NULL, 'first')''');
      // Those were uploaded long ago; the upgrade must not queue them again.
      await disk.customStatement(
        "DELETE FROM sync_outbox WHERE table_name = 'holdings'",
      );
      await disk.customStatement('PRAGMA user_version=52');
      await disk.close();

      disk = AppDatabase(NativeDatabase(file), false);
      final holdings = await HoldingRepository(disk).loadHoldings();
      expect(holdings.map((h) => h.id), unorderedEquals([11, 12, 13]));
      final tcs = holdings.firstWhere((h) => h.id == 11);
      expect(tcs.name, 'TCS');
      expect(tcs.kind, HoldingKind.stock);
      expect(tcs.symbol, 'TCS');
      expect(tcs.exchange, 'NSE');
      expect(tcs.lastPriceE4, 35502500);
      expect(tcs.priceDate, DateTime(2026, 11, 19));
      final fund = holdings.firstWhere((h) => h.id == 12);
      expect(fund.archivedAt, isNotNull);
      expect(fund.lastPriceE4, 824567);
      // Old rows name no source; one is worked out the way it always was.
      expect(tcs.priceSource, isNull);
      expect(tcs.effectivePriceSource, PriceSourceId.yahoo);
      expect(fund.effectivePriceSource, PriceSourceId.amfi);

      final trades = await HoldingRepository(disk).loadTrades();
      expect(trades.single.amountMinor, 35000);
      expect(trades.single.note, 'first');
      final balance = await disk
          .customSelect('SELECT balance_minor FROM accounts')
          .getSingle();
      expect(balance.read<int>('balance_minor'), 777700);

      // The upgrade didn't queue the old rows for upload again...
      final queued = await disk
          .customSelect(
            "SELECT count(*) AS n FROM sync_outbox WHERE table_name='holdings'",
          )
          .getSingle();
      expect(queued.read<int>('n'), 0);
      // ...but edits made afterwards are synced, new columns included.
      await disk.customStatement(
        "INSERT INTO holdings (id, account_id, kind, name, price_source) "
        "VALUES (14, $account, 'gold', 'Gold coin', 'manual')",
      );
      final row = await disk
          .customSelect(
            "SELECT row_json FROM sync_outbox WHERE table_name='holdings'",
          )
          .getSingle();
      expect(row.read<String>('row_json'), contains('"price_source":"manual"'));
      expect(row.read<String>('row_json'), contains('"meta":null'));

      // Idempotent: a second open does nothing and loses nothing.
      await disk.close();
      disk = AppDatabase(NativeDatabase(file), false);
      expect((await HoldingRepository(disk).loadHoldings()).length, 4);
    } finally {
      await disk.close();
      await dir.delete(recursive: true);
    }
  });

  group('holdings written by a newer app', () {
    late AppDatabase db;
    late HoldingRepository repository;
    late int account;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await AccountRepository(db).save(
        name: 'Vault',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
        broker: true,
      );
      account = (await AccountRepository(db).load()).single.id;
      repository = HoldingRepository(db);
      await db.customStatement('''INSERT INTO holdings
          (id, account_id, kind, name, symbol, price_source, meta)
        VALUES (31, $account, 'gold', 'Gold coin', 'XAU',
                'goldsource', '{"purity":"24k"}')''');
    });

    tearDown(() => db.close());

    test('an unknown kind loads as other instead of failing', () async {
      final gold = (await repository.loadHoldings()).single;
      expect(gold.kind, HoldingKind.other);
      expect(gold.kindId, 'gold');
      expect(gold.priceSource, 'goldsource');
      expect(gold.meta, '{"purity":"24k"}');
    });

    test('editing it here keeps its kind, source and details', () async {
      final gold = (await repository.loadHoldings()).single;
      await repository.saveHolding(
        existing: gold,
        accountId: account,
        kind: gold.kind,
        name: 'Gold coin 10g',
        symbol: 'XAU',
      );
      final after = (await repository.loadHoldings()).single;
      expect(after.name, 'Gold coin 10g');
      expect(after.kindId, 'gold');
      expect(after.priceSource, 'goldsource');
      expect(after.meta, '{"purity":"24k"}');
    });

    test('a refresh skips a source it lacks without counting a failure', () async {
      final requests = <Uri>[];
      final service = PriceService(
        MockClient((request) async {
          requests.add(request.url);
          return http.Response('', 500);
        }),
      );
      final gold = (await repository.loadHoldings()).single;
      final result = await service.fetch([(holding: gold, currency: 'INR')]);
      expect(result.failed, 0);
      expect(result.updated, isEmpty);
      expect(requests, isEmpty);
    });
  });

  test('a price source is inferred only for kinds this version knows', () {
    expect(PriceSourceId.infer(HoldingKind.stock, 'TCS'), PriceSourceId.yahoo);
    expect(PriceSourceId.infer(HoldingKind.etf, null), PriceSourceId.yahoo);
    expect(PriceSourceId.infer(HoldingKind.fund, '122639'), PriceSourceId.amfi);
    expect(PriceSourceId.infer(HoldingKind.fund, 'VTSAX'), PriceSourceId.yahoo);
    expect(PriceSourceId.infer(HoldingKind.other, 'XAU'), isNull);
    expect(HoldingKind.parse('crypto'), HoldingKind.other);
    expect(HoldingKind.parse(null), HoldingKind.other);
    expect(HoldingKind.parse('etf'), HoldingKind.etf);
  });
}
