import 'package:drift/drift.dart';

import '../../domain/debt.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import 'transaction_repository.dart';

/// An entry whose money moved through an account also records an ordinary
/// expense or income there, filed under the matching Debt/Loan category, so
/// balances and account history stay right. Home and Budgets leave that
/// category out of their income and spending.
class DebtRepository {
  DebtRepository(this.database);
  final AppDatabase database;

  /// Unpicks every reference to an account being deleted. Debts are still
  /// owed, so their entries only stop pointing at the account.
  Future<void> detachAccount(int accountId) => database.customUpdate(
    '''UPDATE debt_entries SET account_id = NULL, transaction_id = NULL
      WHERE account_id = ?''',
    variables: [Variable(accountId)],
  );

  /// The default Debt/Loan category each kind is filed under.
  static const _categories = {
    DebtKind.lend: (name: 'Loan', icon: 'bank'),
    DebtKind.borrow: (name: 'Debt', icon: 'credit'),
    DebtKind.collect: (name: 'Debt Collection', icon: 'bank_card'),
    DebtKind.repay: (name: 'Repayment', icon: 'bank_transfer'),
  };

  static const _dropUnusedPeople =
      'DELETE FROM debt_people WHERE id NOT IN (SELECT person_id FROM debt_entries)';

  Future<List<PersonDebts>> load() => database.transaction(() async {
    final entries = <int, List<DebtEntry>>{};
    for (final r
        in await database
            .customSelect(
              'SELECT * FROM debt_entries ORDER BY date DESC, id DESC',
            )
            .get()) {
      final due = r.readNullable<int>('due_date');
      entries
          .putIfAbsent(r.read<int>('person_id'), () => [])
          .add(
            DebtEntry(
              id: r.read<int>('id'),
              personId: r.read<int>('person_id'),
              kind: DebtKindStorage.fromStorage(r.read<String>('kind')),
              amountMinor: r.read<int>('amount_minor'),
              currency: r.read<String>('currency'),
              digits: r.read<int>('digits'),
              accountId: r.readNullable<int>('account_id'),
              transactionId: r.readNullable<int>('transaction_id'),
              note: r.readNullable<String>('note'),
              date: DateTime.fromMillisecondsSinceEpoch(r.read<int>('date')),
              dueDate: due == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(due),
            ),
          );
    }
    final people = await database
        .customSelect(
          'SELECT * FROM debt_people ORDER BY name COLLATE NOCASE, id',
        )
        .get();
    return [
      for (final r in people)
        PersonDebts(
          DebtPerson(
            id: r.read<int>('id'),
            name: r.read<String>('name'),
            phone: r.readNullable<String>('phone'),
          ),
          entries[r.read<int>('id')] ?? const [],
        ),
    ];
  });

  /// Records an entry with [personId], or with a new person called
  /// [newPersonName]. With [accountId] the money moves through that account
  /// and the entry takes its currency; without one it's only a record, in
  /// [currency]. With [adoptTransactionId] the ledger already has the money:
  /// that transaction is filed under the entry and no other is written.
  /// Returns the person's id, and whether a deleted Debt/Loan category had to
  /// be added back for the transaction; [onSaved] hears what undoing needs.
  Future<({int personId, bool addedCategory})> addEntry({
    int? personId,
    String? newPersonName,
    String? newPersonPhone,
    required DebtKind kind,
    required int amountMinor,
    int? accountId,
    String? currency,
    int? digits,
    String? note,
    required DateTime date,
    DateTime? dueDate,
    int? adoptTransactionId,
    void Function(int entryId, AdoptedTransaction? adopted)? onSaved,
  }) {
    if (amountMinor <= 0) {
      throw ArgumentError('Enter an amount greater than zero.');
    }
    final name = newPersonName?.trim();
    if ((personId == null) == (name == null)) {
      throw ArgumentError('Choose one person.');
    }
    if (name != null && (name.isEmpty || name.length > 40)) {
      throw ArgumentError('Enter a name of 1–40 characters.');
    }
    if (accountId == null &&
        adoptTransactionId == null &&
        (currency == null || digits == null)) {
      throw ArgumentError('Choose an account or a currency.');
    }
    final due = kind.opensDebt && dueDate != null
        ? DateTime(dueDate.year, dueDate.month, dueDate.day)
        : null;
    return database.transaction(() async {
      final id =
          personId ??
          await database.customInsert(
            'INSERT INTO debt_people (name, phone, created_at) VALUES (?, ?, ?)',
            variables: [
              Variable(name),
              Variable(_optional(newPersonPhone)),
              Variable(DateTime.now().millisecondsSinceEpoch),
            ],
          );
      final person = await database
          .customSelect(
            'SELECT name FROM debt_people WHERE id = ?',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (person == null) throw StateError('This person no longer exists.');
      var entryCurrency = currency;
      var entryDigits = digits;
      int? transactionId;
      var addedCategory = false;
      var entryAccount = accountId;
      AdoptedTransaction? adopted;
      if (adoptTransactionId != null) {
        final category = await _categoryFor(kind);
        addedCategory = category.added;
        adopted = await TransactionRepository(database).adopt(
          adoptTransactionId,
          type: kind.paysOut ? TransactionType.expense : TransactionType.income,
          amountMinor: amountMinor,
          categoryId: category.id,
          title: _title(kind, person.read<String>('name')),
        );
        entryAccount = adopted.accountId;
        transactionId = adopted.id;
      }
      if (entryAccount != null) {
        final account = await database
            .customSelect(
              'SELECT currency, digits FROM accounts WHERE id = ?',
              variables: [Variable(entryAccount)],
            )
            .getSingleOrNull();
        if (account == null) throw StateError('This account no longer exists.');
        entryCurrency = account.read<String>('currency');
        entryDigits = account.read<int>('digits');
      }
      if (entryAccount != null && adopted == null) {
        final category = await _categoryFor(kind);
        addedCategory = category.added;
        transactionId = await TransactionRepository(database)
            .addExpenseOrIncome(
              type: kind.paysOut
                  ? TransactionType.expense
                  : TransactionType.income,
              amountMinor: amountMinor,
              accountId: entryAccount,
              categoryId: category.id,
              title: _title(kind, person.read<String>('name')),
              note: _optional(note),
              date: date,
            );
      }
      final entryId = await database.customInsert(
        '''INSERT INTO debt_entries
        (person_id, kind, amount_minor, currency, digits, account_id,
         transaction_id, note, date, due_date, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        variables: [
          Variable(id),
          Variable(kind.storageValue),
          Variable(amountMinor),
          Variable(entryCurrency),
          Variable(entryDigits),
          Variable(entryAccount),
          Variable(transactionId),
          Variable(_optional(note)),
          Variable(date.millisecondsSinceEpoch),
          Variable(due?.millisecondsSinceEpoch),
          Variable(DateTime.now().millisecondsSinceEpoch),
        ],
      );
      onSaved?.call(entryId, adopted);
      return (personId: id, addedCategory: addedCategory);
    });
  }

  /// Takes an entry back while keeping the transaction it took over, which
  /// goes back to what it was. A person left with no entries goes too.
  Future<void> unlinkAdopted(int id, AdoptedTransaction adopted) =>
      database.transaction(() async {
        await database.customUpdate(
          'DELETE FROM debt_entries WHERE id = ?',
          variables: [Variable(id)],
        );
        await TransactionRepository(database).release(adopted);
        await database.customUpdate(_dropUnusedPeople);
      });

  /// Deletes an entry along with the transaction it recorded, reversing its
  /// effect on the account. A person left with no entries goes too.
  Future<void> deleteEntry(int id) => database.transaction(() async {
    final row = await database
        .customSelect(
          'SELECT transaction_id FROM debt_entries WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return;
    await database.customUpdate(
      'DELETE FROM debt_entries WHERE id = ?',
      variables: [Variable(id)],
    );
    await _deleteTransaction(row.readNullable<int>('transaction_id'));
    await database.customUpdate(_dropUnusedPeople);
  });

  /// Deletes a person and everything recorded with them, reversing each
  /// linked transaction's effect on its account.
  Future<void> deletePerson(int id) => database.transaction(() async {
    final rows = await database
        .customSelect(
          'SELECT transaction_id FROM debt_entries WHERE person_id = ?',
          variables: [Variable(id)],
        )
        .get();
    await database.customUpdate(
      'DELETE FROM debt_entries WHERE person_id = ?',
      variables: [Variable(id)],
    );
    for (final row in rows) {
      await _deleteTransaction(row.readNullable<int>('transaction_id'));
    }
    await database.customUpdate(
      'DELETE FROM debt_people WHERE id = ?',
      variables: [Variable(id)],
    );
  });

  /// Changes a person's name and phone number. The transactions their
  /// entries recorded are named after them, so those follow the new name.
  Future<void> updatePerson(int id, {required String name, String? phone}) {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 40) {
      throw ArgumentError('Enter a name of 1–40 characters.');
    }
    return database.transaction(() async {
      final updated = await database.customUpdate(
        'UPDATE debt_people SET name = ?, phone = ? WHERE id = ?',
        variables: [Variable(clean), Variable(_optional(phone)), Variable(id)],
      );
      if (updated == 0) throw StateError('This person no longer exists.');
      final linked = await database
          .customSelect(
            '''SELECT kind, transaction_id FROM debt_entries
            WHERE person_id = ? AND transaction_id IS NOT NULL''',
            variables: [Variable(id)],
          )
          .get();
      for (final row in linked) {
        await database.customUpdate(
          'UPDATE transactions SET title = ? WHERE id = ?',
          variables: [
            Variable(
              _title(
                DebtKindStorage.fromStorage(row.read<String>('kind')),
                clean,
              ),
            ),
            Variable(row.read<int>('transaction_id')),
          ],
        );
      }
    });
  }

  /// Rewrites an entry's amount, account, dates and note; its person and
  /// kind stay. The transaction it recorded changes along with it: moved to
  /// the new account, added when an account is chosen for a plain record,
  /// or removed when the entry becomes one — balances staying right each way.
  Future<({bool addedCategory})> updateEntry({
    required int id,
    required int amountMinor,
    int? accountId,
    String? currency,
    int? digits,
    String? note,
    required DateTime date,
    DateTime? dueDate,
  }) {
    if (amountMinor <= 0) {
      throw ArgumentError('Enter an amount greater than zero.');
    }
    if (accountId == null && (currency == null || digits == null)) {
      throw ArgumentError('Choose an account or a currency.');
    }
    return database.transaction(() async {
      final row = await database
          .customSelect(
            '''SELECT e.kind, e.transaction_id, p.name FROM debt_entries e
            JOIN debt_people p ON p.id = e.person_id WHERE e.id = ?''',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (row == null) throw StateError('This entry no longer exists.');
      final kind = DebtKindStorage.fromStorage(row.read<String>('kind'));
      final name = row.read<String>('name');
      final due = kind.opensDebt && dueDate != null
          ? DateTime(dueDate.year, dueDate.month, dueDate.day)
          : null;
      final transactions = TransactionRepository(database);
      var transactionId = row.readNullable<int>('transaction_id');
      // The account may have gone, taking the transaction with it.
      if (transactionId != null &&
          await database
                  .customSelect(
                    'SELECT 1 FROM transactions WHERE id = ?',
                    variables: [Variable(transactionId)],
                  )
                  .getSingleOrNull() ==
              null) {
        transactionId = null;
      }
      var entryCurrency = currency;
      var entryDigits = digits;
      var addedCategory = false;
      if (accountId != null) {
        final account = await database
            .customSelect(
              'SELECT currency, digits FROM accounts WHERE id = ?',
              variables: [Variable(accountId)],
            )
            .getSingleOrNull();
        if (account == null) throw StateError('This account no longer exists.');
        entryCurrency = account.read<String>('currency');
        entryDigits = account.read<int>('digits');
        final category = await _categoryFor(kind);
        addedCategory = category.added;
        final type = kind.paysOut
            ? TransactionType.expense
            : TransactionType.income;
        if (transactionId != null) {
          await transactions.updateExpenseOrIncome(
            id: transactionId,
            type: type,
            amountMinor: amountMinor,
            accountId: accountId,
            categoryId: category.id,
            title: _title(kind, name),
            note: _optional(note),
            date: date,
          );
        } else {
          transactionId = await transactions.addExpenseOrIncome(
            type: type,
            amountMinor: amountMinor,
            accountId: accountId,
            categoryId: category.id,
            title: _title(kind, name),
            note: _optional(note),
            date: date,
          );
        }
      }
      final dropped = accountId == null ? transactionId : null;
      await database.customUpdate(
        '''UPDATE debt_entries
        SET amount_minor = ?, currency = ?, digits = ?, account_id = ?,
            transaction_id = ?, note = ?, date = ?, due_date = ?
        WHERE id = ?''',
        variables: [
          Variable(amountMinor),
          Variable(entryCurrency),
          Variable(entryDigits),
          Variable(accountId),
          Variable(accountId == null ? null : transactionId),
          Variable(_optional(note)),
          Variable(date.millisecondsSinceEpoch),
          Variable(due?.millisecondsSinceEpoch),
          Variable(id),
        ],
      );
      // Unlinked first: deleting a debt's transaction deletes its entry.
      await _deleteTransaction(dropped);
      return (addedCategory: addedCategory);
    });
  }

  Future<void> _deleteTransaction(int? id) async {
    if (id == null) return;
    final exists = await database
        .customSelect(
          'SELECT 1 FROM transactions WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (exists != null) await TransactionRepository(database).delete(id);
  }

  /// The kind's Debt/Loan category, added back if it has been deleted.
  Future<({int id, bool added})> _categoryFor(DebtKind kind) async {
    final (:name, :icon) = _categories[kind]!;
    final existing = await database
        .customSelect(
          '''SELECT id FROM categories
          WHERE type = 'debt_loan' AND parent_id IS NULL AND name = ?
          ORDER BY id LIMIT 1''',
          variables: [Variable(name)],
        )
        .getSingleOrNull();
    if (existing != null) return (id: existing.read<int>('id'), added: false);
    final id = await database.customInsert(
      '''INSERT INTO categories (name, type, icon, parent_id, sort_order)
      VALUES (?, 'debt_loan', ?, NULL,
        (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))''',
      variables: [Variable(name), Variable(icon)],
    );
    return (id: id, added: true);
  }

  static String _title(DebtKind kind, String name) => switch (kind) {
    DebtKind.lend => 'Lent to $name',
    DebtKind.borrow => 'Borrowed from $name',
    DebtKind.collect => 'Paid back by $name',
    DebtKind.repay => 'Paid back $name',
  };

  static String? _optional(String? text) {
    final trimmed = text?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
