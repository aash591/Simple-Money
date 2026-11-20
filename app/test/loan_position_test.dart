import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/loan_reminders.dart';
import 'package:simple_money/domain/loan.dart';

LoanTerms contract({
  int principal = 10000000,
  int balance = 10000000,
  int? interest = 0,
  DateTime? start,
  DateTime? snapshot,
  double rate = 12,
  bool known = true,
  LoanInterestBasis basis = LoanInterestBasis.remaining,
  LoanAccrual accrual = LoanAccrual.daily,
  LoanCompounding compounding = LoanCompounding.none,
  int months = 12,
  int emi = 0,
  DateTime? maturity,
  DateTime? interestStarts,
  DateTime? reminder,
}) => LoanTerms(
  lender: 'Gold loan',
  kind: LoanKind.other,
  icon: 'bank',
  principal: principal,
  openingBalance: balance,
  openingInterest: interest,
  startDate: start ?? DateTime(2026, 1, 10),
  snapshotDate: snapshot ?? start ?? DateTime(2026, 1, 10),
  rate: rate,
  rateKnown: known,
  interestBasis: basis,
  accrual: accrual,
  compounding: compounding,
  months: months,
  emi: emi,
  mode: emi > 0 ? LoanRepaymentMode.emi : LoanRepaymentMode.flexible,
  firstDue: DateTime(2026, 2, 10),
  day: 10,
  paidBefore: 0,
  currency: 'INR',
  digits: 2,
  maturityDate: maturity,
  interestStartsOn: interestStarts,
  interestReminderDate: reminder,
);

void main() {
  Loan loan(LoanTerms terms, [List<LoanEvent> events = const []]) =>
      Loan(id: 1, terms: terms, accountId: 1, events: events);
  test(
    'Disbursement accrues actual days, never adds interest to principal',
    () {
      final l = loan(contract());
      expect(l.unpaidInterestAt(DateTime(2026, 1, 10)), 0);
      expect(l.unpaidInterestAt(DateTime(2026, 2, 10)), 101918);
      expect(l.outstanding, 10000000);
      expect(l.totalOutstandingAt(DateTime(2026, 2, 10)), 10101918);
      expect(l.schedule, isEmpty);
    },
  );
  test('Snapshot is the accrual origin; not disbursement a second time', () {
    final l = loan(
      contract(
        balance: 7000000,
        interest: 350000,
        snapshot: DateTime(2026, 2, 10),
        accrual: LoanAccrual.monthly,
      ),
    );
    expect(l.unpaidInterestAt(DateTime(2026, 2, 10)), 350000);
    expect(l.unpaidInterestAt(DateTime(2026, 3, 10)), 420000);
    expect(l.unpaidInterestAt(DateTime(2026, 2, 9)), isNull);
  });
  test('Unknown interest and unknown calculation never become zero', () {
    expect(
      loan(contract(interest: null)).unpaidInterestAt(DateTime(2026, 2, 10)),
      isNull,
    );
    expect(
      loan(contract(basis: LoanInterestBasis.unknown))
          .unpaidInterestAt(DateTime(2026, 2, 10)),
      isNull,
    );
    expect(
      loan(contract(known: false)).totalOutstandingAt(DateTime(2026, 2, 10)),
      isNull,
    );
    expect(
      loan(contract(compounding: LoanCompounding.unknown)).schedule,
      isEmpty,
    );
  });
  test('Daily rate changes apply from their effective date', () {
    final l = loan(contract(), [
      LoanEvent(
        id: 1,
        kind: LoanEventKind.rateChange,
        date: DateTime(2026, 1, 20),
        rateAfter: 6,
      ),
    ]);
    expect(l.unpaidInterestAt(DateTime(2026, 1, 30)), 49315);
  });
  test('Flat interest retains original basis after principal repayment', () {
    final e = LoanEvent(
      id: 1,
      kind: LoanEventKind.emi,
      date: DateTime(2026, 2, 10),
      principal: 5000000,
      interest: 100000,
      interestAfter: 0,
    );
    final flat = loan(
      contract(basis: LoanInterestBasis.original, accrual: LoanAccrual.monthly),
      [e],
    );
    final reducing = loan(contract(accrual: LoanAccrual.monthly), [e]);
    expect(flat.unpaidInterestAt(DateTime(2026, 3, 10)), 100000);
    expect(reducing.unpaidInterestAt(DateTime(2026, 3, 10)), 50000);
  });
  test('Compounding stays in interest; interest-free days do not accrue', () {
    final l = loan(
      contract(
        accrual: LoanAccrual.monthly,
        compounding: LoanCompounding.monthly,
      ),
    );
    expect(l.unpaidInterestAt(DateTime(2026, 3, 10)), 201000);
    expect(l.outstanding, 10000000);
    final grace = loan(
      contract(
        accrual: LoanAccrual.monthly,
        interestStarts: DateTime(2026, 2, 10),
      ),
    );
    expect(grace.unpaidInterestAt(DateTime(2026, 2, 10)), 0);
    expect(grace.unpaidInterestAt(DateTime(2026, 3, 10)), 100000);
  });
  test(
    'No duration survives JSON and only explicitly chosen reminders exist',
    () {
      final t = LoanTerms.fromJson(
        contract(months: 0, interest: null).toJson(),
      );
      t.validate();
      expect(t.months, 0);
      expect(t.openingInterest, isNull);
      expect(LoanReminders.reminderDates(loan(t), DateTime(2026)), isEmpty);
      final reminders = LoanReminders.reminderDates(
        loan(contract(months: 0, reminder: DateTime(2026, 1, 31))),
        DateTime(2026, 2),
      );
      expect(reminders.first.due, DateTime(2026, 2, 28));
    },
  );
  test('Forecast separates existing arrears from future interest', () {
    final t = contract(
      principal: 6000000,
      balance: 6000000,
      rate: 0,
      emi: 500000,
      interest: 100000,
      accrual: LoanAccrual.monthly,
    );
    final l = loan(t);
    final rows = l.projectedSchedule(DateTime(2026, 1, 10));
    expect(rows.fold(0, (n, r) => n + r.principal), 6000000);
    expect(rows.fold(0, (n, r) => n + r.interest), 100000);
    expect(rows.first.principal, 400000);
    expect(rows.last.balance, 0);
    expect(l.futureInterest, 0);
  });

  group('Payment ledger', () {
    late AppDatabase db;
    late LoanRepository repo;
    late int cash;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory(), false);
      repo = LoanRepository(db);
      cash = await AccountRepository(db).save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 20000000,
      );
    });
    tearDown(() => db.close());
    Future<Loan> current() async => (await repo.load()).single;
    test('Partial interest payments keep principal and unpaid interest separate, with audit and undo', () async {
      await repo.add(
        contract(
          balance: 7000000,
          interest: 350000,
          snapshot: DateTime(2026, 2, 10),
          accrual: LoanAccrual.monthly,
        ),
        cash,
      );
      await repo.record(
        await current(),
        kind: LoanEventKind.emi,
        date: DateTime(2026, 3, 10),
        accountId: cash,
        amount: 800000,
        interestCharged: 200000,
      );
      final l = await current();
      expect(l.outstanding, 6400000);
      expect(l.unpaidInterestAt(DateTime(2026, 3, 10)), 220000);
      expect(l.events.single.principalBefore, 7000000);
      expect(l.events.single.interestBefore, 420000);
      expect(l.events.single.interestAfter, 220000);
      expect(
        (await TransactionRepository(db).load()).single.amountMinor,
        800000,
      );
      await repo.undo(l);
      expect((await current()).outstanding, 7000000);
      expect((await current()).events, isEmpty);
    });
    test(
      'Gold-loan interest-only payment leaves principal unchanged',
      () async {
        await repo.add(contract(accrual: LoanAccrual.monthly), cash);
        await repo.record(
          await current(),
          kind: LoanEventKind.emi,
          date: DateTime(2026, 2, 10),
          accountId: cash,
          amount: 100000,
          interestCharged: 100000,
        );
        expect((await current()).outstanding, 10000000);
        expect((await current()).unpaidInterestAt(DateTime(2026, 2, 10)), 0);
        expect((await current()).closed, isFalse);
      },
    );
    test(
      'Unknown opening interest can be reconciled with a lender balance',
      () async {
        await repo.add(
          contract(interest: null, accrual: LoanAccrual.monthly),
          cash,
        );
        await repo.record(
          await current(),
          kind: LoanEventKind.emi,
          date: DateTime(2026, 2, 10),
          accountId: cash,
          amount: 500000,
          interestCharged: 125000,
          unpaidInterestAfter: 0,
        );
        expect((await current()).outstanding, 9625000);
        expect((await current()).unpaidInterestAt(DateTime(2026, 2, 10)), 0);
        expect((await current()).events.single.interestBefore, isNull);
      },
    );
    test('Dates and overallocations fail atomically', () async {
      await repo.add(contract(snapshot: DateTime(2026, 2, 10)), cash);
      await expectLater(
        repo.record(
          await current(),
          kind: LoanEventKind.emi,
          date: DateTime(2026, 1, 10),
          accountId: cash,
          amount: 50000,
          interestCharged: 0,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repo.record(
          await current(),
          kind: LoanEventKind.emi,
          date: DateTime(2026, 2, 10),
          accountId: cash,
          amount: 50000,
          interestCharged: 60000,
        ),
        throwsArgumentError,
      );
      expect((await current()).events, isEmpty);
      expect(await TransactionRepository(db).load(), isEmpty);
    });
    test('Disbursal transaction uses disbursement date', () async {
      await repo.add(contract(), cash, receivedIn: cash);
      expect(
        (await TransactionRepository(db).load()).single.date,
        DateTime(2026, 1, 10),
      );
    });
    test(
      'Ordinary EMI automatically allocates interest at payment date',
      () async {
        final emi = loanEmi(10000000, 12, 12);
        await repo.add(contract(accrual: LoanAccrual.monthly, emi: emi), cash);
        await repo.record(
          await current(),
          kind: LoanEventKind.emi,
          date: DateTime(2026, 2, 10),
          accountId: cash,
          amount: emi,
        );
        final l = await current();
        expect(l.events.single.interest, 100000);
        expect(l.events.single.principal, emi - 100000);
        expect(l.unpaidInterestAt(DateTime(2026, 2, 10)), 0);
      },
    );
  });
}
