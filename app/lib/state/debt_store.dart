import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/debt_reminders.dart';
import '../data/repositories/debt_repository.dart';
import '../domain/debt.dart';
import 'account_store.dart';
import 'category_store.dart';
import 'transaction_store.dart';

class DebtStoreScope extends InheritedNotifier<DebtStore> {
  const DebtStoreScope({
    super.key,
    required DebtStore store,
    required super.child,
  }) : super(notifier: store);

  static DebtStore? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DebtStoreScope>()?.notifier;
}

class DebtStore extends ChangeNotifier {
  DebtStore(
    this.repository, {
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    DebtReminders? reminders,
  }) : reminders = reminders ?? DebtReminders() {
    transactionStore.addListener(_onTransactionsChanged);
  }
  final DebtRepository repository;
  final AccountStore accountStore;
  final CategoryStore categoryStore;

  /// Entries linked to an account add and remove transactions, while
  /// deleting a transaction or an account elsewhere removes or unlinks
  /// entries — so each reloads when the other changes.
  final TransactionStore transactionStore;
  final DebtReminders reminders;

  List<PersonDebts> _people = [];
  List<PersonDebts> get people => List.unmodifiable(_people);
  bool loading = true;
  bool saving = false;
  String? loadError;
  var _generation = 0;
  var _disposed = false;

  /// Fills the store with [people] without touching the database, for
  /// screens that show example data. Nothing is saved.
  void usePreview(List<PersonDebts> people) {
    _people = people;
    loading = false;
    _notify();
  }

  PersonDebts? personById(int id) =>
      _people.where((debts) => debts.person.id == id).firstOrNull;

  /// Only the first load shows as loading; reloads keep the list on screen
  /// (see TransactionStore.load).
  bool _loaded = false;

  Future<void> load() async {
    if (!_loaded) {
      loading = true;
      loadError = null;
      _notify();
    }
    try {
      await _reload();
      _loaded = true;
      loadError = null;
    } catch (_) {
      if (!_loaded) {
        loadError = 'Your debts could not be loaded. Please try again.';
      }
    }
    loading = false;
    _notify();
  }

  /// See [DebtRepository.addEntry]. Returns the person's id.
  Future<int> addEntry({
    int? personId,
    String? newPersonName,
    String? newPersonPhone,
    required DebtKind kind,
    required int amountMinor,
    int? accountId,
    String? currency,
    int? digits,
    String? note,
    required DateTime date,
    DateTime? dueDate,
  }) => _save(() async {
    final result = await repository.addEntry(
      personId: personId,
      newPersonName: newPersonName,
      newPersonPhone: newPersonPhone,
      kind: kind,
      amountMinor: amountMinor,
      accountId: accountId,
      currency: currency,
      digits: digits,
      note: note,
      date: date,
      dueDate: dueDate,
    );
    await Future.wait([
      if (accountId != null) ...[
        transactionStore.refresh(),
        accountStore.load(),
      ],
      if (result.addedCategory) categoryStore.load(),
    ]);
    return result.personId;
  });

  Future<void> deleteEntry(DebtEntry entry) => _save(() async {
    await repository.deleteEntry(entry.id);
    if (entry.transactionId != null) await _reloadLedger();
  });

  Future<void> deletePerson(PersonDebts debts) => _save(() async {
    await repository.deletePerson(debts.person.id);
    if (debts.entries.any((entry) => entry.transactionId != null)) {
      await _reloadLedger();
    }
  });

  /// See [DebtRepository.updatePerson].
  Future<void> updatePerson(int id, {required String name, String? phone}) =>
      _save(() async {
        final debts = personById(id);
        await repository.updatePerson(id, name: name, phone: phone);
        if (debts?.entries.any((entry) => entry.transactionId != null) ??
            false) {
          await transactionStore.refresh();
        }
      });

  /// See [DebtRepository.updateEntry].
  Future<void> updateEntry(
    DebtEntry entry, {
    required int amountMinor,
    int? accountId,
    String? currency,
    int? digits,
    String? note,
    required DateTime date,
    DateTime? dueDate,
  }) => _save(() async {
    final result = await repository.updateEntry(
      id: entry.id,
      amountMinor: amountMinor,
      accountId: accountId,
      currency: currency,
      digits: digits,
      note: note,
      date: date,
      dueDate: dueDate,
    );
    await Future.wait([
      if (accountId != null || entry.transactionId != null) _reloadLedger(),
      if (result.addedCategory) categoryStore.load(),
    ]);
  });

  Future<void> _reloadLedger() =>
      Future.wait([transactionStore.refresh(), accountStore.load()]);

  Future<T> _save<T>(Future<T> Function() action) async {
    if (saving) throw StateError('A debt is already being saved.');
    saving = true;
    _notify();
    try {
      final result = await action();
      await _reload();
      return result;
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    final people = await repository.load();
    // A later reload started meanwhile: its result is the one to keep.
    if (generation != _generation || _disposed) return;
    _people = people;
    unawaited(reminders.reschedule(people));
  }

  void _onTransactionsChanged() {
    if (saving || loading || transactionStore.saving) return;
    if (transactionStore.loading) return;
    _reload().then((_) => _notify(), onError: (Object _) {});
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    transactionStore.removeListener(_onTransactionsChanged);
    super.dispose();
  }
}
