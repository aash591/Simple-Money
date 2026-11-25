import 'dart:async';

import 'package:flutter/material.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../../../data/db/app_database.dart';
import '../../../../data/notification_access_platform.dart';
import '../../../../state/sms_import_store.dart';
import '../../../components/app_toast.dart';
import '../../../components/feature_page.dart';
import '../../../components/menu_list.dart';
import '../sms/teach_sms_sheet.dart';
import 'notification_preview.dart';

/// Smart tracking › App notifications › Teach from a notification.
///
/// Lists the notifications on the phone right now, from any app. Tap one to
/// teach SimpleMoney which words are the amount, who was paid and the
/// account. From then on that app's notifications are read, and no other
/// app's. The list is read from Android while this screen is open and
/// refreshes by itself, so a new alert shows up too.
///
/// One app can send several kinds of notification (sent, received, failed…),
/// and a rule reads only the kind it was taught from. So for an app already
/// taught, each notification says whether it is read yet, the unread ones
/// come first, and the screen stays open after teaching so the next kind can
/// be taught too. Notifications of taught apps are also listed from a short
/// log, even once they've gone from the notification shade.
class TeachNotificationScreen extends StatefulWidget {
  const TeachNotificationScreen({
    super.key,
    required this.database,
    this.platform,
    this.onRulesChanged,
    this.refresh = const Duration(seconds: 3),
  });

  final AppDatabase database;

  /// Replaced in tests.
  final NotificationAccessPlatform? platform;

  /// Reads again with the new rule, after an app was taught.
  final VoidCallback? onRulesChanged;

  /// How often the list is read again.
  final Duration refresh;

  @override
  State<TeachNotificationScreen> createState() =>
      _TeachNotificationScreenState();
}

class _TeachNotificationScreenState extends State<TeachNotificationScreen>
    with WidgetsBindingObserver {
  late final NotificationAccessPlatform _platform =
      widget.platform ?? NotificationAccessPlatform();
  Timer? _poll;
  bool _granted = false, _connected = false, _loaded = false;
  List<_Seen> _items = const [];

  /// Each taught app's rules, as an engine, kept until something is taught.
  final _engines = <String, Future<PortableSmsEngine?>>{};

  /// Whether the rules read a notification (by app and text), once worked out.
  /// Loading the rules takes a moment, so the list shows first and the tags
  /// follow; kept so a refresh doesn't do the work again.
  final _read = <String, bool>{};
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  /// Back from Android's settings, access may now be allowed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _start();
  }

  Future<void> _start() async {
    try {
      final granted = await _platform.isGranted();
      if (!mounted) return;
      setState(() {
        _granted = granted;
        _loaded = true;
      });
      _poll?.cancel();
      if (granted) {
        await _refresh();
        _poll = Timer.periodic(widget.refresh, (_) => _refresh());
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  /// Whether the rules already read [n], for an app that was taught.
  Future<bool> _understood(CapturedNotification n) async {
    try {
      final engine = await (_engines[n.package] ??= () async {
        final sender = notificationSenderKey(n.package);
        final db = widget.database;
        return loadBundledSmsEngineFor(
          sender,
          userPack: await userSmsPack(db),
          communityPack: await communitySmsPack(db),
          roles: await smsSenderRoles(db),
        );
      }());
      if (engine == null) return false;
      final result = engine.parse(
        BankSms(
          sender: notificationSenderKey(n.package),
          body: notificationRuleText(n.message),
          receivedAt: n.receivedAt,
        ),
      );
      return result.candidate != null && result.ruleId != null;
    } catch (_) {
      return false;
    }
  }

  String _id(CapturedNotification n) => '${n.package}\n${n.message}';

  /// The list, taught apps' notifications first when the rules don't read
  /// them yet (those are the ones left to teach), then newest first.
  List<_Seen> _arranged(Iterable<CapturedNotification> all, Set<String> apps) {
    final rows = [
      for (final n in all)
        _Seen(n, apps.contains(n.package) ? _read[_id(n)] : null),
    ];
    rows.sort((a, b) {
      final unread = (b.read == false ? 1 : 0) - (a.read == false ? 1 : 0);
      return unread != 0 ? unread : b.n.receivedAt.compareTo(a.n.receivedAt);
    });
    return rows;
  }

  /// What is on the phone now, and what taught apps sent lately. Shown at
  /// once; whether each is read yet is added as it is worked out.
  Future<void> _refresh() async {
    if (_reading) return;
    _reading = true;
    try {
      final now = await _platform.current();
      final (_, taught) = await _platform.state();
      final apps = {for (final a in taught) a.package};
      // The same notification once, as it is on the phone if it still is.
      final all = <String, CapturedNotification>{};
      for (final n in [...now.items, ...now.earlier]) {
        all.putIfAbsent(_id(n), () => n);
      }
      if (!mounted) return;
      setState(() {
        _connected = now.connected;
        _items = _arranged(all.values, apps);
      });
      // Only what isn't known yet; the list is already on screen.
      var learned = false;
      for (final n in all.values) {
        if (apps.contains(n.package) && !_read.containsKey(_id(n))) {
          _read[_id(n)] = await _understood(n);
          learned = true;
        }
      }
      if (learned && mounted) {
        setState(() => _items = _arranged(all.values, apps));
      }
    } catch (_) {
      /* Try again shortly. */
    } finally {
      _reading = false;
    }
  }

  Future<void> _teach(CapturedNotification n) async {
    final read = await showTeachSmsSheet(
      context,
      database: widget.database,
      message: BankSms(
        sender: notificationSenderKey(n.package),
        body: n.message,
        receivedAt: n.receivedAt,
      ),
      // More from the same app, so the rule is tried on those too.
      others: [
        for (final other in _items)
          if (other.n.package == n.package && other.n.message != n.message)
            BankSms(
              sender: notificationSenderKey(n.package),
              body: other.n.message,
              receivedAt: other.n.receivedAt,
            ),
      ],
      appName: n.label,
      // The notification as it looked, to tap the words of.
      preview: NotificationPreview(n),
    );
    if (read == null || !mounted) return;
    // From now on this app is read, and reading is switched on.
    final (_, taught) = await _platform.state();
    // Taught again, so it is read (even if it was paused), with its icon.
    await _platform.setTaught([
      for (final a in taught)
        if (a.package == n.package)
          a.copyWith(enabled: true, icon: n.icon)
        else
          a,
      if (!taught.any((a) => a.package == n.package))
        TaughtApp(n.package, n.label, icon: n.icon),
    ]);
    await _platform.setEnabled(true);
    widget.onRulesChanged?.call();
    // The new rule may read more of the list: work it out again.
    _engines.clear();
    _read.clear();
    _reading = false;
    await _refresh();
    if (!mounted) return;
    final left = _items
        .where((r) => r.n.package == n.package && r.read == false)
        .length;
    showAppToast(
      context,
      left == 0
          ? 'Taught · ${n.label} notifications are read now'
          : 'Taught · $left more from ${n.label} to teach',
      icon: Icons.check_circle_rounded,
    );
  }

  /// A line under the screen's explanation for the cases with nothing to
  /// pick: what is wrong, and the one thing to do about it.
  Widget _notice(
    IconData icon,
    String title,
    String subtitle, {
    VoidCallback? onTap,
  }) => MenuGroup(
    children: [
      MenuRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        highlight: onTap != null,
        onTap: onTap,
        trailing: onTap == null ? const SizedBox.shrink() : null,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FeaturePage(
      title: 'Teach from a notification',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
                child: Text(
                  'These are the notifications on your phone now. Tap your '
                  'bank’s or payment app’s, then mark the amount. An app can '
                  'send different kinds of notification: teach each kind once.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
              if (!_loaded)
                const SizedBox.shrink()
              else if (!_granted)
                _notice(
                  Icons.verified_user_rounded,
                  'Allow notification access',
                  'Needed to see them. Tap to open Android settings',
                  onTap: _platform.openSettings,
                )
              else if (!_connected)
                // Allowed, but Android hasn't started the listener: usually
                // right after an install. Switching access off and on does it.
                _notice(
                  Icons.sync_problem_rounded,
                  'Almost ready',
                  'Android is still connecting. If this stays, turn access '
                      'off and on again',
                  onTap: _platform.openSettings,
                )
              else if (_items.isEmpty)
                _notice(
                  Icons.notifications_off_rounded,
                  'No notifications right now',
                  'Make a payment or wait for an alert. It shows here',
                )
              else ...[
                // The same label as a group of rows has.
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Text(
                    'On your phone now'.toUpperCase(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .8,
                    ),
                  ),
                ),
                // Each as it looked on the phone, with whether it is read yet.
                for (final r in _items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: NotificationPreview(
                      r.n,
                      key: Key('seen-${r.n.package}-${r.n.message.hashCode}'),
                      onPage: true,
                      read: r.read,
                      maxLines: 3,
                      onTap: () => _teach(r.n),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A notification in the list, and for a taught app whether its rules read it
/// (null for an app not taught yet).
class _Seen {
  const _Seen(this.n, this.read);
  final CapturedNotification n;
  final bool? read;
}
