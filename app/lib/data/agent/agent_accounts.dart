import 'package:drift/drift.dart';

import '../../domain/account.dart';
import '../../domain/account_place.dart';
import '../../domain/bank_institution_icon.dart';
import '../../domain/currency_digits.dart';
import '../db/app_database.dart';
import '../repositories/account_repository.dart';
import '../repositories/balance_report_repository.dart';
import '../repositories/transaction_repository.dart';
import 'agent_loans.dart' show isKnownIcon;
import 'agent_suggestion_repository.dart';

/// What an AI app can ask to do to an account. Every one waits for the
/// user's approval, and goes through [AccountRepository] like the app's own
/// account screen.
enum AgentAccountAction {
  create('Add account'),
  update('Edit account'),
  adjustBalance('Set balance'),
  archive('Archive account'),
  restore('Restore account'),
  merge('Merge accounts'),
  delete('Delete account');

  const AgentAccountAction(this.label);
  final String label;

  /// The name tools use, e.g. `adjust_balance`.
  String get toolName => switch (this) {
    adjustBalance => 'adjust_balance',
    _ => name,
  };

  static AgentAccountAction? fromToolName(String? value) =>
      values.where((a) => a.toolName == value).firstOrNull;

  /// Merging and deleting remove an account for good; the rest can be put
  /// back.
  bool get canUndo => this != merge && this != delete;
}

/// The fields of an account a suggestion may set. Null leaves a field as it
/// is (or, for a new account, at its default).
class AgentAccountFields {
  const AgentAccountFields({
    this.name,
    this.type,
    this.currency,
    this.lastDigits,
    this.institution,
    this.icon,
    this.balance,
    this.creditLimit,
    this.availableCredit,
    this.place,
  });

  /// For create: an investment account (a broker, or an in-hand place for
  /// gold or a wallet) rather than a bank, card or cash account.
  final AccountPlace? place;
  final String? name, currency, lastDigits, institution, icon;
  final AccountType? type;

  /// Decimal strings in the account's currency.
  final String? balance, creditLimit, availableCredit;
}

class AgentAccounts {
  AgentAccounts(this.database);
  final AppDatabase database;

  AccountRepository get _accounts => AccountRepository(database);

  Future<AgentSuggestionDraft> prepare({
    required AgentAccountAction action,
    int? accountId,
    int? mergeIntoId,
    AgentAccountFields fields = const AgentAccountFields(),
    String? reason,
  }) async {
    final all = await _accounts.load();
    Account find(int? id, String role) {
      if (id == null) throw ArgumentError('Give $role.');
      return all.where((a) => a.id == id).firstOrNull ??
          (throw ArgumentError('There is no account $id. See list_accounts.'));
    }

    final payload = <String, Object?>{'action': action.toolName};
    final detail = <String>[];
    late final String target;
    late final String summary;

    switch (action) {
      case AgentAccountAction.create:
        final name = _name(fields.name);
        final currency = _currency(fields.currency ?? _defaultCurrency(all));
        final digits = digitsOf(currency);
        final place = fields.place;
        final type = place != null
            ? AccountType.bank
            : (fields.type ?? AccountType.bank);
        final lastDigits = place != null
            ? null
            : _lastDigits(fields.lastDigits, type);
        if (all.any(
          (a) =>
              !a.isArchived &&
              a.name.toLowerCase() == name.toLowerCase() &&
              a.currency == currency,
        )) {
          throw ArgumentError(
            '“$name” already exists. Check list_accounts, or use update.',
          );
        }
        final balance = _minor(fields.balance, digits, 'balance') ?? 0;
        if (place != null && !place.holdsCash && balance != 0) {
          throw ArgumentError(
            'An in-hand place holds no cash. Leave balance out and add what '
            'is kept there with suggest_portfolio_changes.',
          );
        }
        final limit = type == AccountType.creditCard
            ? _minor(fields.creditLimit, digits, 'credit_limit', positive: true)
            : null;
        final available = type == AccountType.creditCard
            ? _minor(
                fields.availableCredit,
                digits,
                'available_credit',
                positive: true,
              )
            : null;
        final institution = _clean(fields.institution);
        payload.addAll({
          'name': name,
          'type': type.name,
          'currency': currency,
          'digits': digits,
          'lastDigits': lastDigits,
          'institution': institution,
          'icon':
              _icon(fields.icon) ??
              (institution == null
                  ? (type == AccountType.cash ? 'wallet_one' : null)
                  : bankInstitutionIcon(
                      institution,
                      creditCard: type == AccountType.creditCard,
                    )),
          'balance': balance,
          'creditLimit': limit,
          'availableCredit': available,
          if (place != null) ...{'broker': true, 'place': place.name},
        });
        target = 'new:${name.toLowerCase()}:$currency';
        summary = '${action.label} · $name';
        detail.addAll([
          '${place?.tag ?? type.label} · $currency',
          if (lastDigits != null) 'Ending •• $lastDigits',
          if (place == null || place.holdsCash)
            '${place == null ? 'Opening balance' : 'Funds'} ${_money(balance, digits, currency)}',
          if (limit != null) 'Credit limit ${_money(limit, digits, currency)}',
        ]);

      case AgentAccountAction.update:
        final account = find(accountId, 'account_id');
        final name = fields.name == null ? null : _name(fields.name);
        final type = fields.type;
        final currency = fields.currency == null
            ? null
            : _currency(fields.currency!);
        final digits = currency == null ? account.digits : digitsOf(currency);
        final lastDigits = fields.lastDigits == null
            ? null
            : _lastDigits(fields.lastDigits, type ?? account.type);
        final cardAfter = (type ?? account.type) == AccountType.creditCard;
        final limit = cardAfter
            ? _minor(fields.creditLimit, digits, 'credit_limit', positive: true)
            : null;
        final available = cardAfter
            ? _minor(
                fields.availableCredit,
                digits,
                'available_credit',
                positive: true,
              )
            : null;
        final icon = _icon(fields.icon);
        final institution = _clean(fields.institution);
        void change(String label, Object? before, Object? after) {
          if (after != null && after != before) {
            detail.add('$label: ${before ?? '—'} → $after');
          }
        }

        change('Name', account.name, name);
        change('Type', account.type.label, type?.label);
        change('Currency', account.currency, currency);
        change('Last digits', account.lastDigits, lastDigits);
        change('Bank', account.institution, institution);
        if (icon != null && icon != account.icon) detail.add('New icon');
        String? shown(int? minor) => minor == null
            ? null
            : _money(minor, digits, currency ?? account.currency);
        change('Credit limit', shown(account.creditLimitMinor), shown(limit));
        change(
          'Available credit',
          shown(account.availableCreditLimitMinor),
          shown(available),
        );
        if (detail.isEmpty) {
          throw ArgumentError('Nothing to change on “${account.name}”.');
        }
        payload.addAll({
          'accountId': account.id,
          'name': ?name,
          'type': ?type?.name,
          'currency': ?currency,
          if (currency != null) 'digits': digits,
          'lastDigits': ?lastDigits,
          'institution': ?institution,
          'icon': ?icon,
          'creditLimit': ?limit,
          'availableCredit': ?available,
        });
        target = 'account:${account.id}:update';
        summary = '${action.label} · ${account.name}';

      case AgentAccountAction.adjustBalance:
        final account = find(accountId, 'account_id');
        final balance =
            _minor(fields.balance, account.digits, 'balance') ??
            (throw ArgumentError('Give balance: what the account holds now.'));
        if (balance == account.balanceMinor) {
          throw ArgumentError('“${account.name}” already shows that balance.');
        }
        payload.addAll({'accountId': account.id, 'balance': balance});
        target = 'account:${account.id}:balance';
        summary = '${action.label} · ${account.name}';
        detail.add(
          '${_money(account.balanceMinor, account.digits, account.currency)}'
          ' → ${_money(balance, account.digits, account.currency)}',
        );

      case AgentAccountAction.archive || AgentAccountAction.restore:
        final account = find(accountId, 'account_id');
        final archiving = action == AgentAccountAction.archive;
        if (account.isArchived == archiving) {
          throw ArgumentError(
            '“${account.name}” is ${archiving ? 'already' : 'not'} archived.',
          );
        }
        payload['accountId'] = account.id;
        target = 'account:${account.id}:archive';
        summary = '${action.label} · ${account.name}';
        detail.add(
          archiving
              ? 'Hidden from accounts and totals; ${account.transactionCount} transactions kept'
              : 'Back in accounts and totals',
        );

      case AgentAccountAction.merge:
        final source = find(accountId, 'account_id (the one to remove)');
        final into = find(mergeIntoId, 'merge_into_id (the one to keep)');
        _checkMerge(source, into);
        payload.addAll({'accountId': source.id, 'mergeIntoId': into.id});
        target = 'account:${source.id}:remove';
        summary = '${action.label} · ${source.name} → ${into.name}';
        detail.addAll([
          '${source.transactionCount} transactions move to ${into.name}',
          'New balance ${_money(source.balanceMinor + into.balanceMinor, into.digits, into.currency)}',
          '${source.name} is removed',
        ]);

      case AgentAccountAction.delete:
        final account = find(accountId, 'account_id');
        payload['accountId'] = account.id;
        target = 'account:${account.id}:remove';
        summary = '${action.label} · ${account.name}';
        detail.add(
          '${account.transactionCount} transactions deleted with it; '
          'other balances stay the same',
        );
    }

    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.account,
      target: target,
      payload: payload,
      summary: summary,
      detail: detail,
      reason: switch (reason?.trim()) {
        null || '' => null,
        final r when r.length > 280 => '${r.substring(0, 279)}…',
        final r => r,
      },
    );
  }

  /// Carries out an approved suggestion. Returns what undoing needs.
  Future<Map<String, Object?>> apply(Map<String, Object?> p) async {
    final action = AgentAccountAction.fromToolName(p['action'] as String?)!;
    final all = await _accounts.load();
    Account account() =>
        all.where((a) => a.id == p['accountId']).firstOrNull ??
        (throw StateError('This account no longer exists.'));

    switch (action) {
      case AgentAccountAction.create:
        final type = AccountType.values.byName(p['type'] as String);
        final id = await _accounts.save(
          name: p['name'] as String,
          type: type,
          currency: p['currency'] as String,
          digits: p['digits'] as int,
          lastDigits: p['lastDigits'] as String?,
          institution: p['institution'] as String?,
          icon: p['icon'] as String?,
          openingBalance: p['balance'] as int,
          creditLimitMinor: p['creditLimit'] as int?,
          availableCreditLimitMinor: p['availableCredit'] as int?,
          broker: p['broker'] == true,
          place: p['place'] as String?,
        );
        return {'accountId': id};

      case AgentAccountAction.update:
        final before = account();
        await _update(before, p);
        return {'accountId': before.id, 'previous': _snapshot(before)};

      case AgentAccountAction.adjustBalance:
        final before = account();
        final difference = (p['balance'] as int) - before.balanceMinor;
        final reports = BalanceReportRepository(database);
        final entry = difference == 0
            ? null
            : await reports.record(
                before.id,
                difference,
                DateTime.now(),
                note: 'Set by an approved AI suggestion',
              );
        await reports.settleLatest(before.id);
        return {
          'accountId': before.id,
          'balance': before.balanceMinor,
          'transactionId': ?entry,
        };

      case AgentAccountAction.archive:
        await _accounts.archive(account().id);
        return {'accountId': p['accountId']};

      case AgentAccountAction.restore:
        await _accounts.restore(account().id);
        return {'accountId': p['accountId']};

      case AgentAccountAction.merge:
        final source = account();
        final into =
            all.where((a) => a.id == p['mergeIntoId']).firstOrNull ??
            (throw StateError('The account to merge into no longer exists.'));
        _checkMerge(source, into);
        await _accounts.merge(sourceId: source.id, targetId: into.id);
        return {};

      case AgentAccountAction.delete:
        await _accounts.delete(account().id);
        return {};
    }
  }

  /// Puts back what [apply] changed, from what it returned.
  Future<void> undo(String actionName, Map<String, Object?> before) async {
    final action = AgentAccountAction.fromToolName(actionName);
    final id = before['accountId'] as int;
    switch (action) {
      case AgentAccountAction.create:
        final count = await database
            .customSelect(
              'SELECT transaction_count FROM accounts WHERE id = ?',
              variables: [Variable(id)],
            )
            .getSingleOrNull();
        if (count == null) return;
        if (count.read<int>('transaction_count') > 0) {
          throw StateError(
            'This account has transactions now. Archive or delete it from its own screen.',
          );
        }
        await _accounts.delete(id);
      case AgentAccountAction.update:
        final current = (await _accounts.load())
            .where((a) => a.id == id)
            .firstOrNull;
        if (current == null) throw StateError('This account no longer exists.');
        await _update(
          current,
          Map<String, Object?>.from(before['previous'] as Map),
          replaceLimits: true,
        );
      case AgentAccountAction.adjustBalance:
        // Taking the entry out puts the balance back. One the user already
        // deleted has done that.
        if (before['transactionId'] case final int entry) {
          final transactions = TransactionRepository(database);
          if ((await transactions.load(id: entry)).isNotEmpty) {
            await transactions.delete(entry);
          }
        } else {
          // Approved before adjustments had entries.
          await _setBalance(id, before['balance'] as int);
        }
      case AgentAccountAction.archive:
        await _accounts.restore(id);
      case AgentAccountAction.restore:
        await _accounts.archive(id);
      case AgentAccountAction.merge || AgentAccountAction.delete || null:
        throw StateError('This change can’t be undone.');
    }
  }

  // ── Helpers. ──

  Future<void> _update(
    Account existing,
    Map<String, Object?> p, {
    bool replaceLimits = false,
  }) async {
    final hasLimits =
        replaceLimits ||
        p.containsKey('creditLimit') ||
        p.containsKey('availableCredit');
    await _accounts.save(
      existing: existing,
      name: p['name'] as String? ?? existing.name,
      type: switch (p['type']) {
        final String t => AccountType.values.byName(t),
        _ => existing.type,
      },
      currency: p['currency'] as String? ?? existing.currency,
      digits: p['digits'] as int? ?? existing.digits,
      territory: p.containsKey('currency') ? null : existing.territory,
      lastDigits: p['lastDigits'] as String?,
      institution: p['institution'] as String?,
      icon: p['icon'] as String? ?? existing.icon,
      openingBalance: existing.balanceMinor,
      updateCreditLimits: hasLimits,
      creditLimitMinor: hasLimits
          ? (p.containsKey('creditLimit')
                ? p['creditLimit'] as int?
                : existing.creditLimitMinor)
          : null,
      availableCreditLimitMinor: hasLimits
          ? (p.containsKey('availableCredit')
                ? p['availableCredit'] as int?
                : existing.availableCreditLimitMinor)
          : null,
    );
  }

  Map<String, Object?> _snapshot(Account a) => {
    'name': a.name,
    'type': a.type.name,
    'currency': a.currency,
    'digits': a.digits,
    'lastDigits': ?a.lastDigits,
    'institution': ?a.institution,
    'icon': ?a.icon,
    'creditLimit': a.creditLimitMinor,
    'availableCredit': a.availableCreditLimitMinor,
  };

  /// Puts a balance back without an entry.
  Future<void> _setBalance(int id, int minor) => database.customUpdate(
    'UPDATE accounts SET balance_minor = ? WHERE id = ?',
    variables: [Variable(minor), Variable(id)],
  );

  static void _checkMerge(Account source, Account into) {
    if (source.id == into.id) {
      throw ArgumentError('An account can’t merge into itself.');
    }
    if (into.isArchived) {
      throw ArgumentError('“${into.name}” is archived; restore it first.');
    }
    if (source.currency != into.currency || source.digits != into.digits) {
      throw ArgumentError('Only accounts in the same currency can merge.');
    }
  }

  static String _defaultCurrency(List<Account> all) =>
      all.where((a) => !a.isArchived).firstOrNull?.currency ?? 'INR';

  static String _name(String? value) {
    final clean = value?.trim() ?? '';
    if (clean.isEmpty || clean.length > 40) {
      throw ArgumentError('Give a name of 1–40 characters.');
    }
    return clean;
  }

  static String _currency(String value) {
    final code = value.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
      throw ArgumentError('currency must be a 3-letter code such as INR.');
    }
    return code;
  }

  static int digitsOf(String currency) =>
      currencyDigitsOtherThanTwo[currency] ?? 2;

  static String? _lastDigits(String? value, AccountType type) {
    final clean = value?.trim();
    if (clean == null || clean.isEmpty || type == AccountType.cash) return null;
    if (!RegExp(r'^\d{2,4}$').hasMatch(clean)) {
      throw ArgumentError('last_digits must be 2 to 4 digits.');
    }
    return clean;
  }

  static String? _clean(String? value) {
    final clean = value?.trim() ?? '';
    return clean.isEmpty ? null : clean;
  }

  static String? _icon(String? key) {
    if (key == null) return null;
    if (!isKnownIcon(key)) {
      throw ArgumentError('Unknown icon “$key”. Pick one from list_icons.');
    }
    return key;
  }

  static int? _minor(
    String? value,
    int digits,
    String field, {
    bool positive = false,
  }) {
    if (value == null) return null;
    final minor = parseAccountAmount(value.replaceAll(',', ''), digits);
    if (minor == null || (positive && minor < 0)) {
      throw ArgumentError('$field must be an amount like 1250.00.');
    }
    return minor;
  }

  static String _money(int minor, int digits, String currency) =>
      formatAccountMoney(minor, digits: digits, currency: currency);
}
