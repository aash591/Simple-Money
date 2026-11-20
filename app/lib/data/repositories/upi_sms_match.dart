/// A payment made from the UPI scan flow and the bank SMS for it are one
/// payment, whichever reaches the app first: the SMS joins the confirmed
/// expense, or confirming joins the expense the SMS already saved. Only
/// expenses are matched; a UPI transfer between own accounts is not.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/upi_payment.dart';
import '../db/app_database.dart';
import 'sms_import_repository.dart';

/// How every expense confirmed in the UPI flow begins its note.
const upiConfirmedNotePattern = 'UPI • % • Payment confirmed by you%';

/// The UPI scan still waiting to be saved that bank message [sms] reports:
/// an expense draft of its amount, started shortly before it arrived.
Future<PendingUpiPayment?> pendingUpiForSms(
  AppDatabase db,
  PendingSmsImport sms,
) async {
  if (!_canBeUpiPayment(sms)) return null;
  final at = sms.receivedAt;
  PendingUpiPayment? best;
  for (final row
      in await db
          .customSelect('SELECT payload FROM pending_upi_payments')
          .get()) {
    final payment = PendingUpiPayment.fromJson(
      jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
    );
    final amount = upiAmountMinor(
      payment.amountText.isEmpty
          ? payment.recipient.amount
          : payment.amountText,
    );
    if (payment.isTransfer ||
        amount != sms.amountMinor ||
        at.isBefore(payment.date.subtract(_smsBefore)) ||
        at.isAfter(payment.date.add(_smsAfter))) {
      continue;
    }
    if (best == null ||
        at.difference(payment.date).abs() < at.difference(best.date).abs()) {
      best = payment;
    }
  }
  return best;
}

/// The UPI expense bank message [fingerprint] was joined to, when it arrived
/// after the payment was already saved in the scan flow.
Future<({String payee, int amountMinor, String? category})?> upiExpenseJoinedBy(
  AppDatabase db,
  String fingerprint,
) async {
  final row = await db
      .customSelect(
        '''SELECT t.amount_minor, t.title, t.note, c.name AS category
        FROM sms_imports i JOIN transactions t ON t.id = i.transaction_id
        LEFT JOIN categories c ON c.id = t.category_id
        WHERE i.fingerprint = ? AND i.status = 'imported' AND t.note LIKE ?''',
        variables: [Variable(fingerprint), Variable(upiConfirmedNotePattern)],
      )
      .getSingleOrNull();
  if (row == null) return null;
  // "UPI • shop@bank • Payment confirmed by you", then the payee's name.
  final lines = (row.read<String>('note')).split('\n');
  final address = lines.first.split(' • ').elementAtOrNull(1) ?? '';
  final title = row.readNullable<String>('title')?.trim();
  final named = lines.length > 1 && !lines[1].startsWith('Near ')
      ? lines[1].trim()
      : '';
  return (
    payee: title?.isNotEmpty == true
        ? title!
        : named.isNotEmpty
        ? named
        : address,
    amountMinor: row.read<int>('amount_minor'),
    category: row.readNullable<String>('category'),
  );
}

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

/// The confirmed UPI expense (or transfer, paid from the account) [sms]
/// reports, nearest in time, not yet joined by another SMS.
Future<int?> _upiExpenseFor(
  AppDatabase db,
  PendingSmsImport sms, {
  int? accountId,
}) async {
  final at = sms.receivedAt.millisecondsSinceEpoch;
  final row = await db
      .customSelect(
        '''SELECT t.id FROM transactions t JOIN accounts a ON a.id=t.account_id
        WHERE t.type IN ('expense','transfer') AND t.amount_minor=?
          AND a.currency='INR'
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
/// started at [date], not yet joined by a UPI payment. One in [accountId]
/// comes first; failing that, one in any INR account (the payment was
/// moved to another account while saving it).
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
        JOIN accounts a ON a.id=t.account_id
        WHERE t.type='expense' AND a.currency='INR' AND t.amount_minor=?
          AND i.received_at BETWEEN ? AND ?
          AND coalesce(t.note,'') NOT LIKE ?
        ORDER BY t.account_id<>?, abs(i.received_at-?), t.id LIMIT 1''',
        variables: [
          Variable(amountMinor),
          Variable(at - _smsBefore.inMilliseconds),
          Variable(at + _smsAfter.inMilliseconds),
          Variable(upiConfirmedNotePattern),
          Variable(accountId),
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

/// What [upiPaymentSms] found: the account (and, once the SMS saved an
/// expense, the category) it reports, and the message itself.
typedef UpiPaymentSms = ({
  int? accountId,
  int? categoryId,
  bool saved,
  String sender,
  String text,
});

/// The bank SMS for a UPI payment of [amountMinor] started at [date], if it
/// has arrived: the expense it already saved (with that expense's account and
/// category), or an SMS still waiting for review (with its linked account,
/// if any). Null while no such SMS has come.
Future<UpiPaymentSms?> upiPaymentSms(
  AppDatabase db, {
  required int amountMinor,
  required DateTime date,
}) async {
  final at = date.millisecondsSinceEpoch;
  final saved = await db
      .customSelect(
        '''SELECT t.account_id, t.category_id, t.note, i.sender FROM transactions t
        JOIN sms_imports i ON i.transaction_id=t.id
        JOIN accounts a ON a.id=t.account_id
        WHERE t.type='expense' AND t.amount_minor=? AND a.currency='INR'
          AND a.digits=2 AND a.archived_at IS NULL
          AND i.received_at BETWEEN ? AND ?
          AND coalesce(t.note,'') NOT LIKE ?
        ORDER BY abs(i.received_at-?), t.id LIMIT 1''',
        variables: [
          Variable(amountMinor),
          Variable(at - _smsBefore.inMilliseconds),
          Variable(at + _smsAfter.inMilliseconds),
          Variable(upiConfirmedNotePattern),
          Variable(at),
        ],
      )
      .getSingleOrNull();
  if (saved != null) {
    return (
      accountId: saved.read<int>('account_id'),
      categoryId: saved.readNullable<int>('category_id'),
      saved: true,
      sender: saved.read<String>('sender'),
      text: _smsText(saved.readNullable<String>('note')),
    );
  }
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
    final usable = linked == null
        ? null
        : await db
              .customSelect(
                "SELECT id FROM accounts WHERE id=? AND currency='INR' AND digits=2 AND archived_at IS NULL",
                variables: [Variable(linked)],
              )
              .getSingleOrNull();
    return (
      accountId: usable?.read<int>('id'),
      categoryId: null,
      saved: false,
      sender: sms.sender,
      text: sms.body,
    );
  }
  return null;
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
  // The SMS from the payment's own bank first; failing that, one linked to
  // another account (the payment was moved to another account while saving
  // it). That account's reported balance isn't this payment's to correct.
  PendingSmsImport? other;
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
    if (linked != null && linked != accountId) {
      other ??= sms;
      continue;
    }
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
  if (other == null) return false;
  await db.customStatement(
    "UPDATE sms_imports SET status='imported',body=NULL,transaction_id=? WHERE fingerprint=?",
    [transactionId, other.id],
  );
  return true;
}

/// The message an SMS expense's note keeps, without the "Sender:" line it
/// starts with (see [PendingSmsImport.originalSmsNote]).
String _smsText(String? note) {
  if (note == null) return '';
  if (!note.startsWith('Sender: ')) return note;
  final split = note.indexOf('\n\n');
  return split < 0 ? '' : note.substring(split + 2);
}
