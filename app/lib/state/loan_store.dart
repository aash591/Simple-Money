import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/loan_reminders.dart';
import '../data/repositories/loan_repository.dart';
import '../domain/loan.dart';
import 'account_store.dart';
import 'category_store.dart';
import 'transaction_store.dart';

class LoanStoreScope extends InheritedNotifier<LoanStore> {
  const LoanStoreScope({
    super.key,
    required LoanStore store,
    required super.child,
  }) : super(notifier: store);

  static LoanStore? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<LoanStoreScope>()?.notifier;
}

class LoanStore extends ChangeNotifier {
  LoanStore(
    this.repository, {
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    LoanReminders? reminders,
  }) : reminders = reminders ?? LoanReminders() {
    transactionStore.addListener(_changed);
  }
  final LoanRepository repository;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final LoanReminders reminders;
  List<Loan> loans = [];
  bool loading = true, saving = false, _disposed = false;
  String? error;
  int _generation = 0;
  Loan? byId(int id) => loans.where((l) => l.id == id).firstOrNull;

  Future<void> load() async {
    final generation = ++_generation;
    try {
      final result = await repository.load();
      if (_disposed || generation != _generation) return;
      loans = result;
      error = null;
      unawaited(reminders.reschedule(result));
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error = 'Your loans could not be loaded. Please try again.';
    }
    loading = false;
    _notify();
  }

  Future<T> save<T>(Future<T> Function() action) async {
    if (saving) throw StateError('A loan is already being saved.');
    saving = true;
    _notify();
    try {
      final result = await action();
      await Future.wait([
        accountStore.load(),
        categoryStore.load(),
        transactionStore.refresh(),
      ]);
      await load();
      return result;
    } finally {
      saving = false;
      _notify();
    }
  }

  void _changed() {
    if (!saving && !transactionStore.loading && !transactionStore.saving) {
      unawaited(load());
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    transactionStore.removeListener(_changed);
    super.dispose();
  }
}
