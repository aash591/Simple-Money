/// A payment made from the UPI scan flow and the bank SMS for it are one
/// payment, whichever reaches the app first: the SMS joins the confirmed
/// expense, or confirming joins the expense the SMS already saved. Only
/// expenses are matched; a UPI transfer between own accounts is not.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import 'sms_import_repository.dart';

/// How every expense confirmed in the UPI flow begins its note.
const upiConfirmedNotePattern = 'UPI • % • Payment confirmed by you%';

/// The bank SMS comes after the draft was handed to Google Pay: a little
/// earlier allows for clock rounding, an hour later for a slow bank. Wider
/// would join the same ₹20 paid again later in the day.
const _smsBefore = Duration(minutes: 5);
const _smsAfter = Duration(hours: 1);

/// The account an SMS's bank is linked to, if any. Unlinked, the account the
/// user chose for the UPI payment is taken as the SMS's.
Future<int?> _linkedAccount(AppDatabase db, PendingSmsImport sms) async {
  if (sms.data['assignedAccountId'] case final int id) return id;
  final imports = SmsImportRepository(db);
  final resolved = resolveSmsAccount(sms, await imports.detectedAccounts());
  return (await imports.accountLinks())[resolved.bankKey];
}

bool _canBeUpiPayment(PendingSmsImport sms) =>
    !sms.credit && sms.currency == 'INR' && !sms.requiresTransfer;

/// The confirmed UPI expense [sms] reports, nearest in time, not yet joined
/// by another SMS.
Future<int?> _upiExpenseFor(
  AppDatabase db,
  PendingSmsImport sms, {
  int? accountId,
}) async {
  final at = sms.receivedAt.millisecondsSinceEpoch;
  final row = await db
      .customSelect(
        '''SELECT t.id FROM transactions t JOIN accounts a ON a.id=t.account_id
        WHERE t.type='expense' AND t.amount_minor=? AND a.currency='INR'
          AND t.note LIKE ? AND t.date BETWEEN ? AND ?
          AND (? IS NULL OR t.account_id=?)
          AND NOT EXISTS (SELECT 1 FROM sms_imports i WHERE i.transaction_id=t.id)
        ORDER BY abs(t.date-?), t.id LIMIT 1''',
        variables: [
          Variable(sms.amountMinor),
          Variable(upiConfirmedNotePattern),
          Variable(at - _smsAfter.inMilliseconds),
          Variable(at + _smsBefore.inMilliseconds),
          Variable(accountId),
          Variable(accountId),
          Variable(at),
        ],
      )
      .getSingleOrNull();
  return row?.read<int>('id');
}

/// Joins a newly queued SMS to the UPI expense it reports, so it is not
/// offered for review or saved a second time. True when joined.
Future<bool> joinSmsToUpiPayment(AppDatabase db, String fingerprint) async {
  final row = await db
      .customSelect(
        "SELECT * FROM sms_imports WHERE fingerprint=? AND status='pending'",
        variables: [Variable(fingerprint)],
      )
      .getSingleOrNull();
  if (row == null) return false;
  final sms = PendingSmsImport(
    id: fingerprint,
    sender: row.read<String>('sender'),
    body: row.readNullable<String>('body') ?? '',
    receivedAt: DateTime.fromMillisecondsSinceEpoch(
      row.read<int>('received_at'),
    ),
    data: Map<String, dynamic>.from(
      jsonDecode(row.read<String>('candidate')) as Map,
    ),
  );
  if (!_canBeUpiPayment(sms)) return false;
  // Most messages are no UPI payment at all: look before resolving the bank.
  if (await _upiExpenseFor(db, sms) == null) return false;
  final transactionId = await _upiExpenseFor(
    db,
    sms,
    accountId: await _linkedAccount(db, sms),
  );
  if (transactionId == null) return false;
  await db.customStatement(
    "UPDATE sms_imports SET status='imported',body=NULL,transaction_id=? WHERE fingerprint=? AND status='pending'",
    [transactionId, fingerprint],
  );
  return true;
}

/// The expense a bank SMS already saved for a UPI payment of [amountMinor]
/// from [accountId] started at [date], not yet joined by a UPI payment.
Future<({int id, String? title, String? note, DateTime date})?>
smsExpenseForUpiPayment(
  AppDatabase db, {
  required int accountId,
  required int amountMinor,
  required DateTime date,
}) async {
  final at = date.millisecondsSinceEpoch;
  final row = await db
      .customSelect(
        '''SELECT t.id, t.title, t.note, t.date FROM transactions t
        JOIN sms_imports i ON i.transaction_id=t.id
        WHERE t.type='expense' AND t.account_id=? AND t.amount_minor=?
          AND i.received_at BETWEEN ? AND ?
          AND coalesce(t.note,'') NOT LIKE ?
        ORDER BY abs(i.received_at-?), t.id LIMIT 1''',
        variables: [
          Variable(accountId),
          Variable(amountMinor),
          Variable(at - _smsBefore.inMilliseconds),
          Variable(at + _smsAfter.inMilliseconds),
          Variable(upiConfirmedNotePattern),
          Variable(at),
        ],
      )
      .getSingleOrNull();
  if (row == null) return null;
  return (
    id: row.read<int>('id'),
    title: row.readNullable<String>('title'),
    note: row.readNullable<String>('note'),
    date: DateTime.fromMillisecondsSinceEpoch(row.read<int>('date')),
  );
}

/// Joins a bank SMS still waiting for review to the UPI expense
/// [transactionId] just saved. A balance the bank reported in or after that
/// SMS already has this payment taken off, so it is added back once.
Future<bool> joinPendingSmsToUpiExpense(
  AppDatabase db, {
  required int transactionId,
  required int accountId,
  required int amountMinor,
  required DateTime date,
}) async {
  final at = date.millisecondsSinceEpoch;
  final rows = await db
      .customSelect(
        '''SELECT * FROM sms_imports WHERE status='pending'
          AND received_at BETWEEN ? AND ?
          AND json_extract(candidate,'\$.amountMinor')=?
          AND json_extract(candidate,'\$.direction')='debit'
        ORDER BY abs(received_at-?), fingerprint''',
        variables: [
          Variable(at - _smsBefore.inMilliseconds),
          Variable(at + _smsAfter.inMilliseconds),
          Variable(amountMinor),
          Variable(at),
        ],
      )
      .get();
  for (final row in rows) {
    final sms = PendingSmsImport(
      id: row.read<String>('fingerprint'),
      sender: row.read<String>('sender'),
      body: row.readNullable<String>('body') ?? '',
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('received_at'),
      ),
      data: Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      ),
    );
    if (!_canBeUpiPayment(sms)) continue;
    final linked = await _linkedAccount(db, sms);
    if (linked != null && linked != accountId) continue;
    await db.customStatement(
      "UPDATE sms_imports SET status='imported',body=NULL,transaction_id=? WHERE fingerprint=?",
      [transactionId, sms.id],
    );
    await db.customStatement(
      'UPDATE accounts SET balance_minor=balance_minor+? WHERE id=? AND balance_reported_at>=?',
      [amountMinor, accountId, sms.receivedAt.millisecondsSinceEpoch],
    );
    return true;
  }
  return false;
}
