import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:intl/intl.dart';

import '../../domain/account.dart';
import '../../domain/app_icons.dart';
import '../../domain/bank_institution_icon.dart';
import '../../domain/debt.dart';
import '../../domain/loan.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import '../ledger_match.dart';
import '../repositories/account_repository.dart';
import '../repositories/debt_repository.dart';
import '../repositories/loan_repository.dart';
import '../repositories/sms_import_repository.dart';
import '../repositories/transaction_repository.dart';
import 'agent_sms_saver.dart';
import 'agent_suggestion_repository.dart';

/// One payment as a lender's statement lists it. [amount] is everything that
/// was paid, with [fee] and [interest] inside it.
class LoanPaymentInput {
  const LoanPaymentInput({
    required this.date,
    required this.amount,
    this.interest,
    this.fee,
    this.transactionId,
    this.notInLedger = false,
    this.partPayment = false,
    this.smsId,
    this.unparsed,
  });
  final DateTime date;
  final String amount;
  final String? interest, fee;

  /// Which ledger transaction it is, when the app's own guess is wrong.
  final int? transactionId;

  /// It is in the ledger under no transaction, whatever looks like it.
  final bool notInLedger;

  /// Extra money towards the principal, not a monthly instalment.
  final bool partPayment;

  /// The bank message that is this payment, as related_sms listed it: one
  /// waiting for review, or (with [unparsed]) one no rule reads.
  final String? smsId;
  final LoanSms? unparsed;
}

/// What an AI app read off a loan statement.
class LoanInput {
  const LoanInput({
    required this.lender,
    required this.amount,
    required this.startDate,
    this.asset,
    this.assetIcon,
    this.lenderIcon,
    this.kind = LoanKind.other,
    this.rate,
    this.months = 0,
    this.emi,
    this.firstDue,
    this.endDate,
    this.outstanding,
    this.unpaidInterest,
    this.asOf,
    this.paidFromAccountId,
    this.paidFromLastDigits,
    this.receivedInAccountId,
    this.charges,
    this.chargesDeducted = false,
    this.payments = const [],
    this.addMissingToAccount = false,
    this.reason,
  });
  final String lender, amount;
  final DateTime startDate;
  final String? asset, assetIcon, lenderIcon;
  final LoanKind kind;

  /// A year, in percent. Null when the statement doesn't say.
  final double? rate;
  final int months;
  final String? emi, outstanding, unpaidInterest, charges;
  final DateTime? firstDue, endDate, asOf;
  final int? paidFromAccountId, receivedInAccountId;
  final String? paidFromLastDigits;
  final bool chargesDeducted, addMissingToAccount;
  final List<LoanPaymentInput> payments;
  final String? reason;
}

/// A suggestion, with what the AI app should hear about how it was worked out.
class LoanPlan {
  const LoanPlan(this.draft, this.report);
  final AgentSuggestionDraft draft;
  final Map<String, Object?> report;
}

/// A bank message waiting for review that is one of a loan's payments, and
/// the account approving saves it into.
typedef _WaitingSms = ({String id, int account, String title});

/// Payments allowed between a statement's date and the ledger's.
const _matchDays = 3;

/// Turns what was read off a statement into a suggestion, holding every
/// payment against the ledger so a loan never records money twice. Applying
/// and undoing go through the same repositories the loan screens use.
class AgentLoans {
  AgentLoans(this.database);
  final AppDatabase database;

  // ── Loans. ──

  /// [unparsed] are the inbox's bank messages no rule reads, searched with
  /// the ledger and the review queue for this loan's other payments.
  Future<LoanPlan> prepareLoan(
    LoanInput input, {
    List<LoanSms> unparsed = const [],
  }) async {
    final lender = input.lender.trim();
    final active = (await AccountRepository(
      database,
    ).load()).where((a) => !a.isArchived).toList();
    Account? chosen;
    if (input.paidFromAccountId case final id?) {
      chosen = active.where((a) => a.id == id).firstOrNull;
      if (chosen == null) {
        throw ArgumentError('Account $id isn’t an active account.');
      }
    } else if (input.paidFromLastDigits case final digits?) {
      chosen = active
          .where(
            (a) =>
                (a.lastDigits ?? '').isNotEmpty &&
                digits.endsWith(a.lastDigits!),
          )
          .firstOrNull;
    }
    var plan = await _plan(input, lender, chosen);
    if (chosen == null) {
      // Nothing named the account: the payments themselves do.
      final seen = <int, int>{};
      for (final t in plan.matched.whereType<LedgerCandidate>()) {
        seen[t.accountId] = (seen[t.accountId] ?? 0) + 1;
      }
      final likely = seen.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final banks = active.where((a) => a.type != AccountType.cash).toList();
      chosen = likely.isNotEmpty
          ? active.where((a) => a.id == likely.first.key).firstOrNull
          : banks.length == 1
          ? banks.single
          : null;
      if (chosen == null) {
        throw ArgumentError(
          'Say which account pays this loan: give paid_from_account_id from '
          'list_accounts.',
        );
      }
      plan = await _plan(input, lender, chosen);
    }
    return _describe(input, lender, chosen, active, plan, unparsed);
  }

  Future<_Plan> _plan(LoanInput input, String lender, Account? account) async {
    final digits = account?.digits ?? 2;
    int money(String? text, String name) {
      final minor = text == null
          ? 0
          : parseAccountAmount(text.replaceAll(',', ''), digits);
      if (minor == null || minor < 0) {
        throw ArgumentError('$name must be an amount like 2150.00.');
      }
      return minor;
    }

    final principal = money(input.amount, 'amount');
    final payments = [...input.payments]
      ..sort((a, b) => a.date.compareTo(b.date));
    final today = _dayOnly(DateTime.now());
    for (final p in payments) {
      if (_dayOnly(p.date).isBefore(_dayOnly(input.startDate)) ||
          _dayOnly(p.date).isAfter(today)) {
        throw ArgumentError(
          'A payment on ${_iso(p.date)} is outside the loan: use dates from '
          'start_date to today.',
        );
      }
    }
    final paid = [for (final p in payments) money(p.amount, 'A payment')];
    final fees = [for (final p in payments) money(p.fee, 'A fee')];
    for (final (i, amount) in paid.indexed) {
      if (amount - fees[i] <= 0) {
        throw ArgumentError('Each payment must be more than its fee.');
      }
    }
    final outstanding = input.outstanding == null
        ? null
        : money(input.outstanding, 'outstanding');
    if (outstanding != null && outstanding > principal) {
      throw ArgumentError('outstanding can’t be more than amount.');
    }
    final interests = _interest(
      input,
      payments,
      paid,
      fees,
      principal,
      outstanding,
      money,
    );
    final repaid = [
      for (var i = 0; i < paid.length; i++) paid[i] - fees[i] - interests[i],
    ];
    final cleared = principal - repaid.fold<int>(0, (n, p) => n + p);
    if (payments.isNotEmpty && outstanding != null && cleared != outstanding) {
      throw ArgumentError(
        'These payments leave ${_plain(cleared, digits)} of the principal, '
        'but outstanding is ${_plain(outstanding, digits)}. Give the fee '
        'and interest inside each payment (a first instalment often includes '
        'fees), and every payment from the start. If the statement doesn’t '
        'list them all, send no payments and only outstanding.',
      );
    }
    final snapshot =
        payments.isEmpty && outstanding != null && outstanding < principal;
    final left = snapshot ? outstanding : cleared;

    // Hold it against the ledger.
    final dates = [input.startDate, ...payments.map((p) => p.date)];
    const margin = Duration(days: _matchDays);
    final ledger = await ledgerBetween(
      database,
      dates.reduce((a, b) => a.isBefore(b) ? a : b).subtract(margin),
      dates
          .reduce((a, b) => a.isAfter(b) ? a : b)
          .add(margin + const Duration(days: 1)),
    );
    final currencies = {
      for (final a in await AccountRepository(database).load())
        a.id: (a.currency, a.digits),
    };
    bool sameMoney(LedgerCandidate t) =>
        account == null ||
        currencies[t.accountId] == (account.currency, account.digits);
    final word = lender.split(RegExp(r'\s+')).first;
    bool preferred(LedgerCandidate t) =>
        t.accountId == account?.id || t.mentions(word);
    final claimed = <int>{};
    final matched = <LedgerCandidate?>[];
    for (final (i, p) in payments.indexed) {
      LedgerCandidate? match;
      if (p.transactionId case final id?) {
        match = await _named(id, paid[i], TransactionType.expense, sameMoney);
      } else if (!p.notInLedger && p.smsId == null) {
        match = closestInLedger(
          ledger,
          amountMinor: paid[i],
          date: p.date,
          claimed: claimed,
          near: withinDays(_matchDays),
          preferred: preferred,
          fits: (t) =>
              t.free && t.type == TransactionType.expense && sameMoney(t),
        );
      }
      if (match != null && !claimed.add(match.id)) {
        throw ArgumentError('Transaction ${match.id} is used twice.');
      }
      matched.add(match);
    }

    final charges = input.charges == null ? 0 : money(input.charges, 'charges');
    if (input.chargesDeducted && charges >= principal) {
      throw ArgumentError('Charges must be less than the amount borrowed.');
    }
    LedgerCandidate? disbursal, chargesPaid;
    if (input.receivedInAccountId case final into?) {
      if (snapshot) {
        throw ArgumentError(
          'Leave out received_in_account_id: money received is only recorded '
          'for a loan with its payments listed from the start.',
        );
      }
      disbursal = closestInLedger(
        ledger,
        amountMinor: input.chargesDeducted ? principal - charges : principal,
        date: input.startDate,
        claimed: claimed,
        near: withinDays(_matchDays),
        fits: (t) =>
            t.free && t.type == TransactionType.income && t.accountId == into,
      );
      if (disbursal != null) claimed.add(disbursal.id);
    }
    if (charges > 0 && !input.chargesDeducted && !snapshot) {
      chargesPaid = closestInLedger(
        ledger,
        amountMinor: charges,
        date: input.startDate,
        claimed: claimed,
        near: withinDays(_matchDays),
        preferred: preferred,
        fits: (t) =>
            t.free && t.type == TransactionType.expense && sameMoney(t),
      );
    }
    return _Plan(
      principal: principal,
      emi: input.emi == null ? 0 : money(input.emi, 'emi'),
      charges: charges,
      left: left,
      unpaidInterest: money(input.unpaidInterest, 'unpaid_interest'),
      snapshot: snapshot,
      payments: payments,
      paid: paid,
      fees: fees,
      interests: interests,
      matched: matched,
      disbursal: disbursal,
      chargesPaid: chargesPaid,
    );
  }

  /// Each payment's interest: the statement's where it gives it. Where it
  /// doesn't, what the payments came to beyond the principal they cleared is
  /// spread the way a reducing balance would, more of it early on.
  List<int> _interest(
    LoanInput input,
    List<LoanPaymentInput> payments,
    List<int> paid,
    List<int> fees,
    int principal,
    int? outstanding,
    int Function(String?, String) money,
  ) {
    final given = payments.any((p) => p.interest != null);
    if (given || input.rate == 0 || payments.isEmpty) {
      return [
        for (final p in payments)
          p.partPayment ? 0 : money(p.interest, 'A payment’s interest'),
      ];
    }
    if (outstanding == null) {
      throw ArgumentError(
        'Give outstanding, or the interest inside each payment.',
      );
    }
    final scheduled = [
      for (var i = 0; i < payments.length; i++)
        if (!payments[i].partPayment) i,
    ];
    final total =
        paid.fold<int>(0, (n, p) => n + p) -
        fees.fold<int>(0, (n, f) => n + f) -
        (principal - outstanding);
    if (total < 0) {
      throw ArgumentError(
        'These payments come to less than the principal they cleared. Give '
        'every payment from the start, or send only outstanding.',
      );
    }
    final weights = scheduled.length * (scheduled.length + 1) ~/ 2;
    final result = List.filled(payments.length, 0);
    var shared = 0;
    for (final (n, i) in scheduled.indexed) {
      final last = n == scheduled.length - 1;
      final share = last
          ? total - shared
          : (total * (scheduled.length - n) / weights).round();
      result[i] = share;
      shared += share;
    }
    return result;
  }

  /// A transaction the AI app named, checked as a match would be.
  Future<LedgerCandidate> _named(
    int id,
    int amountMinor,
    TransactionType type,
    bool Function(LedgerCandidate) sameMoney,
  ) async {
    final row = await database
        .customSelect(
          'SELECT date FROM transactions WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) throw ArgumentError('No transaction has id $id.');
    final at = DateTime.fromMillisecondsSinceEpoch(row.read<int>('date'));
    final t = (await ledgerBetween(
      database,
      at,
      at,
    )).firstWhere((c) => c.id == id);
    if (!t.free) {
      throw ArgumentError('Transaction $id already belongs to something else.');
    }
    if (t.type != type || t.amountMinor != amountMinor || !sameMoney(t)) {
      throw ArgumentError(
        'Transaction $id isn’t an ${type.name} of this amount and currency.',
      );
    }
    return t;
  }

  Future<LoanPlan> _describe(
    LoanInput input,
    String lender,
    Account account,
    List<Account> accounts,
    _Plan p,
    List<LoanSms> unparsedInbox,
  ) async {
    final loans = await LoanRepository(database).load();
    final day = _dayOnly(input.startDate);
    if (loans.any(
      (l) =>
          l.terms.lender.toLowerCase() == lender.toLowerCase() &&
          l.terms.principal == p.principal &&
          l.terms.startDate != null &&
          _dayOnly(l.terms.startDate!) == day,
    )) {
      throw ArgumentError('$lender is already tracked with this loan.');
    }
    String? assetIcon = input.assetIcon ?? _assetIconFor(input.asset);
    if (assetIcon != null && !isKnownIcon(assetIcon)) {
      throw ArgumentError(
        'No icon is called “$assetIcon”. Look one up with list_icons.',
      );
    }
    final lenderIcon = input.lenderIcon;
    if (lenderIcon != null && !isKnownIcon(lenderIcon)) {
      throw ArgumentError(
        'No icon is called “$lenderIcon”. Look one up with list_icons.',
      );
    }
    final fixed = p.emi > 0;
    final months = input.months;
    final maturity =
        input.endDate ?? (months > 0 ? loanMonth(day, months, day.day) : null);
    var firstDue = input.firstDue ?? loanMonth(day, 1, day.day);
    final today = _dayOnly(DateTime.now());
    final asOf = p.snapshot ? input.asOf ?? today : day;
    if (p.snapshot) {
      // The next one unpaid, for a loan picked up partway.
      final start = firstDue;
      for (var i = 1; firstDue.isBefore(asOf) && i <= 600; i++) {
        firstDue = loanMonth(start, i, start.day);
      }
    }
    final terms = LoanTerms(
      lender: lender,
      kind: input.kind,
      icon: lenderIcon ?? bankInstitutionIcon(lender),
      asset: input.asset?.trim().isEmpty ?? true ? null : input.asset!.trim(),
      assetIcon: assetIcon,
      principal: p.principal,
      openingBalance: p.snapshot ? p.left : p.principal,
      openingInterest: p.snapshot ? p.unpaidInterest : 0,
      startDate: day,
      snapshotDate: asOf,
      rate: input.rate ?? 0,
      rateKnown: input.rate != null,
      interestBasis: input.rate == null
          ? LoanInterestBasis.unknown
          : LoanInterestBasis.remaining,
      months: months,
      maturityDate: maturity,
      emi: p.emi,
      mode: fixed ? LoanRepaymentMode.emi : LoanRepaymentMode.flexible,
      paidBefore: 0,
      firstDue: fixed ? firstDue : maturity ?? day,
      day: fixed ? firstDue.day : (maturity ?? day).day,
      currency: account.currency,
      digits: account.digits,
      existing: p.snapshot,
      chargesMinor: p.charges,
      // A loan picked up partway writes nothing for its start.
      chargesDeducted: input.chargesDeducted || p.snapshot,
    );
    terms.validate();
    final title = Loan(id: 0, terms: terms, accountId: account.id).title;
    String money(int minor) => formatAccountMoney(
      minor,
      digits: account.digits,
      currency: account.currency,
    );

    final added = input.addMissingToAccount;
    // Payments the ledger lacks but a bank message waiting for review has:
    // approving saves the message as that payment.
    final waiting = {
      ...await _waitingSms(account, accounts, [
        for (final (i, payment) in p.payments.indexed)
          if (p.matched[i] == null &&
              !payment.notInLedger &&
              payment.smsId == null)
            (i, payment.date, p.paid[i]),
      ]),
    };
    // Messages the AI app named, once the user said they are this loan's.
    final unparsed = <int, LoanSms>{};
    for (final (i, payment) in p.payments.indexed) {
      final id = payment.smsId;
      if (id == null) continue;
      if (payment.unparsed case final sms?) {
        if (account.digits != 2) {
          throw ArgumentError(
            'Bank messages are only saved to two-decimal accounts.',
          );
        }
        unparsed[i] = sms;
      } else {
        waiting[i] = await _namedSms(id, p.paid[i], account, accounts);
      }
    }
    final smsIds = [
      ...waiting.values.map((s) => s.id),
      ...unparsed.values.map((s) => s.id),
    ];
    if (smsIds.length != smsIds.toSet().length) {
      throw ArgumentError('A bank message is used for two payments.');
    }
    final rows = <Map<String, Object?>>[];
    final lines = <String>[];
    final missing = <int>[];
    for (final (i, payment) in p.payments.indexed) {
      final match = p.matched[i];
      final sms = waiting[i];
      final raw = unparsed[i];
      final date = _shown(payment.date);
      final amount = money(p.paid[i]);
      if (match == null && sms == null && raw == null) missing.add(i);
      lines.add(
        match != null
            ? '$date · $amount → ${match.title ?? 'Saved transaction'} · '
                  '${_name(accounts, match.accountId)}'
            : sms != null
            ? '$date · $amount → saves bank message · ${sms.title} · '
                  '${_name(accounts, sms.account)}'
            : raw != null
            ? '$date · $amount → saves unread bank message · ${account.name}'
            : '$date · $amount → ${added ? 'adds to ${account.name}' : 'counted as paid'}',
      );
      // Kept short: the AI app already has each payment's split.
      rows.add({
        'date': _iso(payment.date),
        'amount': _plain(p.paid[i], account.digits),
        if (match != null)
          'transaction_id': match.id
        else if (sms != null)
          'sms_id': sms.id
        else if (raw != null)
          'sms_id': raw.ref
        else
          'status': added ? 'will_add_to_account' : 'not_in_ledger',
      });
    }
    final repaid = p.principal - p.left;
    final found = p.matched.whereType<LedgerCandidate>().length;
    final emiCount = p.payments.where((x) => !x.partPayment).length;
    final next = fixed && p.left > 0
        ? loanMonth(terms.firstDue, p.snapshot ? 0 : emiCount, terms.day)
        : null;

    final detail = [
      title,
      '${money(p.principal)} at '
          '${input.rate == null ? 'unknown interest' : '${_percent(input.rate!)}%'}'
          '${months > 0 ? ' · $months months' : ''}'
          '${fixed ? ' · ${money(p.emi)} a month' : ''}',
      'Paid from ${account.name}',
      if (repaid > 0) 'Repaid ${money(repaid)} · ${money(p.left)} left',
      if (p.left == p.principal && p.payments.isEmpty) '${money(p.left)} left',
      if (p.fees.any((f) => f > 0) || p.charges > 0)
        'Charges ${money(p.charges + p.fees.fold<int>(0, (n, f) => n + f))}',
      if (next != null) 'Next ${money(p.emi)} on ${_shown(next)}',
      if (input.receivedInAccountId case final into?)
        p.disbursal == null
            ? 'Adds money received to ${_name(accounts, into)}'
            : 'Money received: ${p.disbursal!.title ?? 'saved transaction'}',
      if (p.chargesPaid != null)
        'Charges paid: ${p.chargesPaid!.title ?? 'saved transaction'}',
      if (p.payments.isNotEmpty)
        missing.isEmpty
            ? 'All ${p.payments.length} payments found in your accounts'
            : '${found + waiting.length + unparsed.length} of ${p.payments.length} payments found in your accounts',
      if (waiting.isNotEmpty)
        'Saves ${waiting.length} bank '
            '${waiting.length == 1 ? 'message' : 'messages'} waiting for review',
      if (unparsed.isNotEmpty)
        'Saves ${unparsed.length} bank '
            '${unparsed.length == 1 ? 'message' : 'messages'} the app couldn’t read',
      ...lines,
    ];
    final payload = <String, Object?>{
      'terms': terms.toJson(),
      'accountId': account.id,
      'paidFrom': account.name,
      'receivedIn': input.receivedInAccountId,
      'adoptDisbursal': p.disbursal?.id,
      'adoptCharges': p.chargesPaid?.id,
      'unpaidInterest': p.unpaidInterest,
      'payments': [
        for (final (i, payment) in p.payments.indexed)
          {
            'date': payment.date.toIso8601String(),
            'amount': p.paid[i] - p.fees[i],
            'interest': p.interests[i],
            'fee': p.fees[i],
            'part': payment.partPayment,
            'transactionId': p.matched[i]?.id,
            if (waiting[i] case final sms?) ...{
              'smsId': sms.id,
              'smsAccount': sms.account,
            },
            if (unparsed[i] case final sms?) 'unparsed': unreadSmsPayload(sms),
            // For a message, only used if it's gone by the time of approval.
            'offLedger': p.matched[i] == null && !added,
          },
      ],
    };
    final related = await _relatedSms(
      lender: lender,
      since: day.subtract(const Duration(days: _matchDays)),
      emi: p.emi,
      account: account,
      payments: [for (final i in missing) (p.payments[i].date, p.paid[i])],
      usedTransactions: {
        ...p.matched.whereType<LedgerCandidate>().map((t) => t.id),
        ?p.disbursal?.id,
        ?p.chargesPaid?.id,
      },
      usedSms: smsIds.toSet(),
      unparsed: unparsedInbox,
    );
    return LoanPlan(
      AgentSuggestionDraft(
        kind: AgentSuggestionKind.newLoan,
        target: jsonEncode([lender.toLowerCase(), p.principal, _iso(day)]),
        payload: payload,
        summary: 'New loan · $title',
        detail: detail,
        reason: input.reason,
      ),
      {
        'loan': title,
        'paid_from': account.name,
        'repaid': _plain(repaid, account.digits),
        'left': _plain(p.left, account.digits),
        if (next != null) 'next_due': _iso(next),
        if (p.payments.isNotEmpty) ...{
          'payments_found_in_ledger': found,
          if (waiting.isNotEmpty) 'payments_in_sms_review': waiting.length,
          if (unparsed.isNotEmpty) 'payments_in_unread_sms': unparsed.length,
          'payments_not_found': missing.length,
          'payments': rows,
        },
        if (related.isNotEmpty) 'related_sms': related,
        'next': related.isEmpty
            ? 'Nothing has changed yet. Tell the user what was found, and ask '
                  'them to approve it in SimpleMoney → More → AI suggestions'
                  '${waiting.isEmpty && unparsed.isEmpty ? '' : ', which also saves the bank messages it matched'}. '
                  'Calling suggest_loan again replaces this suggestion.'
            : 'Nothing has changed yet. related_sms lists ${related.length} '
                  'bank ${related.length == 1 ? 'message' : 'messages'} '
                  'that may be repayments of this loan but aren’t in this '
                  'suggestion: saved (already a transaction), needs_review '
                  '(waiting in SMS review) or unparsed (no rule reads it). '
                  'Before anything else, show them to the user (date, amount, '
                  'what the message says) and ask: "Should I mark these as '
                  'repayments of this loan?" Leave out ones that are clearly '
                  'not (a due reminder, a bounce, another loan). For the ones '
                  'the user confirms, call suggest_loan again with the same '
                  'details, adding each as a payment with its date and '
                  'amount, and transaction_id for saved or sms_id for '
                  'needs_review and unparsed; one with matches_payment goes '
                  'on that statement payment instead. Then ask them to '
                  'approve it in SimpleMoney → More → AI suggestions.',
      },
    );
  }

  /// Bank messages waiting for review that look like [payments] the ledger
  /// doesn't have yet, by payment index. One query for the whole loan; each
  /// message is matched once, to the payment closest in date.
  Future<Map<int, _WaitingSms>> _waitingSms(
    Account account,
    List<Account> accounts,
    List<(int, DateTime, int)> payments,
  ) async {
    // Bank messages are only ever saved to two-decimal accounts.
    if (payments.isEmpty || account.digits != 2) return const {};
    const margin = Duration(days: _matchDays + 1);
    final dates = [for (final p in payments) p.$2];
    final rows = await database
        .customSelect(
          '''SELECT i.fingerprint, i.received_at, i.candidate, r.account_id
          FROM sms_imports i
          LEFT JOIN sms_review r ON r.fingerprint = i.fingerprint
          WHERE i.status = 'pending' AND i.received_at BETWEEN ? AND ?
            AND json_extract(i.candidate, '\$.direction') = 'debit'
            AND json_extract(i.candidate, '\$.currencyCode') = ?
          ORDER BY i.received_at, i.fingerprint''',
          variables: [
            Variable(
              dates
                  .reduce((a, b) => a.isBefore(b) ? a : b)
                  .subtract(margin)
                  .millisecondsSinceEpoch,
            ),
            Variable(
              dates
                  .reduce((a, b) => a.isAfter(b) ? a : b)
                  .add(margin)
                  .millisecondsSinceEpoch,
            ),
            Variable(account.currency),
          ],
        )
        .get();
    final candidates = <(PendingSmsImport, int)>[];
    for (final row in rows) {
      final sms = PendingSmsImport(
        id: row.read<String>('fingerprint'),
        sender: '',
        body: '',
        data: Map<String, dynamic>.from(
          jsonDecode(row.read<String>('candidate')) as Map,
        ),
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('received_at'),
        ),
      );
      // A card repayment or cash withdrawal is a transfer, never an EMI.
      if (sms.requiresTransfer || sms.data['amountMinor'] is! int) continue;
      final into =
          row.readNullable<int>('account_id') ??
          sms.data['assignedAccountId'] as int?;
      candidates.add((sms, _smsAccount(into, account, accounts)));
    }
    final found = <int, _WaitingSms>{};
    final used = <String>{};
    for (final (index, date, amount) in payments) {
      final day = _dayOnly(date);
      (PendingSmsImport, int)? best;
      var bestGap = _matchDays + 1;
      for (final c in candidates) {
        if (c.$1.amountMinor != amount || used.contains(c.$1.id)) continue;
        final gap = _dayOnly(c.$1.receivedAt).difference(day).inDays.abs();
        if (gap < bestGap || (gap == bestGap && c.$2 == account.id)) {
          best = c;
          bestGap = gap;
        }
      }
      if (best == null || bestGap > _matchDays) continue;
      used.add(best.$1.id);
      found[index] = (id: best.$1.id, account: best.$2, title: best.$1.title);
    }
    return found;
  }

  /// A bank message waiting for review that the AI app named as payment of
  /// [amount], and the account approving saves it into.
  Future<_WaitingSms> _namedSms(
    String id,
    int amount,
    Account account,
    List<Account> accounts,
  ) async {
    final row = await database
        .customSelect(
          '''SELECT i.status, i.transaction_id, i.received_at, i.candidate,
              r.account_id
          FROM sms_imports i
          LEFT JOIN sms_review r ON r.fingerprint = i.fingerprint
          WHERE i.fingerprint = ?''',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) {
      throw ArgumentError(
        'No bank message has sms_id “$id”. Use an id from related_sms.',
      );
    }
    switch (row.read<String>('status')) {
      case 'imported':
        throw ArgumentError(
          'Bank message “$id” is already saved as transaction '
          '${row.readNullable<int>('transaction_id')}: give that '
          'transaction_id instead.',
        );
      case 'dismissed':
        throw ArgumentError('Bank message “$id” was dismissed in SMS review.');
    }
    final sms = PendingSmsImport(
      id: id,
      sender: '',
      body: '',
      data: Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      ),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('received_at'),
      ),
    );
    if (sms.credit ||
        sms.data['amountMinor'] != amount ||
        sms.data['currencyCode'] != account.currency) {
      throw ArgumentError(
        'Bank message “$id” isn’t a payment of this amount: give the amount '
        'it shows.',
      );
    }
    return (
      id: id,
      account: _smsAccount(
        row.readNullable<int>('account_id') ??
            sms.data['assignedAccountId'] as int?,
        account,
        accounts,
      ),
      title: sms.title,
    );
  }

  /// The account a message linked to [into] saves into: that one when it
  /// fits the loan's money, otherwise the loan's own.
  static int _smsAccount(int? into, Account account, List<Account> accounts) =>
      accounts
          .where(
            (a) =>
                a.id == into && a.currency == account.currency && a.digits == 2,
          )
          .firstOrNull
          ?.id ??
      account.id;

  static final _loanWords = RegExp(
    r'\b(emi|loan|nach|ecs|instal+ment|mandate|repayment)\b',
    caseSensitive: false,
  );
  static final _rupees = RegExp(
    r'(?:rs\.?|inr|₹)\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );

  /// Bank messages from [since] that may be this loan's payments but the
  /// suggestion doesn't use: saved as a transaction, waiting for review, or
  /// read by no rule. They name the lender, are the EMI's amount, or (with
  /// no EMI to go by) speak of a loan. The AI app asks the user about each.
  Future<List<Map<String, Object?>>> _relatedSms({
    required String lender,
    required DateTime since,
    required int emi,
    required Account account,
    required List<(DateTime, int)> payments,
    required Set<int> usedTransactions,
    required Set<String> usedSms,
    required List<LoanSms> unparsed,
  }) async {
    if (account.digits != 2) return const [];
    final names = {
      lender.toLowerCase(),
      for (final w in lender.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
        if (w.length >= 4 &&
            !const {'bank', 'finance', 'loan', 'loans'}.contains(w))
          w,
    };
    bool related(String text, int? amount) {
      final lower = text.toLowerCase();
      return names.any(lower.contains) ||
          (emi > 0 ? amount == emi : _loanWords.hasMatch(text));
    }

    // The statement payment, missing from the ledger, that this one is.
    String? matches(DateTime date, int? amount) {
      for (final (day, paid) in payments) {
        if (paid == amount &&
            _dayOnly(day).difference(_dayOnly(date)).inDays.abs() <=
                _matchDays) {
          return _iso(day);
        }
      }
      return null;
    }

    String clip(String text) {
      final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return flat.length <= 240 ? flat : '${flat.substring(0, 239)}…';
    }

    final found = <(DateTime, Map<String, Object?>)>[];
    void add(
      String kind,
      String key,
      Object id,
      DateTime date,
      int? amount,
      String text,
    ) => found.add((
      date,
      {
        'kind': kind,
        key: id,
        'date': _iso(date),
        'amount': amount == null ? null : _plain(amount, 2),
        'text': clip(text),
        'matches_payment': ?matches(date, amount),
      },
    ));

    final imported = await database
        .customSelect(
          'SELECT fingerprint, transaction_id FROM sms_imports '
          'WHERE received_at >= ?',
          variables: [Variable(since.millisecondsSinceEpoch)],
        )
        .get();
    final fromSms = {
      for (final r in imported) ?r.readNullable<int>('transaction_id'),
    };
    final known = {for (final r in imported) r.read<String>('fingerprint')};
    final money = {
      for (final a in await AccountRepository(database).load())
        a.id: (a.currency, a.digits),
    };
    for (final t in await ledgerBetween(database, since, DateTime.now())) {
      if (t.type != TransactionType.expense ||
          !t.free ||
          !fromSms.contains(t.id) ||
          usedTransactions.contains(t.id) ||
          money[t.accountId] != (account.currency, 2) ||
          !related('${t.title ?? ''} ${t.references}', t.amountMinor)) {
        continue;
      }
      add(
        'saved',
        'transaction_id',
        t.id,
        t.date,
        t.amountMinor,
        t.references.trim().isEmpty ? t.title ?? '' : t.references,
      );
    }

    final waiting = await database
        .customSelect(
          '''SELECT fingerprint, body, received_at, candidate FROM sms_imports
          WHERE status = 'pending' AND received_at >= ?
            AND json_extract(candidate, '\$.direction') = 'debit'
            AND json_extract(candidate, '\$.currencyCode') = ?''',
          variables: [
            Variable(since.millisecondsSinceEpoch),
            Variable(account.currency),
          ],
        )
        .get();
    for (final row in waiting) {
      final sms = PendingSmsImport(
        id: row.read<String>('fingerprint'),
        sender: '',
        body: row.readNullable<String>('body') ?? '',
        data: Map<String, dynamic>.from(
          jsonDecode(row.read<String>('candidate')) as Map,
        ),
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('received_at'),
        ),
      );
      if (usedSms.contains(sms.id) ||
          sms.requiresTransfer ||
          sms.data['amountMinor'] is! int ||
          !related('${sms.title} ${sms.body}', sms.amountMinor)) {
        continue;
      }
      add(
        'needs_review',
        'sms_id',
        sms.id,
        sms.receivedAt,
        sms.amountMinor,
        sms.body.isEmpty ? sms.title : sms.body,
      );
    }

    for (final sms in unparsed) {
      if (sms.receivedAt.isBefore(since) ||
          known.contains(sms.id) ||
          usedSms.contains(sms.id)) {
        continue;
      }
      final amount = switch (_rupees.firstMatch(sms.body)?.group(1)) {
        final text? => parseAccountAmount(text.replaceAll(',', ''), 2),
        null => null,
      };
      if (!related(sms.body, amount)) continue;
      add('unparsed', 'sms_id', sms.ref, sms.receivedAt, amount, sms.body);
    }

    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final f in found.take(40)) f.$2];
  }

  /// Adds the loan and its payments. Returns what undoing needs.
  Future<Map<String, Object?>> applyLoan(Map<String, Object?> payload) async {
    final repository = LoanRepository(database);
    final terms = LoanTerms.fromJson(
      Map<String, dynamic>.from(payload['terms'] as Map),
    );
    final accountId = payload['accountId'] as int;
    final adopted = <AdoptedTransaction>[];
    final id = await repository.add(
      terms,
      accountId,
      receivedIn: payload['receivedIn'] as int?,
      adoptDisbursal: payload['adoptDisbursal'] as int?,
      adoptCharges: payload['adoptCharges'] as int?,
      adopted: adopted,
    );
    Future<Loan> current() async =>
        (await repository.load()).firstWhere((l) => l.id == id);
    final payments = (payload['payments'] as List).cast<Map>();
    int? category;
    for (final (i, p) in payments.indexed) {
      var transactionId = p['transactionId'] as int?;
      if (p['smsId'] case final String sms when transactionId == null) {
        transactionId = await AgentSmsSaver(database).saveWaiting(
          sms,
          accountId: p['smsAccount'] as int,
          categoryId: category ??= await repository.paymentCategory(),
        );
      }
      if (p['unparsed'] case final Map sms when transactionId == null) {
        transactionId = await AgentSmsSaver(database).saveUnread(
          sms,
          accountId: accountId,
          amountMinor: (p['amount'] as int) + (p['fee'] as int),
          categoryId: category ??= await repository.paymentCategory(),
          title: terms.lender,
          currency: terms.currency,
          ruleId: 'loan',
        );
      }
      await repository.record(
        await current(),
        kind: p['part'] == true ? LoanEventKind.partPayment : LoanEventKind.emi,
        date: DateTime.parse(p['date'] as String),
        accountId: accountId,
        amount: p['amount'] as int,
        fee: p['fee'] as int,
        interestCharged: p['interest'] as int,
        // A lender's statement is the last word on what is left unpaid.
        unpaidInterestAfter: i == payments.length - 1
            ? payload['unpaidInterest'] as int
            : 0,
        adoptTransactionId: transactionId,
        offLedger: transactionId == null && p['offLedger'] == true,
      );
    }
    return {
      'loanId': id,
      'version': (await current()).version,
      'adopted': [for (final a in adopted) a.toJson()],
    };
  }

  Future<void> undoLoan(Map<String, Object?> before) async {
    final id = before['loanId'] as int;
    final version = before['version'] as int;
    final repository = LoanRepository(database);
    final loan = (await repository.load()).where((l) => l.id == id).firstOrNull;
    if (loan == null) throw StateError('This loan was already deleted.');
    if (loan.version != version) {
      throw StateError(
        'This loan has new payments. Change it in More › Loans.',
      );
    }
    await repository.unwind(id, version, [
      for (final a in before['adopted'] as List)
        AdoptedTransaction.fromJson(Map<String, dynamic>.from(a as Map)),
    ]);
  }

  // ── Debts. ──

  Future<AgentSuggestionDraft> prepareDebtEntry({
    int? personId,
    String? personName,
    required DebtKind kind,
    required String amount,
    required DateTime date,
    DateTime? dueDate,
    int? accountId,
    String? currency,
    String? note,
    int? transactionId,
    bool ignoreMatches = false,
    String? reason,
  }) async {
    final accounts = await AccountRepository(database).load();
    final active = accounts.where((a) => !a.isArchived).toList();
    Account? account;
    if (accountId != null) {
      account = active.where((a) => a.id == accountId).firstOrNull;
      if (account == null) {
        throw ArgumentError('Account $accountId isn’t an active account.');
      }
    }
    final people = await DebtRepository(database).load();
    final name = personName?.trim() ?? '';
    PersonDebts? person;
    if (personId != null) {
      person = people.where((p) => p.person.id == personId).firstOrNull;
      if (person == null) throw ArgumentError('No person has id $personId.');
    } else {
      final same = people
          .where((p) => p.person.name.toLowerCase() == name.toLowerCase())
          .toList();
      if (same.length > 1) {
        throw ArgumentError(
          'Several people are called “$name”; give person_id from list_debts.',
        );
      }
      person = same.firstOrNull;
      if (person == null && (name.isEmpty || name.length > 40)) {
        throw ArgumentError('Give a person’s name of 1–40 characters.');
      }
    }
    final who = person?.person.name ?? name;

    final type = kind.paysOut
        ? TransactionType.expense
        : TransactionType.income;
    final today = _dayOnly(DateTime.now());
    if (_dayOnly(date).isAfter(today)) {
      throw ArgumentError('The date can’t be in the future.');
    }
    final model = account ?? active.firstOrNull;
    final money = currency ?? model?.currency ?? 'INR';
    final digits =
        account?.digits ??
        active.where((a) => a.currency == money).firstOrNull?.digits ??
        2;
    final minor = parseAccountAmount(amount.replaceAll(',', ''), digits);
    if (minor == null || minor <= 0) {
      throw ArgumentError('amount must be an amount like 5000.00.');
    }
    String shown(int value) =>
        formatAccountMoney(value, digits: digits, currency: money);

    LedgerCandidate? use;
    if (transactionId != null) {
      use = await _named(transactionId, minor, type, (t) {
        final a = accounts.where((x) => x.id == t.accountId).firstOrNull;
        return a?.currency == money && a?.digits == digits;
      });
    } else if (!ignoreMatches) {
      const margin = Duration(days: _matchDays);
      final ledger = await ledgerBetween(
        database,
        date.subtract(margin),
        date.add(margin).add(const Duration(days: 1)),
      );
      final near = ledger
          .where(
            (t) =>
                t.free &&
                t.type == type &&
                t.amountMinor == minor &&
                (accountId == null || t.accountId == accountId) &&
                accounts
                    .where(
                      (a) =>
                          a.id == t.accountId &&
                          a.currency == money &&
                          a.digits == digits,
                    )
                    .isNotEmpty,
          )
          .toList();
      final firstName = who.split(RegExp(r'\s+')).first;
      final named = near.where((t) => t.mentions(firstName)).toList();
      if (named.length == 1) {
        use = named.single;
      } else if (near.isNotEmpty) {
        final list = near
            .take(5)
            .map(
              (t) =>
                  'id ${t.id}: ${t.title ?? 'no title'}, ${_iso(t.date)}, '
                  '${_name(accounts, t.accountId)}',
            )
            .join('; ');
        throw ArgumentError(
          'This may already be saved ($list). Send transaction_id to use one, '
          'or ignore_matches true if it is a different payment.',
        );
      }
    }

    final verb = switch (kind) {
      DebtKind.lend => 'Lent to',
      DebtKind.borrow => 'Borrowed from',
      DebtKind.collect => 'Paid back by',
      DebtKind.repay => 'Paid back',
    };
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.debtEntry,
      target: jsonEncode([
        who.toLowerCase(),
        kind.name,
        minor,
        money,
        _iso(date),
      ]),
      payload: {
        'personId': person?.person.id,
        'personName': who,
        'kind': kind.name,
        'amount': minor,
        'currency': money,
        'digits': digits,
        'accountId': use == null ? accountId : null,
        'transactionId': use?.id,
        'note': note,
        'date': date.toIso8601String(),
        'dueDate': kind.opensDebt ? dueDate?.toIso8601String() : null,
      },
      summary: '$verb $who · ${shown(minor)} · ${_shown(date)}',
      detail: [
        if (person == null) 'New person: $who',
        if (use != null) ...[
          'Uses your saved ${use.title ?? 'transaction'} · '
              '${_name(accounts, use.accountId)} · ${_shown(use.date)}',
          'Balance stays the same',
        ] else if (account != null)
          kind.paysOut
              ? 'Takes ${shown(minor)} out of ${account.name}'
              : 'Adds ${shown(minor)} to ${account.name}'
        else
          'Only tracked here. Balance stays the same.',
        if (kind.opensDebt && dueDate != null) 'Due ${_shown(dueDate)}',
        if (note?.trim().isNotEmpty ?? false) 'Note: ${note!.trim()}',
      ],
      reason: reason,
    );
  }

  /// Adds the entry. Returns what undoing needs.
  Future<Map<String, Object?>> applyDebtEntry(Map<String, Object?> p) async {
    final name = p['personName'] as String;
    // A person a sibling suggestion just added isn't new any more.
    final people = await DebtRepository(database).load();
    final person =
        p['personId'] as int? ??
        people
            .where((x) => x.person.name.toLowerCase() == name.toLowerCase())
            .firstOrNull
            ?.person
            .id;
    final due = p['dueDate'] as String?;
    var undo = <String, Object?>{};
    await DebtRepository(database).addEntry(
      personId: person,
      newPersonName: person == null ? name : null,
      kind: DebtKindStorage.fromStorage(p['kind'] as String),
      amountMinor: p['amount'] as int,
      accountId: p['accountId'] as int?,
      currency: p['currency'] as String,
      digits: p['digits'] as int,
      note: p['note'] as String?,
      date: DateTime.parse(p['date'] as String),
      dueDate: due == null ? null : DateTime.parse(due),
      adoptTransactionId: p['transactionId'] as int?,
      onSaved: (entryId, adopted) =>
          undo = {'entryId': entryId, 'adopted': adopted?.toJson()},
    );
    return undo;
  }

  Future<void> undoDebtEntry(Map<String, Object?> before) async {
    final id = before['entryId'] as int;
    final repository = DebtRepository(database);
    if (before['adopted'] case final Map adopted) {
      await repository.unlinkAdopted(
        id,
        AdoptedTransaction.fromJson(Map<String, dynamic>.from(adopted)),
      );
    } else {
      await repository.deleteEntry(id);
    }
  }

  // ── Shared. ──

  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _iso(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  static String _shown(DateTime d) => DateFormat('d MMM yyyy').format(d);

  static String _name(List<Account> accounts, int id) =>
      accounts.where((a) => a.id == id).firstOrNull?.name ?? 'Account';

  static String _percent(double rate) =>
      rate % 1 == 0 ? '${rate.toInt()}' : '$rate';

  /// Minor units as an exact decimal string, e.g. 45050 → "450.50".
  static String _plain(int minor, int digits) {
    if (digits == 0) return '$minor';
    final text = '$minor'.padLeft(digits + 1, '0');
    final split = text.length - digits;
    return '${text.substring(0, split)}.${text.substring(split)}';
  }

  /// The usual picture for what a loan paid for.
  static String? _assetIconFor(String? asset) {
    final words = asset?.toLowerCase() ?? '';
    for (final (pattern, icon) in const [
      (r'phone|mobile|galaxy|pixel|oneplus|redmi|vivo|oppo', 'phone'),
      (r'laptop|macbook|notebook', 'laptop'),
      (r'headphone|earbud|airpod', 'headphones'),
      (r'\bcar\b|swift|creta|nexon', 'car'),
      (r'\b(house|home|flat|apartment)\b', 'home_two'),
    ]) {
      if (RegExp(pattern).hasMatch(words)) return icon;
    }
    return null;
  }
}

/// A key the app can draw: one of its own, a bank's or a brand's.
bool isKnownIcon(String key) =>
    appIconKeys.contains(key) ||
    resolveBrandIcon(key) != null ||
    resolveWordmarkBrand(key) != null;

class _Plan {
  const _Plan({
    required this.principal,
    required this.emi,
    required this.charges,
    required this.left,
    required this.unpaidInterest,
    required this.snapshot,
    required this.payments,
    required this.paid,
    required this.fees,
    required this.interests,
    required this.matched,
    this.disbursal,
    this.chargesPaid,
  });
  final int principal, emi, charges, unpaidInterest;

  /// The principal still owed.
  final int left;

  /// No payment history: the loan is picked up at its current balance.
  final bool snapshot;
  final List<LoanPaymentInput> payments;
  final List<int> paid, fees, interests;
  final List<LedgerCandidate?> matched;
  final LedgerCandidate? disbursal, chargesPaid;
}
