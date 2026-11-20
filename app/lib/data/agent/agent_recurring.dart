import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../../domain/account.dart' show parseAccountAmount;
import '../../domain/currency_digits.dart';
import '../../domain/recurring_payment.dart';
import '../../domain/recurring_suggestions.dart';
import '../../domain/service_icon.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import '../ledger_match.dart';
import '../repositories/sms_import_repository.dart';
import 'agent_sms_saver.dart';

/// Where one payment of a pattern was seen.
enum RecurringSource { saved, needsReview, unparsed }

/// One payment, wherever it sits: a saved transaction, a bank message
/// waiting in SMS review, or one no rule reads.
class RecurringHit {
  const RecurringHit({
    required this.source,
    required this.date,
    required this.amountMinor,
    required this.currency,
    required this.title,
    this.accountId,
    this.transactionId,
    this.smsId,
  });
  final RecurringSource source;
  final DateTime date;
  final int amountMinor;
  final String currency, title;

  /// The account it is (or, for a message, will be) in, when known.
  final int? accountId;
  final int? transactionId;

  /// For a message: its fingerprint waiting for review, or the short id of
  /// an unparsed one.
  final String? smsId;
}

/// Payments that look like they repeat: the same payee, about the same
/// amount, on a steady cycle. Read from the ledger (every bank SMS already
/// saved), the SMS review queue and the inbox's unparsed bank SMS, so an AI
/// app can ask the user which to track.
class AgentRecurringFinder {
  AgentRecurringFinder(this.database);
  final AppDatabase database;

  /// How far each cycle's payments may drift from it and still count.
  static const _slack = {
    BillingCycle.weekly: 2,
    BillingCycle.monthly: 6,
    BillingCycle.quarterly: 12,
    BillingCycle.yearly: 20,
  };

  /// Fewest payments that make a pattern. A known subscription needs one
  /// fewer monthly: two Netflix charges a month apart already say enough.
  static const _fewest = {
    BillingCycle.weekly: 4,
    BillingCycle.monthly: 3,
    BillingCycle.quarterly: 2,
    BillingCycle.yearly: 2,
  };

  static final _vpa = RegExp(
    r'(?<![\w.])[a-z0-9][\w.\-]{1,}@[a-z]{2,}(?![\w.])',
    caseSensitive: false,
  );
  static final _upiLine = RegExp(r'UPI • (\S+) • Payment confirmed by you');
  static final _noise = RegExp(
    r'\b(?:upi|imps|neft|rtgs|payment|paid|to|by|from|via|ref|txn|pvt|ltd|'
    r'private|limited|india|in|the|and|p2a|p2m|vpa|mr|mrs|ms|on|at|for|a|c|'
    r'ac|acct|account|your|has|been|is|was|debited|credited|sent|received)\b',
  );
  static final _rupees = RegExp(
    r'(?:rs\.?|inr|₹)\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
  static final _debit = RegExp(
    r'\b(?:debited|paid|sent|spent|deducted|withdrawn|purchase|txn of)\b',
    caseSensitive: false,
  );
  static final _credit = RegExp(
    r'\b(?:credited|received|deposited|refund)\b',
    caseSensitive: false,
  );
  static final _party = RegExp(
    r'\b(?:to|at|towards|from|by)\s+([A-Za-z][A-Za-z .&-]{2,40})',
    caseSensitive: false,
  );

  /// Candidates from the last [months], strongest first. [income] includes
  /// money that comes in on a schedule, such as rent received. [unparsed] are
  /// the inbox's bank SMS no rule reads.
  Future<List<RecurringCandidate>> find({
    int months = 12,
    bool income = true,
    List<LoanSms> unparsed = const [],
  }) async {
    final now = DateTime.now();
    final today = dateOnly(now);
    final since = DateTime(now.year, now.month - months, now.day);
    final accounts = {
      for (final a
          in await database
              .customSelect(
                'SELECT id, name, currency, digits FROM accounts '
                'WHERE archived_at IS NULL',
              )
              .get())
        a.read<int>('id'): (
          name: a.read<String>('name'),
          currency: a.read<String>('currency'),
          digits: a.read<int>('digits'),
        ),
    };
    final tracked = [
      for (final r
          in await database
              .customSelect('SELECT name, incoming FROM recurring_payments')
              .get())
        (
          name: _key(r.read<String>('name')),
          incoming: r.read<int>('incoming') == 1,
        ),
    ];

    // Group by payee: a UPI ID when there is one, else the cleaned name.
    final groups = <String, List<RecurringHit>>{};
    final names = <String, Map<String, int>>{};
    final addresses = <String, String>{};
    void add(RecurringHit hit, bool incoming, String text) {
      if (incoming && !income) return;
      final upi =
          _upiLine.firstMatch(text)?.group(1)?.toLowerCase() ??
          _vpa.firstMatch(text)?.group(0)?.toLowerCase();
      final payee = upi ?? _key(hit.title);
      if (payee.isEmpty) return;
      final key = '${incoming ? 'in' : 'out'}|${hit.currency}|$payee';
      (groups[key] ??= []).add(hit);
      if (hit.title.trim().isNotEmpty) {
        final seen = names[key] ??= {};
        seen[hit.title.trim()] = (seen[hit.title.trim()] ?? 0) + 1;
      }
      if (upi != null) addresses[key] = upi;
    }

    // Saved transactions.
    for (final t in await ledgerBetween(database, since, now)) {
      final money = accounts[t.accountId];
      if (!t.free ||
          money == null ||
          (t.type != TransactionType.expense &&
              t.type != TransactionType.income)) {
        continue;
      }
      add(
        RecurringHit(
          source: RecurringSource.saved,
          date: t.date,
          amountMinor: t.amountMinor,
          currency: money.currency,
          title: (t.title ?? '').trim(),
          accountId: t.accountId,
          transactionId: t.id,
        ),
        t.type == TransactionType.income,
        t.references,
      );
    }

    // Waiting in SMS review.
    for (final row
        in await database
            .customSelect(
              '''SELECT i.fingerprint, i.sender, i.body, i.received_at,
              i.candidate, r.account_id
          FROM sms_imports i
          LEFT JOIN sms_review r ON r.fingerprint = i.fingerprint
          WHERE i.status = 'pending' AND i.received_at >= ?''',
              variables: [Variable(since.millisecondsSinceEpoch)],
            )
            .get()) {
      final sms = PendingSmsImport(
        id: row.read<String>('fingerprint'),
        sender: row.read<String>('sender'),
        body: row.readNullable<String>('body') ?? '',
        data: Map<String, dynamic>.from(
          jsonDecode(row.read<String>('candidate')) as Map,
        ),
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('received_at'),
        ),
      );
      if (sms.requiresTransfer || sms.data['amountMinor'] is! int) continue;
      final into =
          row.readNullable<int>('account_id') ??
          sms.data['assignedAccountId'] as int?;
      add(
        RecurringHit(
          source: RecurringSource.needsReview,
          date: sms.receivedAt,
          amountMinor: sms.amountMinor,
          currency: sms.currency,
          title: sms.title,
          accountId: accounts[into]?.currency == sms.currency ? into : null,
          smsId: sms.id,
        ),
        sms.credit,
        '${sms.body} ${sms.data['counterparty'] ?? ''}',
      );
    }

    // Unparsed: the amount and direction read from the words themselves.
    for (final sms in unparsed) {
      if (sms.receivedAt.isBefore(since)) continue;
      final amount = switch (_rupees.firstMatch(sms.body)?.group(1)) {
        final text? => parseAccountAmount(text.replaceAll(',', ''), 2),
        null => null,
      };
      final debit = _debit.hasMatch(sms.body);
      final credit = _credit.hasMatch(sms.body);
      if (amount == null || amount <= 0 || debit == credit) continue;
      final party = _party.firstMatch(sms.body)?.group(1)?.trim() ?? '';
      add(
        RecurringHit(
          source: RecurringSource.unparsed,
          date: sms.receivedAt,
          amountMinor: amount,
          currency: 'INR',
          title: party,
          smsId: sms.ref,
        ),
        credit,
        sms.body,
      );
    }

    final found = <RecurringCandidate>[];
    for (final MapEntry(:key, :value) in groups.entries) {
      final incoming = key.startsWith('in|');
      for (final cluster in _byAmount(value)) {
        final candidate = _pattern(
          cluster,
          incoming: incoming,
          name: _bestName(names[key], addresses[key]),
          address: addresses[key],
          today: today,
        );
        if (candidate == null) continue;
        if (accounts[candidate.accountId] case final account?) {
          candidate.account = account.name;
          candidate.digits = account.digits;
        } else {
          candidate.digits = currencyDigits(candidate.currency);
        }
        candidate.alreadyTracked = tracked.any(
          (r) =>
              r.incoming == incoming &&
              r.name.isNotEmpty &&
              (r.name == _key(candidate.name) ||
                  _key(candidate.name).contains(r.name) ||
                  r.name.contains(_key(candidate.name))),
        );
        found.add(candidate);
      }
    }
    found.sort((a, b) {
      final byConfidence = a.confidence.index.compareTo(b.confidence.index);
      if (byConfidence != 0) return byConfidence;
      return b.cycle
          .monthly(b.amountMinor)
          .compareTo(a.cycle.monthly(a.amountMinor));
    });
    return found;
  }

  /// The payee's name compared loosely: lower case, letters only, without
  /// the words every bank adds ("UPI", "payment to").
  static String _key(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z ]'), ' ')
      .replaceAll(_noise, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// The name it was seen under most often, else its UPI ID.
  static String _bestName(Map<String, int>? titles, String? address) {
    if (titles != null && titles.isNotEmpty) {
      final best = titles.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final name = best.first.key;
      return name.length <= 40 ? name : name.substring(0, 40).trim();
    }
    return address ?? 'Payment';
  }

  /// Payments of about the same amount: within 5% of the cluster's smallest,
  /// so a bill that moves a little stays one pattern.
  static List<List<RecurringHit>> _byAmount(List<RecurringHit> all) {
    final sorted = [...all]
      ..sort((a, b) => a.amountMinor.compareTo(b.amountMinor));
    final clusters = <List<RecurringHit>>[];
    for (final t in sorted) {
      final last = clusters.lastOrNull;
      if (last != null && t.amountMinor <= last.first.amountMinor * 1.05) {
        last.add(t);
      } else {
        clusters.add([t]);
      }
    }
    return clusters;
  }

  RecurringCandidate? _pattern(
    List<RecurringHit> cluster, {
    required bool incoming,
    required String name,
    required String? address,
    required DateTime today,
  }) {
    // One payment a day at most: a retried charge isn't a second renewal,
    // and a saved transaction beats a message about the same payment.
    final byDay = <DateTime, RecurringHit>{};
    for (final t
        in cluster..sort((a, b) {
          final byDate = a.date.compareTo(b.date);
          return byDate != 0
              ? byDate
              : a.source.index.compareTo(b.source.index);
        })) {
      byDay.putIfAbsent(dateOnly(t.date), () => t);
    }
    final payments = byDay.values.toList();
    if (payments.length < 2) return null;
    final gaps = [
      for (var i = 1; i < payments.length; i++)
        dateOnly(payments[i].date)
            .difference(dateOnly(payments[i - 1].date))
            .inDays,
    ];
    final median = ([...gaps]..sort())[gaps.length ~/ 2];
    final cycle = switch (median) {
      >= 6 && <= 8 => BillingCycle.weekly,
      >= 25 && <= 35 => BillingCycle.monthly,
      >= 80 && <= 100 => BillingCycle.quarterly,
      >= 350 && <= 380 => BillingCycle.yearly,
      _ => null,
    };
    if (cycle == null) return null;
    final known = serviceIcon(name) != null;
    final fewest =
        _fewest[cycle]! - (known && cycle == BillingCycle.monthly ? 1 : 0);
    if (payments.length < fewest) return null;
    final length = switch (cycle) {
      BillingCycle.weekly => 7,
      BillingCycle.monthly => 30,
      BillingCycle.quarterly => 91,
      BillingCycle.yearly => 365,
    };
    final steady =
        gaps.where((g) => (g - length).abs() <= _slack[cycle]!).length /
        gaps.length;
    if (steady < 0.6) return null;

    final last = payments.last;
    final day = last.date.day;
    var next = cycle.after(dateOnly(last.date), day);
    // Overdue by more than a cycle and its slack: it has likely stopped.
    final overdue = today.difference(next).inDays;
    final stopped = overdue > length + _slack[cycle]!;
    if (overdue > 2 * length + _slack[cycle]!) return null;
    while (next.isBefore(today)) {
      next = cycle.after(next, day);
    }
    final exact = payments.every((t) => t.amountMinor == last.amountMinor);
    final suggested = suggestRecurring(name, incoming: incoming);
    final confidence =
        steady >= 0.8 && exact && payments.length >= fewest + 2 || known
        ? RecurringConfidence.high
        : steady >= 0.8 && payments.length > fewest
        ? RecurringConfidence.medium
        : RecurringConfidence.low;
    final accounts = <int, int>{};
    for (final t in payments) {
      if (t.accountId case final id?) accounts[id] = (accounts[id] ?? 0) + 1;
    }
    final account = accounts.isEmpty
        ? null
        : (accounts.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .first
              .key;
    return RecurringCandidate(
      name: name,
      incoming: incoming,
      cycle: cycle,
      amountMinor: last.amountMinor,
      currency: last.currency,
      exact: exact,
      accountId: account,
      nextDue: next,
      payments: payments,
      confidence: stopped ? RecurringConfidence.low : confidence,
      stopped: stopped,
      knownService: known,
      kind: known
          ? 'subscription'
          : suggested?.category != null
          ? (suggested!.category!.toLowerCase().contains('rent')
                ? 'rent'
                : 'bill')
          : address != null && RegExp(r'^\d{10}@').hasMatch(address)
          ? 'person'
          : 'other',
      category: suggested?.category,
    );
  }
}

enum RecurringConfidence { high, medium, low }

/// One payment pattern, with every payment seen of it.
class RecurringCandidate {
  RecurringCandidate({
    required this.name,
    required this.incoming,
    required this.cycle,
    required this.amountMinor,
    required this.currency,
    required this.exact,
    required this.accountId,
    required this.nextDue,
    required this.payments,
    required this.confidence,
    required this.stopped,
    required this.knownService,
    required this.kind,
    required this.category,
  });
  final String name, kind, currency;
  final bool incoming, exact, stopped, knownService;
  final BillingCycle cycle;

  /// The latest payment's amount.
  final int amountMinor;

  /// The account most of its payments are in; null when none of them says.
  final int? accountId;
  final DateTime nextDue;
  final List<RecurringHit> payments;
  final RecurringConfidence confidence;

  /// The category its name suggests, as the default categories spell it.
  final String? category;
  String account = '';
  int digits = 2;

  /// Something with a like name is already set up.
  bool alreadyTracked = false;

  Iterable<RecurringHit> from(RecurringSource source) =>
      payments.where((p) => p.source == source);
}
