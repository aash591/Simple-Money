import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/ui/components/account_tile.dart';
import 'package:simple_money/ui/more/accounts/account_card.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  upgradeTest();
  Account account({required bool debit}) => Account(
    id: 1,
    name: 'Federal Bank',
    currency: 'INR',
    digits: 2,
    balanceMinor: 100000,
    lastDigits: '1234',
    hasDebitCard: debit,
  );

  Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(body: child),
    ),
  );

  testWidgets('the account card shows the debit icon beside its kind', (
    tester,
  ) async {
    await show(tester, AccountCard(account: account(debit: true)));
    expect(find.byIcon(debitCardIcon), findsOneWidget);
    expect(find.byIcon(Icons.account_balance_outlined), findsOneWidget);
  });

  testWidgets('without a debit card there is only the kind icon', (
    tester,
  ) async {
    await show(tester, AccountCard(account: account(debit: false)));
    expect(find.byIcon(debitCardIcon), findsNothing);
    expect(find.byIcon(Icons.account_balance_outlined), findsOneWidget);
  });

  testWidgets('the home tile shows it too', (tester) async {
    await show(tester, AccountTile(account: account(debit: true)));
    expect(find.byIcon(debitCardIcon), findsOneWidget);
  });
}

void upgradeTest() {
  test(
    'an upgraded database gets the column and keeps syncing accounts',
    () async {
      final old = AppDatabase(
        NativeDatabase.memory(
          setup: (raw) {
            raw.execute(
              '''CREATE TABLE sync_state (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            enabled INTEGER NOT NULL DEFAULT 0,
            email TEXT, subject TEXT, display_name TEXT, picture_url TEXT,
            installation_id TEXT, mirror_id TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 0,
            next_sequence INTEGER NOT NULL DEFAULT 1,
            last_synced INTEGER, error TEXT, retry_at INTEGER NOT NULL DEFAULT 0,
            failures INTEGER NOT NULL DEFAULT 0,
            lease TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
            encryption_config TEXT, restore_pending INTEGER NOT NULL DEFAULT 0)''',
            );
            raw.execute('''CREATE TABLE sync_outbox (
            table_name TEXT NOT NULL, record_key TEXT NOT NULL,
            row_json TEXT, revision INTEGER NOT NULL,
            PRIMARY KEY(table_name, record_key))''');
            raw.execute(
              "INSERT INTO sync_state (id, mirror_id) VALUES (1, 'm')",
            );
            raw.execute('''CREATE TABLE accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            currency TEXT NOT NULL, territory TEXT, icon TEXT,
            digits INTEGER NOT NULL, balance_minor INTEGER NOT NULL,
            transaction_count INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL, archived_at INTEGER,
            type TEXT NOT NULL DEFAULT 'bank', last_digits TEXT,
            institution TEXT, credit_limit_minor INTEGER,
            available_limit_minor INTEGER, balance_reported_at INTEGER,
            credit_limit_reported_at INTEGER,
            available_limit_reported_at INTEGER)''');
            raw.execute('''INSERT INTO accounts
            (name, currency, digits, balance_minor, sort_order)
            VALUES ('Old', 'INR', 2, 500, 0)''');
            raw.userVersion = 45;
          },
        ),
      );
      addTearDown(old.close);
      final rows = await old
          .customSelect('SELECT debit_card FROM accounts')
          .get();
      expect(rows.single.read<int>('debit_card'), 0);
      await old.customStatement('UPDATE accounts SET debit_card = 1');
      final queued = await old
          .customSelect(
            "SELECT row_json FROM sync_outbox WHERE table_name = 'accounts'",
          )
          .get();
      expect(queued.last.read<String>('row_json'), contains('"debit_card":1'));
    },
  );
}
