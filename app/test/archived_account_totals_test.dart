import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/budget_repository.dart';
import 'package:simple_money/data/repositories/insights_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/transaction_store.dart';

/// Archiving splits the account in two: its balance stops being money you
/// hold, while the spending it did stays spending that happened. These are
/// the two halves, and the line between them is the point of the feature.
void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late TransactionStore transactions;
  late int wallet;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.save(
      name: 'Wallet',
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
    await accounts.load();
    await transactions.load();
    wallet = accounts.accounts.firstWhere((a) => a.name == 'Wallet').id;
    await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 20000,
      accountId: wallet,
      categoryId: 1,
      date: DateTime(2026, 3, 10),
    );
  });

  tearDown(() async {
    transactions.dispose();
    accounts.dispose();
    await db.close();
  });

  int currentBalance() =>
      accounts.accounts.fold(0, (sum, account) => sum + account.balanceMinor);

  test(
    'An archived balance leaves the totals; the money did not move',
    () async {
      expect(currentBalance(), 580000);
      await transactions.archiveAccount(wallet);
      expect(currentBalance(), 500000);
      // The wallet still holds what it held — it is simply not counted.
      expect(accounts.byId(wallet)!.balanceMinor, 80000);
      await transactions.restoreAccount(wallet);
      expect(currentBalance(), 580000);
    },
  );

  test('Net worth over time drops the archived account entirely', () async {
    Future<List<int>> balances() async => (await InsightsRepository(
      db,
    ).load(DateTime(2026, 3), 'INR', 2, now: DateTime(2026, 3, 31))).balances;
    final before = await balances();
    expect(before.last, 580000);
    await transactions.archiveAccount(wallet);
    final after = await balances();
    // Not just the closing figure: the wallet's expense must leave the
    // walk-back too, or every earlier month would be bent by it.
    expect(after.last, 500000);
    expect(after.every((b) => b == 500000), isTrue);
  });

  test(
    'Spending out of an archived account still counts as spending',
    () async {
      await transactions.archiveAccount(wallet);
      // The transaction list keeps it, joined through the row that survived.
      expect(transactions.transactions, hasLength(1));
      expect(transactions.transactions.single.accountId, wallet);

      final budgets = BudgetRepository(db);
      await budgets.saveTotal(
        currency: 'INR',
        digits: 2,
        fromMonth: DateTime(2026, 3),
        amountMinor: 100000,
      );
      final month = await budgets.loadMonth(DateTime(2026, 3), 'INR', 2);
      expect(month.allSpending!.spent, 20000);
    },
  );
}
