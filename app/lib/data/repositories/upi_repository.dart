import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/transaction.dart';
import '../../domain/upi_payment.dart';
import '../db/app_database.dart';
import 'transaction_repository.dart';
import 'upi_sms_match.dart';

/// Device-local drafts. They never affect balances or sync as paid expenses.
class UpiRepository {
  UpiRepository(this.database);
  final AppDatabase database;

  Future<List<PendingUpiPayment>> load() async =>
      (await database
              .customSelect(
                'SELECT payload FROM pending_upi_payments ORDER BY rowid DESC',
              )
              .get())
          .map(
            (row) => PendingUpiPayment.fromJson(
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
            ),
          )
          .toList();

  /// Match the stable UPI address, never a potentially shared display name.
  /// [title] is the custom title (if any) saved on the latest matching
  /// payment \u2014 never the merchant name, which lives in the note instead.
  Future<({int? categoryId, int? accountId, String? title})> remembered(
    UpiRecipient recipient,
  ) async {
    final row = await database
        .customSelect(
          "SELECT category_id, account_id, title FROM transactions WHERE type = 'expense' AND (lower(note) = lower(?) OR lower(substr(note, 1, instr(note, char(10)) - 1)) = lower(?)) ORDER BY created_at DESC, id DESC LIMIT 1",
          variables: [
            Variable(
              'UPI \u2022 ${recipient.address} \u2022 Payment confirmed by you',
            ),
            Variable(
              'UPI \u2022 ${recipient.address} \u2022 Payment confirmed by you',
            ),
          ],
        )
        .getSingleOrNull();
    return (
      categoryId: row?.readNullable<int>('category_id'),
      accountId: row?.readNullable<int>('account_id'),
      title: row?.readNullable<String>('title'),
    );
  }

  Future<void> put(PendingUpiPayment payment) => database.transaction(() async {
    final previous = await database
        .customSelect(
          'SELECT payload FROM pending_upi_payments WHERE id = ?',
          variables: [Variable(payment.id)],
        )
        .getSingleOrNull();
    final savedPlace = previous == null
        ? null
        : (jsonDecode(previous.read<String>('payload'))
                  as Map<String, dynamic>)['place']
              as String?;
    final merged = payment.copyWith(place: payment.place ?? savedPlace);
    await database.customStatement(
      'INSERT INTO pending_upi_payments (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload',
      [payment.id, jsonEncode(merged.toJson())],
    );
  });

  /// Patch only a still-pending row. A late geocoder response must never
  /// recreate a draft after it was saved or deleted, or overwrite edited data.
  Future<void> attachPlace(String id, String place) =>
      database.transaction(() async {
        final row = await database
            .customSelect(
              'SELECT payload FROM pending_upi_payments WHERE id = ?',
              variables: [Variable(id)],
            )
            .getSingleOrNull();
        if (row == null) return;
        final payment = PendingUpiPayment.fromJson(
          jsonDecode(row.read<String>('payload')),
        );
        await database.customStatement(
          'UPDATE pending_upi_payments SET payload = ? WHERE id = ?',
          [jsonEncode(payment.copyWith(place: place).toJson()), id],
        );
      });

  Future<void> delete(String id) => database.customStatement(
    'DELETE FROM pending_upi_payments WHERE id = ?',
    [id],
  );

  /// Consuming the draft and posting the expense share one commit. Retrying
  /// after a crash or double tap cannot record the same payment twice.
  ///
  /// True when the bank's SMS for this payment had already arrived: the
  /// expense it saved takes this payment's details instead of a second one
  /// being added, or the SMS waiting for review joins the new expense.
  Future<bool> confirm(
    String id, {
    PendingUpiPayment? details,
  }) => database.transaction(() async {
    final row = await database
        .customSelect(
          'SELECT payload FROM pending_upi_payments WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return false;
    final stored = PendingUpiPayment.fromJson(
      jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
    );
    final payment = (details ?? stored).copyWith(
      place: details?.place ?? stored.place,
    );
    if (upiAmountMinor(payment.amountText) == null ||
        payment.accountId == null ||
        (!payment.isTransfer && payment.categoryId == null)) {
      throw StateError('Complete the payment details first.');
    }
    final account = await database
        .customSelect(
          // Archived accounts excluded: a UPI draft can outlive the account it
          // was written against, and a payment must not land in a retired one.
          '''SELECT id FROM accounts
             WHERE id = ? AND currency = 'INR' AND digits = 2
               AND archived_at IS NULL''',
          variables: [Variable(payment.accountId)],
        )
        .getSingleOrNull();
    if (payment.isTransfer) {
      final destination = await database
          .customSelect(
            "SELECT id FROM accounts WHERE id = ? AND currency = 'INR' AND digits = 2 AND archived_at IS NULL",
            variables: [Variable(payment.toAccountId)],
          )
          .getSingleOrNull();
      if (account == null ||
          destination == null ||
          payment.accountId == payment.toAccountId) {
        throw StateError('Choose two different existing INR accounts.');
      }
      await TransactionRepository(database).addTransfer(
        amountMinor: upiAmountMinor(payment.amountText)!,
        fromAccountId: payment.accountId!,
        toAccountId: payment.toAccountId!,
        date: payment.date,
        note: [
          'UPI • ${payment.recipient.address} • Payment confirmed by you',
          if (payment.recipient.name != payment.recipient.address)
            payment.recipient.name,
          if (payment.place != null) 'Near ${payment.place}',
          if (payment.title?.trim().isNotEmpty == true) payment.title!.trim(),
          if (payment.note?.trim().isNotEmpty == true) payment.note!.trim(),
        ].join('\n'),
      );
      await delete(id);
      return false;
    }
    final category = await database
        .customSelect(
          "SELECT id FROM categories WHERE id = ? AND type = 'expense'",
          variables: [Variable(payment.categoryId)],
        )
        .getSingleOrNull();
    if (account == null || category == null) {
      throw StateError('Choose an existing INR account and expense category.');
    }
    final recipient = payment.recipient;
    // A display name distinct from the address is worth keeping, in the
    // note; when the QR carried no name, it's already the address above.
    final merchantLine = recipient.name == recipient.address
        ? ''
        : '\n${recipient.name}';
    final note =
        'UPI • ${recipient.address} • Payment confirmed by you$merchantLine'
        '${payment.place == null ? '' : '\nNear ${payment.place}'}'
        '${payment.note == null || payment.note!.trim().isEmpty ? '' : '\n${payment.note!.trim()}'}';
    final amountMinor = upiAmountMinor(payment.amountText)!;
    final ledger = TransactionRepository(database);
    final saved = await smsExpenseForUpiPayment(
      database,
      accountId: payment.accountId!,
      amountMinor: amountMinor,
      date: payment.date,
    );
    if (saved != null) {
      // The UPI line stays first, where [remembered] looks for it. The
      // SMS's own date and amount stay, so its notification still applies.
      await ledger.updateExpenseOrIncome(
        id: saved.id,
        type: TransactionType.expense,
        amountMinor: amountMinor,
        accountId: payment.accountId!,
        categoryId: payment.categoryId!,
        title: payment.title ?? saved.title,
        note: saved.note == null ? note : '$note\n\n${saved.note}',
        date: saved.date,
      );
      await delete(id);
      return true;
    }
    final transactionId = await ledger.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: amountMinor,
      accountId: payment.accountId!,
      categoryId: payment.categoryId!,
      title: payment.title,
      date: payment.date,
      note: note,
    );
    await delete(id);
    return joinPendingSmsToUpiExpense(
      database,
      transactionId: transactionId,
      accountId: payment.accountId!,
      amountMinor: amountMinor,
      date: payment.date,
    );
  });
}
