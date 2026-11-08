import 'package:drift/drift.dart';

import '../../domain/account.dart';
import '../db/app_database.dart';
import 'debt_repository.dart';
import 'loan_repository.dart';
import 'subscription_repository.dart';

class AccountRepository {
  AccountRepository(this.database);
  final AppDatabase database;

  /// Seed only an empty ledger; archived accounts also prevent reseeding.
  Future<void> ensureDefaultCashAccount() => database.transaction(() async {
    final existing = await database
        .customSelect('SELECT id FROM accounts LIMIT 1')
        .get();
    if (existing.isNotEmpty) return;
    await save(
      name: 'Cash in hand',
      type: AccountType.cash,
      currency: 'INR',
      territory: 'IN',
      digits: 2,
      icon: 'wallet_one',
      openingBalance: 0,
    );
  });

  /// Every account, archived ones included. `AccountStore` is what separates
  /// the active ones from the rest; the archived still have to be loaded, or
  /// a transaction belonging to one could not be shown at all.
  Future<List<Account>> load() async =>
      (await database
              .customSelect('SELECT * FROM accounts ORDER BY sort_order, id')
              .get())
          .map(
            (r) => Account(
              id: r.read<int>('id'),
              name: r.read<String>('name'),
              currency: r.read<String>('currency'),
              type: AccountType.values.byName(r.read<String>('type')),
              lastDigits: r.readNullable<String>('last_digits'),
              institution: r.readNullable<String>('institution'),
              creditLimitMinor: r.readNullable<int>('credit_limit_minor'),
              availableCreditLimitMinor: r.readNullable<int>(
                'available_limit_minor',
              ),
              balanceReportedAt:
                  r.readNullable<int>('balance_reported_at') == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      r.read<int>('balance_reported_at'),
                    ),
              territory: r.readNullable<String>('territory'),
              icon: r.readNullable<String>('icon'),
              digits: r.read<int>('digits'),
              balanceMinor: r.read<int>('balance_minor'),
              transactionCount: r.read<int>('transaction_count'),
              archivedAt: switch (r.readNullable<int>('archived_at')) {
                final at? => DateTime.fromMillisecondsSinceEpoch(at),
                null => null,
              },
            ),
          )
          .toList();

  Future<int> save({
    Account? existing,
    AccountType? type,
    String? lastDigits,
    String? institution,
    int? creditLimitMinor,
    int? availableCreditLimitMinor,
    bool updateCreditLimits = false,
    DateTime? balanceReportedAt,
    DateTime? availableLimitReportedAt,
    DateTime? creditLimitReportedAt,
    required String name,
    required String currency,
    String? territory,
    String? icon,
    required int digits,
    required int openingBalance,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty || cleanName.length > 40) {
      throw ArgumentError('Enter a name of 1–40 characters.');
    }
    final accountType = type ?? existing?.type ?? AccountType.bank;
    final suffix = accountType == AccountType.cash
        ? null
        : (lastDigits ?? existing?.lastDigits);
    if (suffix != null && !RegExp(r'^\d{2,4}$').hasMatch(suffix)) {
      throw ArgumentError('Enter the last 2 to 4 digits.');
    }
    final total = accountType == AccountType.creditCard
        ? (updateCreditLimits
              ? creditLimitMinor
              : creditLimitMinor ?? existing?.creditLimitMinor)
        : null;
    final available = accountType == AccountType.creditCard
        ? (updateCreditLimits
              ? availableCreditLimitMinor
              : availableCreditLimitMinor ??
                    existing?.availableCreditLimitMinor)
        : null;
    if ((total != null && total < 0) || (available != null && available < 0)) {
      throw ArgumentError('Limits cannot be negative.');
    }
    if (existing == null) {
      return await database.customInsert(
        '''INSERT INTO accounts
        (name, currency, territory, icon, digits, balance_minor, type, last_digits, institution, credit_limit_minor, available_limit_minor, balance_reported_at, available_limit_reported_at, credit_limit_reported_at, sort_order)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM accounts))''',
        variables: [
          Variable(cleanName),
          Variable(currency),
          Variable(territory),
          Variable(icon),
          Variable(digits),
          Variable(openingBalance),
          Variable(accountType.name),
          Variable(suffix),
          Variable(institution),
          Variable(total),
          Variable(available),
          Variable(balanceReportedAt?.millisecondsSinceEpoch),
          Variable(availableLimitReportedAt?.millisecondsSinceEpoch),
          Variable(creditLimitReportedAt?.millisecondsSinceEpoch),
        ],
      );
    } else {
      if ((existing.currency != currency || existing.digits != digits) &&
          await LoanRepository(database).usesAccount(existing.id)) {
        throw ArgumentError(
          'This account has linked loan payments. Keep its currency and precision to preserve the repayment history.',
        );
      }
      final balance = relabelAmount(
        existing.balanceMinor,
        existing.digits,
        digits,
      );
      if (balance == null) {
        throw ArgumentError(
          'This currency cannot represent the current balance exactly.',
        );
      }
      final savedTotal = accountType == AccountType.creditCard
          ? updateCreditLimits
                ? creditLimitMinor
                : creditLimitMinor ??
                      (existing.creditLimitMinor == null
                          ? null
                          : relabelAmount(
                              existing.creditLimitMinor!,
                              existing.digits,
                              digits,
                            ))
          : null;
      final savedAvailable = accountType == AccountType.creditCard
          ? updateCreditLimits
                ? availableCreditLimitMinor
                : availableCreditLimitMinor ??
                      (existing.availableCreditLimitMinor == null
                          ? null
                          : relabelAmount(
                              existing.availableCreditLimitMinor!,
                              existing.digits,
                              digits,
                            ))
          : null;
      if (!updateCreditLimits &&
          ((accountType == AccountType.creditCard &&
                  existing.creditLimitMinor != null &&
                  savedTotal == null) ||
              (accountType == AccountType.creditCard &&
                  existing.availableCreditLimitMinor != null &&
                  savedAvailable == null))) {
        throw ArgumentError(
          'This precision cannot represent the credit limits exactly.',
        );
      }
      await database.customUpdate(
        'UPDATE accounts SET name = ?, currency = ?, territory = ?, icon = ?, digits = ?, balance_minor = ?, type = ?, last_digits = ?, institution = ?, credit_limit_minor = ?, available_limit_minor = ? WHERE id = ?',
        variables: [
          Variable(cleanName),
          Variable(currency),
          Variable(territory),
          Variable(icon),
          Variable(digits),
          Variable(balance),
          Variable(accountType.name),
          Variable(suffix),
          Variable(institution ?? existing.institution),
          Variable(savedTotal),
          Variable(savedAvailable),
          Variable(existing.id),
        ],
      );
      return existing.id;
    }
  }

  /// Removes the account and every linked entry atomically. Removing history
  /// does not undo real transfers: surviving accounts retain their balances.
  Future<void> delete(int id) => database.transaction(() async {
    // Each feature unpicks its own links; their tables' invariants are not
    // this repository's to know.
    await LoanRepository(database).detachAccount(id);
    await DebtRepository(database).detachAccount(id);
    await SubscriptionRepository(database).detachAccount(id);
    await database.customUpdate(
      '''DELETE FROM transactions WHERE account_id = ? OR to_account_id = ?''',
      variables: [Variable(id), Variable(id)],
    );
    await database.customUpdate(
      'DELETE FROM accounts WHERE id = ?',
      variables: [Variable(id)],
    );
    await database.customUpdate('''UPDATE accounts SET transaction_count = (
        SELECT COUNT(*) FROM transactions t
        WHERE t.account_id = accounts.id OR t.to_account_id = accounts.id
      )''');
  });

  /// Retires the account without touching a single transaction: it leaves the
  /// pickers and the balance totals, while its history stays readable. The
  /// reversible half of [delete], and what the UI recommends instead once an
  /// account carries enough entries that deleting it would be a real loss.
  Future<void> archive(int id) => database.customUpdate(
    'UPDATE accounts SET archived_at = ? WHERE id = ? AND archived_at IS NULL',
    variables: [Variable(DateTime.now().millisecondsSinceEpoch), Variable(id)],
  );

  /// Puts an archived account back in circulation, balance and history intact.
  Future<void> restore(int id) => database.customUpdate(
    'UPDATE accounts SET archived_at = NULL WHERE id = ?',
    variables: [Variable(id)],
  );

  Future<void> reorder(List<Account> accounts) =>
      database.transaction(() async {
        for (var index = 0; index < accounts.length; index++) {
          await database.customUpdate(
            'UPDATE accounts SET sort_order = ? WHERE id = ?',
            variables: [Variable(index), Variable(accounts[index].id)],
          );
        }
      });
}
