import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/insights_repository.dart';
import 'package:simple_money/domain/currency_scope.dart';
import 'package:simple_money/ui/components/charts/callout_donut_chart.dart';
import 'package:simple_money/ui/components/charts/chart_data.dart';

void main() {
  test(
    'v35 upgrade indexes month queries without changing the ledger',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'home_index_test',
      );
      final file = File('${directory.path}/ledger.sqlite');
      var db = AppDatabase(NativeDatabase(file), true);
      try {
        final before = await db
            .customSelect('SELECT * FROM transactions')
            .get();
        await db.customStatement('DROP INDEX transactions_date');
        await db.customStatement('PRAGMA user_version = 35');
        await db.close();
        db = AppDatabase(NativeDatabase(file), false);
        final after = await db.customSelect('SELECT * FROM transactions').get();
        expect(after.map((r) => r.data), before.map((r) => r.data));
        final plan = await db
            .customSelect(
              '''
        EXPLAIN QUERY PLAN SELECT * FROM transactions
        WHERE date >= ? AND date < ? ORDER BY date DESC, id DESC LIMIT 5
      ''',
              variables: [
                Variable(0),
                Variable(DateTime(2027).millisecondsSinceEpoch),
              ],
            )
            .get();
        expect(
          plan.map((r) => r.data.toString()).join(),
          contains('transactions_date'),
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'batched month-end balances match a ledger walk across all cutoffs',
    () async {
      final db = AppDatabase(NativeDatabase.memory(), true);
      try {
        // Include exact month boundaries, an archived source/destination and
        // future movements beyond the last displayed month.
        await db.customStatement('''
        INSERT INTO accounts(name, currency, digits, balance_minor, sort_order)
        VALUES ('USD test', 'USD', 2, 123456, 100)
      ''');
        final ids = await db
            .customSelect('SELECT id FROM accounts ORDER BY id')
            .get();
        final first = ids.first.read<int>('id');
        final last = ids.last.read<int>('id');
        for (var m = 1; m <= 12; m++) {
          await db.customStatement(
            '''
          INSERT INTO transactions(type, amount_minor, account_id,
            to_account_id, date, created_at)
          VALUES ('transfer', ?, ?, ?, ?, ?)
        ''',
            [m * 101, first, last, DateTime(2026, m).millisecondsSinceEpoch, 0],
          );
        }
        await db.customStatement(
          'UPDATE accounts SET archived_at = 1 WHERE id = ?',
          [first],
        );
        final accounts = await db
            .customSelect('SELECT * FROM accounts WHERE archived_at IS NULL')
            .get();
        final ledger = await db
            .customSelect('SELECT * FROM transactions')
            .get();
        for (final month in [
          DateTime(2026, 3),
          DateTime(2026, 8),
          DateTime(2027, 1),
        ]) {
          for (final scope in <CurrencyScope>[
            const SingleCurrency('INR', 2),
            const SingleCurrency('USD', 2),
            const CombinedCurrency('INR', 2, rates: {'USD': 83.17}),
            const CombinedCurrency('INR', 2),
          ]) {
            final actual = await InsightsRepository(db).loadScope(month, scope);
            final expected = <int>[];
            for (final flow in actual.flows) {
              final cutoff = DateTime(
                flow.month.year,
                flow.month.month + 1,
              ).millisecondsSinceEpoch;
              final native = <(String, int), int>{};
              for (final account in accounts) {
                final id = account.read<int>('id');
                var balance = account.read<int>('balance_minor');
                for (final row in ledger) {
                  if (row.read<int>('date') < cutoff) continue;
                  final amount = row.read<int>('amount_minor');
                  if (row.read<int>('account_id') == id) {
                    balance += row.read<String>('type') == 'income'
                        ? -amount
                        : amount;
                  }
                  if (row.read<String>('type') == 'transfer' &&
                      row.readNullable<int>('to_account_id') == id) {
                    balance -= amount;
                  }
                }
                final key = (
                  account.read<String>('currency'),
                  account.read<int>('digits'),
                );
                native.update(key, (v) => v + balance, ifAbsent: () => balance);
              }
              final conversion = CurrencyTotals(scope);
              expected.add(
                native.entries.fold(
                  0,
                  (sum, e) =>
                      sum +
                      (conversion.convert(e.value, e.key.$1, e.key.$2) ?? 0),
                ),
              );
            }
            expect(actual.balances, expected, reason: '$month $scope');
          }
        }
      } finally {
        await db.close();
      }
    },
  );

  testWidgets(
    'donut animation reuses badge content and still updates selection',
    (tester) async {
      var badgeBuilds = 0;
      int? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalloutDonutChart(
              slices: const [
                ChartEntry(label: 'Food', value: 60, color: Colors.blue),
                ChartEntry(label: 'Travel', value: 40, color: Colors.orange),
              ],
              onSelect: (value) => selection = value,
              badgeBuilder: (_, index) {
                badgeBuilds++;
                return Text('Badge $index');
              },
            ),
          ),
        ),
      );
      final initialBuilds = badgeBuilds;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(badgeBuilds, initialBuilds);
      await tester.tap(find.text('Badge 0'));
      await tester.pumpAndSettle();
      expect(selection, 0);
      expect(badgeBuilds, greaterThan(initialBuilds));
      expect(tester.takeException(), isNull);
    },
  );
}
