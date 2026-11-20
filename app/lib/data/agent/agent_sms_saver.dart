import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/transaction.dart';
import '../db/app_database.dart';
import '../repositories/sms_import_repository.dart';
import '../repositories/transaction_repository.dart';

/// A bank message no rule reads. [ref] is the short id the AI app sees,
/// [id] the message's import fingerprint.
typedef LoanSms = ({
  String ref,
  String id,
  String sender,
  String body,
  DateTime receivedAt,
});

/// An unread message as a suggestion's payload keeps it, to save on approval.
Map<String, Object?> unreadSmsPayload(LoanSms sms) => {
  'id': sms.id,
  'sender': sms.sender,
  'body': sms.body,
  'receivedAt': sms.receivedAt.toIso8601String(),
};

/// Saves bank messages a suggestion claimed, when it's approved: one waiting
/// in SMS review leaves the queue as a transaction, and one no rule reads is
/// recorded and marked imported. Either way nothing is left behind to ask
/// about again, and nothing is counted twice.
class AgentSmsSaver {
  AgentSmsSaver(this.database);
  final AppDatabase database;

  /// The transaction message [id], waiting for review, becomes, saved into
  /// [accountId] under [categoryId]. The one it already became when it was
  /// saved since; null when it was dismissed or deleted.
  Future<int?> saveWaiting(
    String id, {
    required int accountId,
    required int categoryId,
    TransactionType type = TransactionType.expense,
    String? title,
  }) async {
    final row = await database
        .customSelect(
          '''SELECT sender, body, received_at, candidate, status, transaction_id
          FROM sms_imports WHERE fingerprint = ?''',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    if (row.read<String>('status') != 'pending') {
      return row.readNullable<int>('transaction_id');
    }
    final sms = PendingSmsImport(
      id: id,
      sender: row.read<String>('sender'),
      body: row.readNullable<String>('body') ?? '',
      data: Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      ),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('received_at'),
      ),
    );
    final imports = SmsImportRepository(database);
    await imports.save(
      sms,
      type: type,
      amountMinor: sms.amountMinor,
      accountId: accountId,
      categoryId: categoryId,
      title: title ?? sms.title,
      date: sms.receivedAt,
    );
    return imports.transactionOf(id);
  }

  /// The transaction an unread message ([unreadSmsPayload]) becomes: of
  /// [amountMinor] into or out of [accountId]. It is marked imported, so a
  /// rule taught later doesn't read it in again. A balance the bank reported
  /// after it already counted this money, so that is undone once.
  Future<int> saveUnread(
    Map sms, {
    required int accountId,
    required int amountMinor,
    required int categoryId,
    required String title,
    required String currency,
    TransactionType type = TransactionType.expense,
    String ruleId = 'agent',
  }) async {
    final id = sms['id'] as String;
    final row = await database
        .customSelect(
          'SELECT status, transaction_id FROM sms_imports WHERE fingerprint = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row != null) {
      // A rule taught since the suggestion read it in after all.
      if (row.read<String>('status') == 'pending') {
        final saved = await saveWaiting(
          id,
          accountId: accountId,
          categoryId: categoryId,
          type: type,
          title: title,
        );
        if (saved != null) return saved;
      } else if (row.readNullable<int>('transaction_id') case final saved?) {
        return saved;
      }
    }
    final sender = sms['sender'] as String;
    final receivedAt = DateTime.parse(sms['receivedAt'] as String);
    final transactionId = await TransactionRepository(database)
        .addExpenseOrIncome(
          type: type,
          amountMinor: amountMinor,
          accountId: accountId,
          categoryId: categoryId,
          title: title,
          date: receivedAt,
          note: 'Sender: $sender\n\n${sms['body']}',
        );
    final credit = type == TransactionType.income;
    await database.customStatement(
      '''INSERT OR REPLACE INTO sms_imports (fingerprint, sender, body,
        received_at, candidate, rule_id, pack_version, status, transaction_id)
      VALUES (?, ?, NULL, ?, ?, ?, 0, 'imported', ?)''',
      [
        id,
        sender,
        receivedAt.millisecondsSinceEpoch,
        jsonEncode({
          'amountMinor': amountMinor,
          'currencyCode': currency,
          'direction': credit ? 'credit' : 'debit',
        }),
        ruleId,
        transactionId,
      ],
    );
    await database.customStatement(
      'UPDATE accounts SET balance_minor = balance_minor + ? '
      'WHERE id = ? AND balance_reported_at >= ?',
      [
        credit ? -amountMinor : amountMinor,
        accountId,
        receivedAt.millisecondsSinceEpoch,
      ],
    );
    return transactionId;
  }
}
