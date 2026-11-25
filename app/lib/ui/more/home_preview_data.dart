import '../../data/db/memory_executor.dart';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../../data/db/app_database.dart';
import '../../data/repositories/account_repository.dart';
import '../../data/repositories/category_repository.dart';
import '../../data/repositories/debt_repository.dart';
import '../../data/repositories/home_repository.dart';
import '../../data/repositories/insights_repository.dart';
import '../../data/repositories/loan_repository.dart';
import '../../data/repositories/sms_import_repository.dart';
import '../../data/repositories/recurring_payment_repository.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../domain/account.dart';
import '../../domain/bank_institution_icon.dart';
import '../../domain/budget.dart';
import '../../domain/category.dart';
import '../../domain/currency_scope.dart';
import '../../domain/debt.dart';
import '../../domain/loan.dart';
import '../../domain/recurring_payment.dart';
import '../../domain/transaction.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/debt_store.dart';
import '../../state/loan_store.dart';
import '../../state/security_controller.dart';
import '../../state/sms_import_store.dart';
import '../../state/recurring_payment_store.dart';
import '../../state/transaction_store.dart';
import '../home/home_cards.dart';

/// A made-up month, built in memory, for the arrange screen to draw Home's
/// real cards with. Nothing here is read from or written to the user's
/// ledger: the stores are filled directly and the database behind them is
/// never opened.
class HomePreviewData {
  HomePreviewData._({
    required this.database,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.loanStore,
    required this.recurringPaymentStore,
    required this.debtStore,
    required this.smsStore,
    required this.security,
    required this.summary,
    required this.insights,
    required this.budget,
    required this.month,
    required this.paceNow,
  });

  final AppDatabase database;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final LoanStore loanStore;
  final RecurringPaymentStore recurringPaymentStore;
  final DebtStore debtStore;
  final SmsImportStore smsStore;

  /// Set to show amounts plainly, whatever the user's own privacy setting:
  /// these are example figures.
  final SecurityController security;
  final HomeSummary summary;
  final HomeInsights insights;
  final BudgetMonth budget;
  final DateTime month;
  final DateTime paceNow;

  static const currency = SingleCurrency('INR', 2);

  /// Home's cards drawn from this data, with no taps leading anywhere.
  HomeCardContext get context => HomeCardContext(
    accountStore: accountStore,
    categoryStore: categoryStore,
    transactionStore: transactionStore,
    loanStore: loanStore,
    recurringPaymentStore: recurringPaymentStore,
    debtStore: debtStore,
    smsStore: smsStore,
    onReviewSms: (_) {},
    month: month,
    currency: currency,
    summary: summary,
    insights: insights,
    budget: budget,
    spaced: false,
    paceNow: paceNow,
    onOpenTransactions: () {},
    onOpenBudgets: () {},
  );

  static HomePreviewData create({DateTime? now}) {
    final today = now ?? DateTime.now();
    final month = DateTime(today.year, today.month);
    // The month is shown as if it were the 12th, so there is a good stretch
    // of spending to draw whatever day it really is.
    final paceNow = DateTime(month.year, month.month, 12);
    final monthLength = DateTime(month.year, month.month + 1, 0).day;
    final previousLength = DateTime(month.year, month.month, 0).day;
    final database = AppDatabase(memoryExecutor(), false);

    // ------------------------------------------------------------ accounts
    final accountStore = AccountStore(AccountRepository(database))
      ..usePreview([
        Account(
          id: 1,
          name: 'HDFC Salary',
          currency: 'INR',
          digits: 2,
          balanceMinor: 8425000,
          icon: bankInstitutionIcon('HDFC Bank'),
          lastDigits: '4821',
        ),
        Account(
          id: 2,
          name: 'SBI Savings',
          currency: 'INR',
          digits: 2,
          balanceMinor: 3140000,
          icon: bankInstitutionIcon('State Bank of India'),
          lastDigits: '2199',
        ),
        Account(
          id: 3,
          name: 'ICICI Card',
          currency: 'INR',
          digits: 2,
          balanceMinor: -1840000,
          icon: bankInstitutionIcon('ICICI Bank', creditCard: true),
          type: AccountType.creditCard,
          lastDigits: '7730',
          creditLimitMinor: 20000000,
          availableCreditLimitMinor: 18160000,
        ),
        const Account(
          id: 4,
          name: 'Cash',
          currency: 'INR',
          digits: 2,
          balanceMinor: 320000,
          icon: 'wallet_one',
          type: AccountType.cash,
        ),
      ]);
    final categoryStore = CategoryStore(CategoryRepository(database))
      ..usePreview(const [
        Category(
          id: 1,
          name: 'Food & Beverage',
          type: CategoryType.expense,
          icon: 'fork_spoon',
        ),
        Category(
          id: 2,
          name: 'Shopping',
          type: CategoryType.expense,
          icon: 'shopping_bag',
        ),
        Category(
          id: 3,
          name: 'Transport',
          type: CategoryType.expense,
          icon: 'car',
        ),
        Category(
          id: 4,
          name: 'Bills & Utilities',
          type: CategoryType.expense,
          icon: 'credit',
        ),
        Category(
          id: 5,
          name: 'Salary',
          type: CategoryType.income,
          icon: 'income_one',
        ),
      ]);
    final transactionStore = TransactionStore(
      TransactionRepository(database),
      accountStore,
    );

    // ------------------------------------------------------- this month
    const byCategory = [
      ('Food & Beverage', 'fork_spoon', 1240000),
      ('Shopping', 'shopping_bag', 830000),
      ('Transport', 'car', 410000),
      ('Bills & Utilities', 'credit', 380000),
    ];
    final spent = byCategory.fold(0, (sum, c) => sum + c.$3);
    const income = 8500000;
    List<int> spread(int total, int days, int length) {
      // Uneven days that add up exactly: weights first, the remainder on the
      // last day so no money goes missing.
      final weights = [for (var d = 0; d < days; d++) 1 + (d * 5) % 4];
      final sum = weights.fold(0, (a, b) => a + b);
      final values = [for (final w in weights) total * w ~/ sum];
      values[days - 1] += total - values.fold(0, (a, b) => a + b);
      return [...values, for (var d = days; d < length; d++) 0];
    }

    final daily = spread(spent, paceNow.day, monthLength);
    final previousDaily = spread(2610000, previousLength, previousLength);
    DateTime day(int d) => DateTime(month.year, month.month, d, 12);
    final summary = HomeSummary(
      income: income,
      spent: spent,
      previousSpent: 2610000,
      dailyIncome: [for (var d = 1; d <= monthLength; d++) d == 1 ? income : 0],
      dailyExpenses: daily,
      categories: [
        for (final c in byCategory) (name: c.$1, icon: c.$2, amount: c.$3),
      ],
      recent: [
        MoneyTransaction(
          id: 1,
          type: TransactionType.expense,
          amountMinor: 85000,
          accountId: 1,
          categoryId: 1,
          title: 'Groceries',
          date: day(12),
        ),
        MoneyTransaction(
          id: 2,
          type: TransactionType.income,
          amountMinor: income,
          accountId: 1,
          categoryId: 5,
          title: 'Salary',
          date: day(11),
        ),
        MoneyTransaction(
          id: 3,
          type: TransactionType.expense,
          amountMinor: 18000,
          accountId: 4,
          categoryId: 1,
          title: 'Coffee',
          date: day(10),
        ),
      ],
    );

    // ---------------------------------------------------------- six months
    const flowIncome = [7800000, 8000000, 8000000, 8200000, 8200000, income];
    const flowSpent = [3100000, 2900000, 3400000, 3000000, 3300000];
    final insights = HomeInsights(
      previousDailyExpenses: previousDaily,
      flows: [
        for (var i = 0; i < 6; i++)
          (
            month: DateTime(month.year, month.month - 5 + i),
            income: flowIncome[i],
            spent: i < 5 ? flowSpent[i] : spent,
          ),
      ],
      balances: const [6200000, 7400000, 8300000, 9600000, 10800000, 10045000],
    );

    // ------------------------------------------------ due soon, and loans
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final loanStore =
        LoanStore(
            LoanRepository(database),
            accountStore: accountStore,
            categoryStore: categoryStore,
            transactionStore: transactionStore,
          )
          ..loans = [
            Loan(
              id: 1,
              accountId: 1,
              terms: LoanTerms(
                lender: 'HDFC Bank',
                kind: LoanKind.car,
                icon: bankInstitutionIcon('HDFC Bank'),
                principal: 50000000,
                openingBalance: 50000000,
                rate: 9.5,
                months: 36,
                emi: 1601700,
                paidBefore: 0,
                firstDue: tomorrow,
                day: tomorrow.day,
                currency: 'INR',
                digits: 2,
                asset: 'Car',
              ),
            ),
          ];
    final recurringPaymentStore =
        RecurringPaymentStore(
            RecurringPaymentRepository(database),
            accountStore: accountStore,
            categoryStore: categoryStore,
            transactionStore: transactionStore,
          )
          ..recurringPayments = [
            RecurringPayment(
              id: 1,
              name: 'Netflix',
              icon: 'brand:netflix',
              amountMinor: 64900,
              currency: 'INR',
              digits: 2,
              cycle: BillingCycle.monthly,
              nextDue: tomorrow,
              day: tomorrow.day,
              accountId: 1,
              categoryId: 4,
              // The card only lists recurring payments that have a reminder on.
              remind: true,
              paused: false,
            ),
          ];
    final debtStore =
        DebtStore(
          DebtRepository(database),
          accountStore: accountStore,
          categoryStore: categoryStore,
          transactionStore: transactionStore,
        )..usePreview([
          PersonDebts(const DebtPerson(id: 1, name: 'Alex'), [
            DebtEntry(
              id: 1,
              personId: 1,
              kind: DebtKind.lend,
              amountMinor: 150000,
              currency: 'INR',
              digits: 2,
              date: DateTime(today.year, today.month, today.day - 14),
              dueDate: DateTime(today.year, today.month, today.day + 3),
            ),
          ]),
        ]);

    // -------------------------------------------------------------- SMS
    final smsStore =
        SmsImportStore(
            SmsImportRepository(database),
            autoImport: false,
            engineLoader: () async =>
                throw UnsupportedError('Example data only.'),
          )
          ..enabled = true
          ..pendingCount = 3
          ..pending = [
            for (final (i, (who, bank, amount, credit)) in const [
              ('Swiggy', 'HDFC Bank', 34900, false),
              ('Amazon Pay', 'HDFC Bank', 129900, false),
              ('Rahul K', 'State Bank of India', 250000, true),
            ].indexed)
              PendingSmsImport(
                id: 'example-$i',
                sender: bank,
                body: '',
                receivedAt: today.subtract(Duration(days: i)),
                data: {
                  'amountMinor': amount,
                  'currencyCode': 'INR',
                  'direction': credit ? 'credit' : 'debit',
                  'counterparty': who,
                  'bankName': bank,
                  'accountLast4': '4821',
                },
              ),
          ]
          ..lastScan = const SmsScanSummary(accountsAdded: 2, saved: 42);

    return HomePreviewData._(
      database: database,
      accountStore: accountStore,
      categoryStore: categoryStore,
      transactionStore: transactionStore,
      loanStore: loanStore,
      recurringPaymentStore: recurringPaymentStore,
      debtStore: debtStore,
      smsStore: smsStore,
      security: SecurityController()..hideAmounts = false,
      summary: summary,
      insights: insights,
      budget: BudgetMonth(
        allSpending: BudgetLine(limit: 4000000, spent: spent),
        budgets: const [],
      ),
      month: month,
      paceNow: paceNow,
    );
  }

  Future<void> dispose() async {
    for (final notifier in <ChangeNotifier>[
      smsStore,
      debtStore,
      recurringPaymentStore,
      loanStore,
      transactionStore,
      categoryStore,
      accountStore,
      security,
    ]) {
      notifier.dispose();
    }
    await database.close();
  }
}
