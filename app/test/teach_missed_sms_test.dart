import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/reportable_sms.dart';
import 'package:simple_money/ui/more/smart_tracking/sms/teach_missed_sms_screen.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart'
    show BankSms;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sms = MethodChannel('simple_money/sms_inbox');
  const improve = MethodChannel('simple_money/help_improve');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime.now().millisecondsSinceEpoch;
  Map<String, Object> row(int id, String sender, String body) => {
    'id': id,
    'sender': sender,
    'body': body,
    'receivedAt': now - id * 60000,
  };
  final inbox = [
    row(
      1,
      'VM-ZETBNK-S',
      'Rs.1,250.00 debited from A/c XX4321 on 12-Oct to VPA shop@okaxis. Ref 612345678901',
    ),
    row(2, '+919876543210', 'Rs.500 debited for dinner, send me back pls'),
    row(
      3,
      'JK-PIRFIN-S',
      'Your loan offer up to Rs.37000 is available. Apply now',
    ),
    row(
      4,
      'VM-ZETBNK-S',
      '123456 is your OTP for a payment of Rs.200. Do not share it.',
    ),
  ];
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'main_currency': '{"code":"INR","digits":2,"territory":"IN"}',
    }),
  );
  tearDown(() {
    messenger.setMockMethodCallHandler(sms, null);
    messenger.setMockMethodCallHandler(improve, null);
  });
  void mockInbox({required bool allowed, List<Map<String, Object>>? rows}) =>
      messenger.setMockMethodCallHandler(
        sms,
        (call) async => switch (call.method) {
          'readPage' =>
            (call.arguments as Map)['afterId'] == 0 ? rows ?? inbox : const [],
          _ => allowed,
        },
      );

  testWidgets('without SMS access nothing is read or sent', (tester) async {
    var reports = 0;
    mockInbox(allowed: false);
    messenger.setMockMethodCallHandler(improve, (_) async {
      reports++;
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: TeachMissedSmsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Allow SMS access'), findsWidgets);
    expect(find.text('Open app settings'), findsOneWidget);
    expect(reports, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('sorts business SMS and reports one with a note and contact', (
    tester,
  ) async {
    final sent = <List<dynamic>>[];
    mockInbox(allowed: true);
    messenger.setMockMethodCallHandler(improve, (call) async {
      sent.add((call.arguments as Map)['messages'] as List);
      return 1;
    });
    await tester.pumpWidget(const MaterialApp(home: TeachMissedSmsScreen()));
    // The real rule packs load and parse on an isolate; give them wall time.
    for (
      var i = 0;
      i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Missed: the unread debit only.
    expect(find.textContaining('debited from A/c XX4321'), findsOneWidget);
    expect(find.textContaining('loan offer'), findsNothing);

    // Other: remaining business SMS. Personal messages and OTPs never show.
    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();
    expect(find.textContaining('loan offer'), findsOneWidget);
    expect(find.textContaining('dinner'), findsNothing);
    expect(find.textContaining('is your OTP'), findsNothing);
    expect(sent, isEmpty);

    await tester.tap(find.text('Missed'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('It’s a debit'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Contact'),
      'me@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Bank or merchant'),
      'Zeta Bank',
    );
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    final report = sent.single.single as Map;
    expect(report, containsPair('address', 'VM-ZETBNK-S'));
    expect(report, containsPair('kind', 'missed'));
    expect(report, containsPair('note', 'It’s a debit'));
    expect(report, containsPair('contact', 'me@example.com'));
    expect(report, containsPair('bank', 'Zeta Bank'));
    expect(report, containsPair('country', 'IN'));
    expect(find.text('Nothing missed'), findsOneWidget);

    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    expect(find.textContaining('debited from A/c XX4321'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  test('Teach is offered for what is not read, and for what was reported', () {
    ReportableSms message(ReportableKind kind, {bool taught = false}) =>
        ReportableSms(
          'id',
          BankSms(
            sender: 'VM-TESTBK-S',
            body: 'Rs.10 debited',
            receivedAt: DateTime(2026),
          ),
          kind,
          '',
          null,
          taught: taught,
        );
    bool can(
      ReportableSms m, {
      bool reported = false,
      bool database = true,
      bool busy = false,
    }) => TeachMissedSmsScreen.canTeach(
      hasDatabase: database,
      message: m,
      reported: reported,
      busy: busy,
    );

    // Not read yet: always.
    expect(can(message(ReportableKind.missed)), isTrue);
    expect(can(message(ReportableKind.other)), isTrue);
    // Read right by the bundled rules: nothing to teach...
    expect(can(message(ReportableKind.detected)), isFalse);
    // ...unless it was reported, which says it may have been read wrongly.
    expect(can(message(ReportableKind.detected), reported: true), isTrue);
    // Taught by hand before: it can be taught again, reported or not.
    expect(can(message(ReportableKind.detected, taught: true)), isTrue);
    // Never without a database to save to, or while a report is sending.
    expect(can(message(ReportableKind.missed), database: false), isFalse);
    expect(can(message(ReportableKind.missed), busy: true), isFalse);
  });
}
