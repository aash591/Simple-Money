import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/account.dart';
import '../domain/subscription.dart';
import 'reminder_sync.dart';

/// Separate notification namespace: rescheduling subscriptions must not
/// cancel loan or debt reminders.
class SubscriptionReminders {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void> _queue = Future.value();
  Future<void>? _ready;
  static const _prefix = 'subscription:';

  /// Renewals scheduled ahead, so reminders keep coming for a while even if
  /// the app isn't opened.
  static const _ahead = 6;

  Future<void> _run(Future<void> Function() work) =>
      _queue = _queue.then((_) async {
        if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
        try {
          await work();
        } catch (_) {
          _ready = null;
        }
      });

  Future<void> _init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_app_art'),
      ),
    );
  }

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

  Future<void> reschedule(List<Subscription> subscriptions) {
    final request = ++_requested;
    return _run(() async {
      await afterLaunch();
      if (request != _requested) return;
      final now = DateTime.now();
      final planned = <PlannedReminder>[];
      for (final subscription in subscriptions.where(
        (s) => s.remind && !s.paused,
      )) {
        var due = subscription.nextDue;
        for (var renewal = 0; renewal < _ahead; renewal++) {
          for (final days in [2, 0]) {
            final at = DateTime(due.year, due.month, due.day - days, 9);
            if (!at.isAfter(now)) continue;
            planned.add(
              PlannedReminder(
                id:
                    200000000 +
                    subscription.id * 32 +
                    renewal * 2 +
                    (days == 0 ? 1 : 0),
                owner: '$_prefix${subscription.id}',
                at: at,
                title:
                    '${subscription.name} renews ${days == 0 ? 'today' : 'in 2 days'}',
                body: formatAccountMoney(
                  subscription.amountMinor,
                  digits: subscription.digits,
                  currency: subscription.currency,
                ),
              ),
            );
          }
          due = subscription.cycle.after(due, subscription.day);
        }
      }
      await syncReminders(
        _plugin,
        namespace: 'subscription',
        ensureReady: () => _ready ??= _init(),
        owns: (payload) => payload?.startsWith(_prefix) ?? false,
        planned: planned,
        details: _details,
      );
    });
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'subscription_due',
      'Subscription reminders',
      channelDescription:
          'Two days before a subscription renews and on the day',
    ),
  );
}
