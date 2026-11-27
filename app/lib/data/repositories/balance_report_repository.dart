import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/account.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import 'account_repository.dart';
import 'sms_import_repository.dart';
import 'transaction_repository.dart';

/// A bank balance that differs from the app's, waiting for the user.
class BalanceMismatch {
  const BalanceMismatch({
    required this.account,
    required this.reportedMinor,
    required this.appMinor,
    required this.reportedAt,
  });
  final Account account;

  /// The bank's figure, and the app's for the same moment.
  final int reportedMinor, appMinor;
  final DateTime reportedAt;
  int get differenceMinor => reportedMinor - appMinor;
}

/// A bank SMS never changes the balance of an existing account. Its figure is
/// compared with the ledger, and the user decides what to do about a gap.
class BalanceReportRepository {
  BalanceReportRepository(this.database);
  final AppDatabase database;

  /// Device-local, like sms_balances: the newest report per account that
  /// already matched, was answered, or was replaced by the user's own figure.
  Future<void> _ensure() => database.customStatement(
    '''CREATE TABLE IF NOT EXISTS sms_balance_settled (
      account_id INTEGER PRIMARY KEY, received_at INTEGER NOT NULL
    )''',
  );

  Future<void> _settle(int accountId, int at) => database.customStatement(
    '''INSERT INTO sms_balance_settled(account_id,received_at) VALUES (?,?)
    ON CONFLICT(account_id) DO UPDATE SET received_at=excluded.received_at
    WHERE excluded.received_at > sms_balance_settled.received_at''',
    [accountId, at],
  );

  Future<QueryRow?> _latestReport(int accountId) => database
      .customSelect(
        '''SELECT b.balance_minor, b.received_at FROM sms_balances b
        JOIN sms_account_links l ON l.bank_key=b.bank_key
        WHERE l.account_id=? ORDER BY b.received_at DESC LIMIT 1''',
        variables: [Variable(accountId)],
      )
      .getSingleOrNull();

  /// Keeps the app's balance; the bank's next report is compared afresh.
  Future<void> keep(BalanceMismatch mismatch) async {
    await _ensure();
    await _settle(
      mismatch.account.id,
      mismatch.reportedAt.millisecondsSinceEpoch,
    );
  }

  /// The user set the balance themselves, which outranks any earlier report.
  Future<void> settleLatest(int accountId) async {
    await _ensure();
    final report = await _latestReport(accountId);
    if (report != null) {
      await _settle(accountId, report.read<int>('received_at'));
    }
  }

  Future<List<BalanceMismatch>> mismatches() async {
    await _ensure();
    final result = <BalanceMismatch>[];
    for (final account in await AccountRepository(database).load()) {
      if (account.isArchived || account.type != AccountType.bank) continue;
      final report = await _latestReport(account.id);
      if (report == null) continue;
      final at = report.read<int>('received_at');
      final reported = report.read<int>('balance_minor');
      final settled = await database
          .customSelect(
            'SELECT received_at FROM sms_balance_settled WHERE account_id=?',
            variables: [Variable(account.id)],
          )
          .getSingleOrNull();
      // Also the report the account was opened with.
      final answered = [
        settled?.read<int>('received_at') ?? -1,
        account.balanceReportedAt?.millisecondsSinceEpoch ?? -1,
      ].reduce((a, b) => a > b ? a : b);
      if (at <= answered) continue;
      // The balance as of the report: without what happened after it.
      final later = await database
          .customSelect(
            '''SELECT coalesce(sum(
              CASE WHEN account_id=?1 THEN
                CASE WHEN type='income' THEN amount_minor ELSE -amount_minor END
              ELSE coalesce(to_amount_minor, amount_minor) END), 0) AS effect
            FROM transactions WHERE date > ?2
            AND (account_id=?1 OR (type='transfer' AND to_account_id=?1))''',
            variables: [Variable(account.id), Variable(at)],
          )
          .getSingle();
      final app = account.balanceMinor - later.read<int>('effect');
      if (app == reported) {
        await _settle(account.id, at);
        continue;
      }
      if (await _waitsForReview(account, at, answered, reported - app)) {
        continue;
      }
      result.add(
        BalanceMismatch(
          account: account,
          reportedMinor: reported,
          appMinor: app,
          reportedAt: DateTime.fromMillisecondsSinceEpoch(at),
        ),
      );
    }
    return result;
  }

  /// Whether messages still waiting for review explain the gap: the one that
  /// carried this balance is unsaved, or the unsaved ones add up to it.
  Future<bool> _waitsForReview(
    Account account,
    int at,
    int answered,
    int difference,
  ) async {
    final rows = await database
        .customSelect(
          '''SELECT candidate, received_at FROM sms_imports
          WHERE status='pending' AND received_at <= ? AND received_at > ?''',
          variables: [Variable(at), Variable(answered)],
        )
        .get();
    if (rows.isEmpty) return false;
    final imports = SmsImportRepository(database);
    final links = await imports.accountLinks();
    var waiting = 0;
    for (final row in rows) {
      final sms = PendingSmsImport(
        id: '',
        sender: '',
        body: '',
        data: Map<String, dynamic>.from(
          jsonDecode(row.read<String>('candidate')) as Map,
        ),
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('received_at'),
        ),
      );
      final target = sms.data['assignedAccountId'] ?? links[sms.bankKey];
      if (target != account.id) continue;
      if (row.read<int>('received_at') == at) return true;
      waiting += sms.credit ? sms.amountMinor : -sms.amountMinor;
    }
    return waiting == difference;
  }

  /// Records the gap as a visible entry dated at the report, which moves the
  /// balance to the bank's figure. Deleting that entry undoes it.
  Future<int> adjust(BalanceMismatch mismatch) =>
      database.transaction(() async {
        final current = (await mismatches())
            .where((m) => m.account.id == mismatch.account.id)
            .firstOrNull;
        if (current == null ||
            current.reportedAt != mismatch.reportedAt ||
            current.differenceMinor != mismatch.differenceMinor) {
          throw StateError('This balance has changed. Check it again.');
        }
        final difference = current.differenceMinor;
        final at = current.reportedAt.millisecondsSinceEpoch;
        final id = await record(
          current.account.id,
          difference,
          current.reportedAt,
          note: 'Matched to the balance your bank reported',
        );
        // The bank's figure includes anything older that is saved later.
        await database.customStatement(
          'UPDATE accounts SET balance_reported_at=? WHERE id=?',
          [at, current.account.id],
        );
        await _settle(current.account.id, at);
        return id;
      });

  /// Adds the entry that moves [accountId]'s balance by [difference].
  Future<int> record(
    int accountId,
    int difference,
    DateTime date, {
    String? note,
  }) async => TransactionRepository(database).addExpenseOrIncome(
    type: difference > 0 ? TransactionType.income : TransactionType.expense,
    amountMinor: difference.abs(),
    accountId: accountId,
    categoryId: await _categoryId(),
    title: balanceAdjustmentCategory,
    note: note,
    date: date,
  );

  Future<int> _categoryId() async {
    final existing = await database
        .customSelect(
          '''SELECT id FROM categories
          WHERE type='debt_loan' AND parent_id IS NULL AND name=?
          ORDER BY id LIMIT 1''',
          variables: [Variable(balanceAdjustmentCategory)],
        )
        .getSingleOrNull();
    if (existing != null) {
      await database.customUpdate(
        "UPDATE categories SET icon=? WHERE id=? AND icon='wallet_one'",
        variables: [
          Variable(balanceAdjustmentIcon),
          Variable(existing.read<int>('id')),
        ],
      );
      return existing.read<int>('id');
    }
    return database.customInsert(
      '''INSERT INTO categories (id, name, type, icon, parent_id, sort_order)
      VALUES (${newRowId('categories')}, ?, 'debt_loan', ?, NULL,
        (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))''',
      variables: [
        Variable(balanceAdjustmentCategory),
        Variable(balanceAdjustmentIcon),
      ],
    );
  }
}
