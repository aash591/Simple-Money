import 'dart:math' as math;

enum LoanKind {
  home,
  car,
  twoWheeler,
  personal,
  education,
  gold,
  creditCard,
  other,
}

extension LoanKindLabel on LoanKind {
  String get label => const [
    'Home',
    'Car',
    'Two-wheeler',
    'Personal',
    'Education',
    'Gold',
    'Credit card EMI',
    'Other',
  ][index];

  /// Whether the borrowed money normally reaches the borrower at all. A
  /// cash loan lands in an account; the rest buy a thing, with the lender
  /// paying the seller — so nothing moves through the borrower's accounts
  /// and the loan is tracked as debt alone.
  bool get fundsReachYou => switch (this) {
    LoanKind.personal || LoanKind.gold || LoanKind.other => true,
    _ => false,
  };
}

/// How a loan is repaid. Not every loan amortises: a gold loan often runs
/// on interest alone with the principal cleared at the end, or is repaid in
/// one go at maturity, and a home loan under construction pays interest
/// only (pre-EMI) until possession.
enum LoanRepaymentMode { emi, interestOnly, bullet, flexible }

enum LoanInterestBasis { remaining, original, unknown }

enum LoanAccrual { daily, monthly }

enum LoanCompounding { none, monthly, unknown }

extension LoanRepaymentModeLabel on LoanRepaymentMode {
  String get label => switch (this) {
    LoanRepaymentMode.emi => 'Monthly EMI',
    LoanRepaymentMode.interestOnly => 'Interest only, principal at the end',
    LoanRepaymentMode.bullet => 'Everything at the end',
    LoanRepaymentMode.flexible => 'Flexible payments',
  };

  /// Whether each payment eats into the principal.
  bool get amortises => this == LoanRepaymentMode.emi;

  /// Whether anything is paid month to month.
  bool get monthly =>
      this == LoanRepaymentMode.emi || this == LoanRepaymentMode.interestOnly;

  /// What one scheduled payment is called.
  String get paymentNoun => switch (this) {
    LoanRepaymentMode.emi => 'EMI',
    LoanRepaymentMode.interestOnly => 'interest payment',
    LoanRepaymentMode.bullet => 'final payment',
    LoanRepaymentMode.flexible => 'payment',
  };
}

/// Dates retain the chosen day across short months (31 Jan -> 28 Feb -> 31 Mar).
DateTime loanMonth(DateTime first, int offset, int day) {
  final month = DateTime(first.year, first.month + offset);
  return DateTime(
    month.year,
    month.month,
    math.min(day, DateTime(month.year, month.month + 1, 0).day),
  );
}

int loanEmi(int principal, double rate, int months) {
  if (principal <= 0 ||
      months < 1 ||
      months > 600 ||
      !rate.isFinite ||
      rate < 0 ||
      rate > 100) {
    throw ArgumentError(
      'Enter a positive amount, 1–600 months, and a rate from 0–100%.',
    );
  }
  final monthly = rate / 1200;
  if (monthly == 0) return (principal / months).ceil();
  final factor = math.pow(1 + monthly, months);
  return math.max(1, (principal * monthly * factor / (factor - 1)).round());
}

class LoanInstallment {
  const LoanInstallment(
    this.number,
    this.due,
    this.principal,
    this.interest,
    this.balance,
  );
  final int number, principal, interest, balance;
  final DateTime due;
  int get amount => principal + interest;
}

/// Monthly reducing-balance estimate, rounded to currency minor units per row.
/// The final installment clears the exact balance; no balloon payment is hidden.
///
/// Only [LoanRepaymentMode.emi] amortises. The other modes charge interest on
/// an untouched principal, so they need [months] — how many payments are left
/// — rather than working it out from the EMI.
List<LoanInstallment> loanSchedule({
  required int principal,
  required double rate,
  required int emi,
  required DateTime first,
  required int day,
  int paid = 0,
  LoanRepaymentMode mode = LoanRepaymentMode.emi,
  int months = 0,
  LoanInterestBasis basis = LoanInterestBasis.remaining,
  int? originalPrincipal,
}) {
  if (mode == LoanRepaymentMode.flexible ||
      basis == LoanInterestBasis.unknown) {
    return [];
  }
  if (principal == 0) return [];
  if (principal < 0 ||
      !rate.isFinite ||
      rate < 0 ||
      rate > 100 ||
      day < 1 ||
      day > 31) {
    throw ArgumentError('Invalid repayment terms.');
  }
  if (!mode.amortises) {
    if (months < 1 || months > 600) {
      throw ArgumentError('Enter a tenure of 1–600 months.');
    }
    if (mode == LoanRepaymentMode.bullet) {
      // Gold-loan practice: simple interest over the tenure, settled with
      // the principal in one payment at maturity.
      return [
        LoanInstallment(
          paid + 1,
          loanMonth(first, 0, day),
          principal,
          (principal * rate / 1200 * months).round(),
          0,
        ),
      ];
    }
    final monthly = (principal * rate / 1200).round();
    return [
      for (var i = 0; i < months; i++)
        LoanInstallment(
          paid + i + 1,
          loanMonth(first, i, day),
          i == months - 1 ? principal : 0,
          monthly,
          i == months - 1 ? 0 : principal,
        ),
    ];
  }
  if (emi <= 0) throw ArgumentError('Invalid repayment terms.');
  final rows = <LoanInstallment>[];
  var balance = principal;
  while (balance > 0 && rows.length < 600) {
    final interest =
        ((basis == LoanInterestBasis.original
                    ? originalPrincipal ?? principal
                    : balance) *
                rate /
                1200)
            .round();
    if (emi <= interest) {
      throw ArgumentError('EMI must be greater than monthly interest.');
    }
    final capital = math.min(balance, emi - interest);
    balance -= capital;
    rows.add(
      LoanInstallment(
        paid + rows.length + 1,
        loanMonth(first, rows.length, day),
        capital,
        interest,
        balance,
      ),
    );
  }
  if (balance > 0) {
    throw ArgumentError('This EMI would take more than 50 years to repay.');
  }
  return rows;
}

class LoanTerms {
  const LoanTerms({
    required this.lender,
    required this.kind,
    required this.icon,
    required this.principal,
    required this.openingBalance,
    required this.rate,
    required this.months,
    required this.emi,
    required this.paidBefore,
    required this.firstDue,
    required this.day,
    required this.currency,
    required this.digits,
    this.remind = true,
    this.mode = LoanRepaymentMode.emi,
    this.chargesMinor = 0,
    this.chargesDeducted = false,
    this.asset,
    this.assetIcon,
    this.startDate,
    this.snapshotDate,
    this.openingInterest = 0,
    this.interestBasis = LoanInterestBasis.remaining,
    this.rateKnown = true,
    this.accrual = LoanAccrual.monthly,
    this.compounding = LoanCompounding.none,
    this.interestStartsOn,
    this.maturityDate,
    this.interestReminderDate,
    this.existing = false,
  });

  /// [icon] pictures the lender; [assetIcon] pictures what the loan paid for.
  final String lender, icon, currency;

  /// What the loan paid for — a car, a phone — when it bought a thing
  /// rather than handing over money. Null for a loan that bought nothing in
  /// particular, like a personal loan.
  final String? asset;
  final String? assetIcon;
  final LoanKind kind;
  final int principal, openingBalance, months, emi, paidBefore, day, digits;
  final double rate;
  final LoanRepaymentMode mode;
  // Null startDate identifies legacy schedule-only loans. New balances are
  // snapshots, not reconstructed payment histories; null interest is unknown.
  final DateTime? startDate,
      snapshotDate,
      interestStartsOn,
      maturityDate,
      interestReminderDate;
  final int? openingInterest;
  final LoanInterestBasis interestBasis;
  final bool rateKnown, existing;
  final LoanAccrual accrual;
  final LoanCompounding compounding;
  bool get tracked => startDate != null;
  bool get canEstimate =>
      rateKnown &&
      (rate == 0 ||
          (interestBasis != LoanInterestBasis.unknown &&
              compounding != LoanCompounding.unknown));
  bool get hasSchedule =>
      mode != LoanRepaymentMode.flexible &&
      canEstimate &&
      (!tracked ||
          (accrual == LoanAccrual.monthly &&
              compounding == LoanCompounding.none &&
              interestStartsOn == null));

  /// Processing fee, documentation and insurance charges taken at the start,
  /// inclusive of GST — what the loan cost before a rupee of interest.
  final int chargesMinor;

  /// Whether those charges were netted off the money disbursed rather than
  /// paid separately.
  final bool chargesDeducted;

  /// First unpaid EMI when tracking begins; imported payments are never logged.
  final DateTime firstDue;
  final bool remind;

  /// The thing bought's icon when the loan names one, else the lender's.
  String get displayIcon {
    final bought = asset?.trim();
    return bought == null || bought.isEmpty ? icon : assetIcon ?? icon;
  }

  /// Payments still to come when tracking starts.
  int get remainingMonths => mode == LoanRepaymentMode.bullet
      ? months
      : math.max(1, months - paidBefore);

  void validate() {
    if (tracked) {
      final snapshot = snapshotDate ?? startDate!;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (principal <= 0 ||
          openingBalance < 0 ||
          openingBalance > principal ||
          months < 0 ||
          months > 600 ||
          !rate.isFinite ||
          rate < 0 ||
          rate > 100 ||
          lender.trim().isEmpty ||
          lender.trim().length > 40 ||
          digits < 0 ||
          digits > 4 ||
          currency.length != 3 ||
          day < 1 ||
          day > 31 ||
          (openingInterest != null && openingInterest! < 0) ||
          startDate!.isAfter(today) ||
          snapshot.isBefore(startDate!) ||
          snapshot.isAfter(today) ||
          (maturityDate != null && maturityDate!.isBefore(startDate!)) ||
          (interestStartsOn != null &&
              interestStartsOn!.isBefore(startDate!)) ||
          (mode.amortises && (emi <= 0 || firstDue.isBefore(startDate!)))) {
        throw ArgumentError('Check the loan amount, rate, duration and dates.');
      }
      if (chargesMinor < 0 || (chargesDeducted && chargesMinor >= principal)) {
        throw ArgumentError('Charges must be less than the amount borrowed.');
      }
      if (asset != null && asset!.trim().length > 40) {
        throw ArgumentError('Use a name of up to 40 characters.');
      }
      if (hasSchedule && openingBalance > 0) {
        loanSchedule(
          principal: openingBalance,
          rate: rate,
          emi: emi,
          first: firstDue,
          day: day,
          mode: mode,
          months: remainingMonths,
          basis: interestBasis,
          originalPrincipal: principal,
        );
      }
      return;
    }
    if (mode.amortises) {
      loanEmi(principal, rate, months);
    } else if (principal <= 0 ||
        months < 1 ||
        months > 600 ||
        !rate.isFinite ||
        rate < 0 ||
        rate > 100) {
      throw ArgumentError(
        'Enter a positive amount, 1–600 months, and a rate from 0–100%.',
      );
    }
    if (lender.trim().isEmpty ||
        lender.trim().length > 40 ||
        openingBalance < 1 ||
        openingBalance > principal ||
        paidBefore < 0 ||
        paidBefore >= months ||
        digits < 0 ||
        digits > 4 ||
        currency.length != 3) {
      throw ArgumentError(
        'Check the lender, outstanding amount and EMIs already paid.',
      );
    }
    if (chargesMinor < 0 || (chargesDeducted && chargesMinor >= principal)) {
      throw ArgumentError('Charges must be less than the amount borrowed.');
    }
    final bought = asset;
    if (bought != null &&
        (bought.trim().isEmpty || bought.trim().length > 40)) {
      throw ArgumentError(
        'Name what the loan paid for in 1–40 characters, or leave it out.',
      );
    }
    loanSchedule(
      principal: openingBalance,
      rate: rate,
      emi: emi,
      first: firstDue,
      day: day,
      mode: mode,
      months: remainingMonths,
    );
  }

  Map<String, dynamic> toJson() => {
    'lender': lender.trim(),
    'kind': kind.name,
    'icon': icon,
    'principal': principal,
    'openingBalance': openingBalance,
    'rate': rate,
    'months': months,
    'emi': emi,
    'paidBefore': paidBefore,
    'firstDue': firstDue.toIso8601String(),
    'day': day,
    'currency': currency,
    'digits': digits,
    'remind': remind,
    'mode': mode.name,
    'charges': chargesMinor,
    'chargesDeducted': chargesDeducted,
    'asset': asset?.trim(),
    'assetIcon': assetIcon,
    if (tracked) ...{
      'startDate': startDate!.toIso8601String(),
      'snapshotDate': snapshotDate?.toIso8601String(),
      'openingInterest': openingInterest,
      'interestBasis': interestBasis.name,
      'rateKnown': rateKnown,
      'accrual': accrual.name,
      'compounding': compounding.name,
      'interestStartsOn': interestStartsOn?.toIso8601String(),
      'maturityDate': maturityDate?.toIso8601String(),
      'interestReminderDate': interestReminderDate?.toIso8601String(),
      'existing': existing,
    },
  };

  /// Loans saved before a field existed read as what they were: an ordinary
  /// EMI loan with no charges recorded.
  factory LoanTerms.fromJson(Map<String, dynamic> j) => LoanTerms(
    lender: j['lender'],
    kind: LoanKind.values.byName(j['kind']),
    icon: j['icon'],
    principal: j['principal'],
    openingBalance: j['openingBalance'],
    rate: (j['rate'] as num).toDouble(),
    months: j['months'],
    emi: j['emi'],
    paidBefore: j['paidBefore'],
    firstDue: DateTime.parse(j['firstDue']),
    day: j['day'],
    currency: j['currency'],
    digits: j['digits'],
    remind: j['remind'],
    mode: j['mode'] == null
        ? LoanRepaymentMode.emi
        : LoanRepaymentMode.values.byName(j['mode']),
    chargesMinor: j['charges'] ?? 0,
    chargesDeducted: j['chargesDeducted'] ?? false,
    asset: j['asset'],
    assetIcon: j['assetIcon'],
    startDate: DateTime.tryParse(j['startDate'] ?? ''),
    snapshotDate: DateTime.tryParse(j['snapshotDate'] ?? ''),
    openingInterest: j.containsKey('openingInterest')
        ? j['openingInterest']
        : 0,
    interestBasis: LoanInterestBasis.values.byName(
      j['interestBasis'] ?? 'remaining',
    ),
    rateKnown: j['rateKnown'] ?? true,
    accrual: LoanAccrual.values.byName(j['accrual'] ?? 'monthly'),
    compounding: LoanCompounding.values.byName(j['compounding'] ?? 'none'),
    interestStartsOn: DateTime.tryParse(j['interestStartsOn'] ?? ''),
    maturityDate: DateTime.tryParse(j['maturityDate'] ?? ''),
    interestReminderDate: DateTime.tryParse(j['interestReminderDate'] ?? ''),
    existing: j['existing'] ?? false,
  );
}

enum LoanEventKind { emi, partPayment, rateChange, closure }

class LoanEvent {
  const LoanEvent({
    required this.id,
    required this.kind,
    required this.date,
    this.principal = 0,
    this.interest = 0,
    this.fee = 0,
    this.emiAfter,
    this.rateAfter,
    this.accountId,
    this.transactionId,
    this.accountName,
    this.principalBefore,
    this.interestBefore,
    this.interestAfter,
    this.adopted,
    this.offLedger = false,
  });
  final int id, principal, interest, fee;
  final LoanEventKind kind;
  final DateTime date;
  final int? emiAfter, accountId, transactionId;
  final double? rateAfter;
  final String? accountName;
  final int? principalBefore, interestBefore, interestAfter;

  /// A payment the ledger already had when the loan took it over: what that
  /// transaction was before, as `AdoptedTransaction.toJson`. Undoing gives
  /// it back rather than deleting real history.
  final Map<String, dynamic>? adopted;

  /// A past payment known only from the lender's statement. No account moved,
  /// because the ledger never recorded it.
  final bool offLedger;
  int get amount => principal + interest + fee;
  Map<String, dynamic> toJson() => {
    'date': date.toIso8601String(),
    'principal': principal,
    'interest': interest,
    'fee': fee,
    'emiAfter': emiAfter,
    'rateAfter': rateAfter,
    'accountName': accountName,
    'principalBefore': principalBefore,
    'interestBefore': interestBefore,
    'interestAfter': interestAfter,
    if (adopted != null) 'adopted': adopted,
    if (offLedger) 'offLedger': true,
  };
  factory LoanEvent.fromJson(
    int id,
    String kind,
    Map<String, dynamic> j,
    int? accountId,
    int? transactionId,
  ) => LoanEvent(
    id: id,
    kind: LoanEventKind.values.byName(kind),
    date: DateTime.parse(j['date']),
    principal: j['principal'],
    interest: j['interest'],
    fee: j['fee'],
    emiAfter: j['emiAfter'],
    rateAfter: (j['rateAfter'] as num?)?.toDouble(),
    accountName: j['accountName'],
    accountId: accountId,
    transactionId: transactionId,
    principalBefore: j['principalBefore'],
    interestBefore: j['interestBefore'],
    interestAfter: j['interestAfter'],
    adopted: j['adopted'] == null
        ? null
        : Map<String, dynamic>.from(j['adopted']),
    offLedger: j['offLedger'] ?? false,
  );
}

class Loan {
  Loan({
    required this.id,
    required this.terms,
    required this.accountId,
    this.disbursalId,
    this.chargesId,
    this.events = const [],
  });
  final int id;
  final LoanTerms terms;
  final int? accountId, disbursalId, chargesId;
  final List<LoanEvent> events;

  /// The thing bought is what the borrower recognises the loan by, so it
  /// leads when there is one; otherwise the lender and the kind name it.
  String get title {
    final bought = terms.asset?.trim();
    return bought == null || bought.isEmpty
        ? (terms.tracked
              ? terms.lender
              : '${terms.lender} ${terms.kind.label} loan')
        : '$bought · ${terms.lender}';
  }

  /// Follows [title]: the thing bought's icon when it leads, else the lender's.
  String get icon => terms.displayIcon;

  int get version => events.lastOrNull?.id ?? 0;
  int get outstanding =>
      terms.openingBalance - events.fold(0, (n, e) => n + e.principal);
  bool get closed =>
      outstanding == 0 &&
      (!terms.tracked || unpaidInterestAt(DateTime.now()) == 0);
  int get paid =>
      terms.paidBefore +
      events.where((e) => e.kind == LoanEventKind.emi).length;
  double get rate =>
      events.where((e) => e.rateAfter != null).lastOrNull?.rateAfter ??
      terms.rate;
  int get emi =>
      events.where((e) => e.emiAfter != null).lastOrNull?.emiAfter ?? terms.emi;
  DateTime get nextDue => terms.mode == LoanRepaymentMode.flexible
      ? terms.maturityDate ?? terms.firstDue
      : loanMonth(terms.firstDue, paid - terms.paidBefore, terms.day);

  /// How far along the loan is: principal repaid where payments amortise,
  /// otherwise how much of the term has been served — a gold loan repays no
  /// principal until the very end, and a bar stuck at zero says nothing.
  double get progress => terms.tracked || terms.mode.amortises
      ? (terms.principal - outstanding) / terms.principal
      : (terms.months == 0 ? 0 : paid / terms.months);

  /// Payments left, for the modes whose schedule doesn't work itself out.
  int get remainingMonths => terms.mode == LoanRepaymentMode.bullet
      ? terms.months
      : math.max(1, terms.months - paid);

  late final List<LoanInstallment> schedule = terms.tracked
      ? projectedSchedule(DateTime.now())
      : !terms.hasSchedule
      ? []
      : loanSchedule(
          principal: outstanding,
          rate: rate,
          emi: emi,
          first: nextDue,
          day: terms.day,
          paid: paid,
          mode: terms.mode,
          months: remainingMonths,
          basis: terms.interestBasis,
          originalPrincipal: terms.principal,
        );

  /// Forecast actual allocations from the dated ledger, keeping accrued
  /// interest separate. Overdue payments are estimated as paid today; no
  /// historical principal reduction is invented. Flexible loans have no plan.
  List<LoanInstallment> projectedSchedule(DateTime asOf) {
    if (!terms.mode.amortises || !terms.canEstimate || emi <= 0) return [];
    final today = DateTime(asOf.year, asOf.month, asOf.day);
    if (unpaidInterestAt(today) == null) return [];
    final simulated = [...events];
    final rows = <LoanInstallment>[];
    var balance = outstanding;
    var due = nextDue.isBefore(today) ? today : nextDue;
    var index = 0;
    for (var i = 0; i < 600; i++) {
      final forecast = Loan(
        id: id,
        terms: terms,
        accountId: accountId,
        events: simulated,
      );
      final accrued = forecast.unpaidInterestAt(due);
      if (accrued == null) return [];
      if (balance == 0 && accrued == 0) return rows;
      final interest = math.min(emi, accrued);
      var principal = math.min(balance, emi - interest);
      // Rounding the EMI leaves a few rupees over, which lenders add to the
      // last instalment rather than billing a month more for them.
      if (paid + i + 1 == terms.months && (balance - principal) * 100 <= emi) {
        principal = balance;
      }
      balance -= principal;
      simulated.add(
        LoanEvent(
          id: -i - 1,
          kind: LoanEventKind.emi,
          date: due,
          principal: principal,
          interest: interest,
          interestAfter: accrued - interest,
        ),
      );
      rows.add(
        LoanInstallment(paid + i + 1, due, principal, interest, balance),
      );
      if (balance == 0 && accrued == interest) return rows;
      do {
        index++;
      } while (!loanMonth(nextDue, index, terms.day).isAfter(due));
      due = loanMonth(nextDue, index, terms.day);
    }
    return []; // No supported payoff horizon; do not claim the loan clears.
  }

  /// Simple interest is accumulated unrounded between ledger events. Monthly
  /// accrual prorates over anniversary months; daily uses actual days / 365.
  /// Monthly compounding affects the interest basis, never the principal ledger.
  int? unpaidInterestAt(DateTime date) {
    if (!terms.tracked) return null;
    DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    final target = day(date);
    var cursor = day(terms.snapshotDate ?? terms.startDate!);
    if (target.isBefore(cursor)) return null;
    double? interest = terms.openingInterest?.toDouble();
    var principal = terms.openingBalance;
    var annualRate = terms.rate;
    var rateKnown = terms.rateKnown;
    final anchor = day(terms.startDate!);
    double compoundBase = interest ?? 0;
    void accrue(DateTime until) {
      while (cursor.isBefore(until)) {
        var index =
            (cursor.year - anchor.year) * 12 + cursor.month - anchor.month;
        DateTime anniversary(int i) => day(loanMonth(anchor, i, anchor.day));
        if (anniversary(index).isAfter(cursor)) index--;
        final begin = anniversary(index), end = anniversary(index + 1);
        final stop = end.isBefore(until) ? end : until;
        var from = cursor;
        final starts = terms.interestStartsOn;
        if (starts != null && day(starts).isAfter(from)) from = day(starts);
        if (stop.isAfter(from) &&
            (principal > 0 ||
                (terms.compounding == LoanCompounding.monthly &&
                    compoundBase > 0))) {
          if (!rateKnown ||
              (annualRate != 0 &&
                  (terms.interestBasis == LoanInterestBasis.unknown ||
                      terms.compounding == LoanCompounding.unknown))) {
            interest = null;
          } else if (interest != null) {
            final basis = terms.interestBasis == LoanInterestBasis.original
                ? terms.principal
                : principal;
            final base =
                basis +
                (terms.compounding == LoanCompounding.monthly
                    ? compoundBase
                    : 0);
            final fraction = terms.accrual == LoanAccrual.daily
                ? stop.difference(from).inDays / 365
                : stop.difference(from).inDays /
                      end.difference(begin).inDays /
                      12;
            interest = interest! + base * annualRate / 100 * fraction;
          }
        }
        cursor = stop;
        if (cursor == end) compoundBase = interest ?? 0;
      }
    }

    for (final event in events) {
      final at = day(event.date);
      if (at.isAfter(target)) break;
      if (at.isBefore(cursor)) continue;
      accrue(at);
      principal -= event.principal;
      if (event.interestAfter != null) {
        interest = event.interestAfter!.toDouble();
      } else if (interest != null) {
        interest = math.max(0.0, interest! - event.interest);
      }
      compoundBase = math.max(0.0, compoundBase - event.interest);
      annualRate = event.rateAfter ?? annualRate;
      if (event.rateAfter != null) rateKnown = true;
    }
    accrue(target);
    return interest?.round();
  }

  int? totalOutstandingAt(DateTime date) {
    final interest = unpaidInterestAt(date);
    final principal =
        terms.openingBalance -
        events
            .where((e) => !e.date.isAfter(date))
            .fold<int>(0, (sum, e) => sum + e.principal);
    return interest == null ? null : principal + interest;
  }

  /// What the next payment comes to — the EMI, a month's interest, or the
  /// whole lot at maturity.
  int get nextAmount => schedule.firstOrNull?.amount ?? 0;
  int get futureInterest => math.max(
    0,
    schedule.fold(0, (n, row) => n + row.interest) -
        (terms.tracked ? unpaidInterestAt(DateTime.now()) ?? 0 : 0),
  );
  int get interestPaid => events.fold(0, (n, e) => n + e.interest);

  /// Every charge the loan has drawn: what it cost to take out, plus each
  /// late fee or penalty since. Never part of the principal — penal charges
  /// are not capitalised.
  int get charges => terms.chargesMinor + events.fold(0, (n, e) => n + e.fee);

  /// Everything the loan costs beyond the money borrowed.
  int get totalCost =>
      interestPaid +
      futureInterest +
      charges +
      (terms.tracked ? unpaidInterestAt(DateTime.now()) ?? 0 : 0);
}
