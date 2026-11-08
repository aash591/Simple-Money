/// What every statement import does once its rows are read, whatever the
/// file was — a UPI app's or a bank's PDF, a CSV or an Excel export: join
/// the two legs of a transfer between the user's own accounts, and hold each
/// row against the ledger to find the ones already recorded and the ones
/// that complete a transfer recorded only on one side. SMS import shares the
/// last step: two banks' SMS of one transfer become that transfer.
library;

import '../../domain/transaction.dart';
import '../ledger_match.dart';
import 'upi_statement.dart';

export '../ledger_match.dart' show LedgerCandidate, nearlySameTime;

/// Where a statement row's money moved in the ledger: the account it left
/// or reached, and a self transfer's destination.
typedef StatementRowAccounts = ({int? account, int? toAccount});

/// How a statement row stands against the ledger.
class StatementMatch {
  /// The row is ledger transaction [transactionId] already.
  const StatementMatch.recorded(this.transactionId)
    : fromAccountId = null,
      toAccountId = null,
      otherLegId = null;

  /// The row is the missing leg of ledger expense or income
  /// [transactionId]: together they are a transfer between two of the
  /// user's accounts, which that transaction becomes.
  const StatementMatch.transfer(
    this.transactionId, {
    required int this.fromAccountId,
    required int this.toAccountId,
    this.otherLegId,
  });

  final int transactionId;
  final int? fromAccountId, toAccountId;

  /// A self transfer's other leg when the ledger recorded both separately —
  /// an expense on one account and an income on the other. The transfer
  /// replaces it.
  final int? otherLegId;

  bool get completesTransfer => fromAccountId != null;
}

/// The UPI references (12-digit RRNs) [text] quotes: an SMS's "UPI Ref
/// 629920840430", an imported row's "UPI ref: …".
Set<String> upiReferencesIn(String text) => {
  for (final match in RegExp(r'(?<!\d)\d{12}(?!\d)').allMatches(text))
    match[0]!,
};

/// The expense–income pairs in [ledger] that are each one transfer between
/// two of the user's accounts, recorded a leg at a time — as when each bank
/// sends its own SMS: the same amount out of one account and into another,
/// days apart at most, both quoting the same UPI reference, as both banks
/// do for one transfer.
List<({LedgerCandidate out, LedgerCandidate into})> recordedTransferLegs(
  List<LedgerCandidate> ledger,
) {
  final receipts = [
    for (final t in ledger)
      if (t.transferable && t.type == TransactionType.income)
        (t, upiReferencesIn(t.references)),
  ];
  final pairs = <({LedgerCandidate out, LedgerCandidate into})>[];
  final used = <int>{};
  for (final out in ledger) {
    if (!out.transferable || out.type != TransactionType.expense) continue;
    final references = upiReferencesIn(out.references);
    if (references.isEmpty) continue;
    for (final (into, quoted) in receipts) {
      if (used.contains(into.id) ||
          into.accountId == out.accountId ||
          into.amountMinor != out.amountMinor ||
          into.date.difference(out.date).abs() > const Duration(days: 3) ||
          !quoted.any(references.contains)) {
        continue;
      }
      used.add(into.id);
      pairs.add((out: out, into: into));
      break;
    }
  }
  return pairs;
}

/// Turns money paid to or received from the statement's [owner] — the
/// user's own name or UPI id, as when a bank's narration reads
/// "UPI/ASHIQUE M/UBIN/…" — into a self transfer. The other side is the
/// user's account at the bank the narration names, or one to choose.
List<UpiStatementRow> markOwnTransfers(
  List<UpiStatementRow> rows,
  StatementOwner owner,
) {
  if (owner.isEmpty) return rows;
  return [
    for (final row in rows)
      if (row.direction == UpiStatementDirection.selfTransfer ||
          !owner.matches(row.counterparty, id: row.counterpartyId))
        row
      else
        _ownTransfer(
          row,
          StatementAccount(bank: row.counterpartyBank, digits: ''),
        ),
  ];
}

UpiStatementRow _ownTransfer(UpiStatementRow row, StatementAccount other) =>
    row.direction == UpiStatementDirection.debit
    ? row.copyWith(
        direction: UpiStatementDirection.selfTransfer,
        counterparty: 'Self transfer',
        toAccount: other,
      )
    : UpiStatementRow(
        date: row.date,
        direction: UpiStatementDirection.selfTransfer,
        amountMinor: row.amountMinor,
        counterparty: 'Self transfer',
        reference: row.reference,
        account: other,
        toAccount: row.account,
        counterpartyBank: row.counterpartyBank,
        counterpartyId: row.counterpartyId,
        narration: row.narration,
      );

/// Turns cash taken out at an ATM, or paid in at one, into a transfer
/// between the account and the user's cash ([StatementAccount.cash]) —
/// [atm] says which rows are: true for a withdrawal or deposit.
List<UpiStatementRow> markCashMovements(
  List<UpiStatementRow> rows,
  bool Function(UpiStatementRow row) atm,
) => [
  for (final row in rows)
    if (row.direction == UpiStatementDirection.selfTransfer || !atm(row))
      row
    else
      _ownTransfer(row, StatementAccount.cash),
];

/// The account money arrives in: a receipt's own, a self transfer's
/// destination.
StatementAccount? _into(UpiStatementRow row) => switch (row.direction) {
  UpiStatementDirection.credit => row.account,
  UpiStatementDirection.selfTransfer => row.toAccount,
  UpiStatementDirection.debit => null,
};

/// The same account, or one named only by its bank and that bank's.
bool _sameAccount(StatementAccount a, StatementAccount b) =>
    a == b ||
    ((a.digits.isEmpty || b.digits.isEmpty) &&
        a.bank != null &&
        b.bank != null &&
        StatementAccount(bank: a.bank, digits: '') ==
            StatementAccount(bank: b.bank, digits: ''));

/// Joins the two legs of a transfer between the user's own accounts that a
/// statement lists separately — a bank export covering several accounts, or
/// a UPI app with more than one bank linked — into one self transfer.
///
/// Only firm evidence joins them, since paying someone ₹116.82 and being
/// paid ₹116.82 minutes later happens: the same UPI reference on both legs,
/// which both banks quote; or a self transfer and a receipt of its amount
/// into the very account it names, minutes apart.
List<UpiStatementRow> pairTransferLegs(List<UpiStatementRow> rows) {
  final result = [...rows];
  final absorbed = <int>{};
  for (var i = 0; i < rows.length; i++) {
    final out = rows[i];
    final from = out.account;
    // A payment out of a named account; not a receipt from the user's own
    // name, which leaves an account the statement doesn't number.
    if (out.direction == UpiStatementDirection.credit ||
        from == null ||
        from.digits.isEmpty ||
        absorbed.contains(i)) {
      continue;
    }
    for (var j = 0; j < rows.length; j++) {
      final into = rows[j];
      final to = _into(into);
      final receipt =
          into.direction == UpiStatementDirection.credit ||
          (into.direction == UpiStatementDirection.selfTransfer &&
              (into.account?.digits.isEmpty ?? true));
      if (j == i ||
          !receipt ||
          absorbed.contains(j) ||
          into.amountMinor != out.amountMinor ||
          to == null ||
          to.digits.isEmpty ||
          _sameAccount(to, from)) {
        continue;
      }
      final sameReference =
          out.reference != null && out.reference == into.reference;
      final named =
          out.direction == UpiStatementDirection.selfTransfer &&
          out.toAccount != null &&
          _sameAccount(out.toAccount!, to) &&
          into.date.difference(out.date).abs() <= const Duration(minutes: 15);
      if (!sameReference && !named) continue;
      absorbed.add(j);
      result[i] = out.copyWith(
        direction: UpiStatementDirection.selfTransfer,
        counterparty: 'Self transfer',
        reference: out.reference ?? into.reference,
        toAccount: to,
      );
      break;
    }
  }
  return [
    for (var i = 0; i < result.length; i++)
      if (!absorbed.contains(i)) result[i],
  ];
}

/// Pairs each statement row with what it is in the ledger, or null when
/// it's new. Each ledger transaction absorbs at most one row, and the
/// strongest evidence goes first:
///
/// 1. The UPI reference. Both banks quote the same one for a transfer, so
///    a reference shared with an expense on another of the user's accounts
///    means this row is that transfer's other leg, not a duplicate.
/// 2. The same amount, way and account at nearly the same time, nearest
///    first.
/// 3. A self transfer the ledger has only one leg of — or both, recorded
///    separately as an expense and an income.
///
/// Rows in [keepSeparate] never complete a transfer: the user said that
/// receipt or payment isn't one.
List<StatementMatch?> matchStatementRows(
  List<UpiStatementRow> rows,
  List<LedgerCandidate> ledger,
  StatementRowAccounts Function(UpiStatementRow row) accountsFor, {
  Set<int> keepSeparate = const {},
}) {
  final matches = List<StatementMatch?>.filled(rows.length, null);
  final claimed = <int>{};

  LedgerCandidate? nearest(
    UpiStatementRow row,
    bool Function(LedgerCandidate) fits,
  ) => closestInLedger(
    ledger,
    amountMinor: row.amountMinor,
    date: row.date,
    claimed: claimed,
    fits: fits,
  );

  bool leg(LedgerCandidate t, TransactionType type, int account) =>
      t.transferable && t.type == type && t.accountId == account;

  /// The transfer a self transfer's row completes from ledger leg [t], with
  /// the other leg when the ledger has that too.
  StatementMatch selfTransfer(
    LedgerCandidate t,
    UpiStatementRow row,
    int from,
    int to,
  ) {
    claimed.add(t.id);
    bool otherLeg(LedgerCandidate o) => t.type == TransactionType.expense
        ? leg(o, TransactionType.income, to)
        : leg(o, TransactionType.expense, from);
    // Both banks quote the transfer's reference, so the leg that does is
    // the one, whichever ₹10 that day is nearer; one quoting another is
    // another transfer's.
    final reference = row.reference;
    final other = reference == null || reference.length < 8
        ? nearest(row, otherLeg)
        : nearest(
                row,
                (o) => otherLeg(o) && o.references.contains(reference),
              ) ??
              nearest(
                row,
                (o) => otherLeg(o) && upiReferencesIn(o.references).isEmpty,
              );
    if (other != null) claimed.add(other.id);
    // Keep the payment's leg; the receipt's is the one that goes.
    final (kept, gone) = t.type == TransactionType.expense || other == null
        ? (t, other)
        : (other, t);
    return StatementMatch.transfer(
      kept.id,
      fromAccountId: from,
      toAccountId: to,
      otherLegId: gone?.id,
    );
  }

  /// What [row] and ledger [t], sharing a reference, are together.
  StatementMatch byReference(int i, LedgerCandidate t) {
    final row = rows[i];
    final (:account, :toAccount) = accountsFor(row);
    if (!t.transferable || account == null || keepSeparate.contains(i)) {
      return StatementMatch.recorded(t.id);
    }
    return switch (row.direction) {
      UpiStatementDirection.credit
          when t.type == TransactionType.expense && t.accountId != account =>
        StatementMatch.transfer(
          t.id,
          fromAccountId: t.accountId,
          toAccountId: account,
        ),
      UpiStatementDirection.debit
          when t.type == TransactionType.income && t.accountId != account =>
        StatementMatch.transfer(
          t.id,
          fromAccountId: account,
          toAccountId: t.accountId,
        ),
      UpiStatementDirection.selfTransfer
          when toAccount != null &&
              toAccount != account &&
              (leg(t, TransactionType.expense, account) ||
                  leg(t, TransactionType.income, toAccount)) =>
        selfTransfer(t, row, account, toAccount),
      _ => StatementMatch.recorded(t.id),
    };
  }

  for (var i = 0; i < rows.length; i++) {
    final reference = rows[i].reference;
    if (reference == null || reference.length < 8) continue;
    final match = ledger
        .where(
          (t) => !claimed.contains(t.id) && t.references.contains(reference),
        )
        .firstOrNull;
    if (match == null) continue;
    claimed.add(match.id);
    matches[i] = byReference(i, match);
  }
  for (var i = 0; i < rows.length; i++) {
    if (matches[i] != null) continue;
    final row = rows[i];
    final accounts = accountsFor(row);
    final match = nearest(
      row,
      (t) => _sameMovement(t, row.direction, accounts),
    );
    if (match == null) continue;
    claimed.add(match.id);
    matches[i] = StatementMatch.recorded(match.id);
  }
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (matches[i] != null ||
        row.direction != UpiStatementDirection.selfTransfer) {
      continue;
    }
    final (:account, :toAccount) = accountsFor(row);
    if (account == null || toAccount == null || toAccount == account) {
      continue;
    }
    final t =
        nearest(row, (t) => leg(t, TransactionType.expense, account)) ??
        nearest(row, (t) => leg(t, TransactionType.income, toAccount));
    if (t == null) continue;
    matches[i] = selfTransfer(t, row, account, toAccount);
  }
  return matches;
}

bool _sameMovement(
  LedgerCandidate t,
  UpiStatementDirection direction,
  StatementRowAccounts accounts,
) {
  bool from(int id) => accounts.account == null || accounts.account == id;
  bool to(int id) => accounts.toAccount == null || accounts.toAccount == id;
  return switch (direction) {
    UpiStatementDirection.debit =>
      (t.type == TransactionType.expense ||
              t.type == TransactionType.transfer) &&
          from(t.accountId),
    UpiStatementDirection.credit =>
      (t.type == TransactionType.income && from(t.accountId)) ||
          (t.type == TransactionType.transfer && from(t.toAccountId ?? -1)),
    // A transfer already; one recorded as a single leg completes it later.
    UpiStatementDirection.selfTransfer =>
      t.type == TransactionType.transfer &&
          from(t.accountId) &&
          to(t.toAccountId ?? -1),
  };
}
