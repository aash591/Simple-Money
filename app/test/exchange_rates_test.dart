import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/rates/exchange_rates.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/domain/currency.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/main_currency_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory(), false);
  });
  tearDown(() => db.close());
  final today = DateTime.utc(2026, 9, 18);
  String body({String date = '2026-09-18'}) => jsonEncode({
    'date': date,
    'inr': {'inr': 1, 'usd': .0125, 'jpy': 2},
  });

  test('jsDelivr failure falls back and persists a daily table', () async {
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      expect(request.url.path, endsWith('/v1/currencies/inr.json'));
      return request.url.host == 'cdn.jsdelivr.net'
          ? http.Response('', 503)
          : http.Response(body(), 200);
    });
    addTearDown(client.close);
    final service = ExchangeRates(db, client, now: () => today);
    final table = await service.refresh('INR');
    expect(hosts, ['cdn.jsdelivr.net', 'latest.currency-api.pages.dev']);
    expect(table!.rates['USD'], .0125);
    expect(table.date, today);
    expect((await service.cached('INR'))!.rates, table.rates);
    await service.refresh('INR');
    expect(hosts.length, 2); // Already fetched today.
  });

  test(
    'offline and malformed JSON retain the last good cache and date',
    () async {
      var mode = 0;
      final client = MockClient((_) async {
        if (mode == 1) throw const SocketException('Offline');
        if (mode == 2) return http.Response('{"date":"bad", "inr":null}', 200);
        if (mode == 3)
          return http.Response(
            '{"date":"2026-09-18", "inr":{"inr":1,"usd":-2}}',
            200,
          );
        return http.Response(body(date: '2026-09-10'), 200);
      });
      addTearDown(client.close);
      final service = ExchangeRates(db, client, now: () => today);
      await service.refresh('INR');
      for (mode = 1; mode <= 3; mode++) {
        final cached = await service.refresh('INR', force: true);
        expect(cached!.rates['USD'], .0125);
        expect(cached.date, DateTime(2026, 9, 10));
      }
    },
  );

  test(
    'malformed primary falls back; no usable response leaves rates absent',
    () async {
      var validFallback = true;
      final client = MockClient(
        (request) async => http.Response(
          validFallback && request.url.host.contains('pages.dev')
              ? body()
              : '[]',
          200,
        ),
      );
      addTearDown(client.close);
      final service = ExchangeRates(db, client, now: () => today);
      expect(await service.refresh('INR'), isNotNull);
      validFallback = false;
      expect(await service.refresh('EUR'), isNull);
    },
  );

  test('concurrent refreshes share the same request', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(body(), 200);
    });
    addTearDown(client.close);
    final service = ExchangeRates(db, client, now: () => today);
    await Future.wait([service.refresh('INR'), service.refresh('INR')]);
    expect(calls, 1);
  });

  test('single currency makes no requests; choice persists with precision and territory', () async {
    final accounts = AccountStore(AccountRepository(db));
    await accounts.load();
    await accounts.save(
      name: 'Yen',
      currency: 'JPY',
      digits: 0,
      territory: 'JP',
      openingBalance: 1200,
    );
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(body(), 200);
    });
    final controller = MainCurrencyController(
      accounts,
      ExchangeRates(db, client),
      isOnline: () async => true,
    );
    await controller.start();
    expect(controller.code, 'JPY');
    await controller.refresh(force: true);
    expect(calls, 0);
    await controller.setCurrency(
      const Currency(
        code: 'KWD',
        digits: 3,
        territory: 'KW',
        country: 'Kuwait',
        name: 'Kuwaiti Dinar',
      ),
    );
    expect(calls, 0);
    expect(controller.accountScope.code, 'JPY');
    final saved = jsonDecode(
      (await SharedPreferences.getInstance()).getString(
        MainCurrencyController.preferenceKey,
      )!,
    );
    expect(saved, {'code': 'KWD', 'digits': 3, 'territory': 'KW'});
    controller.dispose();
    final restored = MainCurrencyController(
      accounts,
      ExchangeRates(db, client),
      isOnline: () async => true,
    );
    await restored.start();
    expect(
      (restored.code, restored.digits, restored.territory),
      ('KWD', 3, 'KW'),
    );
    restored.dispose();
    accounts.dispose();
    client.close();
  });

  test(
    'v16 upgrades the local cache without changing ledger or sync queue',
    () async {
      final dir = await Directory.systemTemp.createTemp('currency_migration_');
      final file = File('${dir.path}/ledger.sqlite');
      var disk = AppDatabase(NativeDatabase(file), false);
      try {
        await AccountRepository(
          disk,
        ).save(name: 'Cash', currency: 'INR', digits: 2, openingBalance: 12345);
        final queue = await disk
            .customSelect('SELECT * FROM sync_outbox')
            .get();
        await disk.customStatement('DROP TABLE exchange_rates');
        await disk.customStatement('PRAGMA user_version = 16');
        await disk.close();
        disk = AppDatabase(NativeDatabase(file), false);
        expect(
          (await AccountRepository(disk).load()).single.balanceMinor,
          12345,
        );
        expect(
          await disk.customSelect('SELECT * FROM exchange_rates').get(),
          isEmpty,
        );
        expect(
          (await disk.customSelect('SELECT * FROM sync_outbox').get()).length,
          queue.length,
        );
        expect(
          (await disk.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          disk.schemaVersion,
        );
      } finally {
        await disk.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
