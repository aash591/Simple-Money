/// Finding the ledger transaction something outside the ledger already is:
/// a statement row, or a payment on a loan statement. Each caller decides
/// what counts as a fit; this holds what they share — which transactions can
/// be claimed, and picking the closest one.
///
/// UPI and SMS joins don't use this: they work within minutes and on
/// messages, and an equal amount alone must never merge them. Sync joins on
/// exact fingerprints, so it has nothing to find.
library;

import 'package:drift/drift.dart';

import '../domain/transaction.dart';
import 'db/app_database.dart';

/// A ledger transaction something might already be.
class LedgerCandidate {
  const LedgerCandidate({
    required this.id,
    required this.type,
    required this.amountMinor,
    required this.accountId,
    this.toAccountId,
    required this.date,
    this.title,
    this.references = '',
    this.transferable = false,
    this.free = false,
  });
  final int id;
  final TransactionType type;
  final int amountMinor, accountId;
  final int? toAccountId;
  final DateTime date;
  final String? title;

  /// Text that quotes the transaction's UPI references: its note (which
  /// keeps an imported SMS, or an earlier statement's reference) and the
  /// references the SMS parser read.
  final String references;

  /// Whether this expense or income may become a transfer: a plain rupee
  /// transaction that no loan, debt or recurring payment is built on.
  final bool transferable;

  /// Whether no loan, debt or recurring payment is built on this transaction yet.
  final bool free;

  /// Whether the transaction's title or note contains [text], ignoring case.
  bool mentions(String text) =>
      '${title ?? ''} $references'.toLowerCase().contains(text.toLowerCase());
}

/// The same day, or a few hours apart across midnight: an SMS is stamped
/// when it arrives, the statement when the payment was made. Wider would
/// swallow a regular payment (the same ₹90 every day) into yesterday's.
bool nearlySameTime(DateTime a, DateTime b) =>
    (a.year == b.year && a.month == b.month && a.day == b.day) ||
    a.difference(b).abs() <= const Duration(hours: 3);

/// Up to [days] calendar days apart, for a lender's statement: it dates a
/// payment when the lender received it, the bank when it left. Monthly
/// payments are far enough apart for this to be safe.
bool Function(DateTime, DateTime) withinDays(int days) => (a, b) {
  DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
  return day(a).difference(day(b)).abs() <= Duration(days: days);
};

/// The unclaimed transaction of [amountMinor] that [fits], nearest to [date].
/// Ones [preferred] marks win over nearer ones that aren't.
LedgerCandidate? closestInLedger(
  Iterable<LedgerCandidate> ledger, {
  required int amountMinor,
  required DateTime date,
  required Set<int> claimed,
  required bool Function(LedgerCandidate) fits,
  bool Function(DateTime, DateTime) near = nearlySameTime,
  bool Function(LedgerCandidate)? preferred,
}) {
  final candidates =
      ledger
          .where(
            (t) =>
                !claimed.contains(t.id) &&
                t.amountMinor == amountMinor &&
                near(t.date, date) &&
                fits(t),
          )
          .toList()
        ..sort((a, b) {
          if (preferred != null && preferred(a) != preferred(b)) {
            return preferred(a) ? -1 : 1;
          }
          return a.date
              .difference(date)
              .abs()
              .compareTo(b.date.difference(date).abs());
        });
  return candidates.firstOrNull;
}

/// The ledger from [start] to [end], as candidates to match against.
Future<List<LedgerCandidate>> ledgerBetween(
  AppDatabase database,
  DateTime start,
  DateTime end,
) async {
  final result = await database
      .customSelect(
        '''SELECT t.id, t.type, t.amount_minor, t.account_id, t.to_account_id,
            t.date, t.title, a.currency, a.digits,
            coalesce(t.note, '') || ' ' ||
            coalesce((SELECT group_concat(coalesce(
                json_extract(s.candidate, '\$.reference'),
                json_extract(s.candidate, '\$.bankReference'), ''), ' ')
              FROM sms_imports s WHERE s.transaction_id = t.id), '') AS refs,
            (NOT EXISTS (SELECT 1 FROM loan_events l
                WHERE l.transaction_id = t.id)
              AND NOT EXISTS (SELECT 1 FROM loans l
                WHERE t.id IN (l.disbursal_id, l.charges_id))
              AND NOT EXISTS (SELECT 1 FROM debt_entries d
                WHERE d.transaction_id = t.id)
              AND NOT EXISTS (SELECT 1 FROM recurring_payment_history p
                WHERE p.transaction_id = t.id)) AS free
          FROM transactions t JOIN accounts a ON a.id = t.account_id
          WHERE t.date >= ? AND t.date <= ?''',
        variables: [
          Variable(start.millisecondsSinceEpoch),
          Variable(end.millisecondsSinceEpoch),
        ],
      )
      .get();
  return [
    for (final r in result)
      () {
        final type = TransactionTypeStorage.fromStorage(r.read<String>('type'));
        final free = r.read<int>('free') == 1;
        return LedgerCandidate(
          id: r.read<int>('id'),
          type: type,
          amountMinor: r.read<int>('amount_minor'),
          accountId: r.read<int>('account_id'),
          toAccountId: r.readNullable<int>('to_account_id'),
          date: DateTime.fromMillisecondsSinceEpoch(r.read<int>('date')),
          title: r.readNullable<String>('title'),
          references: r.read<String>('refs'),
          free: free,
          transferable:
              free &&
              type != TransactionType.transfer &&
              r.read<String>('currency') == 'INR' &&
              r.read<int>('digits') == 2,
        );
      }(),
  ];
}
