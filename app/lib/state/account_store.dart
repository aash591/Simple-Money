import 'package:flutter/foundation.dart';

import '../data/repositories/account_repository.dart';
import '../domain/account.dart';

class AccountStore extends ChangeNotifier {
  AccountStore(this.repository);
  final AccountRepository repository;
  List<Account> _accounts = [];

  /// The accounts you can still use: archived ones are left out, which is what
  /// keeps them out of every picker, total and currency scope without each of
  /// those having to know archiving exists. Use [allAccounts] to resolve an id
  /// that history may refer to.
  List<Account> get accounts =>
      List.unmodifiable(_accounts.where((a) => !a.isArchived));

  /// Every account including the archived, for looking one up by id — a past
  /// transaction still has to name the account it was made in.
  List<Account> get allAccounts => List.unmodifiable(_accounts);

  /// The archived accounts, newest first.
  List<Account> get archivedAccounts => List.unmodifiable(
    _accounts.where((a) => a.isArchived).toList()
      ..sort((a, b) => b.archivedAt!.compareTo(a.archivedAt!)),
  );

  Account? byId(int? id) {
    if (id == null) return null;
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  bool loading = true;
  bool saving = false;
  String? loadError;

  Future<void> load({bool initializeDefault = false}) async {
    loading = true;
    loadError = null;
    notifyListeners();
    try {
      if (initializeDefault) await repository.ensureDefaultCashAccount();
      _accounts = await repository.load();
    } catch (_) {
      loadError = 'Your accounts could not be loaded. Please try again.';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> save({
    Account? existing,
    AccountType? type,
    String? lastDigits,
    String? institution,
    int? creditLimitMinor,
    int? availableCreditLimitMinor,
    bool updateCreditLimits = false,
    required String name,
    required String currency,
    String? territory,
    String? icon,
    required int digits,
    required int openingBalance,
  }) async {
    if (saving) throw StateError('An account update is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await repository.save(
        existing: existing,
        type: type,
        lastDigits: lastDigits,
        institution: institution,
        creditLimitMinor: creditLimitMinor,
        availableCreditLimitMinor: availableCreditLimitMinor,
        updateCreditLimits: updateCreditLimits,
        name: name,
        currency: currency,
        territory: territory,
        icon: icon,
        digits: digits,
        openingBalance: openingBalance,
      );
      _accounts = await repository.load();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> delete(int id) async {
    if (saving) throw StateError('An account update is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await repository.delete(id);
      _accounts = await repository.load();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> archive(int id) => _retire(() => repository.archive(id));

  Future<void> restore(int id) => _retire(() => repository.restore(id));

  Future<void> _retire(Future<void> Function() action) async {
    if (saving) throw StateError('An account update is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await action();
      _accounts = await repository.load();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// Reorders the *active* accounts — the indices come from the list the
  /// accounts screen shows, which is [accounts]. The archived keep their
  /// relative order and are written out after them, so one `sort_order`
  /// sequence still covers every row.
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (saving) return;
    if (newIndex == oldIndex) return;
    final previous = _accounts;
    final active = previous.where((a) => !a.isArchived).toList();
    if (oldIndex >= active.length || newIndex >= active.length) return;
    active.insert(newIndex, active.removeAt(oldIndex));
    final updated = [...active, ...previous.where((a) => a.isArchived)];
    _accounts = updated;
    saving = true;
    notifyListeners();
    try {
      await repository.reorder(updated);
    } catch (_) {
      _accounts = previous;
      rethrow;
    } finally {
      saving = false;
      notifyListeners();
    }
  }
}
