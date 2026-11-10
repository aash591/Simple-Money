part of 'app_database.dart';

/// Disposable profile-build ledger; never used by debug or release installs.
extension _ProfileSampleData on AppDatabase {
  /// A fresh profile install starts with February--September 2026 entries.
  /// Amounts are INR paise and every account balance is derived from this
  /// ledger, so the sample remains useful when testing reports and balances.
  Future<void> _seedProfileSampleData() async {
    await transaction(() async {
      final accountIds = <String, int>{};
      Future<void> addAccount(String name, String icon) async {
        accountIds[name] = await customInsert(
          '''INSERT INTO accounts
          (name, currency, territory, icon, digits, balance_minor, sort_order)
          VALUES (?, 'INR', 'IN', ?, 2, 0, ?)''',
          variables: [
            Variable(name),
            Variable(icon),
            Variable(accountIds.length),
          ],
        );
      }

      await addAccount('HDFC Bank', 'bank');
      await addAccount('UPI Wallet', 'bank_card');
      await addAccount('Cash', 'wallet_one');

      final categoryRows = await customSelect(
        'SELECT id, name, type FROM categories',
      ).get();
      final categoryIds = <String, int>{
        for (final row in categoryRows)
          '${row.read<String>('type')}:${row.read<String>('name')}': row
              .read<int>('id'),
      };

      Future<void> addEntry(_ProfileEntry entry) async {
        final accountId = accountIds[entry.account]!;
        final date = DateTime(2026, entry.month, entry.day, entry.hour);
        if (entry.type == 'transfer') {
          final toAccountId = accountIds[entry.toAccount]!;
          await customInsert(
            '''INSERT INTO transactions
            (type, amount_minor, account_id, to_account_id, note, date, created_at)
            VALUES ('transfer', ?, ?, ?, ?, ?, ?)''',
            variables: [
              Variable(entry.amountMinor),
              Variable(accountId),
              Variable(toAccountId),
              Variable(entry.note),
              Variable(date.millisecondsSinceEpoch),
              Variable(date.millisecondsSinceEpoch),
            ],
          );
          await _applyProfileBalanceChange(accountId, -entry.amountMinor);
          await _applyProfileBalanceChange(toAccountId, entry.amountMinor);
          return;
        }

        await customInsert(
          '''INSERT INTO transactions
          (type, amount_minor, account_id, category_id, title, note, date, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
          variables: [
            Variable(entry.type),
            Variable(entry.amountMinor),
            Variable(accountId),
            Variable(categoryIds['${entry.type}:${entry.category}']!),
            Variable(entry.title),
            Variable(entry.note),
            Variable(date.millisecondsSinceEpoch),
            Variable(date.millisecondsSinceEpoch),
          ],
        );
        await _applyProfileBalanceChange(
          accountId,
          entry.type == 'income' ? entry.amountMinor : -entry.amountMinor,
        );
      }

      for (final entry in _profileEntries) {
        await addEntry(entry);
      }

      await _seedProfileLoans(accountIds);
      await _seedProfileDebts(accountIds);
      await _seedProfileRecurringPayments(accountIds);

      for (final budget in _profileBudgets) {
        final budgetId = await customInsert(
          '''INSERT INTO budgets (kind, name, currency, digits)
          VALUES ('categories', ?, 'INR', 2)''',
          variables: [Variable(budget.name)],
        );
        for (final category in budget.categories) {
          await customInsert(
            'INSERT INTO budget_categories (budget_id, category_id) VALUES (?, ?)',
            variables: [
              Variable(budgetId),
              Variable(categoryIds['expense:$category']!),
            ],
          );
        }
        for (final (startMonth, amountMinor) in budget.amounts) {
          await customInsert(
            '''INSERT INTO budget_amounts (budget_id, start_month, amount_minor)
            VALUES (?, ?, ?)''',
            variables: [
              Variable(budgetId),
              Variable(startMonth),
              Variable(amountMinor),
            ],
          );
        }
      }
    });
  }

  /// One loan of every shape the feature supports, so a profile build has
  /// something in each state: an imported home loan the lender paid the
  /// builder for, a car loan part-way through, a personal loan disbursed
  /// with its charges deducted and an EMI now overdue, an interest-only
  /// education loan, a gold loan due in one payment next year, a bike and a
  /// phone on consumer EMIs, and a no-cost credit-card EMI already closed.
  ///
  /// Payments land on days the seeded ledger already uses, so no day ends up
  /// with a single entry on it.
  Future<void> _seedProfileLoans(Map<String, int> accountIds) async {
    Future<int> categoryFor(String name, String type) async {
      final row = await customSelect(
        '''SELECT id FROM categories
        WHERE name = ? AND type = ? AND parent_id IS NULL ORDER BY id LIMIT 1''',
        variables: [Variable(name), Variable(type)],
      ).getSingleOrNull();
      return row?.read<int>('id') ??
          await customInsert(
            '''INSERT INTO categories (name, type, icon, sort_order)
            VALUES (?, ?, 'bank',
              (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))''',
            variables: [Variable(name), Variable(type)],
          );
    }

    /// Records the loan, the money it moved, and [payments] installments
    /// paid on time from [account] — with a late fee on any of them named
    /// in [fees], by their position.
    Future<void> addLoan(
      LoanTerms terms, {
      required String account,
      required DateTime openedOn,
      String? receivedIn,
      int payments = 0,
      Map<int, int> fees = const {},
    }) async {
      terms.validate();
      final accountId = accountIds[account]!;
      int? disbursalId, chargesId;
      if (receivedIn != null) {
        disbursalId = await _logProfileTransaction(
          type: 'income',
          amountMinor: terms.chargesDeducted
              ? terms.principal - terms.chargesMinor
              : terms.principal,
          accountId: accountIds[receivedIn]!,
          categoryId: await categoryFor('Loan disbursal', 'debt_loan'),
          title: '${terms.lender} loan disbursal',
          date: openedOn,
        );
      }
      if (terms.chargesMinor > 0 && !terms.chargesDeducted) {
        chargesId = await _logProfileTransaction(
          type: 'expense',
          amountMinor: terms.chargesMinor,
          accountId: accountId,
          categoryId: await categoryFor('Loan charges', 'expense'),
          title: '${terms.lender} loan charges',
          date: openedOn,
        );
      }
      final loanId = await customInsert(
        '''INSERT INTO loans (payload, account_id, disbursal_id, charges_id)
        VALUES (?, ?, ?, ?)''',
        variables: [
          Variable(jsonEncode(terms.toJson())),
          Variable(accountId),
          Variable(disbursalId),
          Variable(chargesId),
        ],
      );
      final emiCategory = await categoryFor('Loan EMI', 'expense');
      final events = <LoanEvent>[];
      for (var i = 0; i < payments; i++) {
        // Each installment's split comes from the loan as it stands, exactly
        // as recording a payment in the app would work it out.
        final current = Loan(
          id: loanId,
          terms: terms,
          accountId: accountId,
          events: [...events],
        );
        final due = current.schedule.first;
        final fee = fees[i] ?? 0;
        final paidOn = DateTime(due.due.year, due.due.month, due.due.day, 10);
        LoanEvent event(int id) => LoanEvent(
          id: id,
          kind: LoanEventKind.emi,
          date: paidOn,
          principal: due.principal,
          interest: due.interest,
          fee: fee,
          accountName: account,
        );
        final transactionId = await _logProfileTransaction(
          type: 'expense',
          amountMinor: due.amount + fee,
          accountId: accountId,
          categoryId: emiCategory,
          title: current.title,
          date: paidOn,
        );
        events.add(
          event(
            await customInsert(
              '''INSERT INTO loan_events
              (loan_id, kind, installment, payload, account_id, transaction_id)
              VALUES (?, 'emi', ?, ?, ?, ?)''',
              variables: [
                Variable(loanId),
                Variable(current.paid + 1),
                Variable(jsonEncode(event(0).toJson())),
                Variable(accountId),
                Variable(transactionId),
              ],
            ),
          ),
        );
      }
    }

    /// What is left after [paid] EMIs of the opening schedule — where a loan
    /// imported with history starts from.
    int carried(int principal, double rate, int months, int paid) =>
        loanSchedule(
          principal: principal,
          rate: rate,
          emi: loanEmi(principal, rate, months),
          first: DateTime(2026),
          day: 1,
        )[paid - 1].balance;

    await addLoan(
      LoanTerms(
        lender: 'HDFC Bank',
        kind: LoanKind.home,
        icon: 'bank',
        principal: 220000000,
        openingBalance: carried(220000000, 8.5, 240, 18),
        rate: 8.5,
        months: 240,
        emi: loanEmi(220000000, 8.5, 240),
        paidBefore: 18,
        firstDue: DateTime(2026, 8, 5),
        day: 5,
        currency: 'INR',
        digits: 2,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 8, 5),
      payments: 2,
    );
    await addLoan(
      LoanTerms(
        lender: 'SBI',
        kind: LoanKind.car,
        icon: 'brand:sbi',
        assetIcon: 'car',
        asset: 'Swift Dzire',
        principal: 70000000,
        openingBalance: carried(70000000, 9.2, 60, 6),
        rate: 9.2,
        months: 60,
        emi: loanEmi(70000000, 9.2, 60),
        paidBefore: 6,
        firstDue: DateTime(2026, 8, 6),
        day: 6,
        currency: 'INR',
        digits: 2,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 8, 6),
      payments: 2,
    );
    await addLoan(
      LoanTerms(
        lender: 'Bajaj Finserv',
        kind: LoanKind.personal,
        icon: 'credit',
        principal: 30000000,
        openingBalance: 30000000,
        rate: 14,
        months: 36,
        emi: loanEmi(30000000, 14, 36),
        paidBefore: 0,
        firstDue: DateTime(2026, 4, 3),
        day: 3,
        currency: 'INR',
        digits: 2,
        chargesMinor: 531000,
        chargesDeducted: true,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 3, 3),
      receivedIn: 'HDFC Bank',
      payments: 5,
      // July's EMI bounced and was charged for it.
      fees: const {3: 59000},
    );
    await addLoan(
      LoanTerms(
        lender: 'SBI',
        kind: LoanKind.education,
        icon: 'bank',
        principal: 60000000,
        openingBalance: 60000000,
        rate: 9.5,
        months: 24,
        emi: 0,
        paidBefore: 0,
        firstDue: DateTime(2026, 6),
        day: 1,
        currency: 'INR',
        digits: 2,
        mode: LoanRepaymentMode.interestOnly,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 5),
      receivedIn: 'HDFC Bank',
      payments: 4,
    );
    await addLoan(
      LoanTerms(
        lender: 'Muthoot Finance',
        kind: LoanKind.gold,
        icon: 'bank',
        principal: 15000000,
        openingBalance: 15000000,
        rate: 11,
        months: 12,
        emi: 0,
        paidBefore: 0,
        firstDue: DateTime(2027, 6, 6),
        day: 6,
        currency: 'INR',
        digits: 2,
        mode: LoanRepaymentMode.bullet,
        chargesMinor: 118000,
      ),
      account: 'Cash',
      openedOn: DateTime(2026, 6, 6),
      receivedIn: 'Cash',
    );
    // Bought at the showroom on finance: the dealer was paid, not us.
    await addLoan(
      LoanTerms(
        lender: 'TVS Credit',
        kind: LoanKind.twoWheeler,
        icon: 'bank',
        assetIcon: 'bicycle',
        asset: 'Jupiter 125',
        principal: 12000000,
        openingBalance: 12000000,
        rate: 9.7,
        months: 36,
        emi: loanEmi(12000000, 9.7, 36),
        paidBefore: 0,
        firstDue: DateTime(2026, 5, 6),
        day: 6,
        currency: 'INR',
        digits: 2,
        chargesMinor: 236000,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 4, 6),
      payments: 5,
    );
    // A phone on a no-cost EMI: interest free, but the card still charged
    // a conversion fee for it.
    await addLoan(
      LoanTerms(
        lender: 'ICICI Bank',
        kind: LoanKind.creditCard,
        icon: 'brand:icicibank',
        assetIcon: 'phone',
        asset: 'iPhone 16',
        principal: 7200000,
        openingBalance: 7200000,
        rate: 0,
        months: 9,
        emi: loanEmi(7200000, 0, 9),
        paidBefore: 0,
        firstDue: DateTime(2026, 5, 5),
        day: 5,
        currency: 'INR',
        digits: 2,
        chargesMinor: 59000,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 4, 5),
      payments: 5,
    );
    await addLoan(
      LoanTerms(
        lender: 'HDFC Bank',
        kind: LoanKind.creditCard,
        icon: 'brand:hdfcbank',
        assetIcon: 'washing_machine',
        asset: 'Washing machine',
        principal: 4800000,
        openingBalance: 4800000,
        rate: 0,
        months: 6,
        emi: loanEmi(4800000, 0, 6),
        paidBefore: 0,
        firstDue: DateTime(2026, 4, 5),
        day: 5,
        currency: 'INR',
        digits: 2,
        chargesMinor: 59000,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 3, 5),
      payments: 6,
    );
    // The current flow's flexible contract: the snapshot separates principal
    // from interest, and no hypothetical payment schedule is manufactured.
    await addLoan(
      LoanTerms(
        lender: 'Flexible gold loan',
        kind: LoanKind.other,
        icon: 'bank',
        principal: 10000000,
        openingBalance: 7000000,
        openingInterest: 350000,
        existing: true,
        startDate: DateTime(2026, 6, 6),
        snapshotDate: DateTime(2026, 9, 1),
        maturityDate: DateTime(2027, 6, 6),
        rate: 12,
        accrual: LoanAccrual.daily,
        months: 12,
        emi: 0,
        paidBefore: 0,
        firstDue: DateTime(2027, 6, 6),
        day: 6,
        currency: 'INR',
        digits: 2,
        mode: LoanRepaymentMode.flexible,
      ),
      account: 'Cash',
      openedOn: DateTime(2026, 6, 6),
    );
  }

  /// An overdue loan-out, a soon-due borrow already part paid back, a
  /// longer-overdue loan-out from cash, a borrow settled in full, and a
  /// record-only loan with no account behind it — one example of each shape
  /// Debts supports.
  Future<void> _seedProfileDebts(Map<String, int> accountIds) async {
    Future<int> addPerson(String name) => customInsert(
      'INSERT INTO debt_people (name, created_at) VALUES (?, ?)',
      variables: [
        Variable(name),
        Variable(DateTime.now().millisecondsSinceEpoch),
      ],
    );

    Future<int> categoryFor(DebtKind kind) async {
      final name = switch (kind) {
        DebtKind.lend => 'Loan',
        DebtKind.borrow => 'Debt',
        DebtKind.collect => 'Debt Collection',
        DebtKind.repay => 'Repayment',
      };
      final row = await customSelect(
        '''SELECT id FROM categories
        WHERE type = 'debt_loan' AND parent_id IS NULL AND name = ?
        ORDER BY id LIMIT 1''',
        variables: [Variable(name)],
      ).getSingleOrNull();
      return row!.read<int>('id');
    }

    Future<void> addEntry({
      required int personId,
      required String personName,
      required DebtKind kind,
      required int amountMinor,
      String? account,
      required DateTime date,
      DateTime? dueDate,
      String? note,
    }) async {
      int? accountId;
      int? transactionId;
      if (account != null) {
        accountId = accountIds[account]!;
        final title = switch (kind) {
          DebtKind.lend => 'Lent to $personName',
          DebtKind.borrow => 'Borrowed from $personName',
          DebtKind.collect => 'Paid back by $personName',
          DebtKind.repay => 'Paid back $personName',
        };
        transactionId = await _logProfileTransaction(
          type: kind.paysOut ? 'expense' : 'income',
          amountMinor: amountMinor,
          accountId: accountId,
          categoryId: await categoryFor(kind),
          title: title,
          date: date,
        );
      }
      final due = dueDate == null
          ? null
          : DateTime(dueDate.year, dueDate.month, dueDate.day);
      await customInsert(
        '''INSERT INTO debt_entries
        (person_id, kind, amount_minor, currency, digits, account_id,
         transaction_id, note, date, due_date, created_at)
        VALUES (?, ?, ?, 'INR', 2, ?, ?, ?, ?, ?, ?)''',
        variables: [
          Variable(personId),
          Variable(kind.storageValue),
          Variable(amountMinor),
          Variable(accountId),
          Variable(transactionId),
          Variable(note),
          Variable(date.millisecondsSinceEpoch),
          Variable(due?.millisecondsSinceEpoch),
          Variable(DateTime.now().millisecondsSinceEpoch),
        ],
      );
    }

    final rahul = await addPerson('Rahul Sharma');
    await addEntry(
      personId: rahul,
      personName: 'Rahul Sharma',
      kind: DebtKind.lend,
      amountMinor: 1500000,
      account: 'HDFC Bank',
      date: DateTime(2026, 8, 18),
      dueDate: DateTime(2026, 9, 12),
    );

    final priya = await addPerson('Priya Nair');
    await addEntry(
      personId: priya,
      personName: 'Priya Nair',
      kind: DebtKind.borrow,
      amountMinor: 800000,
      account: 'UPI Wallet',
      date: DateTime(2026, 8, 23),
      dueDate: DateTime(2026, 9, 20),
    );
    await addEntry(
      personId: priya,
      personName: 'Priya Nair',
      kind: DebtKind.repay,
      amountMinor: 300000,
      account: 'UPI Wallet',
      date: DateTime(2026, 9, 5),
    );

    final amit = await addPerson('Amit Verma');
    await addEntry(
      personId: amit,
      personName: 'Amit Verma',
      kind: DebtKind.lend,
      amountMinor: 2500000,
      account: 'Cash',
      date: DateTime(2026, 7, 15),
      dueDate: DateTime(2026, 8, 15),
    );

    final sneha = await addPerson('Sneha Iyer');
    await addEntry(
      personId: sneha,
      personName: 'Sneha Iyer',
      kind: DebtKind.borrow,
      amountMinor: 1200000,
      account: 'HDFC Bank',
      date: DateTime(2026, 8, 5),
      dueDate: DateTime(2026, 9, 5),
    );
    await addEntry(
      personId: sneha,
      personName: 'Sneha Iyer',
      kind: DebtKind.repay,
      amountMinor: 1200000,
      account: 'HDFC Bank',
      date: DateTime(2026, 8, 27),
    );

    final karan = await addPerson('Karan Mehta');
    await addEntry(
      personId: karan,
      personName: 'Karan Mehta',
      kind: DebtKind.lend,
      amountMinor: 500000,
      date: DateTime(2026, 9, 1),
      dueDate: DateTime(2026, 10, 1),
      note: 'Cash, off the books',
    );
  }

  /// A renewal due this week, one already overdue, a quarterly one due next
  /// month, a cheap one with reminders off, and a paused one — one example
  /// of each state Recurring payments shows.
  Future<void> _seedProfileRecurringPayments(
    Map<String, int> accountIds,
  ) async {
    Future<int> categoryId(String name) async {
      final row = await customSelect(
        '''SELECT id FROM categories
        WHERE name = ? AND type = 'expense' ORDER BY parent_id IS NOT NULL, id LIMIT 1''',
        variables: [Variable(name)],
      ).getSingleOrNull();
      return row!.read<int>('id');
    }

    Future<void> addRecurringPayment({
      required String name,
      required String icon,
      required int amountMinor,
      required BillingCycle cycle,
      required DateTime nextDue,
      required String account,
      required String category,
      bool remind = true,
      bool paused = false,
    }) async {
      await customInsert(
        '''INSERT INTO recurring_payments
        (name, icon, amount_minor, currency, digits, cycle, next_due, day,
         account_id, category_id, remind, paused)
        VALUES (?, ?, ?, 'INR', 2, ?, ?, ?, ?, ?, ?, ?)''',
        variables: [
          Variable(name),
          Variable(icon),
          Variable(amountMinor),
          Variable(cycle.name),
          Variable(dateToStorage(nextDue)),
          Variable(nextDue.day),
          Variable(accountIds[account]!),
          Variable(await categoryId(category)),
          Variable(remind ? 1 : 0),
          Variable(paused ? 1 : 0),
        ],
      );
    }

    await addRecurringPayment(
      name: 'Netflix',
      icon: 'brand:netflix',
      amountMinor: 64900,
      cycle: BillingCycle.monthly,
      nextDue: DateTime(2026, 9, 20),
      account: 'UPI Wallet',
      category: 'Subscriptions',
    );
    await addRecurringPayment(
      name: 'Spotify',
      icon: 'brand:spotify',
      amountMinor: 11900,
      cycle: BillingCycle.monthly,
      nextDue: DateTime(2026, 9, 12),
      account: 'HDFC Bank',
      category: 'Subscriptions',
    );
    await addRecurringPayment(
      name: "Gold's Gym",
      icon: 'gym',
      amountMinor: 450000,
      cycle: BillingCycle.quarterly,
      nextDue: DateTime(2026, 10, 1),
      account: 'HDFC Bank',
      category: 'Gym & Sports',
    );
    await addRecurringPayment(
      name: 'iCloud storage',
      icon: 'brand:icloud',
      amountMinor: 7500,
      cycle: BillingCycle.monthly,
      nextDue: DateTime(2026, 9, 25),
      account: 'HDFC Bank',
      category: 'Subscriptions',
      remind: false,
    );
    await addRecurringPayment(
      name: 'Crunchyroll',
      icon: 'brand:crunchyroll',
      amountMinor: 29900,
      cycle: BillingCycle.monthly,
      nextDue: DateTime(2026, 8, 5),
      account: 'UPI Wallet',
      category: 'Subscriptions',
      paused: true,
    );
  }

  /// Inserts one seeded transaction and moves its account's balance the way
  /// its [type] implies. Returns the new row's id.
  Future<int> _logProfileTransaction({
    required String type,
    required int amountMinor,
    required int accountId,
    required int categoryId,
    required String title,
    required DateTime date,
  }) async {
    final id = await customInsert(
      '''INSERT INTO transactions
        (type, amount_minor, account_id, category_id, title, date, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)''',
      variables: [
        Variable(type),
        Variable(amountMinor),
        Variable(accountId),
        Variable(categoryId),
        Variable(title),
        Variable(date.millisecondsSinceEpoch),
        Variable(date.millisecondsSinceEpoch),
      ],
    );
    await _applyProfileBalanceChange(
      accountId,
      type == 'income' ? amountMinor : -amountMinor,
    );
    return id;
  }

  Future<void> _applyProfileBalanceChange(int accountId, int amountMinor) =>
      customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor + ?,
            transaction_count = transaction_count + 1
        WHERE id = ?''',
        variables: [Variable(amountMinor), Variable(accountId)],
      );
}
