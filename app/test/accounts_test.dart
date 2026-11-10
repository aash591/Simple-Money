import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNull, Column;
import 'package:flutter/material.dart' hide Table;
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/rates/exchange_rates.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/main_currency_controller.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/more/accounts/accounts_screen.dart';
import 'package:simple_money/ui/more/settings/main_currency_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/state/account_store.dart';

void main() {
  testWidgets(
    'account total shows converted balance, breakdown and explicit missing rates',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory(), false);
      final accounts = AccountStore(AccountRepository(db));
      final transactions = TransactionStore(
        TransactionRepository(db),
        accounts,
      );
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'date': '2026-09-01',
            'inr': {'inr': 1, 'usd': .0125},
          }),
          200,
        ),
      );
      final rates = ExchangeRates(db, client);
      final controller = MainCurrencyController(
        accounts,
        rates,
        isOnline: () async => false,
      );
      await tester.runAsync(() async {
        await accounts.save(
          name: 'Cash',
          currency: 'INR',
          digits: 2,
          openingBalance: 100000,
        );
        await accounts.save(
          name: 'Dollars',
          currency: 'USD',
          digits: 2,
          openingBalance: 1000,
        );
        await accounts.save(
          name: 'Yen',
          currency: 'JPY',
          digits: 0,
          openingBalance: 2000,
        );
        await accounts.load();
        await rates.refresh('INR');
        await controller.start();
      });
      final capture = GlobalKey();
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MainCurrencyScope(
            controller: controller,
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: AccountsScreen(
                store: accounts,
                transactionStore: transactions,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The total stays masked until it is asked for.
      expect(find.text('≈ ₹1,800'), findsNothing);
      await tester.tap(find.byTooltip('Show total balance'));
      await tester.pumpAndSettle();
      // The digits roll as separate reels, so the total is read by its label.
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Approximately ₹1,800'), findsOneWidget);
      semantics.dispose();
      expect(find.textContaining('Incomplete · Excludes JPY'), findsOneWidget);
      expect(find.textContaining('more than 7 days old'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('≈ ₹800'), findsOneWidget);
      expect(find.text('≈ ₹1,000'), findsNothing);
      expect(find.text('Rate unavailable'), findsOneWidget);
      await tester.tap(find.text('View breakdown'));
      await tester.pumpAndSettle();
      expect(find.text('Rate unavailable'), findsNWidgets(2));
      expect(find.text('JPY'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      // Inspectable screenshot of the real account screen, not a mockup.
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('build/currency_accounts.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
      tester.view.physicalSize = const Size(320, 700);
      final oldErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        debugPrint(details.toString());
        oldErrorHandler!(details);
      };
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      FlutterError.onError = oldErrorHandler;
      await tester.pumpWidget(
        MainCurrencyScope(
          controller: controller,
          child: MaterialApp(home: MainCurrencyScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Fawaz Ahmed Currency API'), findsOneWidget);
      expect(find.text('Refresh rates'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      accounts.dispose();
      transactions.dispose();
      client.close();
      await tester.runAsync(db.close);
    },
  );

  test('Decimal money input retains precision, including zero/three-digit currencies', () {
    expect(parseAccountAmount('1234567890.01', 2), 123456789001);
    expect(parseAccountAmount('-12.05', 2), -1205);
    expect(parseAccountAmount('', 2), 0);
    expect(parseAccountAmount(' 0 ', 2), 0);
    expect(parseAccountAmount('12.345', 2), isNull);
    expect(parseAccountAmount('12.345', 3), 12345);
    expect(parseAccountAmount('12.1', 0), isNull);
    expect(parseAccountAmount('12', 0), 12);
    expect(parseAccountAmount('1e3', 2), isNull);
    expect(parseAccountAmount('NaN', 2), isNull);
    expect(relabelAmount(12050, 2, 3), 120500);
    expect(relabelAmount(12050, 2, 0), isNull);
    expect(relabelAmount(12000, 2, 0), 120);
  });

  test(
    'Accounts, edits and order survive a database close and reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('simple_money_test_');
      final file = File('${dir.path}/accounts.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      try {
        var repo = AccountRepository(db);
        expect(await repo.load(), isEmpty);
        await repo.save(
          name: 'Cash',
          currency: 'INR',
          digits: 2,
          openingBalance: 71400,
        );
        await repo.save(
          name: 'HDFC Bank',
          currency: 'INR',
          digits: 2,
          openingBalance: 37088350,
        );
        var accounts = await repo.load();
        await repo.save(
          existing: accounts.first,
          name: 'Everyday cash',
          currency: 'KWD',
          digits: 3,
          openingBalance: 999,
        );
        accounts = await repo.load();
        expect(accounts.first.balanceMinor, 714000);
        expect(accounts.first.transactionCount, 0);
        expect(accounts.first.formattedBalance, '714');
        await repo.reorder(accounts.reversed.toList());
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        repo = AccountRepository(db);
        accounts = await repo.load();
        expect(accounts.map((a) => a.name), ['HDFC Bank', 'Everyday cash']);
        expect(accounts.last.currency, 'KWD');
        expect(accounts.last.balanceMinor, 714000);
        await expectLater(
          repo.save(
            existing: accounts.first,
            name: 'Bank',
            currency: 'JPY',
            digits: 0,
            openingBalance: 0,
          ),
          throwsArgumentError,
        );
        expect((await repo.load()).first.currency, 'INR');
        await expectLater(
          repo.save(name: ' ', currency: 'INR', digits: 2, openingBalance: 0),
          throwsArgumentError,
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'Upgrading a pre-territory/icon (v1) database preserves existing accounts',
    () async {
      final dir = await Directory.systemTemp.createTemp('simple_money_test_');
      final file = File('${dir.path}/accounts.sqlite');
      try {
        // Seed a v1 database, as an existing on-device install would have.
        final legacy = _LegacyDatabase(NativeDatabase(file));
        await legacy.customInsert(
          '''INSERT INTO accounts
              (name, currency, digits, balance_minor, sort_order)
              VALUES (?, ?, ?, ?, 0)''',
          variables: [
            Variable('Cash'),
            Variable('INR'),
            Variable(2),
            Variable(71400),
          ],
        );
        await legacy.close();

        // Opening it with the current (v3) schema must upgrade in place,
        // running both the v1->v2 (territory) and v2->v3 (icon) steps.
        final db = AppDatabase(NativeDatabase(file));
        final repo = AccountRepository(db);
        try {
          var accounts = await repo.load();
          expect(accounts, hasLength(1));
          expect(accounts.single.name, 'Cash');
          expect(accounts.single.balanceMinor, 71400);
          expect(accounts.single.territory, isNull);
          expect(accounts.single.icon, isNull);

          await repo.save(
            existing: accounts.single,
            name: 'Cash',
            currency: 'INR',
            territory: 'IN',
            icon: 'cash',
            digits: 2,
            openingBalance: 71400,
          );
          accounts = await repo.load();
          expect(accounts.single.territory, 'IN');
          expect(accounts.single.icon, 'cash');
        } finally {
          await db.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'Reorder uses final indices and rolls back when persistence fails',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = _FailingRepository(db);
      final store = AccountStore(repo);
      try {
        for (final name in ['Cash', 'Bank', 'Wallet']) {
          await repo.save(
            name: name,
            currency: 'INR',
            digits: 2,
            openingBalance: 0,
          );
        }
        await store.load();
        await store.reorder(0, 2);
        expect(store.accounts.map((a) => a.name), ['Bank', 'Wallet', 'Cash']);
        repo.fail = true;
        await expectLater(store.reorder(2, 0), throwsStateError);
        expect(store.accounts.map((a) => a.name), ['Bank', 'Wallet', 'Cash']);
        expect(store.saving, isFalse);
      } finally {
        store.dispose();
        await db.close();
      }
    },
  );
}

class _FailingRepository extends AccountRepository {
  _FailingRepository(super.database);
  bool fail = false;
  @override
  Future<void> reorder(List<Account> accounts) {
    if (fail) throw StateError('Disk unavailable');
    return super.reorder(accounts);
  }
}

/// The schema shipped before the `territory` column existed, used to seed a
/// fixture that exercises [AppDatabase]'s real v1 -> v2 upgrade path.
class _LegacyDatabase extends GeneratedDatabase {
  _LegacyDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement('''
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 40),
        currency TEXT NOT NULL CHECK(length(currency) = 3),
        digits INTEGER NOT NULL CHECK(digits BETWEEN 0 AND 4),
        balance_minor INTEGER NOT NULL,
        transaction_count INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL
      )
    ''');
    },
  );
}
