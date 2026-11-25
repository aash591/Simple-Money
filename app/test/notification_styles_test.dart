// One app sends several kinds of notification (sent, received, failed…), and a
// rule reads only the kind it was taught from. The teach screen says which of
// a taught app's notifications are read yet, lists the unread ones first, and
// lists them even once they've gone from the notification shade, so the next
// kind can be taught.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/manual_sms_teacher.dart';
import 'package:simple_money/data/notification_access_platform.dart';
import 'package:simple_money/ui/more/smart_tracking/notifications/teach_notification_screen.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

class _Fake extends NotificationAccessPlatform {
  final taught = [const TaughtApp('com.example.bank', 'Example Bank')];
  var items = <CapturedNotification>[], earlier = <CapturedNotification>[];

  @override
  bool get supported => true;
  @override
  Future<bool> isGranted() async => true;
  @override
  Future<(bool, List<TaughtApp>)> state() async => (true, taught);
  @override
  Future<
    ({
      bool connected,
      List<CapturedNotification> items,
      List<CapturedNotification> earlier,
    })
  >
  current() async => (connected: true, items: items, earlier: earlier);
}

const _sent =
    '₹10.00 sent to ASHIQUE M\nLow balance! Add funds for seamless pay';
const _received = '₹500.00 received from RAVI K\nYour balance is updated';

CapturedNotification _seen(String message, {required int minute}) =>
    CapturedNotification(
      package: 'com.example.bank',
      label: 'Example Bank',
      title: message.split('\n').first,
      text: message.split('\n').last,
      message: message,
      receivedAt: DateTime(2026, 11, 23, 9, minute),
    );

BankSms _sms(String message) => BankSms(
  sender: notificationSenderKey('com.example.bank'),
  body: message,
  receivedAt: DateTime(2026, 11, 23, 9),
);

void main() {
  testWidgets('another kind from a taught app is not read yet, and first; '
      'teaching it reads both', (tester) async {
    tester.view
      ..physicalSize = const Size(420, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    final fake = _Fake()
      // Both kinds are on the phone; the received one is older.
      ..items = [_seen(_sent, minute: 30), _seen(_received, minute: 10)];

    // The app was taught from its "sent" notification only.
    await tester.runAsync(
      () => ManualSmsTeacher(db).teach(
        _sms(_sent),
        const SmsLabels(
          amount: '10.00',
          payee: 'ASHIQUE M',
          moneyOut: true,
          currency: 'INR',
        ),
        appName: 'Example Bank',
      ),
    );

    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: TeachNotificationScreen(
            database: db,
            platform: fake,
            refresh: const Duration(milliseconds: 200),
          ),
        ),
      );
      // The rules load from the database and every bundled pack: real work
      // the test clock doesn't wait for.
      for (var i = 0; i < 40 && find.text('Read').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await open();
    // The kind it was taught is read; the other kind is not, and comes first
    // though it is older: it is the one left to teach.
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Not read yet'), findsOneWidget);
    expect(
      tester.getTopLeft(find.textContaining('received from RAVI K')).dy,
      lessThan(tester.getTopLeft(find.textContaining('sent to ASHIQUE M')).dy),
    );
    await tester.pumpWidget(const SizedBox());

    // Teach the second kind (as the sheet does), and both are read.
    await tester.runAsync(
      () => ManualSmsTeacher(db).teach(
        _sms(_received),
        const SmsLabels(
          amount: '500.00',
          payee: 'RAVI K',
          moneyOut: false,
          currency: 'INR',
        ),
        others: [_sms(_sent)],
        appName: 'Example Bank',
      ),
    );
    await open();
    expect(find.text('Read'), findsNWidgets(2));
    expect(find.text('Not read yet'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a notification gone from the shade is still listed for a '
      'taught app', (tester) async {
    tester.view
      ..physicalSize = const Size(420, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(() => tester.runAsync(db.close));
    // Nothing on the phone now, but the app sent this lately.
    final fake = _Fake()..earlier = [_seen(_received, minute: 10)];
    await tester.pumpWidget(
      MaterialApp(
        home: TeachNotificationScreen(
          database: db,
          platform: fake,
          refresh: const Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('received from RAVI K'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
