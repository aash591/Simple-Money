import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:simple_money/ui/components/more_popup_button.dart';
import 'package:simple_money/ui/sms/sms_results_page.dart';
import 'package:simple_money/ui/transactions/transactions_screen.dart';
import 'package:simple_money/ui/components/transactions/transaction_list_row.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late CategoryStore categories;
  late TransactionStore ledger;
  late int bank;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'transactions_range_kind': 'year'});
    db = AppDatabase(NativeDatabase.memory());
    bank = await AccountRepository(
      db,
    ).save(name: 'Bank', currency: 'INR', digits: 2, openingBalance: 10000000);
    accounts = AccountStore(AccountRepository(db));
    categories = CategoryStore(CategoryRepository(db));
    ledger = TransactionStore(TransactionRepository(db), accounts);
    await Future.wait([accounts.load(), categories.load(), ledger.load()]);
  });
  tearDown(() async {
    accounts.dispose();
    categories.dispose();
    ledger.dispose();
    await db.close();
  });

  testWidgets(
    'shared browser previews 3000 unsaved rows with search, range and category filters',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final category = categories.categories.firstWhere(
        (c) => c.name == 'Personal' && c.type.name == 'expense',
      );
      final rows = [
        for (var i = 0; i < 3000; i++)
          MoneyTransaction(
            id: i,
            type: TransactionType.expense,
            amountMinor: 50000,
            accountId: bank,
            categoryId: category.id,
            title: i == 2999 ? 'Unique recipient' : 'Person $i',
            date: DateTime(2026, 10, 12),
            isCreditCard: i == 2999,
          ),
      ];
      int? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionsScreen(
              accountStore: accounts,
              categoryStore: categories,
              transactionStore: ledger,
              onAddTransaction: () {},
              initialMonth: DateTime(2026, 10, 12),
              preview: TransactionPreview(
                transactions: rows,
                needsAttentionIds: const {2999},
                onOpen: (row) => opened = row.id,
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('All time'), findsNothing);
      expect(
        find.byKey(const ValueKey('transaction-period-indicator-0')),
        findsOneWidget,
      );
      expect(find.byType(TransactionListRow), findsNWidgets(10));
      expect(find.text('Opening balance'), findsNothing);
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Needs attention'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionListRow), findsOneWidget);
      expect(
        tester
            .widget<TransactionListRow>(find.byType(TransactionListRow))
            .transaction
            .id,
        2999,
      );
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Needs attention'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ready to save'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionListRow), findsNWidgets(10));
      expect(
        tester
            .widgetList<TransactionListRow>(find.byType(TransactionListRow))
            .any((row) => row.transaction.id == 2999),
        isFalse,
      );
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      expect(find.text('Ready to save'), findsNothing);
      await tester.tap(find.text('Needs attention'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionListRow), findsOneWidget);
      await tester.tap(find.byTooltip('Search transactions'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Unique recipient');
      await tester.pumpAndSettle();
      expect(find.byType(TransactionListRow), findsOneWidget);
      final row = tester.widget<TransactionListRow>(
        find.byType(TransactionListRow),
      );
      expect(row.transaction.id, 2999);
      final amount = find.descendant(
        of: find.byType(TransactionListRow),
        matching: find.text(row.formattedAmount),
      );
      expect(tester.widget<Text>(amount).style?.color, Colors.orange);
      await tester.tap(find.byType(TransactionListRow));
      expect(opened, 2999);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      expect(find.text('Select account'), findsOneWidget);
      expect(find.text('Adjust balance'), findsNothing);
      await tester.tap(find.text('Select time range'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('transaction-period')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('transaction-period-indicator-0')),
        findsOneWidget,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          'transactions_range_kind',
        ),
        'year',
      );
      expect(await TransactionRepository(db).load(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'bulk save uses package categories and recipient titles without row review',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = BankSmsParser(
        const RuleCompiler().loadRuntime(
          jsonDecode(
            File(
              'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
            ).readAsStringSync(),
          ) as Map<String, dynamic>,
        ),
      );
      final repository = SmsImportRepository(db);
      final store = SmsImportStore(
        repository,
        engineLoader: () async => engine,
      );
      await db.transaction(() async {
        for (var i = 0; i < 150; i++) {
          final sms = BankSms(
            sender: 'ATMSBI',
            body:
                'Rs 500 debited via UPI to VPA Person$i@bank UPI Ref No ${987650 + i} from A/c X1234. Avl Bal Rs 1000.',
            receivedAt: DateTime(2026, 10, 12, 12, i),
          );
          await repository.enqueue(sms, engine.parse(sms));
        }
      });
      await tester.runAsync(store.reload);
      expect(store.pendingCount, 150);
      expect(store.pending, hasLength(50));
      final originalNotes = (await repository.pending())
          .map((sms) => 'Sender: ${sms.sender}\n\n${sms.body}')
          .toList();
      await tester.runAsync(() => store.linkAccount(store.pending.first, bank));
      var reviewed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SmsResultsPage(
            store: store,
            accounts: accounts,
            categories: categories,
            transactions: ledger,
            onReview: (_) => reviewed++,
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TransactionsScreen), findsOneWidget);
      expect(find.text('Total transactions: 150'), findsOneWidget);
      expect(find.byType(TransactionListRow), findsWidgets);
      Future<void> settleQuery() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pumpAndSettle();
      }

      expect(find.byTooltip('Next page'), findsNothing);
      expect(find.byType(TransactionListRow), findsNWidgets(10));
      expect(find.byKey(const Key('transaction-period')), findsOneWidget);
      expect(find.text('SMS review'), findsOneWidget);
      List<String> menuLabels() => tester
          .widget<MorePopupButton>(
            find.byWidgetPredicate((widget) => widget is MorePopupButton),
          )
          .items
          .map((item) => item.label)
          .toList();
      expect(menuLabels(), contains('Needs attention'));
      expect(menuLabels(), isNot(contains('Ready to save')));
      expect(menuLabels(), isNot(contains('All transactions')));
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Needs attention'));
      await tester.pumpAndSettle();
      expect(menuLabels(), contains('Ready to save'));
      expect(menuLabels(), isNot(contains('Needs attention')));
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ready to save'));
      await tester.pumpAndSettle();
      expect(menuLabels(), contains('Needs attention'));
      expect(menuLabels(), isNot(contains('Ready to save')));
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Needs attention'));
      await tester.pumpAndSettle();
      expect(menuLabels(), contains('Ready to save'));
      expect(menuLabels(), isNot(contains('Needs attention')));
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search transactions'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Person0@bank');
      await tester.pump(const Duration(milliseconds: 300));
      await settleQuery();
      expect(find.byType(TransactionListRow), findsOneWidget);
      expect(
        tester
            .widget<TransactionListRow>(find.byType(TransactionListRow))
            .transaction
            .title,
        'Person0@bank',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await settleQuery();
      await tester.runAsync(() async {
        await tester.tap(find.text('Save all transactions'));
        for (var i = 0; i < 500 && store.pending.isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(store.pending, isEmpty);
      });
      await tester.pumpAndSettle();
      final saved = await TransactionRepository(db).load();
      expect(saved, hasLength(150));
      expect(await db.customSelect('SELECT * FROM sms_review').get(), isEmpty);
      expect(saved.map((row) => row.note), unorderedEquals(originalNotes));
      expect(reviewed, 0);
      final personal = categories.categories.firstWhere(
        (c) => c.name == 'Personal' && c.type.name == 'expense',
      );
      expect(saved.every((row) => row.categoryId == personal.id), isTrue);
      expect(saved.map((row) => row.title), contains('Person0@bank'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    },
  );

  testWidgets('creates cash and bulk saves identified ATM transfers only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = BankSmsParser(
      const RuleCompiler().loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
    final repository = SmsImportRepository(db);
    final store = SmsImportStore(repository, engineLoader: () async => engine);
    addTearDown(store.dispose);
    for (final body in [
      'Dear SBI Customer, Rs.500.00 withdrawn at SAMPLE ATM from A/cXX1234 on 08Oct26 Transaction number 123456. Available balance Rs.5000.00.',
      'Your A/C XXXXX1234 Credited INR 250.00 on 12/10/26 -Deposit of Cash at S1NL000001 CDM. Avl Bal INR 9,876.54-SBI',
      'Rs.500 debited from your account on 13Sep25. Avl Bal Rs.1000',
    ]) {
      final message = BankSms(
        sender: body.contains('Deposit of Cash') ? 'CBSSBI' : 'ATMSBI',
        body: body,
        receivedAt: DateTime(2026, 10, 8),
      );
      await repository.enqueue(message, engine.parse(message));
    }
    await tester.runAsync(store.reload);
    expect(store.pending, hasLength(3));
    final depositSms = store.pending.singleWhere((sms) => sms.isAtmDeposit);
    await expectLater(
      repository.save(
        depositSms,
        type: TransactionType.income,
        amountMinor: depositSms.amountMinor,
        accountId: bank,
        date: depositSms.receivedAt,
      ),
      throwsStateError,
    );
    await tester.runAsync(
      () => store.linkAccount(
        store.pending.singleWhere((sms) => sms.isAtmWithdrawal),
        bank,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SmsResultsPage(
          store: store,
          accounts: accounts,
          categories: categories,
          transactions: ledger,
          onReview: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Needed for ATM cash'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Create 1 account'));
      for (
        var i = 0;
        i < 100 && !accounts.accounts.any((a) => a.type == AccountType.cash);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(find.text('Total transactions: 3'), findsOneWidget);
      // The unnumbered debit belongs to SBI's only known account, so all
      // three are ready.
      await tester.tap(find.text('Save all transactions'));
      for (var i = 0; i < 100 && store.pending.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    final transactions = await TransactionRepository(db).load();
    expect(transactions, hasLength(3));
    final saved = transactions.singleWhere(
      (t) => t.accountId == bank && t.type == TransactionType.transfer,
    );
    expect(saved.type, TransactionType.transfer);
    expect(saved.accountId, bank);
    final cash = accounts.accounts.singleWhere(
      (a) => a.type == AccountType.cash,
    );
    expect(saved.toAccountId, cash.id);
    expect(cash.balanceMinor, 25000);
    final deposit = transactions.singleWhere((t) => t.accountId == cash.id);
    expect(deposit.type, TransactionType.transfer);
    expect(deposit.toAccountId, bank);
    expect(deposit.amountMinor, 25000);
    final debit = transactions.singleWhere(
      (t) => t.type == TransactionType.expense,
    );
    expect(debit.accountId, bank);
    expect(store.pending, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
