import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/transaction_store.dart';

void main() {
  test('An expense debits the account and an income credits it, each incrementing its transaction count', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountRepository(db);
    final transactions = TransactionRepository(db);
    try {
      await accounts.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      final cash = (await accounts.load()).single;
      final categories = await db
          .customSelect(
            "SELECT id FROM categories WHERE type = 'expense' LIMIT 1",
          )
          .getSingle();
      final foodId = categories.read<int>('id');

      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 25000,
        accountId: cash.id,
        categoryId: foodId,
        date: DateTime(2026, 3, 1),
      );
      var after = (await accounts.load()).single;
      expect(after.balanceMinor, 75000);
      expect(after.transactionCount, 1);

      await transactions.addExpenseOrIncome(
        type: TransactionType.income,
        amountMinor: 50000,
        accountId: cash.id,
        categoryId: foodId,
        title: 'Refund',
        date: DateTime(2026, 3, 2),
      );
      after = (await accounts.load()).single;
      expect(after.balanceMinor, 125000);
      expect(after.transactionCount, 2);

      final saved = await transactions.load();
      expect(saved, hasLength(2));
      expect(saved.first.title, 'Refund'); // ordered by date desc
      expect(saved.first.type, TransactionType.income);
      expect(saved.last.type, TransactionType.expense);
    } finally {
      await db.close();
    }
  });

  test('Editing an expense into an income on another account moves both balances and counts, in place', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountRepository(db);
    final transactions = TransactionRepository(db);
    try {
      await accounts.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      await accounts.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 500000,
      );
      final all = await accounts.load();
      final cash = all.firstWhere((a) => a.name == 'Cash');
      final bank = all.firstWhere((a) => a.name == 'Bank');
      final categoryId =
          (await db
                  .customSelect(
                    "SELECT id FROM categories WHERE type = 'expense' LIMIT 1",
                  )
                  .getSingle())
              .read<int>('id');

      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 25000,
        accountId: cash.id,
        categoryId: categoryId,
        date: DateTime(2026, 3, 1),
      );
      final id = (await transactions.load()).single.id;

      await transactions.updateExpenseOrIncome(
        id: id,
        type: TransactionType.income,
        amountMinor: 40000,
        accountId: bank.id,
        categoryId: categoryId,
        title: 'Refund',
        date: DateTime(2026, 3, 2, 9, 30),
      );

      final after = await accounts.load();
      final cashAfter = after.firstWhere((a) => a.name == 'Cash');
      final bankAfter = after.firstWhere((a) => a.name == 'Bank');
      expect(cashAfter.balanceMinor, 100000);
      expect(cashAfter.transactionCount, 0);
      expect(bankAfter.balanceMinor, 540000);
      expect(bankAfter.transactionCount, 1);

      final saved = (await transactions.load()).single;
      expect(saved.id, id);
      expect(saved.type, TransactionType.income);
      expect(saved.amountMinor, 40000);
      expect(saved.accountId, bank.id);
      expect(saved.title, 'Refund');
      expect(saved.date, DateTime(2026, 3, 2, 9, 30));
    } finally {
      await db.close();
    }
  });

  test('Editing turns an expense into a transfer and back, keeping every balance and count right', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountRepository(db);
    final transactions = TransactionRepository(db);
    try {
      for (final name in ['Bank', 'Cash']) {
        await accounts.save(
          name: name,
          currency: 'INR',
          digits: 2,
          openingBalance: 100000,
        );
      }
      final all = await accounts.load();
      final bank = all.firstWhere((a) => a.name == 'Bank');
      final cash = all.firstWhere((a) => a.name == 'Cash');
      final food =
          (await db
                  .customSelect(
                    "SELECT id FROM categories WHERE type = 'expense' LIMIT 1",
                  )
                  .getSingle())
              .read<int>('id');
      Future<(int, int, int, int)> balances() async {
        final now = await accounts.load();
        final b = now.firstWhere((a) => a.id == bank.id);
        final c = now.firstWhere((a) => a.id == cash.id);
        return (
          b.balanceMinor,
          b.transactionCount,
          c.balanceMinor,
          c.transactionCount,
        );
      }

      final id = await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 20000,
        accountId: bank.id,
        categoryId: food,
        title: 'ATM',
        date: DateTime(2026, 3, 1),
      );
      expect(await balances(), (80000, 1, 100000, 0));

      // It was really cash taken out: a transfer from Bank to Cash.
      await transactions.edit(
        id: id,
        type: TransactionType.transfer,
        amountMinor: 20000,
        accountId: bank.id,
        toAccountId: cash.id,
        title: 'ATM',
        date: DateTime(2026, 3, 1),
      );
      expect(await balances(), (80000, 1, 120000, 1));
      var saved = (await transactions.load()).single;
      expect(saved.type, TransactionType.transfer);
      expect(saved.categoryId, isNull);
      expect(saved.title, isNull);

      // And back to an expense, for a different amount.
      await transactions.edit(
        id: id,
        type: TransactionType.expense,
        amountMinor: 15000,
        accountId: bank.id,
        categoryId: food,
        title: 'Lunch',
        date: DateTime(2026, 3, 2),
      );
      expect(await balances(), (85000, 1, 100000, 0));
      saved = (await transactions.load()).single;
      expect(saved.type, TransactionType.expense);
      expect(saved.toAccountId, isNull);
      expect(saved.title, 'Lunch');

      await expectLater(
        transactions.edit(
          id: id,
          type: TransactionType.transfer,
          amountMinor: 15000,
          accountId: bank.id,
          toAccountId: bank.id,
          date: DateTime(2026, 3, 2),
        ),
        throwsArgumentError,
      );
    } finally {
      await db.close();
    }
  });

  test('A subscription renewal can be corrected but not turned into a transfer', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountRepository(db);
    final transactions = TransactionRepository(db);
    try {
      for (final name in ['Bank', 'Cash']) {
        await accounts.save(
          name: name,
          currency: 'INR',
          digits: 2,
          openingBalance: 100000,
        );
      }
      final all = await accounts.load();
      final food =
          (await db
                  .customSelect(
                    "SELECT id FROM categories WHERE type = 'expense' LIMIT 1",
                  )
                  .getSingle())
              .read<int>('id');
      final id = await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 64900,
        accountId: all.first.id,
        categoryId: food,
        title: 'Netflix',
        date: DateTime(2026, 3, 1),
      );
      final recurringPayment = await db.customInsert(
        '''INSERT INTO recurring_payments
        (name, amount_minor, currency, digits, cycle, next_due, day)
        VALUES ('Netflix', 64900, 'INR', 2, 'monthly', '2026-04-01', 1)''',
      );
      await db.customInsert(
        'INSERT INTO recurring_payment_history (transaction_id, recurring_payment_id) '
        'VALUES (?, ?)',
        variables: [Variable(id), Variable(recurringPayment)],
      );
      final link = await transactions.link(id);
      expect(link?.kind, TransactionLinkKind.recurringPayment);
      expect(link?.name, 'Netflix');

      // A price change is fine...
      await transactions.edit(
        id: id,
        type: TransactionType.expense,
        amountMinor: 79900,
        accountId: all.first.id,
        categoryId: food,
        title: 'Netflix',
        date: DateTime(2026, 3, 1),
      );
      expect((await transactions.load()).single.amountMinor, 79900);
      // ...but it stays a payment.
      await expectLater(
        transactions.edit(
          id: id,
          type: TransactionType.transfer,
          amountMinor: 79900,
          accountId: all.first.id,
          toAccountId: all.last.id,
          date: DateTime(2026, 3, 1),
        ),
        throwsStateError,
      );
      expect((await transactions.load()).single.type, TransactionType.expense);
    } finally {
      await db.close();
    }
  });

  test('A transfer moves the amount between two accounts and increments both counts, but never negative amounts or same-account transfers', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountRepository(db);
    final transactions = TransactionRepository(db);
    try {
      await accounts.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      await accounts.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 500000,
      );
      final all = await accounts.load();
      final cash = all.firstWhere((a) => a.name == 'Cash');
      final bank = all.firstWhere((a) => a.name == 'Bank');

      await transactions.addTransfer(
        amountMinor: 20000,
        fromAccountId: cash.id,
        toAccountId: bank.id,
        date: DateTime(2026, 3, 1),
      );
      final after = await accounts.load();
      expect(after.firstWhere((a) => a.name == 'Cash').balanceMinor, 80000);
      expect(after.firstWhere((a) => a.name == 'Cash').transactionCount, 1);
      expect(after.firstWhere((a) => a.name == 'Bank').balanceMinor, 520000);
      expect(after.firstWhere((a) => a.name == 'Bank').transactionCount, 1);

      final saved = (await transactions.load()).single;
      expect(saved.type, TransactionType.transfer);
      expect(saved.accountId, cash.id);
      expect(saved.toAccountId, bank.id);
      expect(saved.categoryId, isNull);

      await expectLater(
        transactions.addTransfer(
          amountMinor: 100,
          fromAccountId: cash.id,
          toAccountId: cash.id,
          date: DateTime(2026, 3, 1),
        ),
        throwsArgumentError,
      );
      await expectLater(
        transactions.addTransfer(
          amountMinor: 0,
          fromAccountId: cash.id,
          toAccountId: bank.id,
          date: DateTime(2026, 3, 1),
        ),
        throwsArgumentError,
      );
    } finally {
      await db.close();
    }
  });

  test('Adjusting a balance logs the difference as a balance adjustment entry', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountRepository(db);
    final transactions = TransactionRepository(db);
    try {
      await accounts.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      final cash = (await accounts.load()).single;

      await transactions.adjustBalance(
        accountId: cash.id,
        mode: BalanceAdjustmentMode.add,
        amountMinor: 5000,
      );
      expect((await accounts.load()).single.balanceMinor, 105000);

      await transactions.adjustBalance(
        accountId: cash.id,
        mode: BalanceAdjustmentMode.subtract,
        amountMinor: 20000,
      );
      expect((await accounts.load()).single.balanceMinor, 85000);

      await transactions.adjustBalance(
        accountId: cash.id,
        mode: BalanceAdjustmentMode.setTo,
        amountMinor: 999900,
      );
      final after = await accounts.load();
      expect(after.single.balanceMinor, 999900);
      final entries = await transactions.load();
      expect(after.single.transactionCount, 3);
      expect(entries.every((t) => t.isBalanceAdjustment), isTrue);
      // Setting the same figure changes nothing, so adds nothing.
      await transactions.adjustBalance(
        accountId: cash.id,
        mode: BalanceAdjustmentMode.setTo,
        amountMinor: 999900,
      );
      expect(await transactions.load(), hasLength(3));
    } finally {
      await db.close();
    }
  });

  test('Upgrading a pre-transactions (v4) database preserves existing accounts and categories and adds an empty transactions table', () async {
    final dir = await Directory.systemTemp.createTemp('simple_money_test_');
    final file = File('${dir.path}/transactions.sqlite');
    try {
      final legacy = _LegacyDatabase(NativeDatabase(file));
      await legacy.customStatement('''
          CREATE TABLE accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            currency TEXT NOT NULL,
            territory TEXT,
            icon TEXT,
            digits INTEGER NOT NULL,
            balance_minor INTEGER NOT NULL,
            transaction_count INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL
          )
        ''');
      await legacy.customStatement('''
          CREATE TABLE categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            icon TEXT,
            parent_id INTEGER,
            sort_order INTEGER NOT NULL
          )
        ''');
      await legacy.close();

      final db = AppDatabase(NativeDatabase(file));
      final transactions = TransactionRepository(db);
      try {
        expect(await transactions.load(), isEmpty);
        final accounts = AccountRepository(db);
        await accounts.save(
          name: 'Cash',
          currency: 'INR',
          digits: 2,
          openingBalance: 0,
        );
        await accounts.save(
          name: 'Food',
          currency: 'INR',
          digits: 2,
          openingBalance: 0,
        );
      } finally {
        await db.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('TransactionStore reloads the account store after saving, so balances shown elsewhere stay in sync', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final accountStore = AccountStore(AccountRepository(db));
    final transactionStore = TransactionStore(
      TransactionRepository(db),
      accountStore,
    );
    try {
      await accountStore.load();
      await accountStore.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      final cash = accountStore.accounts.single;
      final foodId =
          (await db
                  .customSelect(
                    "SELECT id FROM categories WHERE type = 'expense' LIMIT 1",
                  )
                  .getSingle())
              .read<int>('id');

      await transactionStore.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 30000,
        accountId: cash.id,
        categoryId: foodId,
        date: DateTime(2026, 3, 1),
      );
      expect(accountStore.accounts.single.balanceMinor, 70000);
      expect(transactionStore.transactions, hasLength(1));
      expect(transactionStore.saving, isFalse);
    } finally {
      transactionStore.dispose();
      accountStore.dispose();
      await db.close();
    }
  });
}

/// The schema shipped before the `transactions` table existed, used to seed
/// a fixture that exercises [AppDatabase]'s real v4 -> v5 upgrade path.
class _LegacyDatabase extends GeneratedDatabase {
  _LegacyDatabase(super.executor);
  @override
  int get schemaVersion => 4;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy();
}
