import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/confirmation_alert.dart';
import 'package:simple_money/ui/more/accounts/accounts_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/adjust_balance_sheet.dart';
import 'package:simple_money/ui/transactions/transfer_sheet.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late TransactionStore transactions;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.save(
      name: 'Cash',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
    );
    await accounts.load();
    await transactions.load();
  });

  tearDown(() async {
    transactions.dispose();
    accounts.dispose();
    await db.close();
  });

  Future<void> openSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: AccountsScreen(store: accounts, transactionStore: transactions),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Account options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('Delete alert Archive keeps the account and its history', (
    tester,
  ) async {
    final id = accounts.accounts.single.id;
    await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 1000,
      accountId: id,
      categoryId: 1,
      date: DateTime(2026),
    );
    await openSettings(tester);
    await choose(tester, 'Delete');
    await tester.tap(find.widgetWithText(GlassButton, 'Archive'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(accounts.accounts, isEmpty);
    expect(accounts.archivedAccounts.single.id, id);
    expect(accounts.archivedAccounts.single.balanceMinor, 99000);
    expect(transactions.transactions, hasLength(1));
    expect(find.text('Manage Accounts'), findsOneWidget);
  });

  testWidgets(
    'Manage accounts opens archived accounts and reflects restoration',
    (tester) async {
      final id = accounts.accounts.single.id;
      await accounts.archive(id);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: AccountsScreen(store: accounts, transactionStore: transactions),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cash'), findsNothing);
      await tester.tap(find.byTooltip('Manage accounts options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View archived accounts'));
      await tester.pumpAndSettle();
      expect(find.text('Archived accounts'), findsOneWidget);
      expect(find.text('Cash'), findsOneWidget);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      expect(find.text('Restore account'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await accounts.restore(id);
      await tester.pumpAndSettle();
      expect(find.text('No archived accounts'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Cash'), findsOneWidget);
    },
  );

  test('Deleting history preserves other balances and fixes both transfer directions', () async {
    final cash = accounts.accounts.single.id;
    await accounts.save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 200000,
    );
    final bank = accounts.accounts.last.id;
    await transactions.addTransfer(
      amountMinor: 5000,
      fromAccountId: cash,
      toAccountId: bank,
      date: DateTime(2026),
    );
    await transactions.addTransfer(
      amountMinor: 2000,
      fromAccountId: bank,
      toAccountId: cash,
      date: DateTime(2026),
    );
    await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 1000,
      accountId: cash,
      categoryId: 1,
      date: DateTime(2026),
    );
    await transactions.addExpenseOrIncome(
      type: TransactionType.income,
      amountMinor: 4000,
      accountId: bank,
      categoryId: 1,
      date: DateTime(2026),
    );
    final bankBalance = accounts.accounts.last.balanceMinor;
    expect(accounts.accounts.last.transactionCount, 3);
    await transactions.deleteAccount(cash);
    expect(accounts.accounts.single.id, bank);
    expect(accounts.accounts.single.balanceMinor, bankBalance);
    expect(accounts.accounts.single.transactionCount, 1);
    expect(transactions.transactions.single.accountId, bank);
    expect(transactions.transactions.single.type, TransactionType.income);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM transactions')
              .getSingle())
          .read<int>('n'),
      1,
    );
    await transactions.deleteAccount(bank);
    expect(accounts.accounts, isEmpty);
    expect(transactions.transactions, isEmpty);
  });

  test('Merging moves history and SMS links, sums balances, drops transfers between', () async {
    final cash = accounts.accounts.single.id;
    await accounts.save(
      name: 'Debit card',
      currency: 'INR',
      digits: 2,
      openingBalance: 30000,
    );
    final card = accounts.accounts.last.id;
    await accounts.save(
      name: 'Euro',
      currency: 'EUR',
      digits: 2,
      openingBalance: 0,
    );
    await transactions.addTransfer(
      amountMinor: 5000,
      fromAccountId: cash,
      toAccountId: card,
      date: DateTime(2026),
    );
    await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 1000,
      accountId: card,
      categoryId: 1,
      date: DateTime(2026),
    );
    await transactions.addExpenseOrIncome(
      type: TransactionType.income,
      amountMinor: 4000,
      accountId: cash,
      categoryId: 1,
      date: DateTime(2026),
    );
    await db.customStatement(
      "INSERT INTO sms_account_links(bank_key, account_id) VALUES ('hdfc:1234', $card)",
    );
    final total =
        accounts.byId(cash)!.balanceMinor + accounts.byId(card)!.balanceMinor;

    await transactions.mergeAccount(sourceId: card, targetId: cash);

    expect(accounts.byId(card), isNull);
    expect(accounts.byId(cash)!.balanceMinor, total);
    expect(accounts.byId(cash)!.transactionCount, 2);
    expect(transactions.transactions.map((t) => t.accountId), [cash, cash]);
    expect(
      transactions.transactions.where(
        (t) => t.type == TransactionType.transfer,
      ),
      isEmpty,
    );
    expect(
      (await db
              .customSelect(
                "SELECT account_id FROM sms_account_links WHERE bank_key = 'hdfc:1234'",
              )
              .getSingle())
          .read<int>('account_id'),
      cash,
    );
    final euro = accounts.accounts.last.id;
    expect(
      () => transactions.mergeAccount(sourceId: euro, targetId: cash),
      throwsArgumentError,
    );
  });

  testWidgets('Merge into picks a same-currency account and leaves one', (
    tester,
  ) async {
    await accounts.save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 200000,
    );
    await openSettings(tester);
    await choose(tester, 'Merge into…');
    await tester.tap(find.text('Bank').last);
    await tester.pumpAndSettle();
    expect(find.text('Merge into Bank?'), findsOneWidget);
    expect(find.text('Cash is removed'), findsOneWidget);
    await tester.tap(find.widgetWithText(GlassButton, 'Merge'));
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(accounts.accounts.single.name, 'Bank');
    expect(accounts.accounts.single.balanceMinor, 300000);
  });

  test('A failed deletion rolls back account and history together', () async {
    final cash = accounts.accounts.single.id;
    await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 1000,
      accountId: cash,
      categoryId: 1,
      date: DateTime(2026),
    );
    await db.customStatement(
      "CREATE TRIGGER reject_delete BEFORE DELETE ON accounts BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    );
    await expectLater(transactions.deleteAccount(cash), throwsA(anything));
    expect((await accounts.repository.load()).single.transactionCount, 1);
    expect(await transactions.repository.load(), hasLength(1));
    expect(accounts.saving, false);
    expect(transactions.saving, false);
  });

  testWidgets(
    'Account actions preselect account and save retains adjusted balance',
    (tester) async {
      await openSettings(tester);
      expect(find.text('Account info'), findsOneWidget);
      expect(find.text('Save changes'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('account-name')))
            .readOnly,
        isTrue,
      );
      await tester.tap(find.widgetWithText(GlassButton, 'Adjust balance'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AdjustBalanceSheet>(find.byType(AdjustBalanceSheet))
            .initialAccountId,
        accounts.accounts.single.id,
      );
      expect(
        find.descendant(
          of: find.byType(AdjustBalanceSheet),
          matching: find.text(accounts.accounts.single.name),
        ),
        findsOneWidget,
      );
      Navigator.of(tester.element(find.byType(AdjustBalanceSheet))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Transfer'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TransferSheet>(find.byType(TransferSheet))
            .initialFromAccountId,
        accounts.accounts.single.id,
      );
      Navigator.of(tester.element(find.byType(TransferSheet))).pop();
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => transactions.adjustBalance(
          accountId: accounts.accounts.single.id,
          mode: BalanceAdjustmentMode.add,
          amountMinor: 5000,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1,050'), findsOneWidget);
      await choose(tester, 'Edit');
      expect(find.text('Edit account'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('account-name')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byKey(const Key('account-name')), 'Wallet');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(GlassButton, 'Save changes'),
      );
      await tester.tap(find.widgetWithText(GlassButton, 'Save changes'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(accounts.accounts.single.name, 'Wallet');
      expect(accounts.accounts.single.balanceMinor, 105000);
      expect(find.text('Manage Accounts'), findsOneWidget);
    },
  );

  testWidgets(
    'Delete warns about history and last account, cancel is safe, confirm removes it',
    (tester) async {
      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 1000,
        accountId: accounts.accounts.single.id,
        categoryId: 1,
        date: DateTime(2026),
      );
      await openSettings(tester);
      await choose(tester, 'Delete');
      expect(find.byType(ConfirmationAlert), findsOneWidget);
      // One line per consequence, not a paragraph to parse.
      expect(find.text('1 transaction deleted'), findsOneWidget);
      expect(find.text('Cash · ₹990'), findsOneWidget);
      expect(find.textContaining('₹990 leaves your totals'), findsOneWidget);
      expect(find.text('No account left to record into'), findsOneWidget);
      expect(find.widgetWithText(GlassButton, 'Archive'), findsOneWidget);
      Navigator.of(tester.element(find.byType(ConfirmationAlert))).pop();
      await tester.pumpAndSettle();
      expect(accounts.accounts, hasLength(1));
      expect(transactions.transactions, hasLength(1));
      await choose(tester, 'Delete');
      await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
      await tester.pumpAndSettle();
      // A second alert asks again, since deleting can't be undone.
      expect(find.text('This can’t be undone.'), findsOneWidget);
      expect(accounts.accounts, hasLength(1));
      await tester.tap(find.widgetWithText(GlassButton, 'Yes, delete'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(accounts.accounts, isEmpty);
      expect(transactions.transactions, isEmpty);
      expect(find.text('Add your first account'), findsOneWidget);
    },
  );

  test('Archiving keeps every transaction and the balance behind it', () async {
    final cash = accounts.accounts.single.id;
    await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 1000,
      accountId: cash,
      categoryId: 1,
      date: DateTime(2026),
    );
    await transactions.archiveAccount(cash);
    // Gone from the list you can pick from, still there to be read.
    expect(accounts.accounts, isEmpty);
    expect(accounts.allAccounts, hasLength(1));
    expect(accounts.archivedAccounts.single.id, cash);
    expect(accounts.byId(cash)!.isArchived, isTrue);
    expect(accounts.byId(cash)!.archivedAt, isNotNull);
    expect(accounts.byId(cash)!.balanceMinor, 99000);
    expect(transactions.transactions, hasLength(1));

    await transactions.restoreAccount(cash);
    expect(accounts.accounts, hasLength(1));
    expect(accounts.archivedAccounts, isEmpty);
    expect(accounts.byId(cash)!.isArchived, isFalse);
    expect(accounts.byId(cash)!.balanceMinor, 99000);
  });

  test('Archiving survives a reopen, and reorder skips the archived', () async {
    final cash = accounts.accounts.single.id;
    for (final name in ['Bank', 'Wallet']) {
      await accounts.save(
        name: name,
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
    }
    await accounts.archive(cash);
    // Reordering the two that are left must not fall over the gap the
    // archived one leaves in the list the screen is showing.
    await accounts.reorder(0, 1);
    expect(accounts.accounts.map((a) => a.name), ['Wallet', 'Bank']);
    expect(accounts.archivedAccounts.single.name, 'Cash');

    final reopened = AccountStore(AccountRepository(db));
    await reopened.load();
    expect(reopened.accounts.map((a) => a.name), ['Wallet', 'Bank']);
    expect(reopened.archivedAccounts.single.name, 'Cash');
    reopened.dispose();
  });

  testWidgets('An account with no history is deleted, not archived', (
    tester,
  ) async {
    await openSettings(tester);
    await tester.tap(find.byTooltip('Account options'));
    await tester.pumpAndSettle();
    // Nothing to preserve, and archiving it would leave no entry to find it
    // from again.
    expect(find.text('Archive'), findsNothing);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('Archive is offered, explains itself, and can be undone', (
    tester,
  ) async {
    await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 1000,
      accountId: accounts.accounts.single.id,
      categoryId: 1,
      date: DateTime(2026),
    );
    await openSettings(tester);
    await choose(tester, 'Archive');
    expect(find.text('1 transaction kept'), findsOneWidget);
    expect(find.textContaining('Hidden from accounts'), findsOneWidget);
    expect(find.text('Restore from any of its entries'), findsOneWidget);
    expect(find.text('No account left to record into'), findsOneWidget);
    // One step, not the two a delete takes: archiving is reversible.
    await tester.tap(find.widgetWithText(GlassButton, 'Archive'));
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(accounts.accounts, isEmpty);
    expect(transactions.transactions, hasLength(1));
    expect(find.text('Add your first account'), findsOneWidget);
  });

  testWidgets('Deleting past the bulk threshold takes a third confirmation', (
    tester,
  ) async {
    final cash = accounts.accounts.single.id;
    for (var i = 0; i < 10; i++) {
      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 100,
        accountId: cash,
        categoryId: 1,
        date: DateTime(2026, 1, i + 1),
      );
    }
    await openSettings(tester);
    await choose(tester, 'Delete');
    expect(find.text('10 transactions deleted'), findsOneWidget);
    expect(find.textContaining('Archiving keeps all of it'), findsOneWidget);
    await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
    await tester.pumpAndSettle();
    // The extra step the first nine entries would not have earned, and it
    // comes before the last word rather than after it.
    expect(find.text('Delete 10 transactions?'), findsOneWidget);
    expect(find.text('10 entries erased for good'), findsOneWidget);
    expect(accounts.accounts, hasLength(1));
    expect(transactions.transactions, hasLength(10));
    await tester.tap(find.widgetWithText(GlassButton, 'Delete it all'));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure?'), findsOneWidget);
    await tester.tap(find.widgetWithText(GlassButton, 'Yes, delete'));
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(accounts.accounts, isEmpty);
    expect(transactions.transactions, isEmpty);
  });

  testWidgets('Under the threshold, delete still takes only two steps', (
    tester,
  ) async {
    final cash = accounts.accounts.single.id;
    for (var i = 0; i < 9; i++) {
      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 100,
        accountId: cash,
        categoryId: 1,
        date: DateTime(2026, 1, i + 1),
      );
    }
    await openSettings(tester);
    await choose(tester, 'Delete');
    expect(find.textContaining('Archiving keeps all of it'), findsNothing);
    await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 9 transactions?'), findsNothing);
    await tester.tap(find.widgetWithText(GlassButton, 'Yes, delete'));
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(accounts.accounts, isEmpty);
    expect(transactions.transactions, isEmpty);
  });

  testWidgets(
    'Confirmation fits a narrow screen with large text in both themes',
    (tester) async {
      tester.view.physicalSize = const Size(350, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: ConfirmationAlert(
                title: 'Do you want to delete this account?',
                message: 'You cannot undo this action.',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Cancel').hitTestable(), findsOneWidget);
        expect(find.text('Delete').hitTestable(), findsOneWidget);
      }
    },
  );

  testWidgets('A fact list fits the same narrow screen at double text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(350, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: ConfirmationAlert(
              title: 'Delete this account?',
              content: ConfirmationFacts(
                subtitle: 'Cash · ₹1,05,000',
                facts: [
                  ConfirmationFact(
                    Icons.delete_outline_rounded,
                    '47 transactions deleted',
                    grave: true,
                  ),
                  ConfirmationFact(
                    Icons.swap_horiz_rounded,
                    'Transfers involving it go too',
                  ),
                  ConfirmationFact(
                    Icons.account_balance_outlined,
                    'Other accounts keep their balances',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Rows wrap instead of overflowing, and the buttons stay reachable
      // below a list that is now several times taller than its one-line form.
      expect(tester.takeException(), isNull);
      expect(find.text('47 transactions deleted'), findsOneWidget);
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      expect(find.text('Delete').hitTestable(), findsOneWidget);
    }
  });
}
