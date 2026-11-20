import 'package:drift/drift.dart';

import '../../domain/recurring_payment.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import 'transaction_repository.dart';

class RecurringPaymentRepository {
  RecurringPaymentRepository(this.database);
  final AppDatabase database;

  /// Unpicks every reference to an account being deleted. A recurring payment keeps
  /// renewing; it just needs another account to pay from.
  Future<void> detachAccount(int accountId) async {
    await database.customUpdate(
      'UPDATE recurring_payments SET account_id = NULL WHERE account_id = ?',
      variables: [Variable(accountId)],
    );
    await database.customUpdate(
      '''DELETE FROM recurring_payment_history WHERE transaction_id IN
      (SELECT id FROM transactions WHERE account_id = ? OR to_account_id = ?)''',
      variables: [Variable(accountId), Variable(accountId)],
    );
  }

  Future<List<RecurringPayment>> load() async => [
    for (final r
        in await database
            .customSelect('SELECT * FROM recurring_payments ORDER BY id')
            .get())
      _fromRow(r),
  ];

  RecurringPayment _fromRow(QueryRow r) => RecurringPayment(
    id: r.read<int>('id'),
    name: r.read<String>('name'),
    icon: r.readNullable<String>('icon'),
    amountMinor: r.read<int>('amount_minor'),
    currency: r.read<String>('currency'),
    digits: r.read<int>('digits'),
    cycle: BillingCycleLabels.fromStorage(r.read<String>('cycle')),
    nextDue: dateFromStorage(r.read<String>('next_due')),
    day: r.read<int>('day'),
    accountId: r.readNullable<int>('account_id'),
    categoryId: r.readNullable<int>('category_id'),
    remind: r.read<int>('remind') == 1,
    paused: r.read<int>('paused') == 1,
    incoming: r.read<int>('incoming') == 1,
  );

  /// Re-read inside the write, so an action taken from a stale screen (say,
  /// Mark paid tapped twice) can't apply to a renewal that has moved on.
  Future<RecurringPayment> _current(RecurringPayment recurringPayment) async {
    final row = await database
        .customSelect(
          'SELECT * FROM recurring_payments WHERE id = ?',
          variables: [Variable(recurringPayment.id)],
        )
        .getSingleOrNull();
    if (row == null) {
      throw StateError('This recurring payment no longer exists.');
    }
    final current = _fromRow(row);
    if (current.nextDue != recurringPayment.nextDue ||
        current.paused != recurringPayment.paused) {
      throw StateError('This recurring payment changed. Please try again.');
    }
    return current;
  }

  Future<(String, int)> _accountCurrency(int accountId) async {
    final row = await database
        .customSelect(
          'SELECT currency, digits FROM accounts WHERE id = ?',
          variables: [Variable(accountId)],
        )
        .getSingleOrNull();
    if (row == null) throw ArgumentError('Choose the account it’s paid from.');
    return (row.read<String>('currency'), row.read<int>('digits'));
  }

  List<Variable> _values(
    RecurringPaymentDraft draft,
    String currency,
    int digits,
  ) {
    final due = dateOnly(draft.nextDue);
    return [
      Variable(draft.name.trim()),
      Variable(draft.icon),
      Variable(draft.amountMinor),
      Variable(currency),
      Variable(digits),
      Variable(draft.cycle.name),
      Variable(dateToStorage(due)),
      Variable(due.day),
      Variable(draft.accountId),
      Variable(draft.categoryId),
      Variable(draft.remind ? 1 : 0),
      Variable(draft.incoming ? 1 : 0),
    ];
  }

  Future<int> add(
    RecurringPaymentDraft draft,
  ) => database.transaction(() async {
    draft.validate();
    final (currency, digits) = await _accountCurrency(draft.accountId);
    return database.customInsert(
      '''INSERT INTO recurring_payments (id, name, icon, amount_minor, currency,
        digits, cycle, next_due, day, account_id, category_id, remind, incoming)
        VALUES (${newRowId('recurring_payments')}, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      variables: _values(draft, currency, digits),
    );
  });

  Future<void> update(int id, RecurringPaymentDraft draft) =>
      database.transaction(() async {
        draft.validate();
        final (currency, digits) = await _accountCurrency(draft.accountId);
        await database.customUpdate(
          '''UPDATE recurring_payments SET name = ?, icon = ?, amount_minor = ?,
            currency = ?, digits = ?, cycle = ?, next_due = ?, day = ?,
            account_id = ?, category_id = ?, remind = ?, incoming = ?
            WHERE id = ?''',
          variables: [..._values(draft, currency, digits), Variable(id)],
        );
      });

  /// Logs this renewal as an expense dated [date], from [accountId] or else
  /// its own account, and moves on to the next one. One that lost its
  /// account keeps the one it was paid from this time.
  Future<int> markPaid(
    RecurringPayment recurringPayment, {
    required DateTime date,
    int? accountId,
  }) => database.transaction(() async {
    final current = await _current(recurringPayment);
    if (current.paused) throw StateError('Resume it before marking paid.');
    final payFrom = accountId ?? current.accountId;
    if (payFrom == null) {
      throw ArgumentError('Choose the account it’s paid from.');
    }
    final (currency, digits) = await _accountCurrency(payFrom);
    if (currency != current.currency || digits != current.digits) {
      throw ArgumentError(
        accountId == null
            ? 'Its account is no longer in ${current.currency}. Edit the '
                  'recurring payment to choose another.'
            : 'Choose an account in ${current.currency}.',
      );
    }
    if (current.accountId == null) {
      await database.customUpdate(
        'UPDATE recurring_payments SET account_id = ? WHERE id = ?',
        variables: [Variable(payFrom), Variable(current.id)],
      );
    }
    final transactionId = await TransactionRepository(database)
        .addExpenseOrIncome(
          type: current.incoming
              ? TransactionType.income
              : TransactionType.expense,
          amountMinor: current.amountMinor,
          accountId: payFrom,
          categoryId: await categoryFor(current.categoryId, current.incoming),
          title: current.name,
          date: date,
        );
    await database.customInsert(
      '''INSERT INTO recurring_payment_history (transaction_id, recurring_payment_id)
      VALUES (?, ?)''',
      variables: [Variable(transactionId), Variable(current.id)],
    );
    await _moveTo(current, current.followingDue);
    return transactionId;
  });

  /// What has actually been paid for [recurringPaymentId], newest first. Only
  /// renewals marked paid here appear: a skipped one logs nothing, and a
  /// payment whose transaction was deleted drops out with it.
  Future<List<RecurringPaymentRecord>> payments(int recurringPaymentId) async =>
      [
        for (final row
            in await database
                .customSelect(
                  '''SELECT t.id, t.amount_minor, t.date, a.name AS account
          FROM recurring_payment_history p
          JOIN transactions t ON t.id = p.transaction_id
          LEFT JOIN accounts a ON a.id = t.account_id
          WHERE p.recurring_payment_id = ?
          ORDER BY t.date DESC, t.id DESC''',
                  variables: [Variable(recurringPaymentId)],
                )
                .get())
          RecurringPaymentRecord(
            transactionId: row.read<int>('id'),
            amountMinor: row.read<int>('amount_minor'),
            date: DateTime.fromMillisecondsSinceEpoch(row.read<int>('date')),
            account: row.readNullable<String>('account'),
          ),
      ];

  /// Moves past this renewal without logging a payment, for one that was
  /// already recorded some other way or wasn't charged.
  Future<void> skip(RecurringPayment recurringPayment) =>
      database.transaction(() async {
        final current = await _current(recurringPayment);
        await _moveTo(current, current.followingDue);
      });

  /// Nothing is charged while paused, so resuming picks up at the first
  /// renewal from today on rather than at every one that was missed.
  Future<void> setPaused(RecurringPayment recurringPayment, bool paused) =>
      database.transaction(() async {
        final current = await _current(recurringPayment);
        var due = current.nextDue;
        if (!paused) {
          final today = dateOnly(DateTime.now());
          while (due.isBefore(today)) {
            due = current.cycle.after(due, current.day);
          }
        }
        await database.customUpdate(
          'UPDATE recurring_payments SET paused = ?, next_due = ? WHERE id = ?',
          variables: [
            Variable(paused ? 1 : 0),
            Variable(dateToStorage(due)),
            Variable(current.id),
          ],
        );
      });

  /// The payments it already logged stay in the ledger, back to their
  /// category's icon.
  Future<void> delete(int id) => database.transaction(() async {
    await database.customUpdate(
      'DELETE FROM recurring_payment_history WHERE recurring_payment_id = ?',
      variables: [Variable(id)],
    );
    await database.customUpdate(
      'DELETE FROM recurring_payments WHERE id = ?',
      variables: [Variable(id)],
    );
  });

  Future<void> _moveTo(RecurringPayment recurringPayment, DateTime due) =>
      database.customUpdate(
        'UPDATE recurring_payments SET next_due = ? WHERE id = ?',
        variables: [
          Variable(dateToStorage(due)),
          Variable(recurringPayment.id),
        ],
      );

  /// Its own category while that still exists, else the default for its
  /// direction (Recurring payments for money out, Rental Income for money in),
  /// recreated if it was deleted.
  Future<int> categoryFor(int? id, bool incoming) async {
    if (id != null) {
      final row = await database
          .customSelect(
            'SELECT id FROM categories WHERE id = ?',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (row != null) return id;
    }
    final (name, type, icon) = incoming
        ? ('Rental Income', 'income', 'rent')
        : ('Subscriptions', 'expense', 'subscriptions');
    final row = await database
        .customSelect(
          'SELECT id FROM categories WHERE name = ? AND type = ? ORDER BY parent_id IS NOT NULL, id LIMIT 1',
          variables: [Variable(name), Variable(type)],
        )
        .getSingleOrNull();
    return row?.read<int>('id') ??
        await database.customInsert(
          'INSERT INTO categories (id, name, type, icon, sort_order) VALUES (${newRowId('categories')}, ?, ?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))',
          variables: [Variable(name), Variable(type), Variable(icon)],
        );
  }
}
