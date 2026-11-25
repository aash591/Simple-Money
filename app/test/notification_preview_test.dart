// The teach sheet shows the original notification, as it looked on the phone:
// the app's icon, its name and how long ago, the bold heading, and the text.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/notification_access_platform.dart';
import 'package:simple_money/ui/more/smart_tracking/notifications/notification_preview.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

CapturedNotification _kotak({List<int>? icon}) => CapturedNotification(
  package: 'com.kotak.mobile',
  label: 'Kotak811',
  title: '₹10.00 sent to ASHIQUE M',
  text: 'Low balance! Add funds for seamless payment',
  message:
      '₹10.00 sent to ASHIQUE M\nLow balance! Add funds for seamless payment',
  receivedAt: DateTime(2026, 11, 23, 12, 0),
  icon: icon == null ? null : Uint8List.fromList(icon),
);

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

void main() {
  test('how long ago, in words', () {
    final now = DateTime(2026, 11, 23, 12, 30);
    String ago(Duration d) => NotificationPreview.ago(now.subtract(d), now);
    expect(ago(const Duration(seconds: 20)), 'just now');
    expect(ago(const Duration(minutes: 1)), '1 minute ago');
    expect(ago(const Duration(minutes: 28)), '28 minutes ago');
    expect(ago(const Duration(hours: 1, minutes: 5)), '1 hour ago');
    expect(ago(const Duration(hours: 5)), '5 hours ago');
    expect(ago(const Duration(days: 2)), '2 days ago');
  });

  testWidgets('shows the app, when, the bold heading and the text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(NotificationPreview(_kotak(), now: DateTime(2026, 11, 23, 12, 28))),
    );
    expect(find.text('Kotak811'), findsOneWidget);
    expect(find.text('28 minutes ago'), findsOneWidget);
    // The app is on the left; the time is at the right edge of the card.
    final card = tester.getRect(find.byKey(const Key('notification-preview')));
    expect(
      tester.getTopRight(find.text('28 minutes ago')).dx,
      closeTo(card.right - 12, 1),
    );
    expect(
      tester.getTopLeft(find.text('Kotak811')).dx,
      lessThan(card.center.dx),
    );
    expect(find.text('₹10.00 sent to ASHIQUE M'), findsOneWidget);
    expect(
      find.text('Low balance! Add funds for seamless payment'),
      findsOneWidget,
    );
    // The heading is bold, the text is not.
    expect(
      tester
          .widget<Text>(find.text('₹10.00 sent to ASHIQUE M'))
          .style!
          .fontWeight,
      FontWeight.w700,
    );
    // No icon from Android: the app's first letter stands in.
    expect(find.text('K'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('draws the app icon when Android gave one', (tester) async {
    // A 1×1 PNG.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    await tester.pumpWidget(_host(NotificationPreview(_kotak(icon: png))));
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('K'), findsNothing);
  });

  testWidgets('a notification with no heading shows just its text', (
    tester,
  ) async {
    final n = CapturedNotification(
      package: 'a.b',
      label: 'Some App',
      title: '',
      text: 'Paid ₹50',
      message: 'Paid ₹50',
      receivedAt: DateTime(2026, 11, 23),
    );
    await tester.pumpWidget(_host(NotificationPreview(n)));
    expect(find.text('Paid ₹50'), findsOneWidget);
  });

  group('as a row of the list on a page', () {
    CapturedNotification long() => CapturedNotification(
      package: 'com.whatsapp',
      label: 'WhatsApp',
      title: 'JOURNEY TRAVELSE (4) (3 messages)',
      text:
          'one two three four five six seven eight nine ten eleven twelve '
          'thirteen fourteen fifteen sixteen seventeen eighteen nineteen '
          'twenty twenty-one twenty-two twenty-three twenty-four',
      message: 'm',
      receivedAt: DateTime(2026, 11, 23, 12),
    );

    testWidgets('is a tappable card of the app, with no tag for an app not '
        'taught', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          NotificationPreview(
            _kotak(),
            onPage: true,
            onTap: () => taps++,
            now: DateTime(2026, 11, 23, 12, 28),
          ),
        ),
      );
      expect(find.byKey(const Key('notification-card')), findsOneWidget);
      // The same content as in the sheet: app, time, heading, text.
      expect(find.text('Kotak811'), findsOneWidget);
      expect(find.text('28 minutes ago'), findsOneWidget);
      expect(find.text('₹10.00 sent to ASHIQUE M'), findsOneWidget);
      // An app that was never taught has no tag.
      expect(find.text('Read'), findsNothing);
      expect(find.text('Not read yet'), findsNothing);
      await tester.tap(find.text('₹10.00 sent to ASHIQUE M'));
      expect(taps, 1);
    });

    testWidgets('says whether a taught app’s notification is read yet', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(NotificationPreview(_kotak(), onPage: true, read: false)),
      );
      expect(find.text('Not read yet'), findsOneWidget);
      await tester.pumpWidget(
        _host(NotificationPreview(_kotak(), onPage: true, read: true)),
      );
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('Not read yet'), findsNothing);
    });

    testWidgets('a long notification is cut to a few lines in the list, but '
        'shown whole when not', (tester) async {
      // In a scrolling list, as on the real screen: a card is then as tall as
      // its content (a bounded height would stretch it to the screen).
      Widget card({int? maxLines}) => _host(
        ListView(
          children: [
            NotificationPreview(long(), onPage: true, maxLines: maxLines),
          ],
        ),
      );
      await tester.pumpWidget(card(maxLines: 3));
      final cut = tester.getSize(find.byKey(const Key('notification-card')));
      await tester.pumpWidget(card());
      final whole = tester.getSize(find.byKey(const Key('notification-card')));
      expect(cut.height, lessThan(whole.height));
    });
  });
}
