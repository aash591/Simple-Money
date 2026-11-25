// Tapping a taught app opens its page: the notification(s) it was taught from,
// each tappable to teach it again, and the way to pause or remove the app.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/manual_sms_teacher.dart';
import 'package:simple_money/data/notification_access_platform.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:simple_money/ui/more/smart_tracking/notifications/notifications_screen.dart';
import 'package:simple_money/ui/more/smart_tracking/notifications/taught_app_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

class _Fake extends NotificationAccessPlatform {
  _Fake(this.taught);
  List<TaughtApp> taught;

  @override
  bool get supported => true;
  @override
  Future<bool> isGranted() async => true;
  @override
  Future<(bool, List<TaughtApp>)> state() async => (true, taught);
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
  current() async => (
    connected: true,
    items: const <CapturedNotification>[],
    earlier: const <CapturedNotification>[],
  );
}

const _app = TaughtApp('com.example.bank', 'Example Bank');
const _sent =
    '₹10.00 sent to ASHIQUE M\nLow balance! Add funds for seamless pay';
const _received = '₹500.00 received from RAVI K\nYour balance is updated';
const _sentLabels = SmsLabels(
  amount: '10.00',
  payee: 'ASHIQUE M',
  moneyOut: true,
  currency: 'INR',
);

BankSms _sms(String message) => BankSms(
  sender: _app.senderKey,
  body: message,
  receivedAt: DateTime(2026, 11, 23, 9),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory(), false));
  tearDown(() => db.close());

  Future<void> teachSent(WidgetTester tester) => tester
      .runAsync(
        () =>
            ManualSmsTeacher(db)
                .teach(_sms(_sent), _sentLabels, appName: 'Example Bank'),
      )
      .then((_) {});

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
  }

  Widget page(NotificationAccessPlatform platform) => MaterialApp(
    theme: appTheme(Brightness.light),
    home: TaughtAppScreen(database: db, app: _app, platform: platform),
  );

  testWidgets('shows the notification it was taught from, as it looked', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(420, 1800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await teachSent(tester);
    await tester.pumpWidget(page(_Fake([_app])));
    await settle(tester);
    // The original: heading and text, without the leading word every
    // notification is read with.
    expect(find.text('₹10.00 sent to ASHIQUE M'), findsOneWidget);
    expect(
      find.text('Low balance! Add funds for seamless pay'),
      findsOneWidget,
    );
    expect(find.textContaining('Notification:'), findsNothing);
    expect(find.text('Reading its notifications'), findsOneWidget);
    expect(find.byKey(const Key('teach-another-kind')), findsNothing);
    // Below it, the transaction its rule reads from it, as the list shows it.
    expect(find.text('Reads as'), findsOneWidget);
    expect(find.text('ASHIQUE M'), findsOneWidget);
    expect(find.textContaining('10.00'), findsWidgets);
  });

  testWidgets('another kind taught later is listed too, newest first', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(420, 2200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await teachSent(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.runAsync(
      () => ManualSmsTeacher(db).teach(
        _sms(_received),
        const SmsLabels(
          amount: '500.00',
          payee: 'RAVI K',
          moneyOut: false,
          currency: 'INR',
        ),
        appName: 'Example Bank',
      ),
    );
    await tester.pumpWidget(page(_Fake([_app])));
    await settle(tester);
    expect(find.text('₹10.00 sent to ASHIQUE M'), findsOneWidget);
    expect(find.text('₹500.00 received from RAVI K'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('₹500.00 received from RAVI K')).dy,
      lessThan(tester.getTopLeft(find.text('₹10.00 sent to ASHIQUE M')).dy),
    );
  });

  testWidgets('the switch pauses it, and there is no separate remove', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(420, 1800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = _Fake([_app]);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    TaughtAppScreen(database: db, app: _app, platform: fake),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('taught-app-switch')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.taught.single.enabled, isFalse);
    expect(find.text('Paused · not reading'), findsOneWidget);

    // No separate remove: the switch is the way to stop it.
    expect(find.byKey(const Key('remove-taught-app')), findsNothing);
    expect(find.textContaining('Stop reading'), findsNothing);
  });

  testWidgets('tapping a taught app in the list opens its page', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(420, 1800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await teachSent(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: NotificationsScreen(database: db, platform: _Fake([_app])),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('taught-com.example.bank')));
    await settle(tester);
    // On the app's own page, with what it was taught.
    expect(find.text('₹10.00 sent to ASHIQUE M'), findsOneWidget);
  });

  testWidgets('tapping a taught notification teaches it again, replacing its '
      'rule', (tester) async {
    tester.view
      ..physicalSize = const Size(420, 2000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await teachSent(tester);
    final before = (await tester.runAsync(
      () => UserSmsRuleRepository(db).load(),
    ))!.single;
    await tester.pumpWidget(page(_Fake([_app])));
    await settle(tester);

    // Tap the notification it was taught from: the same teach sheet opens,
    // showing the original.
    await tester.tap(find.byKey(Key('kind-${before.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Teach this message'), findsOneWidget);
    expect(find.byKey(const Key('notification-preview')), findsOneWidget);

    // Mark it afresh: money out, the amount (word 0), the name (words 3, 4).
    await tester.tap(find.text('Money out'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-0')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-3')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('teach-word-4')));
    await tester.pump();
    await tester.tap(find.text('Teach'));
    // The rule is checked against every bundled pack: real time. Wait for the
    // new rule to be saved in place of the old.
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      final now = await tester.runAsync(() => UserSmsRuleRepository(db).load());
      if (now!.any((r) => r.id != before.id)) break;
    }
    await tester.pumpAndSettle();

    // Still one rule for the app: the old one was replaced by the new.
    final after = (await tester.runAsync(
      () => UserSmsRuleRepository(db).load(),
    ))!;
    expect(after, hasLength(1));
    expect(after.single.id, isNot(before.id));
    // Back on the app's page, with the notification still listed.
    expect(find.text('Teach this message'), findsNothing);
    expect(find.text('₹10.00 sent to ASHIQUE M'), findsOneWidget);
  });

  test(
    'teaching again replaces the rule instead of clashing with it',
    () async {
      final rules = UserSmsRuleRepository(db);
      await ManualSmsTeacher(db)
          .teach(_sms(_sent), _sentLabels, appName: 'Example Bank');
      final first = (await rules.load()).single;

      // The same notification, marked again: the old rule is replaced, not
      // added beside it (and not refused as a clash).
      await ManualSmsTeacher(db).teach(
        _sms(_sent),
        _sentLabels,
        appName: 'Example Bank',
        replacingRuleId: first.id,
      );
      final after = await rules.load();
      expect(after, hasLength(1));
      expect(after.single.id, isNot(first.id));
      expect(after.single.senders, [_app.senderKey]);
    },
  );

  test('if it can not be taught again, the old rule stays', () async {
    final rules = UserSmsRuleRepository(db);
    await ManualSmsTeacher(db)
        .teach(_sms(_sent), _sentLabels, appName: 'Example Bank');
    final first = (await rules.load()).single;
    // An amount that isn't in the message can't be taught.
    await expectLater(
      ManualSmsTeacher(db).teach(
        _sms(_sent),
        const SmsLabels(amount: '99.99', moneyOut: true, currency: 'INR'),
        appName: 'Example Bank',
        replacingRuleId: first.id,
      ),
      throwsA(anything),
    );
    final after = await rules.load();
    expect(after, hasLength(1));
    expect(after.single.samples, first.samples);
  });
}
