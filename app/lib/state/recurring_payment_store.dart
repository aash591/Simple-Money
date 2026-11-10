import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repositories/recurring_payment_repository.dart';
import '../data/recurring_payment_reminders.dart';
import '../domain/recurring_payment.dart';
import 'account_store.dart';
import 'category_store.dart';
import 'transaction_store.dart';

class RecurringPaymentStore extends ChangeNotifier {
  RecurringPaymentStore(
    this.repository, {
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    RecurringPaymentReminders? reminders,
  }) : reminders = reminders ?? RecurringPaymentReminders() {
    // Deleting an account or category detaches it from recurring payments.
    accountStore.addListener(_changed);
    categoryStore.addListener(_changed);
  }
  final RecurringPaymentRepository repository;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final RecurringPaymentReminders reminders;
  List<RecurringPayment> recurringPayments = [];
  bool loading = true, saving = false, _disposed = false;
  String? error;
  int _generation = 0;

  RecurringPayment? byId(int id) =>
      recurringPayments.where((s) => s.id == id).firstOrNull;

  Future<void> load() async {
    final generation = ++_generation;
    try {
      final result = await repository.load();
      if (_disposed || generation != _generation) return;
      recurringPayments = result;
      error = null;
      unawaited(reminders.reschedule(result));
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error = 'Your recurring payments could not be loaded. Please try again.';
    }
    loading = false;
    _notify();
  }

  /// Runs [action], then reloads everything a payment it logged touched.
  Future<T> save<T>(Future<T> Function() action) async {
    if (saving) throw StateError('A recurring payment is already being saved.');
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
    if (!saving && !accountStore.loading && !categoryStore.loading) {
      unawaited(load());
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    accountStore.removeListener(_changed);
    categoryStore.removeListener(_changed);
    super.dispose();
  }
}
