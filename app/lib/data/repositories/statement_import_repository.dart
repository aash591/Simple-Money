import '../community/community_fixes.dart';

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/account.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import '../ledger_match.dart';
import '../statements/statement_reconciliation.dart';
import '../statements/upi_statement.dart';
import 'transaction_repository.dart';

/// One new statement row the user chose to add.
class StatementImport {
  const StatementImport({
    required this.row,
    required this.accountId,
    this.toAccountId,
    this.categoryId,
    this.type,
    this.title,
  });
  final UpiStatementRow row;
  final int accountId;

  /// The user's corrections from reviewing the row; null keeps what the
  /// statement says.
  final TransactionType? type;
  final String? title;

  TransactionType get kind =>
      type ??
      switch (row.direction) {
        UpiStatementDirection.selfTransfer => TransactionType.transfer,
        UpiStatementDirection.credit => TransactionType.income,
        UpiStatementDirection.debit => TransactionType.expense,
      };

  /// A self transfer's destination; null for a payment or receipt.
  final int? toAccountId;

  /// Required for a payment or receipt; null for a self transfer.
  final int? categoryId;
}

/// A statement row that completes a transfer the ledger recorded one leg
/// of (see [StatementMatch.transfer]).
class StatementTransfer {
  const StatementTransfer({required this.row, required this.match});
  final UpiStatementRow row;
  final StatementMatch match;
}

/// The note an imported row carries. Its reference is what a later import of
/// the same statement, here or on a synced phone, recognises it by.
String statementNote(UpiStatementSource source, UpiStatementRow row) => [
  'From ${source.label} statement',
  if (row.reference != null) 'UPI ref: ${row.reference}',
].join('\n');

/// Matches a UPI statement against the ledger and adds its new rows.
class StatementImportRepository {
  StatementImportRepository(this.database);
  final AppDatabase database;

  /// Device-local: which app account each statement account was last given.
  static const linksKey = 'statement_account_links';

  Future<Map<String, int>> accountLinks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(linksKey);
      if (saved == null) return {};
      return {
        for (final MapEntry(:key, :value)
            in (jsonDecode(saved) as Map<String, dynamic>).entries)
          if (value is int) key: value,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveAccountLinks(Map<String, int> links) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(linksKey, jsonEncode(links));
  }

  /// Device-local: who the statements imported so far say the user is.
  static const ownerKey = 'statement_owner';

  Future<StatementOwner> owner() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(ownerKey);
      return saved == null
          ? const StatementOwner()
          : StatementOwner.fromJson(jsonDecode(saved) as Map<String, Object?>);
    } catch (_) {
      return const StatementOwner();
    }
  }

  /// Adds what [statement] says about its owner to what's remembered.
  Future<void> rememberOwner(StatementOwner statement) async {
    if (statement.isEmpty) return;
    final merged = (await owner()).merge(statement);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ownerKey, jsonEncode(merged.toJson()));
  }

  /// Device-local: spreadsheet column mappings, by header signature.
  static const mappingsKey = 'statement_column_mappings';

  Future<Map<String, Object?>> columnMappings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(mappingsKey);
      return saved == null ? {} : jsonDecode(saved) as Map<String, Object?>;
    } catch (_) {
      return {};
    }
  }

  /// Saved mappings over shared layouts from other users, for finding a
  /// file's layout. Saving and undo use [columnMappings], so a shared layout
  /// is never copied into this device's own.
  Future<Map<String, Object?>> knownMappings() async {
    var shared = const <String, Object?>{};
    try {
      shared = await CommunityFixRepository(database).statementLayouts();
    } catch (_) {}
    return {...shared, ...await columnMappings()};
  }

  Future<void> saveColumnMapping(String signature, Object mapping) async {
    if (signature.isEmpty) return;
    final saved = await columnMappings();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      mappingsKey,
      jsonEncode({...saved, signature: mapping}),
    );
  }

  /// Puts back [previous] as [signature]'s mapping, or removes it when null.
  Future<void> restoreColumnMapping(String signature, Object? previous) async {
    final saved = {...await columnMappings()};
    if (previous == null) {
      saved.remove(signature);
    } else {
      saved[signature] = previous;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(mappingsKey, jsonEncode(saved));
  }

  /// The ledger around [rows]' dates, as candidates for [matchStatementRows].
  Future<List<LedgerCandidate>> candidates(List<UpiStatementRow> rows) async {
    if (rows.isEmpty) return const [];
    final dates = rows.map((r) => r.date);
    const margin = Duration(days: 3);
    return ledgerBetween(
      database,
      dates.reduce((a, b) => a.isBefore(b) ? a : b).subtract(margin),
      dates.reduce((a, b) => a.isAfter(b) ? a : b).add(margin),
    );
  }

  /// The category last used for each title, keyed by [categoryHistoryKey]:
  /// a payee paid before keeps the category it was given.
  Future<Map<String, int>> categoryHistory() async {
    final result = await database.customSelect(
      '''SELECT t.type, t.title, t.category_id FROM transactions t
            JOIN categories c ON c.id = t.category_id AND c.type = t.type
            WHERE t.title IS NOT NULL AND t.type != 'transfer'
            ORDER BY t.date ASC''',
    ).get();
    return {
      for (final r in result)
        categoryHistoryKey(
          TransactionTypeStorage.fromStorage(r.read<String>('type')),
          r.read<String>('title'),
        ): r.read<int>(
          'category_id',
        ),
    };
  }

  static String categoryHistoryKey(TransactionType type, String title) =>
      '${type.storageValue}|${title.trim().toLowerCase()}';

  /// Adds [imports] and completes [transfers] in one database transaction:
  /// all of them or none.
  Future<void> add(
    UpiStatementSource source,
    List<StatementImport> imports, {
    List<StatementTransfer> transfers = const [],
  }) {
    final ledger = TransactionRepository(database);
    return database.transaction(() async {
      for (final StatementTransfer(:row, :match) in transfers) {
        await _joinLegs(
          match.transactionId,
          match.otherLegId,
          fromAccountId: match.fromAccountId!,
          toAccountId: match.toAccountId!,
          note: statementNote(source, row),
        );
      }
      for (final item in imports) {
        final row = item.row;
        final note = statementNote(source, row);
        if (item.kind == TransactionType.transfer) {
          await ledger.addTransfer(
            amountMinor: row.amountMinor,
            fromAccountId: item.accountId,
            toAccountId: item.toAccountId!,
            note: note,
            date: row.date,
          );
        } else {
          final title = (item.title ?? row.counterparty).trim();
          await ledger.addExpenseOrIncome(
            type: item.kind,
            amountMinor: row.amountMinor,
            accountId: item.accountId,
            categoryId: item.categoryId!,
            title: title.length > 60 ? title.substring(0, 60).trim() : title,
            note: note,
            date: row.date,
          );
        }
      }
    });
  }

  /// Joins the transfers between the user's accounts recorded a leg at a
  /// time within three days of [date] — each bank's SMS saved as an expense
  /// and an income (see [recordedTransferLegs]). Returns how many.
  Future<int> linkRecordedTransfers(DateTime date) => database.transaction(
    () async {
      const margin = Duration(days: 3);
      final pairs = recordedTransferLegs(
        await ledgerBetween(database, date.subtract(margin), date.add(margin)),
      );
      for (final (:out, :into) in pairs) {
        await _joinLegs(
          out.id,
          into.id,
          fromAccountId: out.accountId,
          toAccountId: into.accountId,
        );
      }
      return pairs.length;
    },
  );

  /// Makes expense or income [keptId] the transfer between the two
  /// accounts, with [note] added, and removes [goneId], its other leg when
  /// the ledger has that too. The other leg's note — another bank's SMS —
  /// stays on the transfer, and its SMS now point at the transfer, so
  /// neither is imported again.
  Future<void> _joinLegs(
    int keptId,
    int? goneId, {
    required int fromAccountId,
    required int toAccountId,
    String? note,
  }) async {
    final ledger = TransactionRepository(database);
    final goneNote = goneId == null
        ? null
        : (await database
                  .customSelect(
                    'SELECT note FROM transactions WHERE id = ?',
                    variables: [Variable(goneId)],
                  )
                  .getSingleOrNull())
              ?.readNullable<String>('note');
    final appended = [
      for (final part in [goneNote, note])
        if (part != null && part.trim().isNotEmpty) part.trim(),
    ].join('\n\n');
    await ledger.convertToTransfer(
      id: keptId,
      fromAccountId: fromAccountId,
      toAccountId: toAccountId,
      appendNote: appended.isEmpty ? null : appended,
    );
    if (goneId == null) return;
    await database.customStatement(
      'UPDATE sms_imports SET transaction_id = ? WHERE transaction_id = ?',
      [keptId, goneId],
    );
    await ledger.delete(goneId);
  }
}

/// The one active rupee account a statement account most plausibly is: by
/// the trailing digits of its number, then by bank when the digits alone
/// fit several — or by bank alone when the statement gives no digits; the
/// user's cash is their one cash account. Null when nothing, or more than
/// one, fits.
Account? guessStatementAccount(StatementAccount named, List<Account> accounts) {
  if (named == StatementAccount.cash) {
    return accounts.where((a) => a.type == AccountType.cash).singleOrNull;
  }
  if (named.digits.isEmpty) {
    final bank = _normalizedBank(named.bank);
    if (bank.isEmpty) return null;
    return accounts
        .where(
          (a) =>
              _normalizedBank(a.institution) == bank ||
              _normalizedBank(a.name) == bank,
        )
        .singleOrNull;
  }
  final byDigits = accounts
      .where(
        (a) =>
            a.lastDigits != null &&
            a.lastDigits!.isNotEmpty &&
            (a.lastDigits!.endsWith(named.digits) ||
                named.digits.endsWith(a.lastDigits!)),
      )
      .toList();
  if (byDigits.length <= 1) return byDigits.singleOrNull;
  final bank = _normalizedBank(named.bank);
  if (bank.isEmpty) return null;
  final byBank = byDigits
      .where(
        (a) =>
            _normalizedBank(a.institution) == bank ||
            _normalizedBank(a.name) == bank,
      )
      .toList();
  return byBank.singleOrNull;
}

String _normalizedBank(String? value) {
  final name = (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  return const {
        'sbi': 'statebankofindia',
        'statebankindia': 'statebankofindia',
        'kotakbank': 'kotakmahindrabank',
      }[name] ??
      name;
}
