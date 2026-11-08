import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repositories/subscription_repository.dart';
import '../data/subscription_reminders.dart';
import '../domain/subscription.dart';
import 'account_store.dart';
import 'category_store.dart';
import 'transaction_store.dart';

class SubscriptionStore extends ChangeNotifier {
  SubscriptionStore(
    this.repository, {
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    SubscriptionReminders? reminders,
  }) : reminders = reminders ?? SubscriptionReminders() {
    // Deleting an account or category detaches it from subscriptions.
    accountStore.addListener(_changed);
    categoryStore.addListener(_changed);
  }
  final SubscriptionRepository repository;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final SubscriptionReminders reminders;
  List<Subscription> subscriptions = [];
  bool loading = true, saving = false, _disposed = false;
  String? error;
  int _generation = 0;

  Subscription? byId(int id) =>
      subscriptions.where((s) => s.id == id).firstOrNull;

  Future<void> load() async {
    final generation = ++_generation;
    try {
      final result = await repository.load();
      if (_disposed || generation != _generation) return;
      subscriptions = result;
      error = null;
      unawaited(reminders.reschedule(result));
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error = 'Your subscriptions could not be loaded. Please try again.';
    }
    loading = false;
    _notify();
  }

  /// Runs [action], then reloads everything a payment it logged touched.
  Future<T> save<T>(Future<T> Function() action) async {
    if (saving) throw StateError('A subscription is already being saved.');
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
