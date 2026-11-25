import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/notification_access_platform.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:simple_money/ui/more/smart_tracking/notifications/notifications_screen.dart';
import 'package:simple_money/ui/more/smart_tracking/notifications/teach_notification_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

class _Fake extends NotificationAccessPlatform {
  bool granted = false, enabled = false, opened = false, connected = true;
  List<TaughtApp> taught = [];
  List<CapturedNotification> items = [], earlier = [];

  @override
  bool get supported => true;
  @override
  Future<bool> isGranted() async => granted;
  @override
  Future<void> openSettings() async => opened = true;
  @override
  Future<(bool, List<TaughtApp>)> state() async => (enabled, taught);
  @override
  Future<void> setEnabled(bool on) async => enabled = on;
  @override
  Future<void> setTaught(List<TaughtApp> apps) async => taught = apps;
  @override
  Future<
    ({
      bool connected,
      List<CapturedNotification> items,
      List<CapturedNotification> earlier,
    })
  >
  current() async => (connected: connected, items: items, earlier: earlier);
}

CapturedNotification _debit({
  DateTime? at,
  String text = 'Rs 2,476.00 debited from A/c XX1234 to ASIANET on 22-11-26',
}) => CapturedNotification(
  package: 'com.example.bank',
  label: 'Example Bank',
  title: 'Debit alert',
  text: text,
  message: 'Debit alert\n$text',
  receivedAt: at ?? DateTime(2026, 11, 22, 9, 30),
);

void main() {
  test('a taught app gets a stable sender ID that rules accept', () {
    final key = notificationSenderKey('com.phonepe.app');
    expect(key, startsWith('APP_'));
    expect(key, hasLength(14));
    expect(key, notificationSenderKey('com.phonepe.app'));
    expect(key, isNot(notificationSenderKey('net.one97.paytm')));
    expect(isNotificationSender(key), isTrue);
    expect(isNotificationSender('HDFCBK'), isFalse);
  });

  testWidgets('lists taught apps; none until one is taught', (tester) async {
    final fake = _Fake()..granted = true;
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(platform: fake)),
    );
    await tester.pumpAndSettle();
    expect(find.text('No apps yet'), findsOneWidget);
    // No database to save a rule in: nothing to teach with.
    expect(find.text('Teach from a notification'), findsNothing);

    fake.taught = [const TaughtApp('com.example.bank', 'Example Bank')];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Example Bank'), findsOneWidget);
    expect(find.text('No apps yet'), findsNothing);
  });

  testWidgets('Teach from a notification is above the list of taught apps', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(420, 1800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final fake = _Fake()
      ..granted = true
      ..taught = [const TaughtApp('com.example.bank', 'Example Bank')];
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationsScreen(platform: fake, database: db),
      ),
    );
    await tester.pumpAndSettle();
    final teach = tester.getTopLeft(
      find.byKey(const Key('teach-from-notification')),
    );
    final taught = tester.getTopLeft(find.text('TAUGHT APPS'));
    final access = tester.getTopLeft(find.text('Notification access'));
    // Under the switch and access, above the apps already taught.
    expect(teach.dy, greaterThan(access.dy));
    expect(teach.dy, lessThan(taught.dy));
    // Only once, and not among the taught apps.
    expect(find.text('Teach from a notification'), findsOneWidget);
  });

  testWidgets('a taught app shows its icon and a chevron, not a switch', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(420, 1800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A 1×1 PNG, standing for the app's icon.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    final fake = _Fake()
      ..granted = true
      ..enabled = true
      ..taught = [TaughtApp('com.example.bank', 'Example Bank', icon: png)];
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(platform: fake)),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('taught-com.example.bank'));

    // The app's own icon (not the letter), reading. No switch on the row: a
    // chevron says it opens.
    expect(
      find.descendant(of: row, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(find.descendant(of: row, matching: find.byType(Switch)), findsNothing);
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.chevron_right_rounded),
      ),
      findsOneWidget,
    );
    expect(find.text('Reading its notifications'), findsOneWidget);

    // Without a database to read what it was taught from, a tap on the row
    // pauses it (the app's own page has the switch).
    await tester.tap(find.text('Example Bank'));
    await tester.pumpAndSettle();
    expect(fake.taught.single.enabled, isFalse);
    expect(fake.taught.single.icon, isNotNull);
    expect(find.text('Paused · not reading'), findsOneWidget);
  });

  testWidgets('an app with no icon yet shows its first letter', (tester) async {
    final fake = _Fake()
      ..granted = true
      ..taught = [const TaughtApp('com.example.bank', 'Example Bank')];
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(platform: fake)),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('taught-com.example.bank'));
    expect(find.descendant(of: row, matching: find.text('E')), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(Image)),
      findsNothing,
    );
  });

  testWidgets('shows off and waiting while access is missing, on once given', (
    tester,
  ) async {
    final fake = _Fake()..enabled = true;
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(platform: fake)),
    );
    await tester.pumpAndSettle();
    // Chosen on, but Android has not allowed it: nothing is being read.
    expect(find.text('Waiting for notification access'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);

    fake.granted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Reading the apps taught below'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
  });

  testWidgets('turning it on asks Android for access', (tester) async {
    final fake = _Fake();
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(platform: fake)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transactions from notifications'));
    await tester.pumpAndSettle();
    expect(fake.enabled, isTrue);
    expect(fake.opened, isTrue);
  });

  /// The rules load from the database and every bundled pack: real work the
  /// test clock doesn't wait for, so give it real time.
  Future<void> rulesWorkedOut(
    WidgetTester tester, {
    required Finder until,
  }) async {
    for (var i = 0; i < 40 && until.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> openTeach(
    WidgetTester tester,
    _Fake fake,
    AppDatabase db, {
    VoidCallback? onRulesChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<bool>(
                  builder: (_) => TeachNotificationScreen(
                    database: db,
                    platform: fake,
                    refresh: const Duration(milliseconds: 200),
                    onRulesChanged: onRulesChanged,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists what is on the phone now, and teaches the one picked', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(420, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final fake = _Fake()
      ..granted = true
      ..items = [_debit()];
    var changed = 0;
    await openTeach(tester, fake, db, onRulesChanged: () => changed++);
    // Already there when the screen opens: nothing to wait for.
    expect(find.text('On your phone now'.toUpperCase()), findsOneWidget);
    expect(find.text('Example Bank'), findsOneWidget);

    await tester.tap(find.text('Example Bank'));
    await tester.pumpAndSettle();
    expect(find.text('Teach this message'), findsOneWidget);
    // The original notification is shown at the top, as it looked, not the
    // internal ID its rules are saved under.
    expect(find.byKey(const Key('notification-preview')), findsOneWidget);
    // Its heading is in the sheet's preview (the list behind has it too).
    expect(
      find.descendant(
        of: find.byKey(const Key('notification-preview')),
        matching: find.text('Debit alert'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('APP_'), findsNothing);
    // Words: 0 Debit · 1 alert · 2 Rs · 3 2,476.00 · 4 debited · 5 from ·
    // 6 A/c · 7 XX1234 · 8 to · 9 ASIANET …
    await tester.tap(find.text('Money out'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-3')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-9')));
    await tester.pump();
    await tester.tap(find.text('Account').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-7')));
    await tester.pump();
    await tester.tap(find.text('Teach'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();

    // The rule is saved under the app's own sender ID, named after the app,
    // and only now is the app read, with reading switched on.
    final rules = await tester.runAsync(() => UserSmsRuleRepository(db).load());
    expect(rules, hasLength(1));
    expect(rules!.single.bankName, 'Example Bank');
    expect(rules.single.senders, [notificationSenderKey('com.example.bank')]);
    expect(fake.taught.map((a) => a.package), ['com.example.bank']);
    expect(fake.enabled, isTrue);
    expect(changed, 1);
    await rulesWorkedOut(tester, until: find.text('Read'));
    // The screen stays open, so another kind of notification from the same
    // app can be taught: this one is read now.
    expect(find.text('Teach from a notification'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Not read yet'), findsNothing);
    // Leave, so the refresh timer stops.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a notification that arrives while open shows up by itself', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final fake = _Fake()..granted = true;
    await openTeach(tester, fake, db);
    expect(find.text('No notifications right now'), findsOneWidget);

    fake.items = [_debit()];
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('Example Bank'), findsOneWidget);
    expect(find.text('No notifications right now'), findsNothing);
    // Leave, so the refresh timer stops.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('asks for access first when it is missing', (tester) async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final fake = _Fake()..items = [_debit()];
    await tester.pumpWidget(
      MaterialApp(
        home: TeachNotificationScreen(database: db, platform: fake),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Allow notification access'), findsOneWidget);
    // Nothing is read without access, even if there were something.
    expect(find.text('Example Bank'), findsNothing);
    await tester.tap(find.text('Allow notification access'));
    expect(fake.opened, isTrue);
  });

  testWidgets('says so when Android has not connected the listener yet', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final fake = _Fake()
      ..granted = true
      ..connected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: TeachNotificationScreen(database: db, platform: fake),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Almost ready'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
