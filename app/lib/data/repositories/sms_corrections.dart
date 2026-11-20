/// What the user (through an approved AI suggestion) says messages of one
/// layout really are, when the bank's wording misleads: "Rs 5,000 credited to
/// your loan a/c XX9876" is the user paying the loan, not income. The
/// correction applies to every message one rule reads from one sender, the
/// ones waiting and the ones still to come.
library;

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../sms_sender_role.dart';
import 'loan_repository.dart';
import 'sms_import_repository.dart';

class SmsCorrection {
  const SmsCorrection({
    required this.sender,
    required this.ruleId,
    this.direction,
    this.loanId,
    this.categoryId,
  });

  /// The canonical sender and the rule that reads the layout.
  final String sender, ruleId;

  /// debit or credit: where the money really went.
  final String? direction;

  /// The loan these messages pay.
  final int? loanId;
  final int? categoryId;
}

class SmsCorrectionRepository {
  SmsCorrectionRepository(this.database);
  final AppDatabase database;

  /// The schema makes it since v47, when corrections started syncing; kept
  /// for databases a test builds by hand.
  Future<void> _table() => database.customStatement(
    'CREATE TABLE IF NOT EXISTS sms_corrections ('
    'sender TEXT NOT NULL, rule_id TEXT NOT NULL, direction TEXT, '
    'loan_id INTEGER, category_id INTEGER, created_at INTEGER NOT NULL, '
    'PRIMARY KEY(sender, rule_id))',
  );

  Future<void> save(SmsCorrection c) async {
    await _table();
    await database.customStatement(
      'INSERT OR REPLACE INTO sms_corrections '
      '(sender,rule_id,direction,loan_id,category_id,created_at) '
      'VALUES (?,?,?,?,?,?)',
      [
        c.sender,
        c.ruleId,
        c.direction,
        c.loanId,
        c.categoryId,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> remove(String sender, String ruleId) async {
    await _table();
    await database.customStatement(
      'DELETE FROM sms_corrections WHERE sender=? AND rule_id=?',
      [sender, ruleId],
    );
  }

  Future<SmsCorrection?> find(String sender, String ruleId) async {
    await _table();
    final r = await database
        .customSelect(
          'SELECT * FROM sms_corrections WHERE sender=? AND rule_id=?',
          variables: [Variable(sender), Variable(ruleId)],
        )
        .getSingleOrNull();
    if (r == null) return null;
    return SmsCorrection(
      sender: sender,
      ruleId: ruleId,
      direction: r.readNullable<String>('direction'),
      loanId: r.readNullable<int>('loan_id'),
      categoryId: r.readNullable<int>('category_id'),
    );
  }

  /// Applies [c] to parsed message [data]. A loan payment goes on the loan's
  /// paying account, under the loan payment category; the account number in
  /// the SMS is the loan's own, so it is kept apart and never becomes an
  /// account. A loan that is closed or in another currency is left out.
  Future<void> apply(Map<String, dynamic> data, SmsCorrection c) async {
    if (c.direction case final String direction) {
      data[correctedDirectionKey] = direction;
    }
    if (c.categoryId case final int category) {
      data['assignedCategoryId'] = category;
    }
    final loanId = c.loanId;
    if (loanId == null) return;
    final loans = LoanRepository(database);
    final loan = (await loans.load()).where((l) => l.id == loanId).firstOrNull;
    if (loan == null ||
        loan.closed ||
        loan.terms.currency != data['currencyCode']) {
      return;
    }
    data[correctedDirectionKey] = 'debit';
    data[assignedLoanKey] = loanId;
    data['assignedCategoryId'] = await loans.paymentCategory();
    if (data.remove('accountLast4') case final String last4) {
      data[otherAccountKey] = last4;
    }
    if (loan.accountId case final int account) {
      data['assignedAccountId'] = account;
    }
    // Waits for the user to pick an account when the loan names none.
    data['ambiguousAccount'] = true;
  }
}
