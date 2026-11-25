import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/issue_report.dart';
import 'package:simple_money/ui/components/action_buttons.dart';
import 'package:simple_money/ui/more/settings/help/help_screen.dart';
import 'package:simple_money/ui/more/settings/help/report_issue_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

base class _Picked extends PlatformFile {
  _Picked(this.name, this.bytes, {int? size}) : _size = size ?? bytes.length;
  @override
  final String name;
  final Uint8List bytes;
  final int _size;
  @override
  Uri get uri => Uri.parse('content://picked/$name');
  @override
  get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => _size;
  @override
  Future<int> length() async => _size;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.fromIterable([
    for (var i = 0; i < bytes.length; i += chunk)
      Uint8List.sublistView(bytes, i, (i + chunk).clamp(0, bytes.length)),
  ]);

  /// How many bytes each piece of the stream carries.
  static const chunk = 2;
}

Future<({String token, String chat})> _creds() async =>
    (token: 'T0KEN', chat: '-100123');

class _Server {
  _Server([this.status = 200]);
  int status;
  http.BaseRequest? request;
  String body = '';

  MockClient get client => MockClient.streaming((request, stream) async {
    this.request = request;
    body += latin1.decode(await stream.expand((c) => c).toList());
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), status);
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('IssueReporter', () {
    test('posts the text and the file to the feedback endpoint', () async {
      final server = _Server();
      final reporter = IssueReporter(
        client: server.client,
        baseUrl: 'https://tg.example',
        credentials: _creds,
      );
      await reporter.send(
        '  The total is wrong  ',
        files: [
          _Picked('screen.png', Uint8List.fromList(utf8.encode('PNGDATA'))),
        ],
      );
      expect(server.request!.method, 'POST');
      expect(server.body, contains('Feedback'));
      expect(
        server.request!.url.toString(),
        'https://tg.example/botT0KEN/sendDocument',
      );
      expect(
        server.request!.headers['content-type'],
        startsWith('multipart/form-data'),
      );
      expect(server.body, contains('name="text"'));
      expect(server.body, contains('The total is wrong'));
      expect(server.body, contains('-100123'));
      expect(server.body, contains('filename="screen.png"'));
      expect(server.body, contains('PNGDATA'));
    });

    test('several files go one after another, with one progress', () async {
      final server = _Server();
      final progress = <double>[];
      await IssueReporter(
        client: server.client,
        baseUrl: 'https://tg.example',
        credentials: _creds,
      ).send(
        'hi',
        files: [_Picked('a.bin', Uint8List(4)), _Picked('b.bin', Uint8List(4))],
        onProgress: progress.add,
      );
      expect(server.body, contains('filename="a.bin"'));
      expect(server.body, contains('filename="b.bin"'));
      expect(server.body, contains('Attachment 1 of 2'));
      expect(server.body, contains('Attachment 2 of 2'));
      expect(progress, [.25, .5, .75, 1.0]);
    });

    test('the files together may not pass 30 MB, nor be over 10', () async {
      final server = _Server();
      final reporter = IssueReporter(
        client: server.client,
        baseUrl: 'https://tg.example',
        credentials: _creds,
      );
      final half = maxReportFileBytes ~/ 2 + 1;
      await expectLater(
        reporter.send(
          'big',
          files: [
            _Picked('a', Uint8List(1), size: half),
            _Picked('b', Uint8List(1), size: half),
          ],
        ),
        throwsA(isA<IssueReportException>()),
      );
      await expectLater(
        reporter.send(
          'many',
          files: [for (var i = 0; i < 11; i++) _Picked('f$i', Uint8List(1))],
        ),
        throwsA(isA<IssueReportException>()),
      );
      expect(server.request, isNull);
    });

    test('reports progress as the file is handed over', () async {
      final server = _Server();
      final progress = <double>[];
      await IssueReporter(
        client: server.client,
        baseUrl: 'https://tg.example',
        credentials: _creds,
      ).send(
        'hi',
        files: [_Picked('a.bin', Uint8List(8))],
        onProgress: progress.add,
      );
      expect(progress, [.25, .5, .75, 1.0]);
    });

    test('text alone is enough, and sends no file part', () async {
      final server = _Server();
      await IssueReporter(
        client: server.client,
        baseUrl: 'https://tg.example',
        credentials: _creds,
      ).send('Crashed on Home');
      expect(server.body, contains('Crashed on Home'));
      expect(server.request!.url.path, endsWith('/sendMessage'));
      expect(server.body, isNot(contains('name="document"')));
    });

    test('empty text and over-30 MB files never leave the phone', () async {
      final server = _Server();
      final reporter = IssueReporter(
        client: server.client,
        baseUrl: 'https://tg.example',
        credentials: _creds,
      );
      await expectLater(
        reporter.send('   '),
        throwsA(isA<IssueReportException>()),
      );
      await expectLater(
        reporter.send(
          'big',
          files: [
            _Picked('big.mov', Uint8List(1), size: maxReportFileBytes + 1),
          ],
        ),
        throwsA(
          isA<IssueReportException>().having(
            (e) => e.message,
            'message',
            contains('30 MB'),
          ),
        ),
      );
      expect(server.request, isNull);
    });

    test('a file of exactly 30 MB is accepted', () async {
      final server = _Server();
      await IssueReporter(
        client: server.client,
        baseUrl: 'https://tg.example',
        credentials: _creds,
      ).send(
        'ok',
        files: [_Picked('x.bin', Uint8List(1), size: maxReportFileBytes)],
      );
      expect(server.request, isNotNull);
    });

    test('server refusals become plain messages', () async {
      for (final (status, expected) in [
        (413, '30 MB'),
        (429, 'Too many'),
        (502, 'Couldn’t send'),
        (503, 'Couldn’t send'),
      ]) {
        final server = _Server(status);
        await expectLater(
          IssueReporter(
            client: server.client,
            baseUrl: 'https://tg.example',
            credentials: _creds,
          ).send('hi'),
          throwsA(
            isA<IssueReportException>().having(
              (e) => e.message,
              'message',
              contains(expected),
            ),
          ),
          reason: '$status',
        );
      }
    });
  });

  group('ReportIssueScreen', () {
    Future<_Server> open(
      WidgetTester tester, {
      Future<List<PlatformFile>> Function()? pick,
      int status = 200,
    }) async {
      final server = _Server(status);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReportIssueScreen(
                    reporter: IssueReporter(
                      client: server.client,
                      baseUrl: 'https://tg.example',
                      credentials: _creds,
                    ),
                    pickFiles: pick,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return server;
    }

    /// Lets the real async work of a send (preferences, the HTTP stream) run.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Not pumpAndSettle: the button's spinner animates for as long as it sends.
      await tester.pump(const Duration(milliseconds: 600));
    }

    bool canSend(WidgetTester tester) =>
        tester.widget<PillButton>(find.byType(PillButton)).onPressed != null;

    testWidgets('Help lists it', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: const HelpScreen(communityUrl: ''),
        ),
      );
      expect(find.text('Send feedback'), findsOneWidget);
      await tester.tap(find.text('Send feedback'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportIssueScreen), findsOneWidget);
      expect(find.text('Add attachment'), findsOneWidget);
      expect(find.text('Up to 30 MB'), findsOneWidget);
    });

    testWidgets('Send waits for some text', (tester) async {
      await open(tester);
      expect(canSend(tester), isFalse);
      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.pump();
      expect(canSend(tester), isFalse);
      await tester.enterText(find.byType(TextField).first, 'It crashed');
      await tester.pump();
      expect(canSend(tester), isTrue);
    });

    testWidgets('an attachment shows its name and size, and can be removed', (
      tester,
    ) async {
      await open(
        tester,
        pick: () async => [
          _Picked('shot.png', Uint8List(0), size: 3 * 1024 * 1024),
        ],
      );
      await tester.tap(find.text('Add attachment'));
      await tester.pumpAndSettle();
      expect(find.text('shot.png'), findsOneWidget);
      expect(find.text('3.0 MB'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove shot.png'));
      await tester.pump();
      expect(find.text('shot.png'), findsNothing);
      expect(find.text('Add attachment'), findsOneWidget);
    });

    testWidgets('a file over 30 MB is refused with a message', (tester) async {
      await open(
        tester,
        pick: () async => [
          _Picked('big.mov', Uint8List(0), size: maxReportFileBytes + 1),
        ],
      );
      await tester.tap(find.text('Add attachment'));
      await tester.pumpAndSettle();
      expect(find.textContaining('add up to 30 MB'), findsOneWidget);
      expect(find.text('big.mov'), findsNothing);
      expect(find.text('Add attachment'), findsOneWidget);
    });

    testWidgets('sending posts the report, then closes the screen', (
      tester,
    ) async {
      final server = await open(
        tester,
        pick: () async => [
          _Picked('log.txt', Uint8List.fromList([65, 66])),
        ],
      );
      await tester.enterText(
        find.byType(TextField).first,
        'The balance is off',
      );
      await tester.tap(find.text('Add attachment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await settle(tester);
      expect(server.body, contains('The balance is off'));
      expect(server.body, contains('filename="log.txt"'));
      // A thank-you popup first; the screen closes when it is dismissed.
      expect(find.text('Thank you!'), findsOneWidget);
      expect(find.byType(ReportIssueScreen), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Thank you!'), findsNothing);
      expect(find.byType(ReportIssueScreen), findsNothing);
    });

    testWidgets('a big attachment shows its progress while it sends', (
      tester,
    ) async {
      final gate = Completer<void>();
      final slow = MockClient.streaming((request, stream) async {
        await stream.toList();
        if (request.url.path.endsWith('sendDocument')) await gate.future;
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: ReportIssueScreen(
            reporter: IssueReporter(
              client: slow,
              baseUrl: 'https://tg.example',
              credentials: _creds,
            ),
            pickFiles: () async => [_Picked('clip.mov', Uint8List(40))],
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'Look at this');
      await tester.tap(find.text('Add attachment'));
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.tap(find.text('Submit'));
      await settle(tester);
      // The file has gone; the server hasn't answered yet.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Almost done…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        1.0,
      );
      gate.complete();
      await settle(tester);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('a failure keeps the text and says so', (tester) async {
      await open(tester, status: 502);
      await tester.enterText(
        find.byType(TextField).first,
        'The balance is off',
      );
      await tester.pump();
      await tester.tap(find.text('Submit'));
      await settle(tester);
      expect(find.byType(ReportIssueScreen), findsOneWidget);
      expect(find.textContaining('Couldn’t send'), findsOneWidget);
      expect(find.text('The balance is off'), findsOneWidget);
      expect(canSend(tester), isTrue);
    });

    testWidgets('leaving with something typed asks first', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'Half a thought');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.text('Your feedback will be discarded if you leave this page.'),
        findsOneWidget,
      );
      expect(find.byType(ReportIssueScreen), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportIssueScreen), findsOneWidget);
      expect(find.text('Half a thought'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportIssueScreen), findsNothing);
    });

    testWidgets('an empty form closes without asking', (tester) async {
      await open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReportIssueScreen), findsNothing);
    });

    testWidgets('several files can be added, and each removed', (tester) async {
      var round = 0;
      await open(
        tester,
        pick: () async => [
          _Picked('one${round++}.png', Uint8List(0), size: 1024 * 1024),
          _Picked('two$round.png', Uint8List(0), size: 2 * 1024 * 1024),
        ],
      );
      await tester.tap(find.text('Add attachment'));
      await tester.pumpAndSettle();
      expect(find.text('one0.png'), findsOneWidget);
      expect(find.text('two1.png'), findsOneWidget);
      expect(find.text('3.0 MB of 30 MB'), findsOneWidget);
      await tester.tap(find.text('Add another'));
      await tester.pumpAndSettle();
      expect(find.text('one1.png'), findsOneWidget);
      expect(find.text('6.0 MB of 30 MB'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove one0.png'));
      await tester.pump();
      expect(find.text('one0.png'), findsNothing);
      expect(find.text('4.0 MB of 30 MB'), findsNothing);
      expect(find.text('5.0 MB of 30 MB'), findsOneWidget);
    });

    testWidgets('back while sending asks, and leaving stops the send', (
      tester,
    ) async {
      final gate = Completer<void>();
      var closed = false;
      final slow = _Closable(
        MockClient.streaming((request, stream) async {
          await stream.toList();
          await gate.future;
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
        }),
        () => closed = true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReportIssueScreen(
                    reporter: IssueReporter(
                      client: slow,
                      baseUrl: 'https://tg.example',
                      credentials: _creds,
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Slow one');
      await tester.pump();
      await tester.tap(find.text('Submit'));
      await settle(tester);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.binding.handlePopRoute();
      // Bounded pumps: the spinner never settles, and the fake clock must not
      // run past the send's own timeout.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Stop sending?'), findsOneWidget);
      await tester.tap(find.text('Leave'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ReportIssueScreen), findsNothing);
      expect(closed, isTrue);
      expect(find.text('Thank you!'), findsNothing);
      // Let the abandoned request end, so no timer is left behind.
      gate.complete();
      await settle(tester);
      expect(find.text('Thank you!'), findsNothing);
    });
  });
}

/// A client that says when it is closed.
class _Closable extends http.BaseClient {
  _Closable(this._inner, this._onClose);
  final http.Client _inner;
  final void Function() _onClose;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);
  @override
  void close() {
    _onClose();
    _inner.close();
  }
}
