import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/app.dart';
import 'package:simple_money/data/backup/data_transfer.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/people_platform.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/budget_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/debt_repository.dart';
import 'package:simple_money/data/repositories/home_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/debt.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/detail_page.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/transactions/transaction_widgets.dart';

void main() {
  late AppDatabase db;
  late DebtRepository debts;
  late int cash;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), false);
    debts = DebtRepository(db);
    cash = await AccountRepository(db)
        .save(name: 'Cash', currency: 'INR', digits: 2, openingBalance: 100000);
  });
  tearDown(() => db.close());

  Future<int> cashBalance() async =>
      (await AccountRepository(db).load()).single.balanceMinor;

  group('DebtRepository', () {
    test('Lending through an account moves money without it being '
        'spending, and being paid back settles it', () async {
      final now = DateTime.now();
      final (:personId, addedCategory: _) = await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 20000,
        accountId: cash,
        date: now,
      );
      expect(await cashBalance(), 80000);
      final rahul = (await debts.load()).single;
      expect(rahul.person.name, 'Rahul');
      expect(rahul.owesYou, isTrue);
      expect(rahul.balances.single.amountMinor, 20000);
      expect(
        (await TransactionRepository(db).load()).single.title,
        'Lent to Rahul',
      );
      final summary = await HomeRepository(db).load(now, 'INR', 2);
      expect(summary.spent, 0);
      expect(summary.income, 0);
      await BudgetRepository(db).saveTotal(
        currency: 'INR',
        digits: 2,
        fromMonth: now,
        amountMinor: 50000,
      );
      final budgets = await BudgetRepository(db).loadMonth(now, 'INR', 2);
      expect(budgets.allSpending!.spent, 0);

      await debts.addEntry(
        personId: personId,
        kind: DebtKind.collect,
        amountMinor: 20000,
        accountId: cash,
        date: now,
      );
      expect(await cashBalance(), 100000);
      expect((await debts.load()).single.settled, isTrue);
    });

    test('A record without an account leaves balances alone', () async {
      await debts.addEntry(
        newPersonName: 'Anu',
        kind: DebtKind.borrow,
        amountMinor: 5000,
        currency: 'INR',
        digits: 2,
        date: DateTime(2026, 9, 1),
      );
      expect(await cashBalance(), 100000);
      expect(await TransactionRepository(db).load(), isEmpty);
      final anu = (await debts.load()).single;
      expect(anu.owesYou, isFalse);
      expect(anu.balances.single.amountMinor, -5000);
    });

    test('Deleting a debt’s transaction removes its entry, and the person '
        'left with nothing', () async {
      await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 20000,
        accountId: cash,
        date: DateTime.now(),
      );
      final transaction = (await TransactionRepository(db).load()).single;
      await TransactionRepository(db).delete(transaction.id);
      expect(await debts.load(), isEmpty);
      expect(await cashBalance(), 100000);
    });

    test('Deleting an entry reverses its transaction', () async {
      final (:personId, addedCategory: _) = await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 20000,
        accountId: cash,
        date: DateTime.now(),
      );
      await debts.addEntry(
        personId: personId,
        kind: DebtKind.lend,
        amountMinor: 5000,
        currency: 'INR',
        digits: 2,
        date: DateTime.now(),
      );
      final linked = (await debts.load()).single.entries.firstWhere(
        (entry) => entry.transactionId != null,
      );
      await debts.deleteEntry(linked.id);
      expect(await cashBalance(), 100000);
      expect(await TransactionRepository(db).load(), isEmpty);
      expect((await debts.load()).single.balances.single.amountMinor, 5000);
    });

    test('Deleting a person reverses all their transactions', () async {
      final (:personId, addedCategory: _) = await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.borrow,
        amountMinor: 30000,
        accountId: cash,
        date: DateTime.now(),
      );
      await debts.addEntry(
        personId: personId,
        kind: DebtKind.repay,
        amountMinor: 10000,
        accountId: cash,
        date: DateTime.now(),
      );
      expect(await cashBalance(), 120000);
      await debts.deletePerson(personId);
      expect(await cashBalance(), 100000);
      expect(await debts.load(), isEmpty);
      expect(await TransactionRepository(db).load(), isEmpty);
    });

    test('Deleting an account keeps its debts, unlinked', () async {
      await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 20000,
        accountId: cash,
        date: DateTime.now(),
      );
      await AccountRepository(db).delete(cash);
      final rahul = (await debts.load()).single;
      expect(rahul.entries.single.accountId, isNull);
      expect(rahul.entries.single.transactionId, isNull);
      expect(rahul.balances.single.amountMinor, 20000);
    });

    test('Editing an entry moves its transaction with it', () async {
      await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 20000,
        accountId: cash,
        date: DateTime(2026, 9, 1),
      );
      final entry = (await debts.load()).single.entries.single;
      await debts.updateEntry(
        id: entry.id,
        amountMinor: 30000,
        accountId: cash,
        note: 'Trip',
        date: DateTime(2026, 9, 2),
        dueDate: DateTime(2026, 10, 5),
      );
      expect(await cashBalance(), 70000);
      final transaction = (await TransactionRepository(db).load()).single;
      expect(transaction.amountMinor, 30000);
      expect(transaction.note, 'Trip');
      final edited = (await debts.load()).single;
      expect(edited.balances.single.amountMinor, 30000);
      expect(edited.entries.single.dueDate, DateTime(2026, 10, 5));
    });

    test('Taking the account off an entry removes its transaction, and '
        'putting one back records it again', () async {
      await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 20000,
        accountId: cash,
        date: DateTime(2026, 9, 1),
      );
      final entry = (await debts.load()).single.entries.single;
      await debts.updateEntry(
        id: entry.id,
        amountMinor: 20000,
        currency: 'INR',
        digits: 2,
        date: entry.date,
      );
      expect(await cashBalance(), 100000);
      expect(await TransactionRepository(db).load(), isEmpty);
      final record = (await debts.load()).single;
      expect(record.entries.single.transactionId, isNull);
      expect(record.balances.single.amountMinor, 20000);

      await debts.updateEntry(
        id: entry.id,
        amountMinor: 20000,
        accountId: cash,
        date: entry.date,
      );
      expect(await cashBalance(), 80000);
      expect(
        (await TransactionRepository(db).load()).single.title,
        'Lent to Rahul',
      );
      expect(
        (await debts.load()).single.entries.single.transactionId,
        isNotNull,
      );
    });

    test('Editing someone renames the transactions they are in', () async {
      final (:personId, addedCategory: _) = await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 20000,
        accountId: cash,
        date: DateTime.now(),
      );
      await debts.updatePerson(
        personId,
        name: 'Rahul Sharma',
        phone: '+91 98765 43210',
      );
      final person = (await debts.load()).single.person;
      expect(person.name, 'Rahul Sharma');
      expect(person.phone, '+91 98765 43210');
      expect(
        (await TransactionRepository(db).load()).single.title,
        'Lent to Rahul Sharma',
      );
    });

    test('A deleted Debt/Loan category is added back when needed', () async {
      final loan = (await CategoryRepository(
        db,
      ).load()).firstWhere((category) => category.name == 'Loan');
      await CategoryRepository(db).delete(loan.id);
      final result = await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 100,
        accountId: cash,
        date: DateTime.now(),
      );
      expect(result.addedCategory, isTrue);
    });

    test('Debts are part of an export', () async {
      await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 100,
        currency: 'INR',
        digits: 2,
        date: DateTime.now(),
        dueDate: DateTime(2026, 10, 1),
      );
      final backup = parseLedgerExport(await exportLedger(db));
      expect(backup.count('debt_people'), 1);
      expect(backup.count('debt_entries'), 1);
      expect(backup.hasLedgerData, isTrue);
    });
  });

  group('PersonDebts', () {
    DebtEntry entry(int day, DebtKind kind, int amount, {DateTime? due}) =>
        DebtEntry(
          id: day,
          personId: 1,
          kind: kind,
          amountMinor: amount,
          currency: 'INR',
          digits: 2,
          date: DateTime(2026, 9, day),
          dueDate: due,
        );
    PersonDebts person(List<DebtEntry> oldestFirst) => PersonDebts(
      const DebtPerson(id: 1, name: 'Rahul'),
      oldestFirst.reversed.toList(),
    );

    test('are due when the earliest open debt is', () {
      final debts = person([
        entry(1, DebtKind.lend, 100, due: DateTime(2026, 10, 5)),
        entry(2, DebtKind.lend, 100, due: DateTime(2026, 9, 30)),
        entry(3, DebtKind.collect, 50),
      ]);
      expect(debts.dueDate, DateTime(2026, 9, 30));
      expect(debts.balances.single.amountMinor, 150);
    });

    test('forget the due date of a debt paid off in full', () {
      final debts = person([
        entry(1, DebtKind.lend, 100, due: DateTime(2026, 9, 20)),
        entry(2, DebtKind.collect, 100),
        entry(3, DebtKind.lend, 50),
      ]);
      expect(debts.dueDate, isNull);
      expect(debts.owesYou, isTrue);
    });

    test('are settled once everything is paid back', () {
      final debts = person([
        entry(1, DebtKind.borrow, 100, due: DateTime(2026, 9, 20)),
        entry(2, DebtKind.repay, 100),
      ]);
      expect(debts.settled, isTrue);
      expect(debts.dueDate, isNull);
    });
  });

  group('Debts screen', () {
    late AccountStore accounts;
    late CategoryStore categories;
    late TransactionStore transactions;

    setUp(() async {
      accounts = AccountStore(AccountRepository(db));
      categories = CategoryStore(CategoryRepository(db));
      transactions = TransactionStore(TransactionRepository(db), accounts);
      await accounts.load();
      await categories.load();
      await transactions.load();
    });
    tearDown(() {
      accounts.dispose();
      categories.dispose();
      transactions.dispose();
    });

    Future<void> tapDigits(WidgetTester tester, String digits) async {
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

    testWidgets('Lend to someone picked from contacts, then settle up', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        PeoplePlatform.channel,
        (call) async => call.method == 'pickContact'
            ? {'name': 'Rahul Sharma', 'phone': '+91 98765 43210'}
            : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(PeoplePlatform.channel, null),
      );

      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Debts'));
      await tester.pumpAndSettle();
      expect(find.text('No debts. Nice.'), findsOneWidget);

      await tester.tap(find.text('Add your first debt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I lent money'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose from contacts'));
      await tester.pumpAndSettle();
      expect(find.text('How much did you lend?'), findsOneWidget);
      expect(find.text('To Rahul Sharma'), findsOneWidget);
      await tapDigits(tester, '500');
      await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Lent to Rahul Sharma'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Rahul Sharma'), findsOneWidget);
      expect(accounts.accounts.single.balanceMinor, 50000);

      await tester.tap(find.text('Rahul Sharma'));
      await tester.pumpAndSettle();
      expect(find.textContaining('owed to you'), findsOneWidget);
      expect(find.text('+91 98765 43210'), findsOneWidget);
      // The same shell the Recurring payment and Loan pages use.
      expect(find.byType(DetailHero), findsOneWidget);
      expect(find.byType(DetailFacts), findsOneWidget);
      expect(find.byType(DetailHistoryCard), findsOneWidget);
      expect(find.text('Lent to Rahul Sharma'), findsOneWidget);
      await tester.tap(find.text('Got paid'));
      await tester.pumpAndSettle();
      expect(find.text('₹500 left to settle'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('All settled'), findsOneWidget);
      expect(
        find.text('Nothing outstanding with Rahul Sharma.'),
        findsOneWidget,
      );
      expect(accounts.accounts.single.balanceMinor, 100000);
      expect(transactions.transactions, hasLength(2));

      // Settled people stay on their side, at the end, not in a section.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Rahul Sharma'), findsOneWidget);
      // Settled reads as a green tick, and drops the pay action entirely:
      // there is nothing left to settle.
      expect(find.text('Settled'), findsOneWidget);
      expect(find.text('Got paid'), findsNothing);
      expect(find.text('Pay back'), findsNothing);
    });

    testWidgets('Edit a person, and an entry, from their page', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 20000,
        accountId: cash,
        date: DateTime(2026, 9, 1),
      );
      await accounts.load();
      await transactions.load();

      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Debts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rahul'));
      await tester.pumpAndSettle();

      // The name and phone number, from the overflow menu.
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit person'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Rahul'),
        'Rahul S',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('owed to you'), findsOneWidget);
      expect(transactions.transactions.single.title, 'Lent to Rahul S');

      // The entry itself, from its row in History.
      await tester.tap(find.text('Lent to Rahul S'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit debt'), findsOneWidget);
      await tester.tap(find.byType(AmountHero));
      await tester.pumpAndSettle();
      await tester.longPress(find.byIcon(Icons.backspace_outlined));
      await tester.pumpAndSettle();
      await tapDigits(tester, '300');
      await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('₹300'), findsWidgets);
      expect(accounts.accounts.single.balanceMinor, 70000);
      expect(transactions.transactions.single.amountMinor, 30000);
    });

    testWidgets('History sorts by date or by the order entries were added', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Added first, but dated later.
      final (:personId, addedCategory: _) = await debts.addEntry(
        newPersonName: 'Rahul',
        kind: DebtKind.lend,
        amountMinor: 10000,
        currency: 'INR',
        digits: 2,
        date: DateTime(2026, 9, 10),
      );
      await debts.addEntry(
        personId: personId,
        kind: DebtKind.lend,
        amountMinor: 5000,
        currency: 'INR',
        digits: 2,
        date: DateTime(2026, 9, 1),
      );

      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Debts'));
      await tester.pumpAndSettle();

      // Swiping switches sides.
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('You don’t owe anyone.'), findsOneWidget);
      await tester.tap(find.text('Owed to you'));
      await tester.pumpAndSettle();
      expect(find.text('People who owe you'), findsOneWidget);

      // Search, like Transactions.
      await tester.tap(find.byTooltip('Search debts'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('debt-search')), 'priya');
      await tester.pumpAndSettle();
      expect(find.text('No one matches your search.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('debt-search')), 'rah');
      await tester.pumpAndSettle();
      expect(find.text('Rahul'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rahul'));
      await tester.pumpAndSettle();

      // Scoped to History: the Details card above it names a date too.
      double top(String date) => tester
          .getTopLeft(
            find.descendant(
              of: find.byType(DetailHistoryCard),
              matching: find.textContaining(date),
            ),
          )
          .dy;
      expect(top('10 Sep 2026'), lessThan(top('1 Sep 2026')));

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort by'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recently added'));
      await tester.pumpAndSettle();
      expect(top('1 Sep 2026'), lessThan(top('10 Sep 2026')));
      expect(find.widgetWithText(TextButton, 'Recently added'), findsOneWidget);
    });
  });
}
