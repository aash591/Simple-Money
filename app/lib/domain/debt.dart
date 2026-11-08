/// Money lent to or borrowed from someone, and paying it back. Everything is
/// kept per person: each entry moves the running balance with them one way
/// or the other, and a balance of zero means you're settled.
library;

/// What an entry does. [lend] and [borrow] open a debt; [collect] (they pay
/// you back) and [repay] (you pay them back) settle one.
enum DebtKind { lend, borrow, collect, repay }

extension DebtKindStorage on DebtKind {
  String get storageValue => name;

  static DebtKind fromStorage(String value) => DebtKind.values.firstWhere(
    (kind) => kind.name == value,
    orElse: () => DebtKind.lend,
  );

  /// +1 when the entry leaves the person owing you more (or you owing them
  /// less), -1 otherwise.
  int get sign => switch (this) {
    DebtKind.lend || DebtKind.repay => 1,
    DebtKind.borrow || DebtKind.collect => -1,
  };

  /// Whether the money left your account (lending, paying back) rather than
  /// arriving in it.
  bool get paysOut => this == DebtKind.lend || this == DebtKind.repay;

  /// Only these can carry a due date.
  bool get opensDebt => this == DebtKind.lend || this == DebtKind.borrow;

  /// Lending and being paid back concern money owed to you; borrowing and
  /// paying back, money you owe.
  bool get concernsOwedToYou =>
      this == DebtKind.lend || this == DebtKind.collect;
}

class DebtPerson {
  const DebtPerson({required this.id, required this.name, this.phone});
  final int id;
  final String name;

  /// Filled in when the person was picked from contacts.
  final String? phone;
}

class DebtEntry {
  const DebtEntry({
    required this.id,
    required this.personId,
    required this.kind,
    required this.amountMinor,
    required this.currency,
    required this.digits,
    this.accountId,
    this.transactionId,
    this.note,
    required this.date,
    this.dueDate,
  });
  final int id, personId;
  final DebtKind kind;

  /// Always positive; direction is implied by [kind].
  final int amountMinor;
  final String currency;
  final int digits;

  /// The account the money moved through, and the transaction recorded
  /// there. Both null for an entry that's only a record.
  final int? accountId, transactionId;
  final String? note;
  final DateTime date;
  final DateTime? dueDate;

  int get signedMinor => kind.sign * amountMinor;
}

/// What's outstanding with someone in one currency: positive when they owe
/// you, negative when you owe them. Never zero.
class DebtBalance {
  const DebtBalance(this.currency, this.digits, this.amountMinor);
  final String currency;
  final int digits;
  final int amountMinor;

  bool sameCurrency(String currency, int digits) =>
      this.currency == currency && this.digits == digits;
}

class PersonDebts {
  PersonDebts(this.person, this.entries);
  final DebtPerson person;

  /// Newest first.
  final List<DebtEntry> entries;

  /// Outstanding balances, in the order their currency was first used.
  late final List<DebtBalance> balances = _balances();

  /// The earliest due date among the debts still open. A debt paid off in
  /// full no longer counts, even if a new one is opened later.
  late final DateTime? dueDate = _dueDate();

  bool get settled => balances.isEmpty;

  /// Grouped by the first balance: a person owing you in one currency while
  /// you owe them in another is rare enough not to split them in two.
  bool get owesYou => balances.isNotEmpty && balances.first.amountMinor > 0;

  /// Which side they're listed on: the way the balance runs or, once
  /// settled, the way their latest entry did.
  bool get onOwedToYouSide => balances.isNotEmpty
      ? owesYou
      : entries.firstOrNull?.kind.concernsOwedToYou ?? true;

  DebtBalance? balanceIn(String currency, int digits) => balances
      .where((balance) => balance.sameCurrency(currency, digits))
      .firstOrNull;

  List<DebtEntry> get _chronological => entries.reversed.toList();

  List<DebtBalance> _balances() {
    final totals = <(String, int), int>{};
    for (final entry in _chronological) {
      final key = (entry.currency, entry.digits);
      totals[key] = (totals[key] ?? 0) + entry.signedMinor;
    }
    return [
      for (final MapEntry(key: (currency, digits), :value) in totals.entries)
        if (value != 0) DebtBalance(currency, digits, value),
    ];
  }

  DateTime? _dueDate() {
    final totals = <(String, int), int>{};
    final open = <({(String, int) key, int sign, DateTime due})>[];
    for (final entry in _chronological) {
      final key = (entry.currency, entry.digits);
      final total = (totals[key] ?? 0) + entry.signedMinor;
      totals[key] = total;
      final due = entry.dueDate;
      if (entry.kind.opensDebt && due != null) {
        open.add((key: key, sign: entry.kind.sign, due: due));
      }
      if (total == 0) open.removeWhere((debt) => debt.key == key);
    }
    DateTime? earliest;
    for (final debt in open) {
      final total = totals[debt.key]!;
      if (total.sign != debt.sign) continue;
      if (earliest == null || debt.due.isBefore(earliest)) earliest = debt.due;
    }
    return earliest;
  }
}
