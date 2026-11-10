import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../data/repositories/transaction_repository.dart';
import '../domain/account.dart';
import '../domain/title_suggestions.dart';
import '../domain/transaction.dart';
import 'account_store.dart';

class TransactionStore extends ChangeNotifier {
  TransactionStore(this.repository, this.accountStore);
  final TransactionRepository repository;

  /// Every operation here moves money between accounts, so the account
  /// list is reloaded after each save — otherwise balances shown elsewhere
  /// (Accounts screen, Home) would silently go stale.
  final AccountStore accountStore;
  List<MoneyTransaction> _transactions = [];

  /// A read-only view, not a copy: the screens read this many times a frame,
  /// and the list is only ever replaced, never edited in place.
  List<MoneyTransaction> get transactions =>
      UnmodifiableListView(_transactions);

  /// Past titles to offer while one is typed, indexed on first use and again
  /// only after the ledger changes.
  TitleSuggestions get titleSuggestions =>
      _titleSuggestions ??= TitleSuggestions(_transactions);
  TitleSuggestions? _titleSuggestions;
  bool loading = true;
  bool saving = false;
  String? loadError;

  Future<void> load() async {
    loading = true;
    loadError = null;
    notifyListeners();
    try {
      _transactions = await repository.load();
      _titleSuggestions = null;
    } catch (_) {
      loadError = 'Your transactions could not be loaded. Please try again.';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> addExpenseOrIncome({
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    required int categoryId,
    String? title,
    String? note,
    required DateTime date,
  }) async {
    if (saving) throw StateError('A transaction is already being saved.');
    saving = true;
    notifyListeners();
    try {
      final id = await repository.addExpenseOrIncome(
        type: type,
        amountMinor: amountMinor,
        accountId: accountId,
        categoryId: categoryId,
        title: title,
        note: note,
        date: date,
      );
      await Future.wait([_reloadTransaction(id), accountStore.load()]);
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> updateExpenseOrIncome({
    required int id,
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    required int categoryId,
    String? title,
    String? note,
    required DateTime date,
  }) async {
    if (saving) throw StateError('A transaction is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await repository.updateExpenseOrIncome(
        id: id,
        type: type,
        amountMinor: amountMinor,
        accountId: accountId,
        categoryId: categoryId,
        title: title,
        note: note,
        date: date,
      );
      await Future.wait([_reloadTransaction(id), accountStore.load()]);
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// Rewrites any transaction, kind included; see
  /// [TransactionRepository.edit].
  Future<void> edit({
    required int id,
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    int? toAccountId,
    int? categoryId,
    String? title,
    String? note,
    required DateTime date,
  }) async {
    if (saving) throw StateError('A transaction is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await repository.edit(
        id: id,
        type: type,
        amountMinor: amountMinor,
        accountId: accountId,
        toAccountId: toAccountId,
        categoryId: categoryId,
        title: title,
        note: note,
        date: date,
      );
      await Future.wait([_reloadTransaction(id), accountStore.load()]);
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> addTransfer({
    required int amountMinor,
    required int fromAccountId,
    required int toAccountId,
    int? toAmountMinor,
    String? note,
    required DateTime date,
  }) async {
    if (saving) throw StateError('A transaction is already being saved.');
    saving = true;
    notifyListeners();
    try {
      final id = await repository.addTransfer(
        amountMinor: amountMinor,
        fromAccountId: fromAccountId,
        toAccountId: toAccountId,
        toAmountMinor: toAmountMinor,
        note: note,
        date: date,
      );
      await Future.wait([_reloadTransaction(id), accountStore.load()]);
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> adjustBalance({
    required int accountId,
    required BalanceAdjustmentMode mode,
    required int amountMinor,
  }) async {
    if (saving) throw StateError('A transaction is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await repository.adjustBalance(
        accountId: accountId,
        mode: mode,
        amountMinor: amountMinor,
      );
      await accountStore.load();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// Permanently removes a transaction and reverses its effect on the
  /// balance(s) it moved.
  Future<void> deleteTransaction(int id) async {
    if (saving) throw StateError('A transaction is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await repository.delete(id);
      await Future.wait([_reload(), accountStore.load()]);
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> deleteAccount(int id) async {
    if (saving) throw StateError('A transaction is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await accountStore.delete(id);
      await _reload();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// Archiving and restoring leave the transactions alone, but both change
  /// which accounts are in play, so the ledger is reread the same way.
  Future<void> archiveAccount(int id) =>
      _withAccounts(() => accountStore.archive(id));

  Future<void> restoreAccount(int id) =>
      _withAccounts(() => accountStore.restore(id));

  Future<void> _withAccounts(Future<void> Function() action) async {
    if (saving) throw StateError('A transaction is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await action();
      await _reload();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// Picks up transactions something else (a debt) added or removed,
  /// without passing through [loading].
  Future<void> refresh() async {
    await _reload();
    notifyListeners();
  }

  /// Preserve the complete history for consumers, but only requery the row
  /// changed by a local save. Imports and restore still use a full refresh.
  Future<void> _reloadTransaction(int id) async {
    if (loading || loadError != null) {
      await _reload();
      return;
    }
    final updated = await repository.load(id: id);
    _transactions =
        [
          for (final transaction in _transactions)
            if (transaction.id != id) transaction,
          ...updated,
        ]..sort((a, b) {
          final date = b.date.compareTo(a.date);
          return date != 0 ? date : b.id.compareTo(a.id);
        });
    _titleSuggestions = null;
  }

  Future<void> _reload() async {
    _transactions = await repository.load();
    _titleSuggestions = null;
  }
}
