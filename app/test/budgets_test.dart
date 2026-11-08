import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/app.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/budget_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/budget.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/budget_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/app_icon.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/components/select_icon_screen.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late CategoryStore categories;
  late TransactionStore transactions;
  late BudgetStore budgets;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    categories = CategoryStore(CategoryRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    budgets = BudgetStore(BudgetRepository(db));
    await accounts.load();
    await categories.load();
    await transactions.load();
    await accounts.save(
      name: 'Wallet',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
    );
  });
  tearDown(() async {
    accounts.dispose();
    categories.dispose();
    transactions.dispose();
    budgets.dispose();
    await db.close();
  });

  int categoryId(String name) =>
      categories.categories.firstWhere((c) => c.name == name).id;
  int accountId(String name) =>
      accounts.accounts.firstWhere((a) => a.name == name).id;
  Future<void> spend(
    int amount,
    DateTime date,
    String category, {
    String account = 'Wallet',
  }) => transactions.addExpenseOrIncome(
    type: TransactionType.expense,
    amountMinor: amount,
    accountId: accountId(account),
    categoryId: categoryId(category),
    date: date,
  );
  Future<void> setBudget(
    List<String> names,
    DateTime from,
    int amount, {
    int? id,
    String? name,
    String? icon,
  }) => budgets.save(
    budgetId: id,
    categoryIds: {for (final category in names) categoryId(category)},
    name: name,
    icon: icon,
    currency: 'INR',
    digits: 2,
    fromMonth: from,
    amountMinor: amount,
  );
  Future<void> setTotal(DateTime from, int amount) => budgets.saveTotal(
    currency: 'INR',
    digits: 2,
    fromMonth: from,
    amountMinor: amount,
  );
  Future<BudgetMonth> load(DateTime month) =>
      budgets.loadMonth(month, 'INR', 2);
  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .read<int>('n');

  test(
    'subcategory budgets count only their scope and prevent overlaps',
    () async {
      final month = DateTime(2026, 3);
      await spend(1000, month, 'Cafe');
      await spend(2000, month, 'Groceries');
      await spend(3000, month, 'Parking');
      await setBudget(['Cafe', 'Transportation'], month, 10000);
      final line = (await load(month)).budgets.single;
      expect(line.spent, 4000);
      expect(line.categoryIds, contains(categoryId('Cafe')));
      await expectLater(
        setBudget(['Food & Beverage'], month, 10000),
        throwsArgumentError,
      );
      await expectLater(
        setBudget(['Parking'], month, 10000),
        throwsArgumentError,
      );
      await setBudget(['Groceries'], month, 5000);
      expect((await load(month)).total!.spent, 6000);
    },
  );

  test('parent and child in one budget count spending once', () async {
    final month = DateTime(2026, 3);
    await spend(1000, month, 'Cafe');
    await spend(2000, month, 'Groceries');
    await setBudget(['Food & Beverage', 'Cafe'], month, 10000);
    expect((await load(month)).budgets.single.spent, 3000);
  });

  testWidgets('budget category search preserves parent and child selections', (
    tester,
  ) async {
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
        budgetStore: budgets,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set a budget'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add category'));
    await tester.pumpAndSettle();
    ListTile row(String name) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, name));
    expect(row('Food & Beverage').selected, isTrue);
    expect(row('Cafe').selected, isTrue);
    expect(row('Groceries').selected, isTrue);
    await tester.tap(find.text('Cafe'));
    await tester.pumpAndSettle();
    expect(row('Food & Beverage').selected, isFalse);
    expect(row('Cafe').selected, isFalse);
    expect(row('Groceries').selected, isTrue);
    await tester.tap(find.byTooltip('Search categories'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'parking');
    await tester.pumpAndSettle();
    expect(find.text('Cafe'), findsNothing);
    expect(find.text('Transportation'), findsOneWidget);
    await tester.tap(find.text('Parking'));
    await tester.pumpAndSettle();
    expect(row('Parking').selected, isTrue);
    await tester.enterText(find.byType(TextField), 'no such category');
    await tester.pumpAndSettle();
    expect(find.text('No categories found'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(row('Groceries').selected, isTrue);
    expect(row('Parking').selected, isTrue);
    await tester.tap(find.text('Food & Beverage'));
    await tester.pumpAndSettle();
    expect(row('Cafe').selected, isTrue);
    await tester.tap(find.widgetWithText(GlassButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.text('Parking'), findsOneWidget);
    expect(find.text('Search categories'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('a picked icon changes in place, keeping the budget', () async {
    const fun = ['Shopping', 'Entertainment'];
    await setBudget(fun, DateTime(2026, 3), 20000, name: 'Fun');
    final march = (await load(DateTime(2026, 3))).budgets.single;
    expect(march.icon, isNull);

    await setBudget(
      fun,
      DateTime(2026, 5),
      20000,
      id: march.id,
      name: 'Fun',
      icon: 'gift',
    );
    final may = (await load(DateTime(2026, 5))).budgets.single;
    expect(may.id, march.id);
    expect(may.icon, 'gift');
    expect((await load(DateTime(2026, 3))).budgets.single.icon, 'gift');
    expect(await count('budgets'), 1);
    expect(await count('budget_amounts'), 1);
  });

  test('budgets carry forward until changed or removed', () async {
    const food = 'Food & Beverage';
    await setBudget([food], DateTime(2026, 3), 60000);
    expect((await load(DateTime(2026, 2))).isEmpty, isTrue);
    final april = (await load(DateTime(2026, 4))).budgets.single;
    expect(april.limit, 60000);
    expect(april.categoryIds, [categoryId(food)]);
    expect(april.isCustom, isFalse);
    final id = april.id!;

    await setBudget([food], DateTime(2026, 5), 45000, id: id);
    expect((await load(DateTime(2026, 4))).budgets.single.limit, 60000);
    expect((await load(DateTime(2026, 7))).budgets.single.limit, 45000);

    await budgets.remove(id, DateTime(2026, 6));
    expect((await load(DateTime(2026, 5))).budgets.single.limit, 45000);
    expect((await load(DateTime(2026, 6))).isEmpty, isTrue);

    // Changing an earlier month replaces every later change.
    await setBudget([food], DateTime(2026, 4), 50000, id: id);
    expect((await load(DateTime(2026, 3))).budgets.single.limit, 60000);
    expect((await load(DateTime(2027, 1))).budgets.single.limit, 50000);
    expect(await count('budget_amounts'), 2);

    // Re-setting what an earlier month already carries adds nothing.
    await setBudget([food], DateTime(2026, 8), 50000, id: id);
    expect(await count('budget_amounts'), 2);

    // Removing a budget from its first month leaves nothing behind.
    await setBudget(['Shopping'], DateTime(2026, 9), 10000);
    final shopping = (await load(DateTime(2026, 9))).budgets.last;
    await budgets.remove(shopping.id!, DateTime(2026, 9));
    expect(await count('budgets'), 1);

    // Awaited one at a time: the store refuses overlapping saves.
    await expectLater(
      setBudget([food], DateTime(2026, 3), 0, id: id),
      throwsArgumentError,
    );
    await expectLater(
      setBudget(['Cafe'], DateTime(2026, 3), 100),
      throwsArgumentError,
    );
    await expectLater(
      setBudget(['Salary'], DateTime(2026, 3), 100),
      throwsArgumentError,
    );
    await expectLater(
      setBudget([], DateTime(2026, 3), 100),
      throwsArgumentError,
    );
  });

  test(
    'custom budgets combine categories, each in one budget at a time',
    () async {
      const food = 'Food & Beverage', transport = 'Transportation';
      await spend(15000, DateTime(2026, 3, 2), 'Cafe');
      await spend(7000, DateTime(2026, 3, 5), 'Parking');
      await spend(3000, DateTime(2026, 3, 6), 'Movies');
      await setBudget(
        [transport, food],
        DateTime(2026, 3),
        30000,
        name: '  Daily  ',
      );
      final march = (await load(DateTime(2026, 3))).budgets.single;
      expect(march.name, 'Daily');
      expect(march.isCustom, isTrue);
      expect(march.categoryIds, [categoryId(food), categoryId(transport)]);
      expect(march.spent, 22000);

      // Taken this month, and — from an earlier month — later on.
      await expectLater(
        setBudget([transport], DateTime(2026, 3), 100),
        throwsArgumentError,
      );
      await expectLater(
        setBudget([transport], DateTime(2026, 1), 100),
        throwsArgumentError,
      );

      // Covering other categories leaves earlier months as they were.
      await setBudget(
        [food, transport, 'Entertainment'],
        DateTime(2026, 5),
        40000,
        id: march.id,
        name: 'Daily',
      );
      final april = (await load(DateTime(2026, 4))).budgets.single;
      expect(april.id, march.id);
      expect(april.categoryIds, hasLength(2));
      expect(april.limit, 30000);
      final may = (await load(DateTime(2026, 5))).budgets.single;
      expect(may.id, isNot(march.id));
      expect(may.categoryIds, hasLength(3));
      expect(may.limit, 40000);

      // One that starts this month changes in place; one category, no name.
      await setBudget(
        [food],
        DateTime(2026, 5),
        40000,
        id: may.id,
        name: 'Daily',
      );
      final single = (await load(DateTime(2026, 5))).budgets.single;
      expect(single.id, may.id);
      expect(single.name, isNull);
      expect(single.categoryIds, [categoryId(food)]);

      // Transportation is free again from May.
      await setBudget([transport], DateTime(2026, 5), 10000);
      expect((await load(DateTime(2026, 5))).budgets, hasLength(2));
    },
  );

  test(
    'spending counts subcategories and one currency, never transfers or income',
    () async {
      await accounts.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
      await accounts.save(
        name: 'Dollars',
        currency: 'USD',
        digits: 2,
        openingBalance: 0,
      );
      await setTotal(DateTime(2026, 3), 100000);
      await setBudget(['Food & Beverage'], DateTime(2026, 3), 20000);
      await setBudget(['Transportation'], DateTime(2026, 3), 10000);
      await spend(15000, DateTime(2026, 3, 2), 'Cafe');
      await spend(
        9000,
        DateTime(2026, 3, 31, 23, 59),
        'Food & Beverage',
        account: 'Bank',
      );
      await spend(7000, DateTime(2026, 3, 5), 'Parking');
      await spend(3000, DateTime(2026, 3, 6), 'Movies');
      await spend(50000, DateTime(2026, 3, 6), 'Cafe', account: 'Dollars');
      await spend(4000, DateTime(2026, 4, 1), 'Cafe');
      await transactions.addExpenseOrIncome(
        type: TransactionType.income,
        amountMinor: 90000,
        accountId: accountId('Wallet'),
        categoryId: categoryId('Salary'),
        date: DateTime(2026, 3, 1),
      );
      await transactions.addTransfer(
        amountMinor: 600,
        fromAccountId: accountId('Wallet'),
        toAccountId: accountId('Bank'),
        date: DateTime(2026, 3, 4),
      );

      final march = await load(DateTime(2026, 3));
      expect(march.totalIsDerived, isFalse);
      expect(march.total!.limit, 100000);
      expect(march.total!.spent, 34000);
      expect(march.budgets.map((line) => line.categoryIds.single), [
        categoryId('Food & Beverage'),
        categoryId('Transportation'),
      ]);
      final food = march.budgets.first;
      expect(food.spent, 24000);
      expect(food.isOver, isTrue);
      expect(food.left, -4000);
      expect(food.percentUsed, 120);
      expect(march.budgets.last.percentUsed, 70);

      // Without a total budget, the total adds up the others.
      await budgets.remove(march.allSpending!.id!, DateTime(2026, 3));
      final derived = await load(DateTime(2026, 3));
      expect(derived.totalIsDerived, isTrue);
      expect(derived.total!.limit, 30000);
      expect(derived.total!.spent, 31000);
      expect(
        (await budgets.loadMonth(DateTime(2026, 3), 'USD', 2)).isEmpty,
        isTrue,
      );
    },
  );

  test('deleting a category takes it out of its budget', () async {
    await setBudget(['Food & Beverage'], DateTime(2026, 3), 20000);
    await setBudget(['Shopping', 'Entertainment'], DateTime(2026, 3), 30000);
    await categories.delete(
      categories.categories.firstWhere((c) => c.name == 'Food & Beverage'),
    );
    expect(await count('budgets'), 1);
    expect(await count('budget_amounts'), 1);
    await categories.delete(
      categories.categories.firstWhere((c) => c.name == 'Shopping'),
    );
    expect((await load(DateTime(2026, 3))).budgets.single.categoryIds, [
      categoryId('Entertainment'),
    ]);
  });

  test('upgrading from version 5 adds the budget tables', () async {
    final upgraded = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''CREATE TABLE accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            currency TEXT NOT NULL, territory TEXT, icon TEXT,
            digits INTEGER NOT NULL, balance_minor INTEGER NOT NULL,
            transaction_count INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL)''');
          raw.execute('''CREATE TABLE categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            type TEXT NOT NULL, icon TEXT, parent_id INTEGER,
            sort_order INTEGER NOT NULL)''');
          raw.execute('''CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL,
            amount_minor INTEGER NOT NULL, account_id INTEGER NOT NULL,
            to_account_id INTEGER, category_id INTEGER, title TEXT,
            note TEXT, date INTEGER NOT NULL, created_at INTEGER NOT NULL)''');
          raw.userVersion = 5;
        },
      ),
      false,
    );
    try {
      final repository = BudgetRepository(upgraded);
      await repository.saveTotal(
        currency: 'INR',
        digits: 2,
        fromMonth: DateTime(2026, 3),
        amountMinor: 5000,
      );
      final month = await repository.loadMonth(DateTime(2026, 3), 'INR', 2);
      expect(month.allSpending!.limit, 5000);
    } finally {
      await upgraded.close();
    }
  });

  test('upgrading from version 6 keeps every budget and its history', () async {
    final upgraded = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''CREATE TABLE accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            currency TEXT NOT NULL, territory TEXT, icon TEXT,
            digits INTEGER NOT NULL, balance_minor INTEGER NOT NULL,
            transaction_count INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL)''');
          raw.execute('''CREATE TABLE categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            type TEXT NOT NULL, icon TEXT, parent_id INTEGER,
            sort_order INTEGER NOT NULL)''');
          raw.execute('''CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL,
            amount_minor INTEGER NOT NULL, account_id INTEGER NOT NULL,
            to_account_id INTEGER, category_id INTEGER, title TEXT,
            note TEXT, date INTEGER NOT NULL, created_at INTEGER NOT NULL)''');
          raw.execute('''CREATE TABLE budgets (
            id INTEGER PRIMARY KEY AUTOINCREMENT, category_id INTEGER,
            currency TEXT NOT NULL, digits INTEGER NOT NULL,
            start_month INTEGER NOT NULL, amount_minor INTEGER)''');
          raw.execute(
            '''CREATE UNIQUE INDEX budgets_scope
            ON budgets(COALESCE(category_id, 0), currency, digits, start_month)''',
          );
          raw.execute('''INSERT INTO categories
            (id, name, type, parent_id, sort_order)
            VALUES (1, 'Food', 'expense', NULL, 0)''');
          raw.execute('''INSERT INTO budgets
            (category_id, currency, digits, start_month, amount_minor) VALUES
            (NULL, 'INR', 2, 202603, 90000), (1, 'INR', 2, 202603, 20000),
            (1, 'INR', 2, 202605, NULL), (1, 'USD', 2, 202603, 500)''');
          raw.userVersion = 6;
        },
      ),
      false,
    );
    try {
      final repository = BudgetRepository(upgraded);
      final march = await repository.loadMonth(DateTime(2026, 3), 'INR', 2);
      expect(march.allSpending!.limit, 90000);
      expect(march.budgets.single.categoryIds, [1]);
      expect(march.budgets.single.limit, 20000);
      final may = await repository.loadMonth(DateTime(2026, 5), 'INR', 2);
      expect(may.allSpending!.limit, 90000);
      expect(may.budgets, isEmpty);
      final dollars = await repository.loadMonth(DateTime(2026, 3), 'USD', 2);
      expect(dollars.budgets.single.limit, 500);
    } finally {
      await upgraded.close();
    }
  });

  test(
    'profile sample data includes carried-forward and custom budgets',
    () async {
      final profileDb = AppDatabase(NativeDatabase.memory(), true);
      try {
        final repository = BudgetRepository(profileDb);
        final june = await repository.loadMonth(DateTime(2026, 6), 'INR', 2);
        final august = await repository.loadMonth(DateTime(2026, 8), 'INR', 2);
        expect(june.budgets, hasLength(6));
        expect(june.budgets.first.limit, 800000);
        expect(august.budgets.first.limit, 500000);
        final custom = june.budgets.singleWhere((line) => line.isCustom);
        expect(custom.name, 'Fun & shopping');
        expect(custom.categoryIds, hasLength(2));
        expect(
          (await repository.loadMonth(DateTime(2026, 1), 'INR', 2)).isEmpty,
          isTrue,
        );
      } finally {
        await profileDb.close();
      }
    },
  );

  testWidgets('derived category total opens its summary, not the editor', (
    tester,
  ) async {
    await tester.runAsync(
      () => setBudget(['Food & Beverage'], DateTime.now(), 3750000),
    );
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
        budgetStore: budgets,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    final derivedTotal = find.text('Total of category budgets');
    expect(derivedTotal, findsOneWidget);

    await tester.tap(derivedTotal);
    await tester.pumpAndSettle();
    expect(find.text('Total of category budgets'), findsOneWidget);
    expect(find.text('Adds up your 1 category budget.'), findsOneWidget);
    expect(find.byTooltip('Edit budget'), findsNothing);
    expect(find.text('Total spending'), findsNothing);
  });

  testWidgets('a budget opens its month summary, which leads to the editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    await tester.runAsync(() async {
      await spend(120000, month, 'Cafe');
      await spend(30000, month, 'Groceries');
      await spend(50000, DateTime(now.year, now.month - 1, 3), 'Cafe');
      await setBudget(
        ['Food & Beverage'],
        DateTime(now.year, now.month - 1),
        300000,
      );
    });
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
        budgetStore: budgets,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Food & Beverage').last);
    await tester.pumpAndSettle();
    expect(find.text('Category budget'), findsOneWidget);
    expect(find.text('Left to spend'), findsOneWidget);
    expect(find.text('₹1,500'), findsWidgets);
    expect(find.text('of ₹3,000'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Spending pace'), findsOneWidget);
    expect(find.text('Spent so far'), findsOneWidget);
    expect(find.text('Even pace by today'), findsOneWidget);
    expect(find.text('By subcategory'), findsOneWidget);
    expect(find.text('Last 6 months'), findsOneWidget);
    expect(find.text('Transactions'), findsOneWidget);
    expect(find.text('₹1,200'), findsWidgets);
    expect(find.text('Edit budget'), findsNothing);

    // The pencil opens the editor; closing it comes back here.
    await tester.tap(find.byTooltip('Edit budget'));
    await tester.pumpAndSettle();
    expect(find.text('Edit budget'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Spending pace'), findsOneWidget);

    // Removing the budget goes back to the list.
    await tester.tap(find.byTooltip('Edit budget'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove budget'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GlassButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GlassButton, 'Yes, remove'));
    await tester.pumpAndSettle();
    expect(find.text('Spending pace'), findsNothing);
    expect(find.text('Set your first budget'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Budgets tab sets, shows, and removes budgets; Home follows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => spend(200000, DateTime.now(), 'Cafe'));

    Future<void> tapDigits(String digits) async {
      for (final digit in digits.split('')) {
        await tester.tap(
          find.descendant(
            of: find.byType(NumberKeypad),
            matching: find.text(digit),
          ),
        );
      }
      await tester.pump();
    }

    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
        budgetStore: budgets,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Net savings'), findsOneWidget);
    expect(find.text('Budget left'), findsNothing);
    expect(find.text('Over budget'), findsNothing);

    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    expect(find.text('Set your first budget'), findsOneWidget);

    expect(find.text('Set a total monthly budget'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Set a budget'), findsOneWidget);

    // Existing total budgets still display alongside category budgets.
    await tester.runAsync(() async {
      await setTotal(DateTime.now(), 150000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Total monthly budget'), findsOneWidget);
    expect(find.text('₹1,500'), findsOneWidget);
    expect(find.text('₹500 over'), findsOneWidget);
    expect(find.text('133% used'), findsOneWidget);
    expect(find.text('Add a category budget'), findsOneWidget);

    // "+" starts on the first category without a budget; Add category
    // slides over to combine it with another into a custom budget.
    await tester.tap(find.byTooltip('Add budget'));
    await tester.pumpAndSettle();
    // Its title and its one category chip, which can't be taken out.
    expect(find.text('Food & Beverage'), findsNWidgets(2));
    expect(find.byTooltip('Remove Food & Beverage'), findsNothing);
    await tester.tap(find.text('Add category'));
    await tester.pumpAndSettle();
    expect(find.text('Choose categories'), findsOneWidget);
    await tester.tap(find.text('Transportation'));
    await tester.pump();
    await tester.tap(find.widgetWithText(GlassButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.text('Food & Beverage + 1 more'), findsOneWidget);
    expect(find.text('2 categories'), findsOneWidget);
    expect(find.byTooltip('Remove Food & Beverage'), findsOneWidget);
    expect(find.byTooltip('Remove Transportation'), findsOneWidget);

    await tester.tap(find.byTooltip('Change icon'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an icon'), findsOneWidget);
    await tester.tap(
      find
          .descendant(
            of: find.byType(SelectIconScreen),
            matching: find.byType(AppIcon),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tapDigits('3000');
    await tester.tap(find.widgetWithText(GlassButton, 'Set budget'));
    await tester.pumpAndSettle();
    expect(find.text('Food & Beverage + 1 more'), findsOneWidget);
    expect(find.text('Food & Beverage, Transportation'), findsOneWidget);
    expect(find.text('₹3,000'), findsOneWidget);
    expect(find.text('₹1,000 left'), findsOneWidget);
    expect(find.text('67%'), findsOneWidget);
    final saved = await tester.runAsync(() => load(DateTime.now()));
    expect(saved!.budgets.single.icon, isNotNull);

    await tester.tap(find.text('Food & Beverage + 1 more'));
    await tester.pumpAndSettle();
    expect(find.text('Custom budget'), findsOneWidget);
    // "+1 more" lists what the custom budget combines.
    await tester.tap(find.text('+1 more'));
    await tester.pumpAndSettle();
    expect(find.text('Included categories'), findsOneWidget);
    expect(find.text('Transportation'), findsOneWidget);
    expect(find.text('With its subcategories'), findsNWidgets(2));
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('Included categories'), findsNothing);
    await tester.tap(find.byTooltip('Edit budget'));
    await tester.pumpAndSettle();
    expect(find.text('Edit budget'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove budget'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GlassButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GlassButton, 'Yes, remove'));
    await tester.pumpAndSettle();
    expect(find.text('Food & Beverage + 1 more'), findsNothing);
    expect(find.text('Add a category budget'), findsOneWidget);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Over budget'), findsOneWidget);
    expect(
      find.textContaining('of ₹1,500', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('Over budget'));
    await tester.pumpAndSettle();
    expect(find.text('Total monthly budget'), findsOneWidget);

    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The editor scrolls rather than overflowing on a small, large-text screen.
    await tester.tap(find.byTooltip('Add budget'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
