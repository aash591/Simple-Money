import '../../domain/app_icons.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../domain/transaction.dart';
import '../../domain/account.dart';
import 'account_repository.dart';
import 'sms_corrections.dart';
import 'category_repository.dart';
import '../../domain/category.dart';
import '../db/app_database.dart';
import '../bank_sms_parser.dart';
import '../notification_access_platform.dart';
import '../sms_inbox_platform.dart';
import 'statement_import_repository.dart';
import 'transaction_repository.dart';
import 'upi_sms_match.dart';
import '../../domain/currency_digits.dart';
import '../sms_amounts.dart';

/// Where a message keeps a direction the user corrected.
const correctedDirectionKey = 'correctedDirection';

/// Where a message keeps the loan an approved correction says it pays.
const assignedLoanKey = 'assignedLoanId';

String smsBankKey(Map<String, dynamic> data) => jsonEncode([
  data['countryCode'],
  data['bankName'],
  data['currencyCode'],
  data['accountLast4'],
  if (data['isCreditCard'] == true) 'creditCard',
]);

class PendingSmsImport {
  PendingSmsImport({
    required this.id,
    required this.sender,
    required this.body,
    required this.data,
    required this.receivedAt,
  });
  final String id, sender, body;
  final Map<String, dynamic> data;
  final DateTime receivedAt;
  String get originalSmsNote => 'Sender: $sender\n\n$body';
  int get amountMinor => data['amountMinor'] as int;
  String get currency => data['currencyCode'] as String;

  /// Money in. A correction the user approved ("credited to your loan
  /// account" is a payment) wins over what the SMS said.
  bool get credit =>
      (data[correctedDirectionKey] ?? data['direction']) == 'credit';

  /// The loan this message pays, from an approved correction.
  int? get assignedLoanId => data[assignedLoanKey] as int?;
  bool get creditCard => data['isCreditCard'] == true;
  bool get isCreditCardRepayment =>
      suggestedCategory?.isCreditCardRepayment ?? false;
  bool get isAtmWithdrawal =>
      !credit && (suggestedCategory?.isAtmWithdrawal ?? false);
  bool get isAtmDeposit => credit && (suggestedCategory?.isAtmDeposit ?? false);
  bool get isAtmCashMovement => isAtmWithdrawal || isAtmDeposit;
  bool get requiresTransfer => isCreditCardRepayment || isAtmCashMovement;
  bool get needsCategoryConfirmation =>
      suggestedCategory?.needsCategoryConfirmation ?? false;
  SmsSuggestedCategory? get suggestedCategory => data['category'] == null
      ? null
      : SmsSuggestedCategory.fromJson(
          Map<String, dynamic>.from(data['category'] as Map),
        );
  int? get balanceMinor => data['balanceMinor'] as int?;
  int? get availableCreditLimitMinor =>
      data['availableCreditLimitMinor'] as int?;
  String get title =>
      (data['counterparty'] as String?) ??
      (data['bankName'] as String?) ??
      sender;
  String? get accountLast4 => data['accountLast4'] as String?;
  String? get reference =>
      (data['reference'] ?? data['bankReference']) as String?;
  String get bankName => data['bankName'] as String? ?? sender;

  /// No account number, and the bank has several known ones to choose from.
  /// Without a number and with none known, the bank name is the identity.
  bool get ambiguousAccount => data['ambiguousAccount'] == true;

  /// Whether the sender holds the money (a bank, card or wallet), so its
  /// name can stand for an account. False for a shop's or biller's SMS.
  bool get holdsMoney => dataHoldsMoney(data);
  late final String bankKey = smsBankKey(data);

  /// The app's decimal places for [currency]; [amountMinor] uses them.
  int get digits => currencyDigits(currency);
}

/// Whether two messages come from the same bank, currency and card-or-account
/// kind, regardless of the account number.
bool sameSmsInstitution(PendingSmsImport a, PendingSmsImport b) =>
    a.bankName == b.bankName &&
    a.data['countryCode'] == b.data['countryCode'] &&
    a.currency == b.currency &&
    a.creditCard == b.creditCard;

/// The fullest number [suffix] can stand for among [known]: some banks print
/// `XX1234` in one message and `XX234` (leading zero dropped, or the mask cut
/// short) in the next, and those are one account. Only a tail of three or more
/// digits counts, and only when exactly one longer number ends with it —
/// `234` could as well be `1234` or `5234`, and then it stays as it is.
String? fullerAccountSuffix(String suffix, Iterable<String> known) {
  if (suffix.length < 3 || !RegExp(r'^\d+$').hasMatch(suffix)) return null;
  final longer = {
    for (final other in known)
      if (other.length > suffix.length &&
          RegExp(r'^\d+$').hasMatch(other) &&
          other.endsWith(suffix))
        other,
  };
  return longer.length == 1 ? longer.single : null;
}

PendingSmsImport _withAccountLast4(PendingSmsImport sms, String last4) =>
    PendingSmsImport(
      id: sms.id,
      sender: sms.sender,
      body: sms.body,
      receivedAt: sms.receivedAt,
      data: {...sms.data, 'accountLast4': last4},
    );

/// A debit-card message: the number it carries is the card's, not the
/// account's ("on Federal Bank Debit Card 6226"). A credit card is an account
/// of its own, so it is not one of these.
bool isDebitCardMessage(PendingSmsImport sms) =>
    sms.data['channel'] == 'card' && !sms.creditCard;

/// The number [sms] should be known by, given what [known] shows of the same
/// bank, or null to leave it as it is.
///
/// A shortened number joins the fuller one (`XX234` is `XX1234`). A debit
/// card's number joins the bank's one account when the bank has only one: the
/// card is how that account was paid, not another account. With several
/// accounts the card can't be placed, so it stays as it was.
String? canonicalAccountLast4(
  PendingSmsImport sms,
  Iterable<PendingSmsImport> known,
) {
  final last4 = sms.accountLast4;
  if (last4 == null) return null;
  final same = [
    for (final row in known)
      if (row.accountLast4 != null && sameSmsInstitution(row, sms)) row,
  ];
  final accounts = {
    for (final row in same)
      if (!isDebitCardMessage(row)) row.accountLast4!,
  };
  if (isDebitCardMessage(sms)) {
    final identities = {
      for (final number in accounts)
        fullerAccountSuffix(number, accounts) ?? number,
    };
    if (identities.length == 1) return identities.single;
  }
  return fullerAccountSuffix(
    last4,
    isDebitCardMessage(sms)
        ? {
            ...accounts,
            for (final row in same)
              if (isDebitCardMessage(row)) row.accountLast4!,
          }
        : accounts,
  );
}

/// [rows] with each shortened number or debit-card number replaced by the
/// account number the same bank also sends, so one account is not counted
/// twice.
List<PendingSmsImport> unifyAccountSuffixes(List<PendingSmsImport> rows) => [
  for (final row in rows)
    switch (canonicalAccountLast4(row, rows)) {
      // Carrying the account's number, the row stands for the account and
      // no longer for the card it was read from.
      final last4? when last4 != row.accountLast4 => PendingSmsImport(
        id: row.id,
        sender: row.sender,
        body: row.body,
        receivedAt: row.receivedAt,
        data: {...row.data, 'accountLast4': last4, 'channel': 'other'},
      ),
      _ => row,
    },
];

/// Infer only from explicit account identities in history, never from an
/// earlier inference. Keep the stored SMS candidate unchanged so new accounts
/// can make an old suggestion ambiguous again.
///
/// Many banks omit the number from some messages (most Federal Bank UPI
/// debits, for one). Such a message belongs to the bank's only known number;
/// with none known it is identified by the bank name alone; with several it
/// is ambiguous and must be assigned.
PendingSmsImport resolveSmsAccount(
  PendingSmsImport sms,
  List<PendingSmsImport> detected,
) {
  final last4 = sms.accountLast4;
  if (last4 != null) {
    final canonical = canonicalAccountLast4(sms, detected);
    return canonical == null || canonical == last4
        ? sms
        : _withAccountLast4(sms, canonical);
  }
  // A shop's or biller's SMS waits for the user, or the bank's SMS, to give
  // its account; it is never resolved by its sender's name.
  if (!sms.holdsMoney || sms.data.containsKey(otherAccountKey)) {
    return sms;
  }
  final suffixes = detected
      .where((row) => row.accountLast4 != null && sameSmsInstitution(row, sms))
      .map((row) => row.accountLast4!)
      .toSet();
  final data = {...sms.data}..remove('ambiguousAccount');
  if (suffixes.length == 1) data['accountLast4'] = suffixes.single;
  if (suffixes.length > 1) data['ambiguousAccount'] = true;
  return PendingSmsImport(
    id: sms.id,
    sender: sms.sender,
    body: sms.body,
    receivedAt: sms.receivedAt,
    data: data,
  );
}

class SmsImportRepository {
  SmsImportRepository(this.database);
  final AppDatabase database;

  /// Only one inbox page is staged at a time. A retry replaces any interrupted
  /// page; the scan checkpoint advances only after the entire inbox succeeds.
  Future<void> stagePage(List<InboxSms> page) => database.transaction(() async {
    await clearStagedPage();
    await database.batch((batch) {
      for (final row in page) {
        batch.customStatement(
          'INSERT INTO sms_scan_queue(id,sender,body,received_at) VALUES (?,?,?,?)',
          [
            row.id,
            row.sms.sender,
            row.sms.body,
            row.sms.receivedAt.millisecondsSinceEpoch,
          ],
        );
      }
    });
  });

  Future<List<InboxSms>> stagedPage() async => [
    for (final row
        in await database
            .customSelect('SELECT * FROM sms_scan_queue ORDER BY id')
            .get())
      InboxSms(
        row.read<int>('id'),
        BankSms(
          sender: row.read<String>('sender'),
          body: row.read<String>('body'),
          receivedAt: DateTime.fromMillisecondsSinceEpoch(
            row.read<int>('received_at'),
          ),
        ),
      ),
  ];

  Future<void> clearStagedPage() =>
      database.customStatement('DELETE FROM sms_scan_queue');
  Future<List<PendingSmsImport>> _detected() async => [
    for (final row
        in await database
            .customSelect(
              'SELECT * FROM sms_detected_accounts ORDER BY received_at DESC',
            )
            .get())
      PendingSmsImport(
        id: 'detected:${row.read<String>('bank_key')}',
        sender: '',
        body: '',
        data: {
          'amountMinor': 0,
          ...Map<String, dynamic>.from(
            jsonDecode(row.read<String>('data')) as Map,
          ),
        },
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('received_at'),
        ),
      ),
  ];
  Future<List<PendingSmsImport>> detectedAccounts({
    List<PendingSmsImport>? queued,
  }) async {
    final groups = <String, PendingSmsImport>{};
    final rows = unifyAccountSuffixes([
      ...await _detected(),
      ...(queued ?? const <PendingSmsImport>[]),
    ]);
    for (final row in rows) {
      // A bank seen only without a number is one account under its name; once
      // a number is known, unnumbered messages resolve to it instead.
      if (row.ambiguousAccount ||
          (row.accountLast4 == null &&
              rows.any(
                (other) =>
                    other.accountLast4 != null &&
                    sameSmsInstitution(other, row),
              ))) {
        continue;
      }
      final previous = groups[row.bankKey];
      if (previous == null || row.receivedAt.isAfter(previous.receivedAt)) {
        groups[row.bankKey] = row;
      }
    }
    return groups.values.toList();
  }

  Future<Map<String, int>> detectedAccountMessageCounts() async {
    final counts = <String, int>{};
    for (final row
        in await database
            .customSelect(
              "SELECT coalesce(r.candidate,i.candidate) AS candidate "
              "FROM sms_imports i LEFT JOIN sms_review r ON r.fingerprint=i.fingerprint "
              "WHERE i.status='pending'",
            )
            .get()) {
      final data = Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      );
      if (data['accountLast4'] == null) continue;
      counts.update(smsBankKey(data), (count) => count + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  Future<Map<String, int>> latestTotalCreditLimits() async => {
    for (final r
        in await database
            .customSelect(
              'SELECT bank_key,credit_limit_minor FROM sms_total_credit_limits',
            )
            .get())
      r.read<String>('bank_key'): r.read<int>('credit_limit_minor'),
  };

  /// Gives the accounts a debit card is used on their card icon: for each
  /// debit-card message seen, the account its number belongs to (the bank's
  /// one account, or the card's own when it stands alone).
  Future<void> markDebitCardAccounts() async {
    final detected = await _detected();
    final links = await accountLinks();
    final accounts = AccountRepository(database);
    for (final row in detected) {
      final last4 = row.accountLast4;
      if (last4 == null || !isDebitCardMessage(row)) continue;
      final number = canonicalAccountLast4(row, detected) ?? last4;
      final id = links[smsBankKey({...row.data, 'accountLast4': number})];
      if (id != null) await accounts.markDebitCard(id);
    }
  }

  Future<void> recordBalance(
    Map<String, dynamic> data,
    DateTime receivedAt,
  ) async {
    if (data['ambiguousAccount'] != true) {
      final key = PendingSmsImport(
        id: '',
        sender: '',
        body: '',
        data: data,
        receivedAt: receivedAt,
      ).bankKey;
      await database.customStatement(
        '''INSERT INTO sms_detected_accounts(bank_key,data,received_at) VALUES (?,?,?)
        ON CONFLICT(bank_key) DO UPDATE SET data=excluded.data,received_at=excluded.received_at WHERE excluded.received_at > sms_detected_accounts.received_at''',
        [key, jsonEncode(data), receivedAt.millisecondsSinceEpoch],
      );
      if (data['channel'] == 'card' && data['isCreditCard'] != true) {
        await markDebitCardAccounts();
      }
    }
    final balance = data['balanceMinor'] as int?;
    final limit = data['availableCreditLimitMinor'] as int?;
    final total = data['creditLimitMinor'] as int?;
    if (data['ambiguousAccount'] == true ||
        (balance == null && limit == null && total == null)) {
      return;
    }
    final key = PendingSmsImport(
      id: '',
      sender: '',
      body: '',
      data: data,
      receivedAt: receivedAt,
    ).bankKey;
    if (total != null && data['isCreditCard'] == true) {
      await database.customStatement(
        '''INSERT INTO sms_total_credit_limits(bank_key,credit_limit_minor,received_at) VALUES (?,?,?)
        ON CONFLICT(bank_key) DO UPDATE SET credit_limit_minor=excluded.credit_limit_minor,received_at=excluded.received_at
        WHERE excluded.received_at > sms_total_credit_limits.received_at''',
        [key, total, receivedAt.millisecondsSinceEpoch],
      );
    }
    if (limit != null && data['isCreditCard'] == true) {
      await database.customStatement(
        '''INSERT INTO sms_credit_limits(bank_key,available_limit_minor,received_at) VALUES (?,?,?)
        ON CONFLICT(bank_key) DO UPDATE SET available_limit_minor=excluded.available_limit_minor, received_at=excluded.received_at
        WHERE excluded.received_at > sms_credit_limits.received_at''',
        [key, limit, receivedAt.millisecondsSinceEpoch],
      );
    }
    if (data['isCreditCard'] == true) {
      for (final entry in {
        'credit_limit_minor': total,
        'available_limit_minor': limit,
      }.entries) {
        if (entry.value == null) continue;
        final atColumn = entry.key == 'credit_limit_minor'
            ? 'credit_limit_reported_at'
            : 'available_limit_reported_at';
        await database.customStatement(
          '''UPDATE accounts SET ${entry.key}=?, $atColumn=?
          WHERE id IN (SELECT account_id FROM sms_account_links WHERE bank_key=?) AND type='creditCard'
          AND ($atColumn IS NULL OR $atColumn < ?)''',
          [
            entry.value,
            receivedAt.millisecondsSinceEpoch,
            key,
            receivedAt.millisecondsSinceEpoch,
          ],
        );
      }
      return;
    }
    if (balance == null) return;
    await database.customStatement(
      '''INSERT INTO sms_balances(bank_key,balance_minor,received_at) VALUES (?,?,?)
      ON CONFLICT(bank_key) DO UPDATE SET balance_minor=excluded.balance_minor, received_at=excluded.received_at
      WHERE excluded.received_at > sms_balances.received_at''',
      [key, balance, receivedAt.millisecondsSinceEpoch],
    );
    // The account's own balance is left alone: a bank's figure that differs
    // from the ledger is offered to the user (see BalanceReportRepository).
  }

  Future<Map<String, int>> latestBalances({bool backfill = true}) async {
    // Backfill messages scanned before balance metadata was introduced.
    if (backfill) {
      for (final row
          in await database
              .customSelect(
                // A sample saved by hand is a marker, not a bank message.
                "SELECT candidate, body, sender, received_at FROM sms_imports WHERE fingerprint NOT LIKE 'sample:%' ORDER BY received_at DESC",
              )
              .get()) {
        final data = Map<String, dynamic>.from(
          jsonDecode(row.read<String>('candidate')) as Map,
        );
        final body = row.readNullable<String>('body');
        if (body != null) {
          data.addAll(smsMetadata(body, sender: row.read<String>('sender')));
        }
        final at = DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('received_at'),
        );
        await recordBalance(data, at);
      }
    }
    return {
      for (final row
          in await database
              .customSelect('SELECT bank_key, balance_minor FROM sms_balances')
              .get())
        row.read<String>('bank_key'): row.read<int>('balance_minor'),
    };
  }

  Future<Map<String, int>> accountLinks() async => {
    for (final row
        in await database.customSelect('SELECT * FROM sms_account_links').get())
      row.read<String>('bank_key'): row.read<int>('account_id'),
  };
  Future<Map<String, int>> latestCreditLimits() async => {
    for (final row
        in await database
            .customSelect(
              'SELECT bank_key, available_limit_minor FROM sms_credit_limits',
            )
            .get())
      row.read<String>('bank_key'): row.read<int>('available_limit_minor'),
  };

  /// Creates and links detected accounts in one commit; retries reuse links.
  Future<void> createDetectedAccounts(
    List<PendingSmsImport> groups, {
    Map<String, String> icons = const {},
    Map<String, int> openingBalances = const {},
    Map<String, int> availableLimits = const {},
    Map<String, int> creditLimits = const {},
  }) => database.transaction(() async {
    final links = await accountLinks();
    final accounts = AccountRepository(database);
    for (final sms in groups) {
      if (sms.ambiguousAccount) continue;
      final existingAccounts = await accounts.load();
      final linked = existingAccounts
          .where(
            (a) =>
                a.id == links[sms.bankKey] &&
                !a.isArchived &&
                a.currency == sms.currency,
          )
          .firstOrNull;
      final type = sms.creditCard ? AccountType.creditCard : AccountType.bank;
      final matches = existingAccounts
          .where(
            (a) =>
                !a.isArchived &&
                a.currency == sms.currency &&
                a.digits == currencyDigits(a.currency) &&
                a.type == type &&
                sms.accountLast4 != null &&
                a.lastDigits != null &&
                sms.accountLast4!.endsWith(a.lastDigits!) &&
                (a.institution == null || a.institution == sms.bankName) &&
                groups
                        .where(
                          (g) =>
                              g.currency == a.currency &&
                              g.creditCard ==
                                  (a.type == AccountType.creditCard) &&
                              g.accountLast4?.endsWith(a.lastDigits!) == true &&
                              (a.institution == null ||
                                  a.institution == g.bankName),
                        )
                        .length ==
                    1,
          )
          .toList();
      // The bank's only account without a number: an account created from
      // an unnumbered message, or one the user made by name.
      final named = existingAccounts
          .where(
            (a) =>
                !a.isArchived &&
                a.currency == sms.currency &&
                a.digits == currencyDigits(a.currency) &&
                a.type == type &&
                a.lastDigits == null &&
                a.institution?.toLowerCase() == sms.bankName.toLowerCase(),
          )
          .toList();
      final sameBank = existingAccounts
          .where(
            (a) =>
                !a.isArchived &&
                a.type == type &&
                a.currency == sms.currency &&
                a.digits == currencyDigits(a.currency) &&
                a.institution?.toLowerCase() == sms.bankName.toLowerCase(),
          )
          .toList();
      int id;
      if (linked != null || matches.length == 1) {
        id = linked?.id ?? matches.single.id;
      } else if (sms.accountLast4 == null && sameBank.length == 1) {
        id = sameBank.single.id;
      } else if (sms.accountLast4 != null && named.length == 1) {
        id = named.single.id;
      } else {
        final balance = await database
            .customSelect(
              'SELECT balance_minor,received_at FROM sms_balances WHERE bank_key=?',
              variables: [Variable(sms.bankKey)],
            )
            .getSingleOrNull();
        final available = await database
            .customSelect(
              'SELECT available_limit_minor,received_at FROM sms_credit_limits WHERE bank_key=?',
              variables: [Variable(sms.bankKey)],
            )
            .getSingleOrNull();
        final total = await database
            .customSelect(
              'SELECT credit_limit_minor,received_at FROM sms_total_credit_limits WHERE bank_key=?',
              variables: [Variable(sms.bankKey)],
            )
            .getSingleOrNull();
        final availableMinor =
            available?.read<int>('available_limit_minor') ??
            availableLimits[sms.bankKey];
        final totalMinor =
            total?.read<int>('credit_limit_minor') ?? creditLimits[sms.bankKey];
        final enteredAt = DateTime.now();
        final at = sms.creditCard
            ? available?.read<int>('received_at') ??
                  (availableMinor != null
                      ? enteredAt.millisecondsSinceEpoch
                      : null)
            : balance?.read<int>('received_at') ??
                  (openingBalances.containsKey(sms.bankKey)
                      ? DateTime.now().millisecondsSinceEpoch
                      : null);
        id = await accounts.save(
          name: sms.bankName.length > 40
              ? sms.bankName.substring(0, 40)
              : sms.bankName,
          currency: sms.currency,
          territory: sms.data['countryCode'] as String?,
          icon: icons[sms.bankKey],
          digits: sms.digits,
          type: type,
          lastDigits: sms.accountLast4,
          institution: sms.bankName,
          creditLimitMinor: totalMinor,
          availableCreditLimitMinor: availableMinor,
          openingBalance: sms.creditCard
              ? (totalMinor != null && availableMinor != null
                    ? availableMinor - totalMinor
                    : 0)
              : balance?.read<int>('balance_minor') ??
                    openingBalances[sms.bankKey] ??
                    0,
          balanceReportedAt: at == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(at),
          availableLimitReportedAt: available == null
              ? (availableMinor != null ? enteredAt : null)
              : DateTime.fromMillisecondsSinceEpoch(
                  available.read<int>('received_at'),
                ),
          creditLimitReportedAt: total == null
              ? (totalMinor != null ? enteredAt : null)
              : DateTime.fromMillisecondsSinceEpoch(
                  total.read<int>('received_at'),
                ),
        );
      }
      await linkAccount(sms, id);
      links[sms.bankKey] = id;
      await database.customStatement(
        'UPDATE accounts SET type=?,last_digits=COALESCE(last_digits,?),institution=COALESCE(institution,?) WHERE id=?',
        [type.name, sms.accountLast4, sms.bankName, id],
      );
      for (final entry in {
        'sms_balances': ('balance_minor', 'balanceMinor'),
        'sms_credit_limits': (
          'available_limit_minor',
          'availableCreditLimitMinor',
        ),
        'sms_total_credit_limits': ('credit_limit_minor', 'creditLimitMinor'),
      }.entries) {
        final report = await database
            .customSelect(
              'SELECT ${entry.value.$1},received_at FROM ${entry.key} WHERE bank_key=?',
              variables: [Variable(sms.bankKey)],
            )
            .getSingleOrNull();
        if (report == null) continue;
        await recordBalance(
          {
            'countryCode': sms.data['countryCode'],
            'bankName': sms.bankName,
            'currencyCode': sms.currency,
            'accountLast4': sms.accountLast4,
            'isCreditCard': sms.creditCard,
            entry.value.$2: report.read<int>(entry.value.$1),
          },
          DateTime.fromMillisecondsSinceEpoch(report.read<int>('received_at')),
        );
      }
    }
    await markDebitCardAccounts();
  });
  Future<void> linkAccount(PendingSmsImport sms, int accountId) async {
    await _account(accountId, sms.currency);
    await database.customStatement(
      'INSERT OR REPLACE INTO sms_account_links(bank_key,account_id) VALUES (?,?)',
      [sms.bankKey, accountId],
    );
  }

  /// Every message of [bankKey] (see [smsBankKey]) goes to [accountId] from
  /// now on, before any has arrived: for an app whose notifications carry no
  /// account number, the account the user chose while teaching it.
  Future<void> linkBank(String bankKey, int accountId, String currency) async {
    await _account(accountId, currency);
    await database.customStatement(
      'INSERT OR REPLACE INTO sms_account_links(bank_key,account_id) VALUES (?,?)',
      [bankKey, accountId],
    );
  }

  Future<List<PendingSmsImport>> pending({int? limit, int offset = 0}) async {
    final rows =
        (await database
                .customSelect(
                  "SELECT * FROM sms_imports WHERE status = 'pending' ORDER BY received_at DESC, fingerprint LIMIT ? OFFSET ?",
                  variables: [Variable(limit ?? -1), Variable(offset)],
                )
                .get())
            .map(
              (r) => PendingSmsImport(
                id: r.read<String>('fingerprint'),
                sender: r.read<String>('sender'),
                body: r.readNullable<String>('body') ?? '',
                data: {
                  ...Map<String, dynamic>.from(
                    jsonDecode(r.read<String>('candidate')) as Map,
                  ),
                  if (r.readNullable<String>('body') != null)
                    ...smsMetadata(
                      r.read<String>('body'),
                      sender: r.read<String>('sender'),
                    ),
                },
                receivedAt: DateTime.fromMillisecondsSinceEpoch(
                  r.read<int>('received_at'),
                ),
              ),
            )
            .toList();
    return rows;
  }

  /// Pending messages which have not yet been projected into the lightweight
  /// review index. Keeping this query here avoids decoding every historical
  /// candidate merely to discover that the review index is already current.
  Future<List<PendingSmsImport>> pendingWithoutReview({int limit = 200}) async {
    final rows = await database
        .customSelect(
          '''SELECT i.* FROM sms_imports i
          WHERE i.status='pending' AND NOT EXISTS (
            SELECT 1 FROM sms_review r WHERE r.fingerprint=i.fingerprint
          )
          ORDER BY i.received_at DESC,i.fingerprint LIMIT ?''',
          variables: [Variable(limit)],
        )
        .get();
    return [
      for (final r in rows)
        PendingSmsImport(
          id: r.read<String>('fingerprint'),
          sender: r.read<String>('sender'),
          body: r.readNullable<String>('body') ?? '',
          data: {
            ...Map<String, dynamic>.from(
              jsonDecode(r.read<String>('candidate')) as Map,
            ),
            if (r.readNullable<String>('body') != null)
              ...smsMetadata(
                r.read<String>('body'),
                sender: r.read<String>('sender'),
              ),
          },
          receivedAt: DateTime.fromMillisecondsSinceEpoch(
            r.read<int>('received_at'),
          ),
        ),
    ];
  }

  Future<List<String>> _repeatedNotificationIds(
    BankSms sms, {
    String? exclude,
  }) async {
    final identity = smsNotificationIdentity(sms);
    final key = sha256.convert(utf8.encode(identity)).toString();
    final at = sms.receivedAt.millisecondsSinceEpoch;
    final matches = <String>[];
    for (final row
        in await database
            .customSelect(
              'SELECT fingerprint,sender,body,candidate FROM sms_imports WHERE received_at BETWEEN ? AND ?',
              variables: [Variable(at - 30000), Variable(at + 30000)],
            )
            .get()) {
      final id = row.read<String>('fingerprint');
      if (id == exclude) continue;
      final data = jsonDecode(row.read<String>('candidate')) as Map;
      final body = row.readNullable<String>('body');
      if (data['notificationKey'] == key ||
          (body != null &&
              smsNotificationIdentity(
                    BankSms(
                      sender: row.read<String>('sender'),
                      body: body,
                      receivedAt: sms.receivedAt,
                    ),
                  ) ==
                  identity)) {
        matches.add(id);
      }
    }
    return matches;
  }

  /// Identifies an SMS by its text alone, spaces collapsed, for one the user
  /// already saved by hand before any rule could read it.
  static String sampleKey(String body) => sha256
      .convert(utf8.encode(body.trim().replaceAll(RegExp(r'\s+'), ' ')))
      .toString();

  /// The user saved a new rule's sample message by hand: when the inbox is
  /// read with the rule, that message joins this transaction instead of
  /// waiting for review again.
  Future<void> markSampleSaved({
    required String sender,
    required String body,
    required int transactionId,
  }) async {
    final key = sampleKey(body);
    await database.customInsert(
      "INSERT OR REPLACE INTO sms_imports (fingerprint,sender,body,received_at,candidate,rule_id,pack_version,status,transaction_id) VALUES (?,?,NULL,?,?,'sample',0,'imported',?)",
      variables: [
        Variable('sample:$key'),
        Variable(sender),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(jsonEncode({'sampleKey': key})),
        Variable(transactionId),
      ],
    );
  }

  /// The transaction a message was saved as by hand, from [markSampleSaved].
  Future<int?> _savedSample(String body) async =>
      (await database
              .customSelect(
                "SELECT transaction_id FROM sms_imports WHERE fingerprint = ? AND status = 'imported'",
                variables: [Variable('sample:${sampleKey(body)}')],
              )
              .getSingleOrNull())
          ?.readNullable<int>('transaction_id');

  /// How far apart a shop's SMS and the bank's SMS for one payment may be.
  /// A refund often reaches the bank days after the shop says it was sent; a
  /// payment the shop confirms is in the bank's SMS within the day.
  static const _creditTwinWindow = Duration(days: 7);
  static const _debitTwinWindow = Duration(days: 1);

  /// One payment often reaches the user twice: the shop says "Rs.216
  /// refunded" (or "payment of Rs.216 received") and the bank says "Rs.216
  /// credited to ••1234". The bank's message names the account, so it wins;
  /// the shop's is folded into it, lending its name and category.
  ///
  /// Only messages from different senders pair up, one from a sender that
  /// holds the money (a bank, card or wallet) and one from a sender that
  /// doesn't, with the same amount, currency and direction. Of several bank
  /// messages that could match, the nearest in time wins. Returns the
  /// fingerprint of the bank's message when [candidate] is the shop's and
  /// should be dropped. When [candidate] is the bank's, a waiting shop message
  /// is dropped here, its name and category carried over, and null returned.
  ///
  /// The bank may never send its SMS (a refund to a wallet or the original
  /// card): the shop's message then stays in review for the user to pick the
  /// account.
  /// A bank may send one payment as an SMS and as an app notification. When
  /// exactly one of two messages is a taught app's (see
  /// [isNotificationSender]) and the other has the same amount, currency and
  /// direction within two minutes, they are one payment: the fingerprint of
  /// the one that came first is returned, and the later one is dropped.
  Future<String?> _otherChannelTwin(
    String id,
    BankSms sms,
    Map<String, dynamic> candidate,
  ) async {
    // A corrected message is what the user said it is, not a twin.
    if (candidate[correctedDirectionKey] != null) return null;
    final app = isNotificationSender(sms.sender);
    final at = sms.receivedAt.millisecondsSinceEpoch;
    const window = Duration(minutes: 2);
    final rows = await database
        .customSelect(
          "SELECT fingerprint,sender,candidate FROM sms_imports WHERE received_at BETWEEN ? AND ? AND status IN ('pending','imported') AND fingerprint<>? ORDER BY abs(received_at-?)",
          variables: [
            Variable(at - window.inMilliseconds),
            Variable(at + window.inMilliseconds),
            Variable(id),
            Variable(at),
          ],
        )
        .get();
    for (final row in rows) {
      if (isNotificationSender(row.read<String>('sender')) == app) continue;
      final other = Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      );
      if (other['direction'] == candidate['direction'] &&
          other['amountMinor'] == candidate['amountMinor'] &&
          other['currencyCode'] == candidate['currencyCode'] &&
          other['mergedInto'] == null) {
        return row.read<String>('fingerprint');
      }
    }
    return null;
  }

  Future<String?> _reconcileTwin(
    String id,
    BankSms sms,
    Map<String, dynamic> candidate,
  ) async {
    // A corrected message is what the user said it is, not a twin.
    if (candidate[correctedDirectionKey] != null) return null;
    final credit = candidate['direction'] == 'credit';
    final holds = dataHoldsMoney(candidate);
    final at = sms.receivedAt.millisecondsSinceEpoch;
    final span = (credit ? _creditTwinWindow : _debitTwinWindow).inMilliseconds;
    // A shop's message comes before the bank's, or a little after.
    final from = holds ? at - span : at - _debitTwinWindow.inMilliseconds;
    final to = holds ? at + _debitTwinWindow.inMilliseconds : at + span;
    final rows = await database
        .customSelect(
          "SELECT fingerprint,sender,candidate,status,received_at FROM sms_imports WHERE received_at BETWEEN ? AND ? AND status IN ('pending','imported') AND fingerprint<>? ORDER BY abs(received_at-?)",
          variables: [Variable(from), Variable(to), Variable(id), Variable(at)],
        )
        .get();
    for (final row in rows) {
      if (row.read<String>('sender') == sms.sender) continue;
      final other = Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      );
      if (other['direction'] != candidate['direction'] ||
          other['amountMinor'] != candidate['amountMinor'] ||
          other['currencyCode'] != candidate['currencyCode'] ||
          other['mergedInto'] != null ||
          dataHoldsMoney(other) == holds) {
        continue;
      }
      final fingerprint = row.read<String>('fingerprint');
      final pending = row.read<String>('status') == 'pending';
      if (!holds) {
        // The bank's message came first; if it still waits for review, it
        // takes this one's name and category.
        if (pending && _lend(candidate, other)) {
          await database.customStatement(
            "UPDATE sms_imports SET candidate=? WHERE fingerprint=? AND status='pending'",
            [jsonEncode(other), fingerprint],
          );
        }
        return fingerprint;
      }
      // This is the bank's message; the shop's is still waiting.
      if (!pending) continue;
      _lend(other, candidate);
      await database.customStatement(
        "UPDATE sms_imports SET status='dismissed',body=NULL,candidate=json_set(candidate,'\$.mergedInto',?) WHERE fingerprint=? AND status='pending'",
        [id, fingerprint],
      );
      return null;
    }
    return null;
  }

  /// Gives the bank's message [bank] what the shop's [shop] knows better: who
  /// paid or was paid, and a category the bank's message lacks (a refund
  /// reads as a plain credit at the bank). True when [bank] changed.
  static bool _lend(Map<String, dynamic> shop, Map<String, dynamic> bank) {
    var changed = false;
    if (bank['counterparty'] == null && shop['counterparty'] != null) {
      bank['counterparty'] = shop['counterparty'];
      changed = true;
    }
    final category = shop['category'];
    final own = bank['category'];
    if (category is Map &&
        category['isFallback'] != true &&
        (own is! Map || own['isFallback'] == true)) {
      bank['category'] = category;
      changed = true;
    }
    return changed;
  }

  /// The one active account whose number ends in [last4], for a shop's SMS
  /// that names the bank account money went to or came from.
  Future<int?> _accountEndingIn(String last4, String currency) async {
    final matches = [
      for (final a in await AccountRepository(database).load())
        if (!a.isArchived &&
            a.currency == currency &&
            a.lastDigits != null &&
            last4.endsWith(a.lastDigits!))
          a.id,
    ];
    return matches.length == 1 ? matches.single : null;
  }

  /// Queues a parsed message. [role] is who sent it ([smsSenderRole]); a
  /// sender that holds no money of the user's never names, or makes, an
  /// account under its own name.
  Future<void> enqueue(
    BankSms sms,
    PortableParseResult result, {
    SmsSenderRole role = SmsSenderRole.bank,
  }) async {
    if (result.candidate == null || result.ruleId == null) return;
    final notificationKey = sha256
        .convert(utf8.encode(smsNotificationIdentity(sms)))
        .toString();
    if ((await _repeatedNotificationIds(sms)).isNotEmpty) return;
    final candidate = {
      'notificationKey': notificationKey,
      ...Map<String, dynamic>.from(result.toJson()['candidate'] as Map),
      ...smsMetadata(sms.body, sender: sms.sender),
    };
    candidate['amountMinor'] = smsAmountToApp(
      result.candidate!.amountMinor,
      result.candidate!.currencyCode,
    );
    applySenderRole(candidate, role);
    if (candidate[otherAccountKey] case final String last4) {
      final account = await _accountEndingIn(
        last4,
        candidate['currencyCode'] as String,
      );
      if (account != null) candidate['assignedAccountId'] = account;
    }
    // A correction the user approved for messages of this layout.
    if (normalizeRuleSender(sms.sender) case final sender?) {
      final corrections = SmsCorrectionRepository(database);
      if (await corrections.find(sender, result.ruleId!) case final c?) {
        await corrections.apply(candidate, c);
      }
    }
    await recordBalance(candidate, sms.receivedAt);
    final id = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              sms.sender,
              sms.body,
              sms.receivedAt.millisecondsSinceEpoch,
            ]),
          ),
        )
        .toString();
    if (await _savedSample(sms.body) case final transactionId?) {
      await database.customInsert(
        "INSERT OR IGNORE INTO sms_imports (fingerprint,sender,body,received_at,candidate,rule_id,pack_version,status,transaction_id) VALUES (?,?,NULL,?,?,?,?,'imported',?)",
        variables: [
          Variable(id),
          Variable(sms.sender),
          Variable(sms.receivedAt.millisecondsSinceEpoch),
          Variable(jsonEncode(candidate)),
          Variable(result.ruleId!),
          Variable(result.packVersion),
          Variable(transactionId),
        ],
      );
      return;
    }
    final channelTwin = await _otherChannelTwin(id, sms, candidate);
    if (channelTwin != null) {
      // The same payment already arrived the other way (SMS or an app's
      // notification): keep that one, and this one on record so a rescan
      // doesn't bring it back.
      await database.customInsert(
        "INSERT OR IGNORE INTO sms_imports (fingerprint,sender,body,received_at,candidate,rule_id,pack_version,status) VALUES (?,?,NULL,?,?,?,?,'dismissed')",
        variables: [
          Variable(id),
          Variable(sms.sender),
          Variable(sms.receivedAt.millisecondsSinceEpoch),
          Variable(jsonEncode({...candidate, 'mergedInto': channelTwin})),
          Variable(result.ruleId!),
          Variable(result.packVersion),
        ],
      );
      return;
    }
    final bankTwin = await _reconcileTwin(id, sms, candidate);
    if (bankTwin != null) {
      // The bank's own SMS for this credit is already here and wins: keep
      // this one out of the review queue, but on record so a rescan doesn't
      // bring it back.
      await database.customInsert(
        "INSERT OR IGNORE INTO sms_imports (fingerprint,sender,body,received_at,candidate,rule_id,pack_version,status) VALUES (?,?,NULL,?,?,?,?,'dismissed')",
        variables: [
          Variable(id),
          Variable(sms.sender),
          Variable(sms.receivedAt.millisecondsSinceEpoch),
          Variable(jsonEncode({...candidate, 'mergedInto': bankTwin})),
          Variable(result.ruleId!),
          Variable(result.packVersion),
        ],
      );
      return;
    }
    await database.customInsert(
      'INSERT OR IGNORE INTO sms_imports (fingerprint,sender,body,received_at,candidate,rule_id,pack_version) VALUES (?,?,?,?,?,?,?)',
      variables: [
        Variable(id),
        Variable(sms.sender),
        Variable(sms.body),
        Variable(sms.receivedAt.millisecondsSinceEpoch),
        Variable(jsonEncode(candidate)),
        Variable(result.ruleId!),
        Variable(result.packVersion),
      ],
    );
    // The bank's SMS for a payment already confirmed in the UPI flow.
    await joinSmsToUpiPayment(database, id);
  }

  Future<(bool, int)> state() async {
    final r = await database
        .customSelect('SELECT * FROM sms_import_state WHERE id=1')
        .getSingle();
    return (r.read<int>('enabled') == 1, r.read<int>('scanned_at'));
  }

  Future<void> enable(bool value) => database.customStatement(
    'UPDATE sms_import_state SET enabled=? WHERE id=1',
    [value ? 1 : 0],
  );
  Future<void> checkpoint(int value) => database.customStatement(
    'UPDATE sms_import_state SET scanned_at=? WHERE id=1',
    [value],
  );

  /// Sets aside every message still waiting: used when the person chooses to
  /// start fresh, so what the first scan found is not saved. The messages stay
  /// on record as dismissed, so a later scan does not queue them again.
  Future<void> dismissAllPending() => database.customStatement(
    "UPDATE sms_imports SET status='dismissed',body=NULL WHERE status='pending'",
  );
  Future<void> dismiss(String id) => database.transaction(() async {
    final original = await database
        .customSelect(
          "SELECT sender,body,received_at FROM sms_imports WHERE fingerprint=? AND status='pending'",
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (original == null) return;
    final message = BankSms(
      sender: original.read<String>('sender'),
      body: original.read<String>('body'),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        original.read<int>('received_at'),
      ),
    );
    final key = sha256
        .convert(utf8.encode(smsNotificationIdentity(message)))
        .toString();
    for (final duplicate in {id, ...await _repeatedNotificationIds(message)}) {
      await database.customStatement(
        "UPDATE sms_imports SET status='dismissed',body=NULL,candidate=json_set(candidate,'\$.notificationKey',?) WHERE fingerprint=? AND status='pending'",
        [key, duplicate],
      );
    }
  });

  /// Explicit per-message choice; never invent account digits or alter bank identity.
  Future<void> assignAccounts(Set<String> ids, int accountId) =>
      database.transaction(() async {
        final account = (await AccountRepository(database).load())
            .where(
              (a) =>
                  a.id == accountId &&
                  !a.isArchived &&
                  a.type != AccountType.cash,
            )
            .firstOrNull;
        if (account == null) {
          throw StateError('Choose an active bank account or card.');
        }
        for (final id in ids) {
          await _requirePending(id);
          final row = await database
              .customSelect(
                'SELECT candidate FROM sms_imports WHERE fingerprint=?',
                variables: [Variable(id)],
              )
              .getSingle();
          final data = jsonDecode(row.read<String>('candidate')) as Map;
          if (data['currencyCode'] != account.currency ||
              account.digits != 2 ||
              (data['isCreditCard'] == true &&
                  account.type != AccountType.creditCard)) {
            throw StateError(
              'The selected account must match the currency and account type.',
            );
          }
          await database.customStatement(
            "UPDATE sms_imports SET candidate=json_set(candidate,'\$.assignedAccountId',?) WHERE fingerprint=?",
            [accountId, id],
          );
          await database.customStatement(
            'DELETE FROM sms_review WHERE fingerprint=?',
            [id],
          );
        }
      });

  Future<void> _requirePending(String id) async {
    final r = await database
        .customSelect(
          "SELECT fingerprint FROM sms_imports WHERE fingerprint=? AND status='pending'",
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (r == null) throw StateError('This message has already been reviewed.');
  }

  Future<void> _account(int id, String currency) async {
    final r = await database
        .customSelect(
          'SELECT id FROM accounts WHERE id=? AND currency=? AND digits=2 AND archived_at IS NULL',
          variables: [Variable(id), Variable(currency)],
        )
        .getSingleOrNull();
    if (r == null) throw StateError('Choose an active account in $currency.');
  }

  /// The transaction a saved message became.
  Future<int?> transactionOf(String id) async =>
      (await database
              .customSelect(
                'SELECT transaction_id FROM sms_imports WHERE fingerprint=?',
                variables: [Variable(id)],
              )
              .getSingleOrNull())
          ?.readNullable<int>('transaction_id');

  /// The balance update and queue consumption commit together, including on retries.
  Future<void> save(
    PendingSmsImport sms, {
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    int? categoryId,
    int? toAccountId,
    int? toAmountMinor,
    String? title,
    String? note,
    required DateTime date,
  }) => database.transaction(() async {
    await _requirePending(sms.id);
    final notification = BankSms(
      sender: sms.sender,
      body: sms.body,
      receivedAt: sms.receivedAt,
    );
    final repeatedIds = await _repeatedNotificationIds(
      notification,
      exclude: sms.id,
    );
    if (sms.requiresTransfer && type != TransactionType.transfer) {
      throw StateError('This movement must be recorded as a transfer.');
    }
    await _account(accountId, sms.currency);
    final ledger = TransactionRepository(database);
    int? transactionId;
    if (type == TransactionType.transfer) {
      await _account(toAccountId!, sms.currency);
      if (sms.isAtmCashMovement) {
        final cashId = sms.isAtmDeposit ? accountId : toAccountId;
        final bankId = sms.isAtmDeposit ? toAccountId : accountId;
        final accounts = await database
            .customSelect(
              'SELECT id,type FROM accounts WHERE id IN (?,?)',
              variables: [Variable(accountId), Variable(toAccountId)],
            )
            .get();
        if (accounts
                    .singleWhere((a) => a.read<int>('id') == cashId)
                    .read<String>('type') !=
                AccountType.cash.name ||
            accounts
                    .singleWhere((a) => a.read<int>('id') == bankId)
                    .read<String>('type') !=
                AccountType.bank.name) {
          throw StateError(
            'Choose a bank account and a cash account for this ATM transfer.',
          );
        }
      }
      if (sms.isCreditCardRepayment) {
        final destination = await database
            .customSelect(
              'SELECT type FROM accounts WHERE id=?',
              variables: [Variable(toAccountId)],
            )
            .getSingle();
        if (destination.read<String>('type') != AccountType.creditCard.name) {
          throw StateError(
            'Choose a credit card as the repayment destination.',
          );
        }
      }
      transactionId = await ledger.addTransfer(
        amountMinor: amountMinor,
        fromAccountId: accountId,
        toAccountId: toAccountId,
        toAmountMinor: toAmountMinor,
        note: note ?? sms.originalSmsNote,
        date: date,
      );
    } else {
      final draftName = draftFoodCategories[categoryId];
      if (draftName != null) {
        if (type != TransactionType.expense ||
            foodDeliveryMerchant(sms.body) != draftName) {
          throw StateError('Choose a matching category.');
        }
        final repository = CategoryRepository(database);
        final categories = await repository.load();
        final parent = categories
            .where(
              (c) =>
                  c.type == CategoryType.expense &&
                  c.parentId == null &&
                  ['food', 'food & beverage'].contains(c.name.toLowerCase()),
            )
            .firstOrNull;
        if (parent == null) throw StateError('Choose a Food category.');
        var child = categories
            .where(
              (c) =>
                  c.parentId == parent.id &&
                  c.name.toLowerCase() == draftName.toLowerCase(),
            )
            .firstOrNull;
        if (child == null) {
          await repository.save(
            name: draftName,
            type: CategoryType.expense,
            parentId: parent.id,
            icon: brandIconKey(draftName.toLowerCase()),
          );
          child = (await repository.load()).firstWhere(
            (c) => c.parentId == parent.id && c.name == draftName,
          );
        }
        categoryId = child.id;
      }
      final category = await database
          .customSelect(
            'SELECT id FROM categories WHERE id=? AND type=?',
            variables: [Variable(categoryId!), Variable(type.storageValue)],
          )
          .getSingleOrNull();
      if (category == null) throw StateError('Choose a matching category.');
      transactionId = await ledger.addExpenseOrIncome(
        type: type,
        amountMinor: amountMinor,
        accountId: accountId,
        categoryId: categoryId!,
        title: title,
        note: note ?? sms.originalSmsNote,
        date: date,
      );
    }
    await database.customStatement(
      "UPDATE sms_imports SET status='imported', body=NULL, transaction_id=?, candidate=? WHERE fingerprint=?",
      [
        transactionId,
        jsonEncode({
          ...sms.data,
          'notificationKey': sha256
              .convert(utf8.encode(smsNotificationIdentity(notification)))
              .toString(),
        }),
        sms.id,
      ],
    );
    for (final id in repeatedIds) {
      await database.customStatement(
        "UPDATE sms_imports SET status='imported',body=NULL,transaction_id=? WHERE fingerprint=? AND status='pending'",
        [transactionId, id],
      );
    }
    // This history is already included in a reported balance used at creation.
    Future<void> compensateReportedBalance(int id, int effect) async {
      final account = await database
          .customSelect(
            'SELECT balance_reported_at FROM accounts WHERE id=?',
            variables: [Variable(id)],
          )
          .getSingle();
      final reportedAt = account.readNullable<int>('balance_reported_at');
      if (reportedAt != null &&
          sms.receivedAt.millisecondsSinceEpoch <= reportedAt) {
        await database.customStatement(
          'UPDATE accounts SET balance_minor=balance_minor-? WHERE id=?',
          [effect, id],
        );
      }
    }

    await compensateReportedBalance(
      accountId,
      type == TransactionType.income ? amountMinor : -amountMinor,
    );
    if (type == TransactionType.transfer) {
      await compensateReportedBalance(
        toAccountId!,
        toAmountMinor ?? amountMinor,
      );
    } else {
      // A transfer between the user's own accounts arrives as two SMS, one
      // from each bank, quoting one UPI reference: with both saved, the
      // expense and income are that transfer.
      await StatementImportRepository(database).linkRecordedTransfers(date);
    }
  });
}
