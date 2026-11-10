import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

/// One notification a reminder namespace wants on the phone.
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.owner,
    required this.at,
    required this.title,
    required this.body,
  });
  final int id;

  /// Payload prefix plus the loan/debt/recurring payment id, e.g. `loan:3`.
  final String owner;
  final DateTime at;
  final String title, body;

  /// The instant rides along in the payload, so a pending notification can
  /// be matched against the plan without the plugin reporting its time.
  String get payload => '$owner@${at.millisecondsSinceEpoch}';
}

final _sinceLaunch = Stopwatch()..start();

/// Reminders are never urgent, so the first seconds after launch are left
/// to drawing the app.
const _launchQuiet = Duration(seconds: 4);

/// Waits out the launch window, so callers can coalesce the burst of loads
/// that arrives meanwhile. Only on a device: tests must not leave timers.
Future<void> afterLaunch() async {
  if (!Platform.isAndroid) return;
  final wait = _launchQuiet - _sinceLaunch.elapsed;
  if (wait > Duration.zero) await Future<void>.delayed(wait);
}

/// Brings the pending notifications [owns] claims in line with [planned],
/// cancelling and scheduling only what differs.
///
/// On Android the plugin keeps every scheduled notification as one JSON
/// string in SharedPreferences, easily hundreds of kilobytes. Merely asking
/// what's pending loads and parses all of it on the thread Dart draws the UI
/// on, and every cancel or schedule rewrites it. So a plan identical to the
/// last one applied in [namespace] never touches the plugin at all, and
/// [ensureReady] (the plugin's initialisation) only runs when it must.
Future<void> syncReminders(
  FlutterLocalNotificationsPlugin plugin, {
  required String namespace,
  required Future<void> Function() ensureReady,
  required bool Function(String? payload) owns,
  required List<PlannedReminder> planned,
  required NotificationDetails details,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final key = 'reminders_applied_$namespace';
  final fingerprint = sha1
      .convert(
        utf8.encode(
          jsonEncode([
            for (final r in planned) [r.id, r.payload, r.title, r.body],
          ]),
        ),
      )
      .toString();
  if (prefs.getString(key) == fingerprint) return;

  await ensureReady();
  final wanted = {for (final r in planned) r.id: r};
  for (final pending in await plugin.pendingNotificationRequests()) {
    if (!owns(pending.payload)) continue;
    final match = wanted[pending.id];
    if (match != null &&
        match.payload == pending.payload &&
        match.title == pending.title &&
        match.body == pending.body) {
      wanted.remove(pending.id);
    } else if (match == null) {
      await plugin.cancel(id: pending.id);
    }
    // A changed reminder is overwritten in place by scheduling its id again.
  }
  for (final r in wanted.values) {
    await plugin.zonedSchedule(
      id: r.id,
      title: r.title,
      body: r.body,
      payload: r.payload,
      // Only the instant matters for a one-off, so UTC is as good as the
      // local time zone and needs no time zone database.
      scheduledDate: tz.TZDateTime.from(r.at, tz.UTC),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      notificationDetails: details,
    );
  }
  await prefs.setString(key, fingerprint);
}
