import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../domain/account.dart';
import '../../domain/bank_institution_icon.dart';
import '../../domain/category.dart';
import '../../domain/realtime_sms_category.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import 'account_repository.dart';
import 'category_repository.dart';
import 'sms_import_repository.dart';
import 'transaction_repository.dart';

class LiveSms {
  LiveSms(
    this.sms,
    this.accountId,
    this.categoryId,
    this.transactionId,
    this.otherAccountId,
  );
  final PendingSmsImport sms;
  final int? accountId, categoryId, transactionId, otherAccountId;
}

/// Notification state is device-local. The ledger and SMS deduplication record
/// are committed together; a retried background job cannot save twice.
class RealtimeSmsRepository {
  RealtimeSmsRepository(this.db);
  final AppDatabase db;

  Future<void> initialize() async {
    await db.customStatement('''
    CREATE TABLE IF NOT EXISTS realtime_sms (
      fingerprint TEXT PRIMARY KEY, account_id INTEGER, category_id INTEGER,
      other_account_id INTEGER
    )''');
    await db.customStatement('''CREATE TABLE IF NOT EXISTS sms_category_memory (
      merchant TEXT PRIMARY KEY, category_id INTEGER NOT NULL, owner TEXT NOT NULL
    )''');
    await db.customStatement('''CREATE TABLE IF NOT EXISTS sms_category_undo (
      fingerprint TEXT PRIMARY KEY, state TEXT NOT NULL
    )''');
    // Accounts created for a message, while the notification can undo them,
    // and banks whose created account the user undid: those wait for a tap.
    await db.customStatement(
      '''CREATE TABLE IF NOT EXISTS sms_created_accounts (
      fingerprint TEXT PRIMARY KEY, account_id INTEGER NOT NULL
    )''',
    );
    await db.customStatement(
      '''CREATE TABLE IF NOT EXISTS sms_declined_accounts (
      bank_key TEXT PRIMARY KEY
    )''',
    );
  }

  /// The account created for this message, while it can still be undone.
  Future<int?> createdAccount(String id) async {
    await initialize();
    final row = await db
        .customSelect(
          '''SELECT c.account_id FROM sms_created_accounts c
          JOIN accounts a ON a.id=c.account_id WHERE c.fingerprint=?''',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    return row?.read<int>('account_id');
  }

  Future<PendingSmsImport> _resolved(PendingSmsImport sms) async =>
      resolveSmsAccount(sms, await SmsImportRepository(db).detectedAccounts());

  /// Finds or creates the account for an unambiguous message: one named after
  /// the bank, its number kept separately, its balance taken from the SMS.
  Future<({int id, bool created})?> _accountFor(PendingSmsImport sms) async {
    if (sms.ambiguousAccount) return null;
    final imports = SmsImportRepository(db);
    final before = (await AccountRepository(
      db,
    ).load()).map((a) => a.id).toSet();
    await imports.createDetectedAccounts(
      [sms],
      icons: {
        sms.bankKey: bankInstitutionIcon(
          sms.bankName,
          creditCard: sms.creditCard,
        ),
      },
    );
    final id = (await imports.accountLinks())[sms.bankKey];
    return id == null ? null : (id: id, created: !before.contains(id));
  }

  /// "Add account" on a notification: create it and save the transaction.
  Future<void> createAccountFor(String id) => db.transaction(() async {
    final current = await load(id);
    if (current == null) {
      throw StateError('This transaction is no longer available.');
    }
    if (current.accountId != null) return;
    final sms = await _resolved(current.sms);
    await db.customStatement(
      'DELETE FROM sms_declined_accounts WHERE bank_key=?',
      [sms.bankKey],
    );
    final account = await _accountFor(sms);
    if (account == null) {
      throw StateError('Choose an account for this message.');
    }
    await edit(id, accountId: account.id, categoryId: current.categoryId);
    if (account.created) {
      await db.customStatement(
        'INSERT OR REPLACE INTO sms_created_accounts VALUES (?,?)',
        [id, account.id],
      );
    }
  });

  /// Removes the account created for this message and its transaction. The
  /// message returns to pending, and the bank is not created again unasked.
  Future<void> undoCreatedAccount(String id) => db.transaction(() async {
    final accountId = await createdAccount(id);
    final current = await load(id);
    if (accountId == null || current == null) return;
    final count = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM transactions WHERE (account_id=? OR to_account_id=?) AND id IS NOT ?',
          variables: [
            Variable(accountId),
            Variable(accountId),
            Variable(current.transactionId),
          ],
        )
        .getSingle();
    if (count.read<int>('n') > 0) {
      throw StateError(
        'This account already has other transactions. Remove it in the app.',
      );
    }
    final sms = await _resolved(current.sms);
    await AccountRepository(db).delete(accountId);
    await db.customStatement(
      "UPDATE sms_imports SET status='pending',transaction_id=NULL WHERE fingerprint=?",
      [id],
    );
    await db.customStatement(
      'UPDATE realtime_sms SET account_id=NULL,other_account_id=NULL WHERE fingerprint=?',
      [id],
    );
    await db.customStatement(
      'DELETE FROM sms_account_links WHERE account_id=?',
      [accountId],
    );
    await db.customStatement(
      'INSERT OR IGNORE INTO sms_declined_accounts VALUES (?)',
      [sms.bankKey],
    );
    await db.customStatement(
      'DELETE FROM sms_created_accounts WHERE fingerprint=?',
      [id],
    );
  });

  String? _merchant(PendingSmsImport sms) {
    final party = (sms.data['counterparty'] as String?)
        ?.trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    // A payment channel is not a merchant. Never learn a blanket transfer rule.
    if (party == null ||
        party.isEmpty ||
        {
          'mob bk',
          'mobile banking transfer',
          'upi',
          'transfer',
          'bank transfer',
          'unknown',
          'merchant',
        }.contains(party)) {
      return null;
    }
    return '${sms.credit ? 'credit' : 'debit'}|$party';
  }

  Future<Map<String, dynamic>?> categoryConfirmation(String id) async {
    await initialize();
    final row = await db
        .customSelect(
          'SELECT state FROM sms_category_undo WHERE fingerprint=?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final state = jsonDecode(row.read<String>('state')) as Map<String, dynamic>;
    final current = await load(id);
    if (current == null ||
        current.categoryId != state['selected'] ||
        current.otherAccountId != null) {
      return null;
    }
    return state;
  }

  /// The categories the user filed [credit] or debit transactions under most
  /// in the last 90 days, most used first.
  Future<List<int>> frequentCategories({
    required bool credit,
    int limit = 6,
  }) async {
    final since = DateTime.now().subtract(const Duration(days: 90));
    final rows = await db
        .customSelect(
          '''SELECT category_id FROM transactions
          WHERE type=? AND category_id IS NOT NULL AND date>=?
          GROUP BY category_id ORDER BY COUNT(*) DESC, MAX(date) DESC LIMIT ?''',
          variables: [
            Variable(credit ? 'income' : 'expense'),
            Variable(since.millisecondsSinceEpoch),
            Variable(limit),
          ],
        )
        .get();
    return [for (final row in rows) row.read<int>('category_id')];
  }

  Future<void> selectCategory(
    String id,
    int categoryId, {
    int? accountId,
    int? previousCategoryId,
  }) => db.transaction(() async {
    final before = await load(id);
    if (before == null) {
      throw StateError('This transaction is no longer available.');
    }
    final merchant = _merchant(before.sms);
    final previous = merchant == null
        ? null
        : await db
              .customSelect(
                'SELECT category_id, owner FROM sms_category_memory WHERE merchant=?',
                variables: [Variable(merchant)],
              )
              .getSingleOrNull();
    final partner = before.otherAccountId == null
        ? null
        : await db
              .customSelect(
                'SELECT fingerprint FROM sms_imports WHERE transaction_id=? AND fingerprint!=? LIMIT 1',
                variables: [Variable(before.transactionId!), Variable(id)],
              )
              .getSingleOrNull();
    if (accountId != null) {
      await edit(id, accountId: accountId, categoryId: categoryId);
    } else {
      await choosePendingCategory(id, categoryId);
    }
    final token = '$id:${DateTime.now().microsecondsSinceEpoch}';
    if (merchant != null) {
      await db.customStatement(
        'INSERT OR REPLACE INTO sms_category_memory VALUES (?,?,?)',
        [merchant, categoryId, token],
      );
    }
    await db.customStatement(
      'INSERT OR REPLACE INTO sms_category_undo VALUES (?,?)',
      [
        id,
        jsonEncode({
          'token': token,
          'merchant': merchant,
          'selected': categoryId,
          'previousCategory': previousCategoryId ?? before.categoryId,
          'other': before.otherAccountId,
          'partner': partner?.read<String>('fingerprint'),
          'previousRule': previous?.read<int>('category_id'),
          'previousOwner': previous?.read<String>('owner'),
        }),
      ],
    );
  });

  Future<void> undoCategory(String id, String token) =>
      db.transaction(() async {
        final state = await categoryConfirmation(id);
        if (state == null || state['token'] != token) return;
        final current = (await load(id))!;
        if (current.accountId == null) {
          await choosePendingCategory(id, state['previousCategory'] as int);
        } else {
          await edit(
            id,
            accountId: current.accountId!,
            categoryId: state['previousCategory'] as int?,
            otherAccountId: state['other'] as int?,
            confirmedMatchId: state['partner'] as String?,
            autoMatch: false,
          );
        }
        final merchant = state['merchant'] as String?;
        if (merchant != null) {
          // A later correction from another notification takes precedence.
          final row = await db
              .customSelect(
                'SELECT owner FROM sms_category_memory WHERE merchant=?',
                variables: [Variable(merchant)],
              )
              .getSingleOrNull();
          if (row?.read<String>('owner') == token) {
            await db.customStatement(
              'DELETE FROM sms_category_memory WHERE merchant=?',
              [merchant],
            );
            if (state['previousRule'] != null) {
              await db.customStatement(
                'INSERT INTO sms_category_memory VALUES (?,?,?)',
                [merchant, state['previousRule'], state['previousOwner']],
              );
            }
          }
        }
        await db.customStatement(
          'DELETE FROM sms_category_undo WHERE fingerprint=?',
          [id],
        );
      });

  Future<LiveSms?> load(String id) async {
    await initialize();
    final r = await db
        .customSelect(
          '''
      SELECT i.*, r.account_id, r.category_id, r.other_account_id
      FROM realtime_sms r JOIN sms_imports i ON i.fingerprint=r.fingerprint
      WHERE r.fingerprint=? AND i.status!='dismissed'
    ''',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (r == null) return null;
    final transactionId = r.readNullable<int>('transaction_id');
    if (transactionId == null && r.read<String>('status') == 'imported') {
      return null;
    }
    final candidate = Map<String, dynamic>.from(
      jsonDecode(r.read<String>('candidate')) as Map,
    );
    var accountId = r.readNullable<int>('account_id');
    var categoryId = r.readNullable<int>('category_id');
    var otherAccountId = r.readNullable<int>('other_account_id');
    // A notification must never recreate a transaction deleted in the app.
    if (transactionId != null) {
      final transaction = await db
          .customSelect(
            'SELECT * FROM transactions WHERE id=?',
            variables: [Variable(transactionId)],
          )
          .getSingleOrNull();
      if (transaction == null) return null;
      final credit = candidate['direction'] == 'credit';
      final transfer = transaction.read<String>('type') == 'transfer';
      // Amount/date/direction edits in the full editor supersede this SMS.
      if (transaction.read<int>('amount_minor') != candidate['amountMinor'] ||
          (!transfer &&
              transaction.read<int>('date') != r.read<int>('received_at')) ||
          (!transfer &&
              transaction.read<String>('type') !=
                  (credit ? 'income' : 'expense'))) {
        return null;
      }
      accountId = transaction.read<int>(
        transfer && credit ? 'to_account_id' : 'account_id',
      );
      otherAccountId = transfer
          ? transaction.read<int>(credit ? 'account_id' : 'to_account_id')
          : null;
      if (!transfer) categoryId = transaction.read<int>('category_id');
    }
    return LiveSms(
      PendingSmsImport(
        id: id,
        sender: r.read<String>('sender'),
        body: r.readNullable<String>('body') ?? '',
        data: candidate,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          r.read<int>('received_at'),
        ),
      ),
      accountId,
      categoryId,
      transactionId,
      otherAccountId,
    );
  }

  Future<LiveSms?> receive(BankSms message, PortableSmsEngine engine) async {
    await initialize();
    if (!(await SmsImportRepository(db).state()).$1) return null;
    final result = engine.parse(message);
    if (result.candidate == null || result.ruleId == null) return null;
    final id = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              message.sender,
              message.body,
              message.receivedAt.millisecondsSinceEpoch,
            ]),
          ),
        )
        .toString();
    return db.transaction(() async {
      final previous = await load(id);
      if (previous != null) return previous;
      final imports = SmsImportRepository(db);
      await imports.enqueue(message, result);
      final pending = await db
          .customSelect(
            "SELECT * FROM sms_imports WHERE fingerprint=? AND status='pending'",
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (pending == null) return null;
      var sms = PendingSmsImport(
        id: id,
        sender: message.sender,
        body: message.body,
        receivedAt: message.receivedAt,
        data: Map<String, dynamic>.from(
          jsonDecode(pending.read<String>('candidate')) as Map,
        ),
      );
      sms = resolveSmsAccount(sms, await imports.detectedAccounts());
      final accounts = await AccountRepository(db).load();
      final links = await imports.accountLinks();
      var account = accounts
          .where(
            (a) =>
                a.id == links[sms.bankKey] &&
                !a.isArchived &&
                a.currency == sms.currency &&
                a.digits == 2,
          )
          .firstOrNull;
      // A last-four match also requires the institution, currency and type.
      if (account == null && sms.accountLast4 != null) {
        final matches = accounts
            .where(
              (a) =>
                  !a.isArchived &&
                  a.digits == 2 &&
                  a.currency == sms.currency &&
                  a.lastDigits == sms.accountLast4 &&
                  a.institution?.toLowerCase() == sms.bankName.toLowerCase() &&
                  (sms.creditCard
                      ? a.type == AccountType.creditCard
                      : a.type == AccountType.bank),
            )
            .toList();
        if (matches.length == 1) account = matches.single;
      }
      // An unknown bank account is created rather than asked about. Only an
      // unnumbered message from a bank with several accounts, or a bank whose
      // created account was undone, waits for a choice.
      int? createdAccountId;
      if (account == null &&
          (await db
                  .customSelect(
                    'SELECT 1 FROM sms_declined_accounts WHERE bank_key=?',
                    variables: [Variable(sms.bankKey)],
                  )
                  .getSingleOrNull()) ==
              null) {
        final found = await _accountFor(sms);
        if (found != null) {
          account = (await AccountRepository(
            db,
          ).load()).where((a) => a.id == found.id).firstOrNull;
          if (found.created) createdAccountId = found.id;
        }
      }
      final categories = CategoryRepository(db);
      var category = realtimeSmsCategory(sms, await categories.load());
      final merchant = _merchant(sms);
      if (merchant != null) {
        final remembered = await db
            .customSelect(
              'SELECT category_id FROM sms_category_memory WHERE merchant=?',
              variables: [Variable(merchant)],
            )
            .getSingleOrNull();
        final rememberedCategory = (await categories.load())
            .where(
              (c) =>
                  c.id == remembered?.read<int>('category_id') &&
                  c.type ==
                      (sms.credit ? CategoryType.income : CategoryType.expense),
            )
            .firstOrNull;
        category = rememberedCategory ?? category;
      }
      if (category != null && category.id < 0) {
        await categories.save(
          name: category.name,
          type: category.type,
          icon: category.icon,
          parentId: category.parentId,
        );
        category = realtimeSmsCategory(sms, await categories.load());
      }
      if (category == null) {
        // A deleted fallback category is recreated only when needed by a new
        // live message. Never use a category of the opposite direction.
        final type = sms.credit ? CategoryType.income : CategoryType.expense;
        final name = realtimeFallbackCategoryName(sms.credit);
        await categories.save(
          name: name,
          type: type,
          icon: sms.credit ? 'wallet_one' : 'shield',
        );
        category = (await categories.load()).firstWhere(
          (c) => c.type == type && c.name == name,
        );
      }
      await db.customStatement(
        'INSERT OR REPLACE INTO realtime_sms(fingerprint,account_id,category_id) VALUES (?,?,?)',
        [id, account?.id, category.id],
      );
      if (createdAccountId != null) {
        await db.customStatement(
          'INSERT OR REPLACE INTO sms_created_accounts VALUES (?,?)',
          [id, createdAccountId],
        );
      }
      if (account != null) {
        final pair = await _counterpart(sms, account.id);
        if (pair?.otherAccountId == account.id && pair?.transactionId != null) {
          await db.customStatement(
            "UPDATE sms_imports SET status='imported',body=NULL,transaction_id=? WHERE fingerprint=?",
            [pair!.transactionId, id],
          );
          await db.customStatement(
            'UPDATE realtime_sms SET other_account_id=? WHERE fingerprint=?',
            [pair.accountId, id],
          );
          return load(id);
        }
        await edit(id, accountId: account.id, categoryId: category.id);
      }
      return load(id);
    });
  }

  Future<void> edit(
    String id, {
    required int accountId,
    int? categoryId,
    int? otherAccountId,
    String? confirmedMatchId,
    bool autoMatch = true,
  }) => db.transaction(() async {
    final current = await load(id);
    if (current == null) {
      throw StateError('This transaction is no longer available.');
    }
    final sms = current.sms;
    categoryId ??= current.categoryId;
    final accounts = await AccountRepository(db).load();
    for (final account in [accountId, ?otherAccountId]) {
      if (!accounts.any(
        (a) =>
            a.id == account &&
            !a.isArchived &&
            a.currency == sms.currency &&
            a.digits == 2,
      )) {
        throw StateError('Choose an active account in ${sms.currency}.');
      }
    }
    if (otherAccountId == accountId) {
      throw StateError('Choose two different accounts.');
    }
    if (otherAccountId == null &&
        !(await CategoryRepository(db).load()).any(
          (c) =>
              c.id == categoryId &&
              c.type ==
                  (sms.credit ? CategoryType.income : CategoryType.expense),
        )) {
      throw StateError('Choose a matching category.');
    }
    final ledger = TransactionRepository(db);
    var note = sms.originalSmsNote;
    final paired = confirmedMatchId != null
        ? (await possibleTransferMatches(
            id,
            accountId: accountId,
            otherAccountId: otherAccountId,
          )).where((m) => m.sms.id == confirmedMatchId).firstOrNull
        : otherAccountId == null || !autoMatch
        ? null
        : await _counterpart(sms, accountId, expectedAccount: otherAccountId);
    if (confirmedMatchId != null && paired == null) {
      throw StateError(
        'This match has changed. Choose the matching transaction again.',
      );
    }
    // The second SMS may arrive after the first was already made a transfer.
    // Attach it to that transfer instead of applying the two balances again.
    if (paired?.otherAccountId != null &&
        paired!.transactionId != current.transactionId) {
      if (paired.otherAccountId != accountId ||
          paired.accountId != otherAccountId) {
        throw StateError('That message belongs to a different transfer.');
      }
      if (current.otherAccountId != null) {
        throw StateError(
          'Both entries are already transfers. Review them in the ledger.',
        );
      }
      if (current.transactionId != null) {
        await _snapshotAdjustment(
          sms,
          sms.credit ? 'income' : 'expense',
          current.accountId!,
          null,
          sms.amountMinor,
          reverse: true,
        );
        await ledger.delete(current.transactionId!);
        await db.customStatement(
          'UPDATE sms_imports SET transaction_id=? WHERE transaction_id=?',
          [paired.transactionId, current.transactionId],
        );
      }
      await db.customStatement(
        "UPDATE sms_imports SET status='imported',body=NULL,transaction_id=? WHERE fingerprint=?",
        [paired.transactionId, id],
      );
      await db.customStatement(
        'UPDATE realtime_sms SET account_id=?,category_id=?,other_account_id=? WHERE fingerprint=?',
        [accountId, categoryId, otherAccountId, id],
      );
      await db.customStatement('DELETE FROM sms_review WHERE fingerprint=?', [
        id,
      ]);
      return;
    }
    // An exact bank reference, amount, opposite direction and both chosen
    // account identities are required. Equal amounts alone never merge SMS.
    if (paired?.transactionId != null &&
        paired!.transactionId != current.transactionId) {
      final oldPair = await db
          .customSelect(
            'SELECT * FROM transactions WHERE id=?',
            variables: [Variable(paired.transactionId!)],
          )
          .getSingle();
      if (oldPair.read<String>('type') == 'transfer') {
        throw StateError('That message already belongs to another transfer.');
      }
      await _snapshotAdjustment(
        paired.sms,
        oldPair.read<String>('type'),
        oldPair.read<int>('account_id'),
        null,
        oldPair.read<int>('amount_minor'),
        reverse: true,
      );
      await ledger.delete(paired.transactionId!);
    }
    final shared = current.transactionId == null
        ? <LiveSms>[]
        : [
            for (final row
                in await db
                    .customSelect(
                      'SELECT fingerprint FROM sms_imports WHERE transaction_id=? AND fingerprint!=?',
                      variables: [
                        Variable(current.transactionId!),
                        Variable(id),
                      ],
                    )
                    .get())
              if (await load(row.read<String>('fingerprint'))
                  case final LiveSms value)
                value,
          ];
    // Reclassifying one side of a confirmed transfer restores the other side
    // as its original directional entry, so neither bank message disappears.
    if (otherAccountId == null) {
      for (final side in shared) {
        await db.customStatement(
          "UPDATE sms_imports SET transaction_id=NULL,status='pending' WHERE fingerprint=?",
          [side.sms.id],
        );
        await edit(
          side.sms.id,
          accountId: side.accountId!,
          categoryId: side.categoryId,
        );
      }
    }
    if (current.transactionId != null) {
      final old = await db
          .customSelect(
            'SELECT * FROM transactions WHERE id=?',
            variables: [Variable(current.transactionId!)],
          )
          .getSingle();
      note = old.readNullable<String>('note') ?? note;
      await _snapshotAdjustment(
        sms,
        old.read<String>('type'),
        old.read<int>('account_id'),
        old.readNullable<int>('to_account_id'),
        old.read<int>('amount_minor'),
        reverse: true,
      );
      await ledger.delete(current.transactionId!);
    }
    final from = sms.credit && otherAccountId != null
        ? otherAccountId
        : accountId;
    final to = sms.credit ? accountId : otherAccountId;
    final type = otherAccountId != null
        ? TransactionType.transfer
        : sms.credit
        ? TransactionType.income
        : TransactionType.expense;
    final transactionId = type == TransactionType.transfer
        ? await ledger.addTransfer(
            amountMinor: sms.amountMinor,
            fromAccountId: from,
            toAccountId: to!,
            note: note,
            date: sms.receivedAt,
          )
        : await ledger.addExpenseOrIncome(
            type: type,
            amountMinor: sms.amountMinor,
            accountId: accountId,
            categoryId: categoryId!,
            title: sms.title,
            note: note,
            date: sms.receivedAt,
          );
    await _snapshotAdjustment(
      sms,
      type.storageValue,
      from,
      type == TransactionType.transfer ? to : null,
      sms.amountMinor,
    );
    await db.customStatement(
      '''UPDATE sms_imports SET status='imported',
      body=NULL, transaction_id=? WHERE fingerprint=?''',
      [transactionId, id],
    );
    if (current.transactionId != null) {
      await db.customStatement(
        'UPDATE sms_imports SET transaction_id=? WHERE transaction_id=?',
        [transactionId, current.transactionId],
      );
    }
    await db.customStatement(
      '''UPDATE realtime_sms SET account_id=?,category_id=?,
      other_account_id=? WHERE fingerprint=?''',
      [accountId, categoryId, otherAccountId, id],
    );
    await db.customStatement('DELETE FROM sms_review WHERE fingerprint=?', [
      id,
    ]);
    if (otherAccountId != null) {
      for (final side in {
        if (paired != null) paired.sms.id,
        ...shared.map((s) => s.sms.id),
      }) {
        await db.customStatement(
          "UPDATE sms_imports SET status='imported',body=NULL,transaction_id=? WHERE fingerprint=?",
          [transactionId, side],
        );
        await db.customStatement(
          'UPDATE realtime_sms SET account_id=?,other_account_id=? WHERE fingerprint=?',
          [otherAccountId, accountId, side],
        );
        await db.customStatement('DELETE FROM sms_review WHERE fingerprint=?', [
          side,
        ]);
      }
    }
  });

  Future<void> choosePendingCategory(String id, int categoryId) =>
      db.transaction(() async {
        final current = await load(id);
        if (current == null) {
          throw StateError('This transaction is no longer available.');
        }
        if (current.accountId != null) {
          await edit(id, accountId: current.accountId!, categoryId: categoryId);
          return;
        }
        final type = current.sms.credit
            ? CategoryType.income
            : CategoryType.expense;
        if (!(await CategoryRepository(
          db,
        ).load()).any((c) => c.id == categoryId && c.type == type)) {
          throw StateError('Choose a matching category.');
        }
        await db.customStatement(
          'UPDATE realtime_sms SET category_id=? WHERE fingerprint=?',
          [categoryId, id],
        );
      });

  /// Suggestions only: never use these to merge without a user selection.
  Future<List<LiveSms>> possibleTransferMatches(
    String id, {
    required int accountId,
    required int? otherAccountId,
  }) async {
    final current = await load(id);
    if (current == null ||
        otherAccountId == null ||
        accountId == otherAccountId) {
      return [];
    }
    final at = current.sms.receivedAt.millisecondsSinceEpoch;
    final rows = await db
        .customSelect(
          '''SELECT i.fingerprint FROM sms_imports i
      JOIN realtime_sms r ON r.fingerprint=i.fingerprint
      WHERE i.fingerprint!=? AND i.received_at BETWEEN ? AND ?
      ORDER BY abs(i.received_at-?), i.fingerprint''',
          variables: [
            Variable(id),
            Variable(at - 300000),
            Variable(at + 300000),
            Variable(at),
          ],
        )
        .get();
    final matches = <LiveSms>[];
    final transactions = <int>{};
    for (final row in rows) {
      final candidate = await load(row.read<String>('fingerprint'));
      if (candidate == null ||
          candidate.transactionId == null ||
          candidate.transactionId == current.transactionId ||
          candidate.accountId != otherAccountId ||
          candidate.sms.credit == current.sms.credit ||
          candidate.sms.amountMinor != current.sms.amountMinor ||
          candidate.sms.currency != current.sms.currency ||
          (candidate.otherAccountId != null &&
              candidate.otherAccountId != accountId)) {
        continue;
      }
      if (candidate.otherAccountId != null) {
        final linked = await db
            .customSelect(
              '''SELECT 1 FROM sms_imports
          WHERE transaction_id=? AND json_extract(candidate,'\$.direction')=? LIMIT 1''',
              variables: [
                Variable(candidate.transactionId!),
                Variable(current.sms.credit ? 'credit' : 'debit'),
              ],
            )
            .getSingleOrNull();
        if (linked != null) continue;
      }
      if (transactions.add(candidate.transactionId!)) matches.add(candidate);
    }
    return matches;
  }

  Future<bool> hasExactTransferMatch(
    String id, {
    required int accountId,
    required int otherAccountId,
  }) async {
    final current = await load(id);
    return current != null &&
        await _counterpart(
              current.sms,
              accountId,
              expectedAccount: otherAccountId,
            ) !=
            null;
  }

  Future<LiveSms?> _counterpart(
    PendingSmsImport sms,
    int accountId, {
    int? expectedAccount,
  }) async {
    final reference = sms.reference?.trim();
    if (reference == null || reference.isEmpty) return null;
    final matches = <LiveSms>[];
    final rows = await db
        .customSelect(
          '''SELECT i.fingerprint FROM sms_imports i
      JOIN realtime_sms r ON r.fingerprint=i.fingerprint
      WHERE i.fingerprint!=? AND i.received_at BETWEEN ? AND ?
      AND coalesce(json_extract(i.candidate,'\$.reference'),json_extract(i.candidate,'\$.bankReference'))=?''',
          variables: [
            Variable(sms.id),
            Variable(sms.receivedAt.millisecondsSinceEpoch - 300000),
            Variable(sms.receivedAt.millisecondsSinceEpoch + 300000),
            Variable(reference),
          ],
        )
        .get();
    for (final row in rows) {
      final value = await load(row.read<String>('fingerprint'));
      if (value != null &&
          value.accountId != null &&
          value.accountId != accountId &&
          (expectedAccount == null || value.accountId == expectedAccount) &&
          value.sms.credit != sms.credit &&
          value.sms.currency == sms.currency &&
          value.sms.amountMinor == sms.amountMinor) {
        matches.add(value);
      }
    }
    return matches.length == 1 ? matches.single : null;
  }

  Future<void> _snapshotAdjustment(
    PendingSmsImport sms,
    String type,
    int from,
    int? to,
    int amount, {
    bool reverse = false,
  }) async {
    for (final entry in {
      from: type == 'income' ? amount : -amount,
      ?to: amount,
    }.entries) {
      await db.customStatement(
        '''UPDATE accounts SET balance_minor=balance_minor+?
        WHERE id=? AND balance_reported_at>=?''',
        [
          (reverse ? 1 : -1) * entry.value,
          entry.key,
          sms.receivedAt.millisecondsSinceEpoch,
        ],
      );
    }
  }
}
