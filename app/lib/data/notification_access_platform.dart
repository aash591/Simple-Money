import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Rules read SMS by sender ID. An app's package name can't be one (it has
/// dots, and can be long), so a taught app gets a short stable ID of its own.
const notificationSenderPrefix = 'APP_';

/// The sender ID rules for [package]'s notifications are saved under:
/// `APP_` and ten letters and digits taken from the package name.
String notificationSenderKey(String package) =>
    '$notificationSenderPrefix'
    '${sha1.convert(utf8.encode(package)).toString().substring(0, 10).toUpperCase()}';

/// Whether [sender] is a taught app's ID rather than an SMS sender.
bool isNotificationSender(String sender) =>
    sender.startsWith(notificationSenderPrefix);

/// A rule needs fixed words before the first value it reads, to know where
/// to start. A notification often begins with the amount ("₹10.00 sent to…"),
/// so every notification is read with this word in front. Teaching, checking
/// and reading all use [notificationRuleText], so they agree.
const notificationRuleAnchor = 'Notification: ';

/// [message] as rules read it.
String notificationRuleText(String message) =>
    '$notificationRuleAnchor$message';

/// An app the user taught: its notifications are read from now on.
class TaughtApp {
  const TaughtApp(this.package, this.label, {this.enabled = true, this.icon});
  final String package, label;

  /// Whether it is being read: the user can pause an app without losing what
  /// it was taught.
  final bool enabled;

  /// The app's icon (a small PNG), kept so it shows even when the app isn't
  /// sending anything.
  final Uint8List? icon;

  TaughtApp copyWith({bool? enabled, Uint8List? icon}) => TaughtApp(
    package,
    label,
    enabled: enabled ?? this.enabled,
    icon: icon ?? this.icon,
  );

  /// The sender ID its rules are saved under.
  String get senderKey => notificationSenderKey(package);
}

/// A notification on the phone right now, listed so one can be taught. It is
/// read when the teach screen asks and is not kept.
class CapturedNotification {
  const CapturedNotification({
    required this.package,
    required this.label,
    required this.title,
    required this.text,
    required this.message,
    required this.receivedAt,
    this.icon,
  });

  /// The app, its name as the user knows it, and what it showed.
  final String package, label, title, text;

  /// Heading and details together, as a rule is taught and later read.
  final String message;
  final DateTime receivedAt;

  /// The app's icon (a small PNG), when Android could give it.
  final Uint8List? icon;
}

/// Android's notification access: the permission, the taught apps, and the
/// notifications seen while teaching.
class NotificationAccessPlatform {
  static const _channel = MethodChannel('simple_money/notification_access');

  /// False in the Google Play build (`build app:play` sets PLAY_BUILD): it
  /// doesn't declare the notification listener, so nothing here is offered.
  /// Every other build has it.
  static const available = !bool.fromEnvironment('PLAY_BUILD');

  bool get supported =>
      available && !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> isGranted() async =>
      supported && (await _channel.invokeMethod<bool>('isGranted') ?? false);

  Future<void> openSettings() async {
    if (supported) await _channel.invokeMethod<void>('openSettings');
  }

  /// Whether reading is switched on, and the apps taught so far.
  Future<(bool, List<TaughtApp>)> state() async {
    if (!supported) return (false, <TaughtApp>[]);
    final map = await _channel.invokeMapMethod<String, dynamic>('state');
    return (
      map?['enabled'] == true,
      [
        for (final r in (map?['taught'] as List?) ?? const [])
          TaughtApp(
            (r as Map)['package'] as String,
            r['label'] as String,
            enabled: r['enabled'] != false,
            icon: r['icon'] as Uint8List?,
          ),
      ],
    );
  }

  Future<void> setEnabled(bool enabled) async {
    if (supported) await _channel.invokeMethod<void>('setEnabled', enabled);
  }

  /// Replaces the taught apps. Only these are read, and only once they are
  /// switched on.
  Future<void> setTaught(List<TaughtApp> apps) async {
    if (!supported) return;
    await _channel.invokeMethod<void>('setTaught', [
      for (final a in apps)
        {
          'package': a.package,
          'label': a.label,
          'key': a.senderKey,
          'enabled': a.enabled,
          'icon': ?a.icon,
        },
    ]);
  }

  /// The notifications on the phone right now (newest first), and whether
  /// Android has connected SimpleMoney's listener yet. Not connected right
  /// after an install: it is asked to, and answers on the next try.
  /// [earlier] are the taught apps' recent notifications, even ones since
  /// dismissed, so a style of alert the app didn't read can still be taught.
  Future<
    ({
      bool connected,
      List<CapturedNotification> items,
      List<CapturedNotification> earlier,
    })
  >
  current() async {
    if (!supported) {
      return (
        connected: false,
        items: const <CapturedNotification>[],
        earlier: const <CapturedNotification>[],
      );
    }
    final map = await _channel.invokeMapMethod<String, dynamic>('current');
    List<CapturedNotification> rows(Object? list) => [
      for (final r in (list as List?) ?? const [])
        CapturedNotification(
          package: (r as Map)['package'] as String,
          label: r['label'] as String,
          title: r['title'] as String,
          text: r['text'] as String,
          message: r['message'] as String,
          receivedAt: DateTime.fromMillisecondsSinceEpoch(
            (r['receivedAt'] as num).toInt(),
          ),
          icon: r['icon'] as Uint8List?,
        ),
    ];
    return (
      connected: map?['connected'] == true,
      items: rows(map?['items']),
      earlier: rows(map?['earlier']),
    );
  }
}
