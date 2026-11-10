import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/transaction_store.dart';

class _RecordingRepository extends TransactionRepository {
  _RecordingRepository(super.database);
  final queries = <int?>[];

  @override
  Future<List<MoneyTransaction>> load({
    int? id,
    DateTime? start,
    DateTime? end,
    String? currency,
    int? digits,
    int? limit,
  }) {
    queries.add(id);
    return super.load(
      id: id,
      start: start,
      end: end,
      currency: currency,
      digits: digits,
      limit: limit,
    );
  }
}

void main() {
  test(
    'local saves retain history and ordering without full ledger queries',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final accounts = AccountStore(AccountRepository(db));
      final repository = _RecordingRepository(db);
      final store = TransactionStore(repository, accounts);
      addTearDown(() async {
        store.dispose();
        accounts.dispose();
        await db.close();
      });
      await accounts.load();
      await accounts.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 10000,
      );
      final account = accounts.accounts.single.id;
      final category =
          (await db
                  .customSelect(
                    "SELECT id FROM categories WHERE type = 'expense' LIMIT 1",
                  )
                  .getSingle())
              .read<int>('id');
      await store.load();
      repository.queries.clear();
      final date = DateTime(2026, 10, 1);
      for (var i = 0; i < 3; i++) {
        await store.addExpenseOrIncome(
          type: TransactionType.expense,
          amountMinor: 100,
          accountId: account,
          categoryId: category,
          title: 'Expense $i',
          date: date,
        );
      }
      expect(repository.queries, everyElement(isNotNull));
      expect(store.transactions.map((t) => t.title), [
        'Expense 2',
        'Expense 1',
        'Expense 0',
      ]);
      final id = store.transactions.last.id;
      await store.updateExpenseOrIncome(
        id: id,
        type: TransactionType.expense,
        amountMinor: 250,
        accountId: account,
        categoryId: category,
        title: 'Updated',
        date: date.add(const Duration(days: 1)),
      );
      expect(store.transactions.first.id, id);
      expect(store.transactions, hasLength(3));
      expect(accounts.accounts.single.balanceMinor, 9550);
      await store.edit(
        id: id,
        type: TransactionType.expense,
        amountMinor: 300,
        accountId: account,
        categoryId: category,
        title: 'Earlier',
        date: date.subtract(const Duration(days: 1)),
      );
      expect(store.transactions.last.id, id);
      expect(repository.queries, everyElement(isNotNull));
      expect(
        store.transactions.map((t) => t.title),
        (await TransactionRepository(db).load()).map((t) => t.title),
      );
      await accounts.save(
        name: 'Dollar account',
        currency: 'USD',
        digits: 2,
        openingBalance: 0,
      );
      final destination = accounts.accounts.last.id;
      await store.addTransfer(
        amountMinor: 1000,
        fromAccountId: account,
        toAccountId: destination,
        toAmountMinor: 12,
        date: date,
      );
      final transfer = store.transactions.firstWhere(
        (t) => t.type == TransactionType.transfer,
      );
      expect(transfer.toAmountMinor, 12);
      expect(repository.queries.last, transfer.id);
      expect(accounts.accounts.first.balanceMinor, 8500);
      expect(accounts.accounts.last.balanceMinor, 12);
      await store.deleteTransaction(transfer.id);
      expect(store.transactions, hasLength(3));
      expect(accounts.accounts.first.balanceMinor, 9500);
      expect(accounts.accounts.last.balanceMinor, 0);
      await store.refresh();
      expect(repository.queries.last, isNull);
    },
  );
}
