import 'package:drift/drift.dart';

import '../../domain/subscription.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import 'transaction_repository.dart';

class SubscriptionRepository {
  SubscriptionRepository(this.database);
  final AppDatabase database;

  /// Unpicks every reference to an account being deleted. A subscription keeps
  /// renewing; it just needs another account to pay from.
  Future<void> detachAccount(int accountId) async {
    await database.customUpdate(
      'UPDATE subscriptions SET account_id = NULL WHERE account_id = ?',
      variables: [Variable(accountId)],
    );
    await database.customUpdate(
      '''DELETE FROM subscription_payments WHERE transaction_id IN
      (SELECT id FROM transactions WHERE account_id = ? OR to_account_id = ?)''',
      variables: [Variable(accountId), Variable(accountId)],
    );
  }

  Future<List<Subscription>> load() async => [
    for (final r
        in await database
            .customSelect('SELECT * FROM subscriptions ORDER BY id')
            .get())
      _fromRow(r),
  ];

  Subscription _fromRow(QueryRow r) => Subscription(
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
  );

  /// Re-read inside the write, so an action taken from a stale screen (say,
  /// Mark paid tapped twice) can't apply to a renewal that has moved on.
  Future<Subscription> _current(Subscription subscription) async {
    final row = await database
        .customSelect(
          'SELECT * FROM subscriptions WHERE id = ?',
          variables: [Variable(subscription.id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('This subscription no longer exists.');
    final current = _fromRow(row);
    if (current.nextDue != subscription.nextDue ||
        current.paused != subscription.paused) {
      throw StateError('This subscription changed. Please try again.');
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

  List<Variable> _values(SubscriptionDraft draft, String currency, int digits) {
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
    ];
  }

  Future<int> add(SubscriptionDraft draft) => database.transaction(() async {
    draft.validate();
    final (currency, digits) = await _accountCurrency(draft.accountId);
    return database.customInsert(
      '''INSERT INTO subscriptions (name, icon, amount_minor, currency, digits,
        cycle, next_due, day, account_id, category_id, remind)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      variables: _values(draft, currency, digits),
    );
  });

  Future<void> update(int id, SubscriptionDraft draft) =>
      database.transaction(() async {
        draft.validate();
        final (currency, digits) = await _accountCurrency(draft.accountId);
        await database.customUpdate(
          '''UPDATE subscriptions SET name = ?, icon = ?, amount_minor = ?,
            currency = ?, digits = ?, cycle = ?, next_due = ?, day = ?,
            account_id = ?, category_id = ?, remind = ? WHERE id = ?''',
          variables: [..._values(draft, currency, digits), Variable(id)],
        );
      });

  /// Logs this renewal as an expense dated [date], from [accountId] or else
  /// its own account, and moves on to the next one. One that lost its
  /// account keeps the one it was paid from this time.
  Future<int> markPaid(
    Subscription subscription, {
    required DateTime date,
    int? accountId,
  }) => database.transaction(() async {
    final current = await _current(subscription);
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
                  'subscription to choose another.'
            : 'Choose an account in ${current.currency}.',
      );
    }
    if (current.accountId == null) {
      await database.customUpdate(
        'UPDATE subscriptions SET account_id = ? WHERE id = ?',
        variables: [Variable(payFrom), Variable(current.id)],
      );
    }
    final transactionId = await TransactionRepository(database)
        .addExpenseOrIncome(
          type: TransactionType.expense,
          amountMinor: current.amountMinor,
          accountId: payFrom,
          categoryId: await _category(current.categoryId),
          title: current.name,
          date: date,
        );
    await database.customInsert(
      '''INSERT INTO subscription_payments (transaction_id, subscription_id)
      VALUES (?, ?)''',
      variables: [Variable(transactionId), Variable(current.id)],
    );
    await _moveTo(current, current.followingDue);
    return transactionId;
  });

  /// What has actually been paid for [subscriptionId], newest first. Only
  /// renewals marked paid here appear: a skipped one logs nothing, and a
  /// payment whose transaction was deleted drops out with it.
  Future<List<SubscriptionPayment>> payments(int subscriptionId) async => [
    for (final row
        in await database
            .customSelect(
              '''SELECT t.id, t.amount_minor, t.date, a.name AS account
          FROM subscription_payments p
          JOIN transactions t ON t.id = p.transaction_id
          LEFT JOIN accounts a ON a.id = t.account_id
          WHERE p.subscription_id = ?
          ORDER BY t.date DESC, t.id DESC''',
              variables: [Variable(subscriptionId)],
            )
            .get())
      SubscriptionPayment(
        transactionId: row.read<int>('id'),
        amountMinor: row.read<int>('amount_minor'),
        date: DateTime.fromMillisecondsSinceEpoch(row.read<int>('date')),
        account: row.readNullable<String>('account'),
      ),
  ];

  /// Moves past this renewal without logging a payment, for one that was
  /// already recorded some other way or wasn't charged.
  Future<void> skip(Subscription subscription) =>
      database.transaction(() async {
        final current = await _current(subscription);
        await _moveTo(current, current.followingDue);
      });

  /// Nothing is charged while paused, so resuming picks up at the first
  /// renewal from today on rather than at every one that was missed.
  Future<void> setPaused(Subscription subscription, bool paused) =>
      database.transaction(() async {
        final current = await _current(subscription);
        var due = current.nextDue;
        if (!paused) {
          final today = dateOnly(DateTime.now());
          while (due.isBefore(today)) {
            due = current.cycle.after(due, current.day);
          }
        }
        await database.customUpdate(
          'UPDATE subscriptions SET paused = ?, next_due = ? WHERE id = ?',
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
      'DELETE FROM subscription_payments WHERE subscription_id = ?',
      variables: [Variable(id)],
    );
    await database.customUpdate(
      'DELETE FROM subscriptions WHERE id = ?',
      variables: [Variable(id)],
    );
  });

  Future<void> _moveTo(Subscription subscription, DateTime due) =>
      database.customUpdate(
        'UPDATE subscriptions SET next_due = ? WHERE id = ?',
        variables: [Variable(dateToStorage(due)), Variable(subscription.id)],
      );

  /// Its own category while that still exists, else the default
  /// Subscriptions expense category, recreated if it was deleted.
  Future<int> _category(int? id) async {
    if (id != null) {
      final row = await database
          .customSelect(
            'SELECT id FROM categories WHERE id = ?',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (row != null) return id;
    }
    final row = await database
        .customSelect(
          "SELECT id FROM categories WHERE name = 'Subscriptions' AND type = 'expense' ORDER BY parent_id IS NOT NULL, id LIMIT 1",
        )
        .getSingleOrNull();
    return row?.read<int>('id') ??
        await database.customInsert(
          "INSERT INTO categories (name, type, icon, sort_order) VALUES ('Subscriptions', 'expense', 'subscriptions', (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))",
        );
  }
}
