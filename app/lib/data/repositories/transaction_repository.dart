import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/account.dart';
import '../../domain/loan.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';

class TransactionRepository {
  TransactionRepository(this.database);

  /// The badge on a subscription payment's logo.
  static const _subscriptionBadge = 'subscriptions';
  final AppDatabase database;

  Future<List<MoneyTransaction>> load({
    DateTime? start,
    DateTime? end,
    String? currency,
    int? digits,
    int? limit,
  }) async {
    // Every instalment of one loan carries the same payload; parse each
    // distinct one once rather than per row.
    final loans = <String, LoanTerms>{};
    return (await database
            .customSelect(
              '''SELECT t.*,
                  a.type = 'creditCard' OR EXISTS(SELECT 1 FROM sms_imports sms
                    WHERE sms.transaction_id = t.id
                    AND json_extract(sms.candidate, '\$.isCreditCard') = 1) AS is_credit_card,
                  (SELECT l.payload FROM loans l
                   WHERE l.disbursal_id = t.id OR l.charges_id = t.id
                      OR l.id IN (SELECT e.loan_id FROM loan_events e
                                  WHERE e.transaction_id = t.id)
                   LIMIT 1) AS loan_payload,
                  (SELECT coalesce(s.icon, 'subscriptions')
                   FROM subscription_payments p
                   JOIN subscriptions s ON s.id = p.subscription_id
                   WHERE p.transaction_id = t.id) AS subscription_icon
                FROM transactions t JOIN accounts a ON a.id = t.account_id
                WHERE 1 = 1
                ${start != null ? 'AND t.date >= ?' : ''}
                ${end != null ? 'AND t.date < ?' : ''}
                ${currency != null ? 'AND a.currency = ?' : ''}
                ${digits != null ? 'AND a.digits = ?' : ''}
                ORDER BY t.date DESC, t.id DESC ${limit != null ? 'LIMIT ?' : ''}''',
              variables: [
                if (start != null) Variable(start.millisecondsSinceEpoch),
                if (end != null) Variable(end.millisecondsSinceEpoch),
                if (currency != null) Variable(currency),
                if (digits != null) Variable(digits),
                if (limit != null) Variable(limit),
              ],
            )
            .get())
        .map((r) {
          final payload = r.readNullable<String>('loan_payload');
          final loan = payload == null
              ? null
              : loans[payload] ??= LoanTerms.fromJson(jsonDecode(payload));
          // A loan's payment shows what it paid for with the lender as a
          // badge; a subscription's its logo, badged as a subscription.
          final subscriptionIcon = r.readNullable<String>('subscription_icon');
          final icon = loan?.displayIcon ?? subscriptionIcon;
          final badge = loan != null
              ? loan.icon
              : subscriptionIcon == null
              ? null
              : _subscriptionBadge;
          return MoneyTransaction(
            id: r.read<int>('id'),
            type: TransactionTypeStorage.fromStorage(r.read<String>('type')),
            isCreditCard: r.read<int>('is_credit_card') == 1,
            amountMinor: r.read<int>('amount_minor'),
            accountId: r.read<int>('account_id'),
            toAccountId: r.readNullable<int>('to_account_id'),
            toAmountMinor: r.readNullable<int>('to_amount_minor'),
            categoryId: r.readNullable<int>('category_id'),
            title: r.readNullable<String>('title'),
            note: r.readNullable<String>('note'),
            date: DateTime.fromMillisecondsSinceEpoch(r.read<int>('date')),
            icon: icon,
            badgeIcon: icon == badge ? null : badge,
          );
        })
        .toList();
  }

  /// Records an expense or income and moves the account's balance opposite
  /// (expense) or with (income) the amount, atomically. Returns its id.
  Future<int> addExpenseOrIncome({
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    required int categoryId,
    String? title,
    String? note,
    required DateTime date,
  }) async {
    if (type == TransactionType.transfer) {
      throw ArgumentError('Use addTransfer for a transfer.');
    }
    if (amountMinor <= 0) {
      throw ArgumentError('Enter an amount greater than zero.');
    }
    return database.transaction(() async {
      final id = await database.customInsert(
        '''INSERT INTO transactions
        (type, amount_minor, account_id, category_id, title, note, date, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        variables: [
          Variable(type.storageValue),
          Variable(amountMinor),
          Variable(accountId),
          Variable(categoryId),
          Variable(title),
          Variable(note),
          Variable(date.millisecondsSinceEpoch),
          Variable(DateTime.now().millisecondsSinceEpoch),
        ],
      );
      final signedAmount = type == TransactionType.income
          ? amountMinor
          : -amountMinor;
      await database.customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor + ?, transaction_count = transaction_count + 1
        WHERE id = ?''',
        variables: [Variable(signedAmount), Variable(accountId)],
      );
      return id;
    });
  }

  /// Rewrites an existing expense or income in place. Its old effect on its
  /// old account is undone and the new one applied in one database
  /// transaction, so moving it to another account, or switching it between
  /// expense and income, keeps every balance and count right.
  Future<void> updateExpenseOrIncome({
    required int id,
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    required int categoryId,
    String? title,
    String? note,
    required DateTime date,
  }) async {
    if (type == TransactionType.transfer) {
      throw ArgumentError('Transfers cannot be edited.');
    }
    if (amountMinor <= 0) {
      throw ArgumentError('Enter an amount greater than zero.');
    }
    await database.transaction(() async {
      await _checkLoanLink(id);
      final old = await database
          .customSelect(
            'SELECT type, amount_minor, account_id FROM transactions WHERE id = ?',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (old == null) throw StateError('This transaction no longer exists.');
      final oldType = TransactionTypeStorage.fromStorage(
        old.read<String>('type'),
      );
      if (oldType == TransactionType.transfer) {
        throw ArgumentError('Transfers cannot be edited.');
      }
      await database.customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor - ?, transaction_count = transaction_count - 1
        WHERE id = ?''',
        variables: [
          Variable(_balanceEffect(oldType, old.read<int>('amount_minor'))),
          Variable(old.read<int>('account_id')),
        ],
      );
      await database.customUpdate(
        '''UPDATE transactions
        SET type = ?, amount_minor = ?, account_id = ?, category_id = ?,
            title = ?, note = ?, date = ?
        WHERE id = ?''',
        variables: [
          Variable(type.storageValue),
          Variable(amountMinor),
          Variable(accountId),
          Variable(categoryId),
          Variable(title),
          Variable(note),
          Variable(date.millisecondsSinceEpoch),
          Variable(id),
        ],
      );
      await database.customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor + ?, transaction_count = transaction_count + 1
        WHERE id = ?''',
        variables: [
          Variable(_balanceEffect(type, amountMinor)),
          Variable(accountId),
        ],
      );
    });
  }

  /// How an expense or income moves its account's balance.
  static int _balanceEffect(TransactionType type, int amountMinor) =>
      type == TransactionType.income ? amountMinor : -amountMinor;

  /// Records a transfer and moves the amount out of one account's balance and
  /// into the other's, atomically. Never counted as income or expense.
  ///
  /// [toAmountMinor] is what reached the destination, in the destination's own
  /// currency. Leave it null when the whole amount arrives unchanged. It is
  /// required when the two accounts disagree on currency or precision, because
  /// there is no rate here to derive it from and crediting the source's figure
  /// would leave both balances wrong. The gap between the two is the charge.
  Future<int> addTransfer({
    required int amountMinor,
    required int fromAccountId,
    required int toAccountId,
    int? toAmountMinor,
    String? note,
    required DateTime date,
  }) async {
    if (amountMinor <= 0) {
      throw ArgumentError('Enter an amount greater than zero.');
    }
    if (toAmountMinor != null && toAmountMinor <= 0) {
      throw ArgumentError('Enter a received amount greater than zero.');
    }
    if (fromAccountId == toAccountId) {
      throw ArgumentError('Choose two different accounts to transfer between.');
    }
    return database.transaction(() async {
      if (toAmountMinor == null) {
        final pair = await database
            .customSelect(
              'SELECT currency, digits FROM accounts WHERE id IN (?, ?)',
              variables: [Variable(fromAccountId), Variable(toAccountId)],
            )
            .get();
        if (pair.length == 2 &&
            (pair[0].read<String>('currency') !=
                    pair[1].read<String>('currency') ||
                pair[0].read<int>('digits') != pair[1].read<int>('digits'))) {
          throw ArgumentError(
            'Enter how much reached the destination account.',
          );
        }
      }
      final id = await database.customInsert(
        '''INSERT INTO transactions
        (type, amount_minor, account_id, to_account_id, to_amount_minor,
         note, date, created_at)
        VALUES ('transfer', ?, ?, ?, ?, ?, ?, ?)''',
        variables: [
          Variable(amountMinor),
          Variable(fromAccountId),
          Variable(toAccountId),
          Variable(toAmountMinor),
          Variable(note),
          Variable(date.millisecondsSinceEpoch),
          Variable(DateTime.now().millisecondsSinceEpoch),
        ],
      );
      await database.customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor - ?, transaction_count = transaction_count + 1
        WHERE id = ?''',
        variables: [Variable(amountMinor), Variable(fromAccountId)],
      );
      await database.customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor + ?, transaction_count = transaction_count + 1
        WHERE id = ?''',
        variables: [
          Variable(toAmountMinor ?? amountMinor),
          Variable(toAccountId),
        ],
      );
      return id;
    });
  }

  /// Turns a recorded expense or income into a transfer between two of the
  /// user's accounts — once its other leg turns up, as in a statement — and
  /// moves both balances as that transfer would have. A transfer has no
  /// category or title; [appendNote] is added under the existing note.
  Future<void> convertToTransfer({
    required int id,
    required int fromAccountId,
    required int toAccountId,
    String? appendNote,
  }) async {
    if (fromAccountId == toAccountId) {
      throw ArgumentError('Choose two different accounts to transfer between.');
    }
    await database.transaction(() async {
      await _checkLoanLink(id);
      final old = await database
          .customSelect(
            'SELECT type, amount_minor, account_id FROM transactions WHERE id = ?',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (old == null) throw StateError('This transaction no longer exists.');
      final type = TransactionTypeStorage.fromStorage(old.read<String>('type'));
      if (type == TransactionType.transfer) {
        throw ArgumentError('This is already a transfer.');
      }
      final amountMinor = old.read<int>('amount_minor');
      Future<void> move(int accountId, int balance, int count) =>
          database.customUpdate(
            '''UPDATE accounts
            SET balance_minor = balance_minor + ?,
                transaction_count = transaction_count + ?
            WHERE id = ?''',
            variables: [
              Variable(balance),
              Variable(count),
              Variable(accountId),
            ],
          );
      await move(
        old.read<int>('account_id'),
        -_balanceEffect(type, amountMinor),
        -1,
      );
      await database.customUpdate(
        '''UPDATE transactions
        SET type = 'transfer', account_id = ?, to_account_id = ?,
            to_amount_minor = NULL, category_id = NULL, title = NULL,
            note = CASE WHEN ? IS NULL THEN note
              WHEN note IS NULL OR note = '' THEN ?
              ELSE note || char(10) || char(10) || ? END
        WHERE id = ?''',
        variables: [
          Variable(fromAccountId),
          Variable(toAccountId),
          Variable(appendNote),
          Variable(appendNote),
          Variable(appendNote),
          Variable(id),
        ],
      );
      await move(fromAccountId, -amountMinor, 1);
      await move(toAccountId, amountMinor, 1);
    });
  }

  /// What else, besides the ledger, records [id]: its loan, debt or
  /// subscription. Null when nothing does.
  Future<TransactionLink?> link(int id) async {
    final loanId = await linkedLoanId(id);
    if (loanId != null) {
      final loan = await database
          .customSelect(
            "SELECT json_extract(payload, '\$.lender') AS name FROM loans "
            'WHERE id = ?',
            variables: [Variable(loanId)],
          )
          .getSingleOrNull();
      return TransactionLink(
        TransactionLinkKind.loan,
        loanId,
        loan?.readNullable<String>('name') ?? 'Loan',
      );
    }
    final debt = await database
        .customSelect(
          '''SELECT p.id, p.name FROM debt_entries e
          JOIN debt_people p ON p.id = e.person_id
          WHERE e.transaction_id = ? LIMIT 1''',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (debt != null) {
      return TransactionLink(
        TransactionLinkKind.debt,
        debt.read<int>('id'),
        debt.read<String>('name'),
      );
    }
    final subscription = await database
        .customSelect(
          '''SELECT s.id, s.name FROM subscription_payments p
          JOIN subscriptions s ON s.id = p.subscription_id
          WHERE p.transaction_id = ?''',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (subscription != null) {
      return TransactionLink(
        TransactionLinkKind.subscription,
        subscription.read<int>('id'),
        subscription.read<String>('name'),
      );
    }
    return null;
  }

  /// Rewrites any transaction in place, including its kind: an expense or
  /// income can become a transfer between the user's accounts, and back.
  /// Its old effect on balances and counts is undone and the new one applied
  /// in one database transaction.
  ///
  /// A transaction another record owns keeps what that record depends on
  /// (see [TransactionLink.locks]); changing those throws.
  Future<void> edit({
    required int id,
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    int? toAccountId,
    int? categoryId,
    String? title,
    String? note,
    required DateTime date,
  }) async {
    final transfer = type == TransactionType.transfer;
    if (amountMinor <= 0) {
      throw ArgumentError('Enter an amount greater than zero.');
    }
    if (transfer && (toAccountId == null || toAccountId == accountId)) {
      throw ArgumentError('Choose two different accounts to transfer between.');
    }
    if (!transfer && categoryId == null) {
      throw ArgumentError('Choose a category.');
    }
    await database.transaction(() async {
      final old = await database
          .customSelect(
            '''SELECT type, amount_minor, account_id, to_account_id,
              to_amount_minor, category_id, date
            FROM transactions WHERE id = ?''',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (old == null) throw StateError('This transaction no longer exists.');
      final oldType = TransactionTypeStorage.fromStorage(
        old.read<String>('type'),
      );
      final oldAmount = old.read<int>('amount_minor');
      final oldAccount = old.read<int>('account_id');
      final oldTo = old.readNullable<int>('to_account_id');
      final oldToAmount = old.readNullable<int>('to_amount_minor');
      final locks = (await link(id))?.locks ?? const TransactionLocks();
      if (locks.type && type != oldType ||
          locks.amount && amountMinor != oldAmount ||
          locks.accounts && (accountId != oldAccount || toAccountId != oldTo) ||
          locks.date && date.millisecondsSinceEpoch != old.read<int>('date') ||
          locks.category &&
              categoryId != old.readNullable<int>('category_id') ||
          locks.transfer && transfer) {
        throw StateError(
          'Part of this transaction is managed by its loan, debt or '
          'subscription. Change it from there.',
        );
      }
      // A transfer between currencies keeps what reached the other side,
      // as long as nothing it was entered against has changed.
      int? toAmount;
      if (transfer) {
        final unchanged =
            oldType == TransactionType.transfer &&
            amountMinor == oldAmount &&
            accountId == oldAccount &&
            toAccountId == oldTo;
        if (unchanged) {
          toAmount = oldToAmount;
        } else {
          final pair = await database
              .customSelect(
                'SELECT currency, digits FROM accounts WHERE id IN (?, ?)',
                variables: [Variable(accountId), Variable(toAccountId)],
              )
              .get();
          if (pair.length == 2 &&
              (pair[0].read<String>('currency') !=
                      pair[1].read<String>('currency') ||
                  pair[0].read<int>('digits') != pair[1].read<int>('digits'))) {
            throw ArgumentError(
              'Both accounts need the same currency to edit this transfer.',
            );
          }
        }
      }
      Future<void> move(int account, int balance, int count) =>
          database.customUpdate(
            '''UPDATE accounts
            SET balance_minor = balance_minor + ?,
                transaction_count = transaction_count + ?
            WHERE id = ?''',
            variables: [Variable(balance), Variable(count), Variable(account)],
          );
      // Undo the old effect.
      if (oldType == TransactionType.transfer) {
        await move(oldAccount, oldAmount, -1);
        await move(oldTo!, -(oldToAmount ?? oldAmount), -1);
      } else {
        await move(oldAccount, -_balanceEffect(oldType, oldAmount), -1);
      }
      await database.customUpdate(
        '''UPDATE transactions
        SET type = ?, amount_minor = ?, account_id = ?, to_account_id = ?,
            to_amount_minor = ?, category_id = ?, title = ?, note = ?, date = ?
        WHERE id = ?''',
        variables: [
          Variable(type.storageValue),
          Variable(amountMinor),
          Variable(accountId),
          Variable(transfer ? toAccountId : null),
          Variable(toAmount),
          Variable(transfer ? null : categoryId),
          // Transfers carry no title anywhere else in the app.
          Variable(transfer ? null : title),
          Variable(note),
          Variable(date.millisecondsSinceEpoch),
          Variable(id),
        ],
      );
      // Apply the new one.
      if (transfer) {
        await move(accountId, -amountMinor, 1);
        await move(toAccountId!, toAmount ?? amountMinor, 1);
      } else {
        await move(accountId, _balanceEffect(type, amountMinor), 1);
      }
    });
  }

  /// Throws when [id] is a loan's own transaction, which must be corrected
  /// from the loan rather than edited or deleted directly.
  Future<void> _checkLoanLink(int id) async {
    if (await linkedLoanId(id) != null) {
      throw StateError(
        'Manage this transaction from its loan. Undo the latest action there to correct a payment.',
      );
    }
  }

  Future<int?> linkedLoanId(int id) async {
    final link = await database
        .customSelect(
          '''SELECT loan_id AS id FROM loan_events WHERE transaction_id = ?
          UNION ALL SELECT id FROM loans WHERE disbursal_id = ?
          UNION ALL SELECT id FROM loans WHERE charges_id = ? LIMIT 1''',
          variables: [Variable(id), Variable(id), Variable(id)],
        )
        .getSingleOrNull();
    return link?.read<int>('id');
  }

  /// Files an expense or income the ledger already has under a loan or debt
  /// that turned out to own it, instead of recording the money twice. Its
  /// amount, account and date stay, so no balance moves. Returns what undoing
  /// needs to put back, with the account it is on.
  Future<AdoptedTransaction> adopt(
    int id, {
    required TransactionType type,
    required int amountMinor,
    required int categoryId,
    required String title,
  }) => database.transaction(() async {
    final row = await database
        .customSelect(
          'SELECT type, amount_minor, account_id, category_id, title '
          'FROM transactions WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('Transaction $id no longer exists.');
    if (row.read<String>('type') != type.storageValue ||
        row.read<int>('amount_minor') != amountMinor) {
      throw StateError('Transaction $id no longer matches this payment.');
    }
    if (await link(id) != null) {
      throw StateError('Transaction $id already belongs to something else.');
    }
    await database.customUpdate(
      'UPDATE transactions SET category_id = ?, title = ? WHERE id = ?',
      variables: [Variable(categoryId), Variable(title), Variable(id)],
    );
    return AdoptedTransaction(
      id: id,
      accountId: row.read<int>('account_id'),
      categoryId: row.readNullable<int>('category_id'),
      title: row.readNullable<String>('title'),
    );
  });

  /// Gives an adopted transaction its category and title back. Whatever
  /// owned it must have let go first. One the user has since deleted, with
  /// its account, needs nothing.
  Future<void> release(AdoptedTransaction adopted) => database.customUpdate(
    '''UPDATE transactions SET title = ?,
      category_id = (SELECT id FROM categories WHERE id = ?) WHERE id = ?''',
    variables: [
      Variable(adopted.title),
      Variable(adopted.categoryId),
      Variable(adopted.id),
    ],
  );

  /// Permanently removes a transaction and reverses its effect on the
  /// balance(s) and transaction count(s) it moved, atomically.
  Future<void> delete(int id) => database.transaction(() async {
    await _checkLoanLink(id);
    final row = await database
        .customSelect(
          '''SELECT type, amount_minor, account_id, to_account_id,
             to_amount_minor
          FROM transactions WHERE id = ?''',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('This transaction no longer exists.');
    final type = TransactionTypeStorage.fromStorage(row.read<String>('type'));
    final amountMinor = row.read<int>('amount_minor');
    final accountId = row.read<int>('account_id');
    if (type == TransactionType.transfer) {
      final toAccountId = row.read<int>('to_account_id');
      // Each side is reversed by what it actually moved. Taking back the
      // source's figure from a destination that received a different one
      // leaves the balance this delete was meant to restore.
      final receivedMinor =
          row.readNullable<int>('to_amount_minor') ?? amountMinor;
      await database.customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor + ?, transaction_count = transaction_count - 1
        WHERE id = ?''',
        variables: [Variable(amountMinor), Variable(accountId)],
      );
      await database.customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor - ?, transaction_count = transaction_count - 1
        WHERE id = ?''',
        variables: [Variable(receivedMinor), Variable(toAccountId)],
      );
    } else {
      await database.customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor - ?, transaction_count = transaction_count - 1
        WHERE id = ?''',
        variables: [
          Variable(_balanceEffect(type, amountMinor)),
          Variable(accountId),
        ],
      );
    }
    await database.customUpdate(
      'DELETE FROM transactions WHERE id = ?',
      variables: [Variable(id)],
    );
    await database.customUpdate(
      'DELETE FROM subscription_payments WHERE transaction_id = ?',
      variables: [Variable(id)],
    );
    // A debt's transaction takes its debt entry along, and the person too
    // once nothing is left with them (see DebtRepository).
    await database.customUpdate(
      'DELETE FROM debt_entries WHERE transaction_id = ?',
      variables: [Variable(id)],
    );
    await database.customUpdate(
      'DELETE FROM debt_people WHERE id NOT IN (SELECT person_id FROM debt_entries)',
    );
  });

  /// Sets, adds to, or subtracts from an account's balance directly — see
  /// [BalanceAdjustmentMode] for why this isn't logged as a transaction.
  Future<void> adjustBalance({
    required int accountId,
    required BalanceAdjustmentMode mode,
    required int amountMinor,
  }) async {
    if (amountMinor < 0) {
      throw ArgumentError('Enter a valid amount.');
    }
    final sql = switch (mode) {
      BalanceAdjustmentMode.setTo =>
        'UPDATE accounts SET balance_minor = ? WHERE id = ?',
      BalanceAdjustmentMode.add =>
        'UPDATE accounts SET balance_minor = balance_minor + ? WHERE id = ?',
      BalanceAdjustmentMode.subtract =>
        'UPDATE accounts SET balance_minor = balance_minor - ? WHERE id = ?',
    };
    await database.customUpdate(
      sql,
      variables: [Variable(amountMinor), Variable(accountId)],
    );
  }
}

enum TransactionLinkKind { loan, debt, subscription }

/// A transaction a loan or debt took over, and what it was before.
class AdoptedTransaction {
  const AdoptedTransaction({
    required this.id,
    required this.accountId,
    this.categoryId,
    this.title,
  });
  final int id, accountId;
  final int? categoryId;
  final String? title;

  Map<String, dynamic> toJson() => {
    'id': id,
    'accountId': accountId,
    'categoryId': categoryId,
    'title': title,
  };

  factory AdoptedTransaction.fromJson(Map<String, dynamic> j) =>
      AdoptedTransaction(
        id: j['id'],
        accountId: j['accountId'],
        categoryId: j['categoryId'],
        title: j['title'],
      );
}

/// The fields of a transaction its owning record depends on, which only
/// that record may change.
class TransactionLocks {
  const TransactionLocks({
    this.type = false,
    this.amount = false,
    this.accounts = false,
    this.date = false,
    this.category = false,
    this.transfer = false,
  });
  final bool type, amount, accounts, date, category;

  /// May not become a transfer, though its kind is otherwise free.
  final bool transfer;

  bool get any => type || amount || accounts || date || category || transfer;
}

/// The loan, debt or subscription a transaction belongs to.
class TransactionLink {
  const TransactionLink(this.kind, this.ownerId, this.name);
  final TransactionLinkKind kind;
  final int ownerId;
  final String name;

  /// A loan's schedule and a debt's balance are built from the amount,
  /// accounts and dates of their transactions, so those stay theirs; a debt
  /// keeps its category too. A subscription renewal may be corrected freely
  /// but stays a payment.
  TransactionLocks get locks => switch (kind) {
    TransactionLinkKind.loan ||
    TransactionLinkKind.debt => const TransactionLocks(
      type: true,
      amount: true,
      accounts: true,
      date: true,
      category: true,
      transfer: true,
    ),
    TransactionLinkKind.subscription => const TransactionLocks(transfer: true),
  };
}
