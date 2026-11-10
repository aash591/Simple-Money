import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/recurring_payment_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/currency_scope.dart';
import 'package:simple_money/domain/recurring_payment.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/loan_store.dart';
import 'package:simple_money/state/recurring_payment_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/home/cards/committed_card.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late CategoryStore categories;
  late TransactionStore transactions;
  late LoanStore loans;
  late RecurringPaymentStore recurringPayments;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    categories = CategoryStore(CategoryRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    loans = LoanStore(
      LoanRepository(db),
      accountStore: accounts,
      categoryStore: categories,
      transactionStore: transactions,
    );
    recurringPayments = RecurringPaymentStore(
      RecurringPaymentRepository(db),
      accountStore: accounts,
      categoryStore: categories,
      transactionStore: transactions,
    );
    await accounts.load();
    await categories.load();
    await transactions.load();
    await accounts.save(
      name: 'Cash',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
    );
  });
  tearDown(() async {
    loans.dispose();
    recurringPayments.dispose();
    accounts.dispose();
    categories.dispose();
    transactions.dispose();
    await db.close();
  });

  Future<void> show(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: CommittedCard(
            accountStore: accounts,
            loanStore: loans,
            recurringPaymentStore: recurringPayments,
            currency: const SingleCurrency('INR', 2),
          ),
        ),
      ),
    ),
  );

  testWidgets('with no loan or subscription it invites adding one', (
    tester,
  ) async {
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Plan the next 30 days'), findsOneWidget);
    expect(find.text('Add loan'), findsOneWidget);
    expect(find.text('Add recurring payment'), findsOneWidget);
    expect(find.text('Coming up'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('once a subscription exists the full card takes over', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await RecurringPaymentRepository(db).add(
        RecurringPaymentDraft(
          name: 'Netflix',
          icon: null,
          categoryId: null,
          amountMinor: 64900,
          cycle: BillingCycle.monthly,
          nextDue: DateTime.now().add(const Duration(days: 3)),
          accountId: accounts.accounts.first.id,
          remind: false,
        ),
      );
      await recurringPayments.load();
    });
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Coming up'), findsOneWidget);
    expect(find.text('Plan the next 30 days'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
