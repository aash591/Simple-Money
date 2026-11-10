import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reminder_sync.dart';

/// Two end-of-day nudges to log the day's spending: one at 8 pm and one at
/// 10 pm. They are scheduled a week ahead each time the app opens or the
/// ledger changes, and a day that already has a transaction gets none.
class DailyReminders extends ChangeNotifier {
  DailyReminders([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static final instance = DailyReminders();
  static const preferenceKey = 'daily_reminders_enabled';
  static const _askedKey = 'daily_reminders_permission_asked';
  static const _hours = [20, 22];
  static const _days = 7;
  static const _idBase = 9100000;
  static const _prefix = 'daily:';

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'daily_add_transactions',
      'Daily reminders',
      channelDescription: 'Evening reminders to add the day’s transactions',
    ),
  );

  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _ready;
  Future<void> _queue = Future.value();
  int _requested = 0;
  bool _addedToday = false;

  bool enabled = true;
  bool saving = false;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(preferenceKey) ?? true;
    } catch (_) {
      enabled = true;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (saving) return;
    saving = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(preferenceKey, value)) {
        throw StateError('Could not save reminder setting.');
      }
      enabled = value;
    } finally {
      saving = false;
      notifyListeners();
    }
    await reschedule(addedToday: _addedToday);
  }

  Future<void> _init() => _plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_app_art'),
    ),
  );

  /// Applies the plan for the coming week. [addedToday] drops today's two
  /// nudges, since there is nothing left to remind about.
  Future<void> reschedule({required bool addedToday}) {
    _addedToday = addedToday;
    final request = ++_requested;
    return _queue = _queue.then((_) async {
      if (!_supported) return;
      try {
        await afterLaunch();
        if (request != _requested) return;
        final now = DateTime.now();
        final planned = <PlannedReminder>[];
        if (enabled) {
          for (var day = 0; day < _days; day++) {
            if (day == 0 && addedToday) continue;
            for (var slot = 0; slot < _hours.length; slot++) {
              final date = DateTime(now.year, now.month, now.day + day);
              final at = DateTime(
                date.year,
                date.month,
                date.day,
                _hours[slot],
              );
              if (!at.isAfter(now)) continue;
              planned.add(
                PlannedReminder(
                  id: _idBase + day * 10 + slot,
                  owner: '$_prefix$day.$slot',
                  at: at,
                  title: slot == 0
                      ? 'Add today’s transactions'
                      : 'Last call for today’s transactions',
                  body: slot == 0
                      ? 'Take a minute to record what you spent today.'
                      : 'Did you log everything today? It only takes a moment.',
                ),
              );
            }
          }
          await _askPermissionOnce();
        }
        await syncReminders(
          _plugin,
          namespace: 'daily',
          ensureReady: () => _ready ??= _init(),
          owns: (payload) => payload?.startsWith(_prefix) ?? false,
          planned: planned,
          details: _details,
        );
      } catch (_) {
        _ready = null;
      }
    });
  }

  /// Android 13 and later need a runtime grant; ask a single time, the
  /// first time reminders would be scheduled.
  Future<void> _askPermissionOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedKey) ?? false) return;
    await prefs.setBool(_askedKey, true);
    await (_ready ??= _init());
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }
}
