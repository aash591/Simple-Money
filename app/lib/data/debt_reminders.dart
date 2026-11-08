import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/account.dart';
import '../domain/debt.dart';
import 'reminder_sync.dart';

/// A morning notification on the day someone's debt is due: one per person,
/// for their earliest open debt. Every change reschedules them all from
/// scratch, so they never drift from what's on the phone.
class DebtReminders {
  DebtReminders([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _ready;
  Future<void> _queue = Future.value();

  static const _hour = 9;
  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'debt_due',
      'Debt reminders',
      channelDescription: 'On the day money you lent or borrowed is due',
    ),
  );

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_app_art'),
      ),
    );
  }

  /// Android 13 and later ask before an app may notify; earlier versions
  /// don't, and this does nothing there.
  Future<void> requestPermission() => _run(() async {
    await (_ready ??= _init());
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  });

  /// Loads come in bursts (startup, every ledger change); only the newest
  /// list is worth applying.
  int _requested = 0;

  Future<void> reschedule(List<PersonDebts> people) {
    final request = ++_requested;
    return _run(() async {
      await afterLaunch();
      if (request != _requested) return;
      final now = DateTime.now();
      final planned = <PlannedReminder>[];
      for (final debts in people) {
        final due = debts.dueDate;
        final balance = debts.balances.firstOrNull;
        if (due == null || balance == null) continue;
        final at = DateTime(due.year, due.month, due.day, _hour);
        if (!at.isAfter(now)) continue;
        final amount = formatAccountMoney(
          balance.amountMinor.abs(),
          digits: balance.digits,
          currency: balance.currency,
        );
        final name = debts.person.name;
        final owesYou = balance.amountMinor > 0;
        planned.add(
          PlannedReminder(
            id: debts.person.id,
            owner: 'debt:${debts.person.id}',
            at: at,
            title: owesYou
                ? '$name owes you $amount'
                : 'Pay back $name $amount',
            body: owesYou
                ? 'It’s due today. Maybe send a friendly reminder?'
                : 'It’s due today.',
          ),
        );
      }
      await syncReminders(
        _plugin,
        namespace: 'debt',
        ensureReady: () => _ready ??= _init(),
        // Existing debt reminders had no payload; loan reminders use loan:.
        owns: (payload) => payload == null || payload.startsWith('debt:'),
        planned: planned,
        details: _details,
      );
    });
  }

  /// One at a time, so a reschedule never interleaves with another. A
  /// reminder is a nicety: failing to schedule one never gets in the way.
  Future<void> _run(Future<void> Function() action) =>
      _queue = _queue.then((_) async {
        if (!_supported) return;
        try {
          await action();
        } catch (_) {
          _ready = null;
        }
      });
}
