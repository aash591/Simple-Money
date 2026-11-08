import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../domain/loan.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import 'transaction_repository.dart';

/// The three ledger categories a loan writes into.
enum _LoanCategory { disbursal, emi, charges }

class LoanRepository {
  LoanRepository(this.database);
  final AppDatabase database;

  /// Whether any loan still draws on the account, directly or through the
  /// transactions it wrote — the account's currency is then fixed, because a
  /// repayment history cannot be restated in another one.
  Future<bool> usesAccount(int accountId) async =>
      await database
          .customSelect(
            '''SELECT id FROM loan_events WHERE account_id = ?
          UNION ALL SELECT id FROM loans WHERE disbursal_id IN
          (SELECT id FROM transactions WHERE account_id = ?)
          UNION ALL SELECT id FROM loans WHERE charges_id IN
          (SELECT id FROM transactions WHERE account_id = ?) LIMIT 1''',
            variables: [
              Variable(accountId),
              Variable(accountId),
              Variable(accountId),
            ],
          )
          .getSingleOrNull() !=
      null;

  /// Unpicks every reference to an account being deleted. The loans and their
  /// events survive; they simply no longer name an account or its entries.
  Future<void> detachAccount(int accountId) async {
    await database.customUpdate(
      'UPDATE loans SET account_id = NULL WHERE account_id = ?',
      variables: [Variable(accountId)],
    );
    await database.customUpdate(
      'UPDATE loans SET disbursal_id = NULL WHERE disbursal_id IN (SELECT id FROM transactions WHERE account_id = ?)',
      variables: [Variable(accountId)],
    );
    await database.customUpdate(
      'UPDATE loans SET charges_id = NULL WHERE charges_id IN (SELECT id FROM transactions WHERE account_id = ?)',
      variables: [Variable(accountId)],
    );
    await database.customUpdate(
      'UPDATE loan_events SET account_id = NULL, transaction_id = NULL WHERE account_id = ?',
      variables: [Variable(accountId)],
    );
  }

  Future<List<Loan>> load() => database.transaction(() async {
    final events = <int, List<LoanEvent>>{};
    for (final r
        in await database
            .customSelect('SELECT * FROM loan_events ORDER BY id')
            .get()) {
      events
          .putIfAbsent(r.read<int>('loan_id'), () => [])
          .add(
            LoanEvent.fromJson(
              r.read<int>('id'),
              r.read<String>('kind'),
              jsonDecode(r.read<String>('payload')),
              r.readNullable<int>('account_id'),
              r.readNullable<int>('transaction_id'),
            ),
          );
    }
    return [
      for (final r
          in await database
              .customSelect('SELECT * FROM loans ORDER BY id')
              .get())
        Loan(
          id: r.read<int>('id'),
          terms: LoanTerms.fromJson(jsonDecode(r.read<String>('payload'))),
          accountId: r.readNullable<int>('account_id'),
          disbursalId: r.readNullable<int>('disbursal_id'),
          chargesId: r.readNullable<int>('charges_id'),
          events: events[r.read<int>('id')] ?? [],
        ),
    ];
  });

  Future<Loan> _current(int id, int version) async {
    final loan = (await load()).where((l) => l.id == id).firstOrNull;
    if (loan == null) throw StateError('This loan no longer exists.');
    if (loan.version != version) {
      throw StateError('This loan changed. Reopen the action and try again.');
    }
    return loan;
  }

  Future<String> _account(int id, LoanTerms terms) async {
    final row = await database
        .customSelect(
          'SELECT * FROM accounts WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) {
      throw ArgumentError('Choose an existing repayment account.');
    }
    if (row.read<String>('currency') != terms.currency ||
        row.read<int>('digits') != terms.digits) {
      throw ArgumentError(
        'Choose an account in ${terms.currency} with the same precision.',
      );
    }
    return row.read<String>('name');
  }

  /// Money borrowed is not income and repaid principal is not spending, so
  /// the disbursal is filed under Debt/Loan, which Home and Budgets leave
  /// out. Charges and EMIs are real outgoings and stay ordinary expenses.
  Future<int> _category(_LoanCategory category) async {
    final (name, type) = switch (category) {
      _LoanCategory.disbursal => ('Loan disbursal', 'debt_loan'),
      _LoanCategory.emi => ('Loan EMI', 'expense'),
      _LoanCategory.charges => ('Loan charges', 'expense'),
    };
    final row = await database
        .customSelect(
          'SELECT id FROM categories WHERE name = ? AND type = ? AND parent_id IS NULL ORDER BY id LIMIT 1',
          variables: [Variable(name), Variable(type)],
        )
        .getSingleOrNull();
    return row?.read<int>('id') ??
        await database.customInsert(
          "INSERT INTO categories (name, type, icon, sort_order) VALUES (?, ?, 'bank', (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))",
          variables: [Variable(name), Variable(type)],
        );
  }

  /// Records the loan, the money disbursed into [receivedIn] if any reached
  /// the borrower, and its opening charges. Charges netted off the disbursal
  /// reduce what lands in the account without touching the principal repaid;
  /// charges paid separately are logged as their own expense.
  ///
  /// [adoptDisbursal] and [adoptCharges] name transactions the ledger already
  /// has for those, which are filed under the loan instead of being written
  /// again; [adopted] collects what they were, for undoing.
  Future<int> add(
    LoanTerms terms,
    int accountId, {
    int? receivedIn,
    int? adoptDisbursal,
    int? adoptCharges,
    List<AdoptedTransaction>? adopted,
  }) => database.transaction(() async {
    terms.validate();
    await _account(accountId, terms);
    final (disbursal, charges) = await _takeOver(
      terms,
      accountId,
      receivedIn,
      adoptDisbursal,
      adoptCharges,
      adopted,
    );
    return database.customInsert(
      '''INSERT INTO loans (payload, account_id, disbursal_id, charges_id)
      VALUES (?, ?, ?, ?)''',
      variables: [
        Variable(jsonEncode(terms.toJson())),
        Variable(accountId),
        Variable(disbursal),
        Variable(charges),
      ],
    );
  });

  /// Like [_ledger], for a start the ledger has partly or wholly recorded.
  Future<(int?, int?)> _takeOver(
    LoanTerms terms,
    int accountId,
    int? receivedIn,
    int? adoptDisbursal,
    int? adoptCharges,
    List<AdoptedTransaction>? adopted,
  ) async {
    final transactions = TransactionRepository(database);
    // What the ledger lacks is still written the ordinary way.
    final (written, writtenCharges) = await _ledger(
      adoptCharges == null
          ? terms
          : LoanTerms.fromJson({...terms.toJson(), 'charges': 0}),
      accountId,
      adoptDisbursal == null ? receivedIn : null,
    );
    var disbursal = written;
    var charges = writtenCharges;
    if (adoptDisbursal != null) {
      final taken = await transactions.adopt(
        adoptDisbursal,
        type: TransactionType.income,
        amountMinor: terms.chargesDeducted
            ? terms.principal - terms.chargesMinor
            : terms.principal,
        categoryId: await _category(_LoanCategory.disbursal),
        title: '${terms.lender} loan disbursal',
      );
      await _account(taken.accountId, terms);
      adopted?.add(taken);
      disbursal = taken.id;
    }
    if (adoptCharges != null) {
      final taken = await transactions.adopt(
        adoptCharges,
        type: TransactionType.expense,
        amountMinor: terms.chargesMinor,
        categoryId: await _category(_LoanCategory.charges),
        title: '${terms.lender} loan charges',
      );
      await _account(taken.accountId, terms);
      adopted?.add(taken);
      charges = taken.id;
    }
    return (disbursal, charges);
  }

  /// Writes the transactions a loan's start calls for — the disbursal and
  /// any charges paid separately — and returns their ids.
  Future<(int?, int?)> _ledger(
    LoanTerms terms,
    int accountId,
    int? receivedIn,
  ) async {
    final newLoan =
        !terms.existing &&
        terms.paidBefore == 0 &&
        terms.openingBalance == terms.principal;
    int? disbursal;
    int? charges;
    if (receivedIn != null) {
      if (!newLoan) {
        throw ArgumentError('Only a new loan can record money received.');
      }
      await _account(receivedIn, terms);
      disbursal = await TransactionRepository(database).addExpenseOrIncome(
        type: TransactionType.income,
        amountMinor: terms.chargesDeducted
            ? terms.principal - terms.chargesMinor
            : terms.principal,
        accountId: receivedIn,
        categoryId: await _category(_LoanCategory.disbursal),
        title: '${terms.lender} loan disbursal',
        note: terms.chargesDeducted && terms.chargesMinor > 0
            ? 'Net of ${terms.chargesMinor} minor units of charges'
            : null,
        date: terms.startDate ?? DateTime.now(),
      );
    }
    if (terms.chargesMinor > 0 && !terms.chargesDeducted) {
      if (!newLoan) {
        throw ArgumentError(
          'Only a new loan can record charges paid separately.',
        );
      }
      charges = await TransactionRepository(database).addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: terms.chargesMinor,
        accountId: accountId,
        categoryId: await _category(_LoanCategory.charges),
        title: '${terms.lender} loan charges',
        date: terms.startDate ?? DateTime.now(),
      );
    }
    return (disbursal, charges);
  }

  /// Whether every answer that set up [loan] can still be rewritten: nothing
  /// has been recorded against it, so no payment depends on its terms.
  static bool canRestate(Loan loan) =>
      loan.events.isEmpty &&
      loan.terms.tracked &&
      loan.terms.paidBefore == 0 &&
      (loan.terms.mode == LoanRepaymentMode.emi ||
          loan.terms.mode == LoanRepaymentMode.flexible);

  /// Sets [loan] up again from new answers, as if it had been added with
  /// them: its terms, account, and the disbursal and charges transactions
  /// its start wrote, which are replaced rather than patched.
  Future<void> restate(
    Loan loan,
    LoanTerms terms,
    int accountId, {
    int? receivedIn,
  }) => database.transaction(() async {
    final current = await _current(loan.id, loan.version);
    if (!canRestate(current)) {
      throw StateError(
        'This loan has recorded payments, so its amounts and dates can’t be changed.',
      );
    }
    terms.validate();
    await _account(accountId, terms);
    await database.customUpdate(
      'UPDATE loans SET disbursal_id = NULL, charges_id = NULL WHERE id = ?',
      variables: [Variable(loan.id)],
    );
    for (final id in [current.disbursalId, current.chargesId]) {
      if (id != null) await TransactionRepository(database).delete(id);
    }
    final (disbursal, charges) = await _ledger(terms, accountId, receivedIn);
    await database.customUpdate(
      '''UPDATE loans SET payload = ?, account_id = ?, disbursal_id = ?,
      charges_id = ? WHERE id = ?''',
      variables: [
        Variable(jsonEncode(terms.toJson())),
        Variable(accountId),
        Variable(disbursal),
        Variable(charges),
        Variable(loan.id),
      ],
    );
  });

  /// The account a transaction the loan wrote went to, for pre-filling an
  /// edit. Null once that transaction or its account is gone.
  Future<int?> transactionAccount(int id) async =>
      (await database
              .customSelect(
                'SELECT account_id FROM transactions WHERE id = ?',
                variables: [Variable(id)],
              )
              .getSingleOrNull())
          ?.read<int>('account_id');

  /// Historical terms remain immutable. Corrections to future terms are events.
  Future<void> edit(
    Loan loan, {
    required String lender,
    required String icon,
    required int accountId,
    required bool remind,
    String? asset,
    String? assetIcon,
  }) => database.transaction(() async {
    final current = await _current(loan.id, loan.version);
    final terms = LoanTerms.fromJson({
      ...current.terms.toJson(),
      'lender': lender,
      'icon': icon,
      'remind': remind,
      'asset': asset,
      'assetIcon': ?assetIcon,
    });
    terms.validate();
    await _account(accountId, terms);
    await database.customUpdate(
      'UPDATE loans SET payload = ?, account_id = ? WHERE id = ?',
      variables: [
        Variable(jsonEncode(terms.toJson())),
        Variable(accountId),
        Variable(loan.id),
      ],
    );
  });

  Future<void> record(
    Loan loan, {
    required LoanEventKind kind,
    required DateTime date,
    int? accountId,
    int? amount,
    int fee = 0,
    int? interestCharged,
    int? unpaidInterestAfter,
    double? newRate,
    bool reduceEmi = false,
    int? adoptTransactionId,
    bool offLedger = false,
  }) => database.transaction(() async {
    final current = await _current(loan.id, loan.version);
    if (current.closed) throw StateError('This loan is already closed.');
    final today = DateTime.now();
    if ((current.terms.tracked &&
            date.isBefore(
              current.terms.snapshotDate ?? current.terms.startDate!,
            )) ||
        date.isAfter(
          DateTime(today.year, today.month, today.day, 23, 59, 59),
        ) ||
        (current.events.isNotEmpty &&
            date.isBefore(current.events.last.date))) {
      throw ArgumentError(
        'Use a date on or after the last loan action and no later than today.',
      );
    }
    if (fee < 0) throw ArgumentError('A fee cannot be negative.');
    final next = current.schedule.firstOrNull;
    final accrued = current.unpaidInterestAt(date);
    int principal = 0, interest = 0;
    int? emiAfter;
    double? rateAfter;
    switch (kind) {
      case LoanEventKind.emi:
        final payment = amount ?? next?.amount ?? 0;
        // A payment made late is charged more interest than the schedule
        // assumed, so what the lender actually charged can be given.
        final charged =
            interestCharged ??
            (current.terms.tracked
                ? (current.terms.mode.amortises && accrued != null
                      ? math.min(payment, accrued)
                      : null)
                : next?.interest);
        if (charged == null) {
          throw ArgumentError('Enter the interest portion of this payment.');
        }
        if (charged < 0) {
          throw ArgumentError('Interest charged cannot be negative.');
        }
        // An interest-only installment repays nothing, so it may equal the
        // interest exactly; every other kind has to exceed it.
        if (payment <= 0 ||
            payment < charged ||
            (!current.terms.tracked &&
                payment == charged &&
                (next?.principal ?? 0) > 0) ||
            payment > current.outstanding + charged) {
          throw ArgumentError(
            'Payment must cover interest and cannot exceed the amount to settle.',
          );
        }
        principal = payment - charged;
        interest = charged;
      case LoanEventKind.partPayment:
        if (amount == null || amount <= 0 || amount >= current.outstanding) {
          throw ArgumentError(
            'Enter a part-payment below the outstanding principal.',
          );
        }
        principal = amount;
        // Only an amortising loan has an EMI to lower; elsewhere a smaller
        // principal simply charges less interest.
        if (reduceEmi && current.terms.mode.amortises) {
          emiAfter = loanEmi(
            current.outstanding - amount,
            current.rate,
            current.schedule.length,
          );
        }
      case LoanEventKind.rateChange:
        if (newRate == null ||
            !newRate.isFinite ||
            newRate < 0 ||
            newRate > 100) {
          throw ArgumentError('Enter a rate from 0–100%.');
        }
        rateAfter = newRate;
        if (reduceEmi && current.terms.mode.amortises) {
          emiAfter = loanEmi(
            current.outstanding,
            newRate,
            current.schedule.length,
          );
        }
      case LoanEventKind.closure:
        if (amount == null || amount < current.outstanding) {
          throw ArgumentError(
            'Settlement must cover the outstanding principal.',
          );
        }
        principal = current.outstanding;
        interest = amount - principal;
    }
    if (current.terms.hasSchedule) {
      loanSchedule(
        principal: current.outstanding - principal,
        rate: rateAfter ?? current.rate,
        emi: emiAfter ?? current.emi,
        first: current.nextDue,
        day: current.terms.day,
        mode: current.terms.mode,
        months: current.remainingMonths,
        basis: current.terms.interestBasis,
        originalPrincipal: current.terms.principal,
      );
    }
    int? interestAfter;
    if (current.terms.tracked) {
      if (unpaidInterestAfter != null && unpaidInterestAfter < 0) {
        throw ArgumentError('Unpaid interest cannot be negative.');
      }
      if (kind == LoanEventKind.closure) {
        interestAfter = 0; // Explicit lender settlement confirms closure.
      } else if (unpaidInterestAfter != null) {
        interestAfter = unpaidInterestAfter;
      } else if (accrued != null) {
        if (interest > accrued) {
          throw ArgumentError(
            'Interest paid exceeds the estimate. Enter the unpaid interest after payment from your lender statement.',
          );
        }
        interestAfter = accrued - interest;
      }
    }
    int? transactionId;
    String? accountName;
    AdoptedTransaction? adopted;
    int? eventAccount = accountId;
    if (offLedger) {
      eventAccount = null;
    } else if (adoptTransactionId != null) {
      adopted = await TransactionRepository(database).adopt(
        adoptTransactionId,
        type: TransactionType.expense,
        amountMinor: principal + interest + fee,
        categoryId: await _category(_LoanCategory.emi),
        title: current.title,
      );
      eventAccount = adopted.accountId;
      accountName = await _account(adopted.accountId, current.terms);
      transactionId = adopted.id;
    } else if (kind != LoanEventKind.rateChange) {
      if (accountId == null) throw ArgumentError('Choose a repayment account.');
      accountName = await _account(accountId, current.terms);
      transactionId = await TransactionRepository(database).addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: principal + interest + fee,
        accountId: accountId,
        categoryId: await _category(_LoanCategory.emi),
        title: current.title,
        note:
            '${kind.name}: principal $principal, interest $interest, fee $fee (minor units)',
        date: date,
      );
    }
    final event = LoanEvent(
      id: 0,
      kind: kind,
      date: date,
      principal: principal,
      interest: interest,
      fee: kind == LoanEventKind.rateChange ? 0 : fee,
      emiAfter: emiAfter,
      rateAfter: rateAfter,
      accountName: accountName,
      principalBefore: current.terms.tracked ? current.outstanding : null,
      interestBefore: accrued,
      interestAfter: interestAfter,
      adopted: adopted?.toJson(),
      offLedger: offLedger,
    );
    await database.customInsert(
      '''INSERT INTO loan_events
        (loan_id, kind, installment, payload, account_id, transaction_id) VALUES (?, ?, ?, ?, ?, ?)''',
      variables: [
        Variable(current.id),
        Variable(kind.name),
        Variable(kind == LoanEventKind.emi ? current.paid + 1 : null),
        Variable(jsonEncode(event.toJson())),
        Variable(eventAccount),
        Variable(transactionId),
      ],
    );
  });

  /// The category a loan's payments are filed under.
  Future<int> paymentCategory() => _category(_LoanCategory.emi);

  /// Makes saved expense [transactionId] the loan's next payment: a bank SMS
  /// or a transaction already in the ledger, so the money isn't recorded
  /// twice. Its amount, account and date stay. Interest is what has built up
  /// by then, as for a payment made from the loan's own screen.
  Future<void> payWith(int loanId, int transactionId) =>
      database.transaction(() async {
        final loan = (await load()).where((l) => l.id == loanId).firstOrNull;
        if (loan == null) throw StateError('This loan no longer exists.');
        final row = await database
            .customSelect(
              'SELECT amount_minor, account_id, date FROM transactions WHERE id = ?',
              variables: [Variable(transactionId)],
            )
            .getSingle();
        final date = DateTime.fromMillisecondsSinceEpoch(row.read<int>('date'));
        final amount = row.read<int>('amount_minor');
        final accrued = loan.unpaidInterestAt(date);
        await record(
          loan,
          kind: LoanEventKind.emi,
          date: date,
          accountId: row.read<int>('account_id'),
          amount: amount,
          // A loan with no estimate can't say; the payment then counts
          // towards the principal and can be corrected from the loan.
          interestCharged: !loan.terms.tracked
              ? null
              : accrued == null
              ? 0
              : math.min(amount, accrued),
          adoptTransactionId: transactionId,
        );
      });

  Future<void> undo(Loan loan) => database.transaction(() async {
    final current = await _current(loan.id, loan.version);
    if (current.events.isEmpty) return;
    final event = current.events.last;
    if (event.kind != LoanEventKind.rateChange &&
        event.transactionId == null &&
        !event.offLedger) {
      throw StateError(
        'This payment’s account was deleted; its payment history is retained.',
      );
    }
    await database.customUpdate(
      'DELETE FROM loan_events WHERE id = ?',
      variables: [Variable(event.id)],
    );
    if (event.adopted case final adopted?) {
      await TransactionRepository(
        database,
      ).release(AdoptedTransaction.fromJson(adopted));
    } else if (event.transactionId != null) {
      await TransactionRepository(database).delete(event.transactionId!);
    }
  });

  /// Takes back a loan that was set up from a statement, as if it had never
  /// been added: every payment is undone, the start's own transactions go,
  /// and the ones it took over from the ledger are given back. Only while
  /// nothing has been recorded since — [version] says what it was left at.
  Future<void> unwind(
    int id,
    int version,
    List<AdoptedTransaction> adopted,
  ) => database.transaction(() async {
    var loan = await _current(id, version);
    while (loan.events.isNotEmpty) {
      await undo(loan);
      loan = (await load()).firstWhere((l) => l.id == id);
    }
    await database.customUpdate(
      'DELETE FROM loans WHERE id = ?',
      variables: [Variable(id)],
    );
    final transactions = TransactionRepository(database);
    for (final transaction in [loan.disbursalId, loan.chargesId]) {
      if (transaction == null) continue;
      if (adopted.where((a) => a.id == transaction).firstOrNull
          case final taken?) {
        await transactions.release(taken);
      } else {
        await transactions.delete(transaction);
      }
    }
  });

  /// Deleting tracking retains real account transactions. Undo is explicit.
  Future<void> delete(Loan loan) => database.transaction(() async {
    await _current(loan.id, loan.version);
    await database.customUpdate(
      'DELETE FROM loan_events WHERE loan_id = ?',
      variables: [Variable(loan.id)],
    );
    await database.customUpdate(
      'DELETE FROM loans WHERE id = ?',
      variables: [Variable(loan.id)],
    );
  });
}
