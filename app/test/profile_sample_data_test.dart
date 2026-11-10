import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/debt_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/recurring_payment_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/debt.dart';
import 'package:simple_money/domain/loan.dart';
import 'package:simple_money/domain/recurring_payment.dart';

void main() {
  test('release data has no sample accounts, transactions or loans', () async {
    final releaseDb = AppDatabase(NativeDatabase.memory(), false);
    try {
      expect(await AccountRepository(releaseDb).load(), isEmpty);
      expect(await TransactionRepository(releaseDb).load(), isEmpty);
      expect(await LoanRepository(releaseDb).load(), isEmpty);
      expect(await DebtRepository(releaseDb).load(), isEmpty);
      expect(await RecurringPaymentRepository(releaseDb).load(), isEmpty);
    } finally {
      await releaseDb.close();
    }
  });

  test('profile sample data covers every kind of loan', () async {
    final profileDb = AppDatabase(NativeDatabase.memory(), true);
    try {
      final loans = await LoanRepository(profileDb).load();
      // A loan that bought something is known by the thing; the rest by
      // their lender and kind.
      expect(loans.map((loan) => loan.title), [
        'HDFC Bank Home loan',
        'Swift Dzire · SBI',
        'Bajaj Finserv Personal loan',
        'SBI Education loan',
        'Muthoot Finance Gold loan',
        'Jupiter 125 · TVS Credit',
        'iPhone 16 · ICICI Bank',
        'Washing machine · HDFC Bank',
        'Flexible gold loan',
      ]);
      expect(
        loans.map((loan) => loan.terms.mode).toSet(),
        LoanRepaymentMode.values.toSet(),
      );
      expect(
        loans.map((loan) => loan.terms.kind).toSet(),
        LoanKind.values.toSet(),
      );
      Loan named(String title) =>
          loans.firstWhere((loan) => loan.title == title);

      final home = loans.first;
      expect(home.paid, 20, reason: '18 imported plus 2 recorded');
      expect(home.disbursalId, isNull, reason: 'the lender paid the builder');
      expect(home.nextDue, DateTime(2026, 10, 5));

      // Disbursed with its charges taken off the top, and one EMI bounced.
      final personal = named('Bajaj Finserv Personal loan');
      expect(personal.disbursalId, isNotNull);
      expect(personal.terms.chargesDeducted, isTrue);
      expect(personal.charges, 531000 + 59000);
      expect(personal.events.where((e) => e.fee > 0), hasLength(1));

      // Interest only: four payments in, nothing repaid.
      final education = named('SBI Education loan');
      expect(education.outstanding, education.terms.principal);
      expect(education.events.every((e) => e.principal == 0), isTrue);
      expect(education.interestPaid, 475000 * 4);

      // One payment, next year.
      final gold = named('Muthoot Finance Gold loan');
      expect(gold.schedule, hasLength(1));
      expect(gold.nextDue, DateTime(2027, 6, 6));
      expect(gold.nextAmount, 15000000 + 1650000);

      // Consumer EMIs: the dealer and the shop were paid, not us.
      final bike = named('Jupiter 125 · TVS Credit');
      expect(bike.disbursalId, isNull);
      expect(bike.chargesId, isNotNull);
      expect(bike.paid, 5);
      expect(bike.nextDue, DateTime(2026, 10, 6));

      final phone = named('iPhone 16 · ICICI Bank');
      expect(phone.disbursalId, isNull);
      expect(phone.rate, 0);
      expect(phone.nextAmount, 800000, reason: '₹72,000 over nine months');
      expect(phone.futureInterest, 0);
      expect(phone.schedule, hasLength(4));

      final card = named('Washing machine · HDFC Bank');
      expect(card.closed, isTrue);
      expect(card.interestPaid, 0, reason: 'a no-cost EMI charges no interest');
      final flexible = named('Flexible gold loan');
      expect(flexible.schedule, isEmpty);
      expect(flexible.outstanding, 7000000);
      expect(flexible.unpaidInterestAt(DateTime(2026, 9, 1)), 350000);

      final accounts = await AccountRepository(profileDb).load();
      expect(
        accounts.every((account) => account.balanceMinor > 0),
        isTrue,
        reason: 'borrowing and repaying should leave the demo ledger solvent',
      );
    } finally {
      await profileDb.close();
    }
  });

  test(
    'profile sample data covers every kind of debt and subscription',
    () async {
      final profileDb = AppDatabase(NativeDatabase.memory(), true);
      try {
        final debts = await DebtRepository(profileDb).load();
        expect(debts.map((p) => p.person.name), [
          'Amit Verma',
          'Karan Mehta',
          'Priya Nair',
          'Rahul Sharma',
          'Sneha Iyer',
        ]);
        PersonDebts named(String name) =>
            debts.firstWhere((p) => p.person.name == name);

        // Overdue loan-out, unpaid.
        final amit = named('Amit Verma');
        expect(amit.owesYou, isTrue);
        expect(amit.balances.single.amountMinor, 2500000);

        // A record-only loan-out, with no account behind it.
        final karan = named('Karan Mehta');
        expect(karan.entries.single.accountId, isNull);
        expect(karan.owesYou, isTrue);

        // Borrowed, then partly paid back — still owes them the rest.
        final priya = named('Priya Nair');
        expect(priya.owesYou, isFalse);
        expect(priya.balances.single.amountMinor, -500000);

        // A soon-due loan-out, unpaid.
        final rahul = named('Rahul Sharma');
        expect(rahul.owesYou, isTrue);
        expect(rahul.dueDate, DateTime(2026, 9, 12));

        // Borrowed, then paid back in full — settled.
        final sneha = named('Sneha Iyer');
        expect(sneha.settled, isTrue);

        final recurringPayments = await RecurringPaymentRepository(profileDb)
            .load();
        expect(recurringPayments.map((s) => s.name), [
          'Netflix',
          'Spotify',
          "Gold's Gym",
          'iCloud storage',
          'Crunchyroll',
        ]);
        expect(recurringPayments.where((s) => s.paused).map((s) => s.name), [
          'Crunchyroll',
        ]);
        expect(
          recurringPayments
              .firstWhere((s) => s.name == 'iCloud storage')
              .remind,
          isFalse,
        );
        expect(
          recurringPayments.firstWhere((s) => s.name == "Gold's Gym").cycle,
          BillingCycle.quarterly,
        );
      } finally {
        await profileDb.close();
      }
    },
  );

  test('profile sample data spans February through September 2026', () async {
    final profileDb = AppDatabase(NativeDatabase.memory(), true);
    try {
      final accounts = await AccountRepository(profileDb).load();
      final transactions = await TransactionRepository(profileDb).load();
      expect(accounts.map((account) => account.name), [
        'HDFC Bank',
        'UPI Wallet',
        'Cash',
      ]);
      // 138 everyday entries plus the 36 the loans move (disbursals, charges
      // and the EMIs recorded so far) and the 6 the debts move.
      expect(transactions, hasLength(180));
      expect(transactions.last.date, DateTime(2026, 2, 1, 12));
      expect(transactions.first.date, DateTime(2026, 9, 9, 19));
      final entriesByDay = <DateTime, int>{};
      for (final transaction in transactions) {
        final day = DateTime(
          transaction.date.year,
          transaction.date.month,
          transaction.date.day,
        );
        entriesByDay.update(day, (count) => count + 1, ifAbsent: () => 1);
      }
      expect(entriesByDay.values.every((count) => count >= 2), isTrue);
      expect(accounts.every((account) => account.transactionCount > 0), isTrue);
    } finally {
      await profileDb.close();
    }
  });
}
