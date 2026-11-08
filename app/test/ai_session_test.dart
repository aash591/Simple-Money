import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/ai_session.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';

class _Platform extends AiSessionPlatform {
  String? credential;
  @override
  bool get supported => false;
  @override
  Future<String?> readCredential() async => credential;
  @override
  Future<void> writeCredential(String? value) async => credential = value;
  @override
  void onActions({
    required void Function() extend,
    required void Function() stop,
  }) {}
}

/// The relay's phone API, in process: registration, pairing, and the
/// session WebSocket, recording what the phone sends.
class _Relay {
  late final HttpServer server;
  final sockets = <WebSocket>[];
  final received = <Map<String, dynamic>>[];
  Map<String, dynamic>? paired;
  int pairs = 0;

  /// The phone's live code, as the relay sees it.
  String? current;

  /// What GET /device/connections answers.
  List<Map<String, Object?>> listed = [];
  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (path != '/device' &&
          request.headers.value('authorization') !=
              'Device ${'a' * 32}.${'b' * 43}') {
        request.response.statusCode = 401;
        await request.response.close();
        return;
      }
      if (path == '/device/connect') {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((message) {
          if (message == 'ping') return socket.add('pong');
          received.add(jsonDecode(message as String) as Map<String, dynamic>);
        });
        return;
      }
      Object body = {};
      if (path == '/device') body = {'deviceId': 'a' * 32, 'secret': 'b' * 43};
      if (path == '/device/pair' && request.method == 'GET') {
        body = {'code': current};
      } else if (path == '/device/pair') {
        paired = jsonDecode(
          await utf8.decodeStream(request),
        ) as Map<String, dynamic>;
        final keep = request.uri.queryParameters['keep'];
        if (keep == null || keep != current) current = '12345${++pairs}';
        body = {'code': current, 'expiresIn': 300};
      }
      if (path == '/device/connections') body = {'connections': listed};
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    });
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting');
}

void main() {
  late AppDatabase db;
  late _Relay relay;
  late _Platform platform;
  late AiSessionController ai;

  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await AccountRepository(db)
        .save(name: 'HDFC', currency: 'INR', digits: 2, openingBalance: 50000);
    relay = _Relay();
    await relay.start();
    platform = _Platform();
    ai = AiSessionController(database: db, platform: platform);
    await ai.load();
    await ai.setRelayUrl(relay.url);
  });

  tearDown(() async {
    ai.dispose();
    await relay.server.close(force: true);
    await db.close();
  });

  test('Relay addresses must be https, except on this computer', () {
    expect(
      AiSessionController.normalizeRelayUrl(' https://relay.example.dev/mcp/ '),
      'https://relay.example.dev',
    );
    expect(
      AiSessionController.normalizeRelayUrl('http://relay.example.dev'),
      isNull,
    );
    expect(
      AiSessionController.normalizeRelayUrl('http://10.0.2.2:8787'),
      'http://10.0.2.2:8787',
    );
  });

  test('Pairing registers once and sends the tools along', () async {
    final pairing = await ai.pairingCode();
    expect(pairing.code, '123451');
    expect(jsonDecode(platform.credential!)['relay'], relay.url);
    final tools = (relay.paired!['tools'] as List).map(
      (t) => (t as Map)['name'],
    );
    expect(tools, containsAll(['list_accounts', 'suggest_parser_rule']));
    expect(relay.paired!['instructions'], contains('SimpleMoney'));
  });

  test(
    'The code on show is kept, not replaced, even after a restart',
    () async {
      final first = await ai.pairingCode();
      expect((await ai.pairingCode()).code, first.code);
      expect(ai.pairing?.code, first.code);

      // The app is closed and opened again: same code, no new one asked for.
      final again = AiSessionController(database: db, platform: platform);
      await again.load();
      expect(again.pairing?.code, first.code);
      expect((await again.pairingCode()).code, first.code);
      expect(relay.pairs, 1);
      again.dispose();
    },
  );

  test('A used code disappears, with a note that the app connected', () async {
    await ai.pairingCode();
    relay.current = null; // An AI app signed in with it.
    await ai.refreshConnections();
    expect(ai.pairing, isNull);
    expect(ai.pairedAt, isNotNull);
    // The next code is a new one.
    expect((await ai.pairingCode()).code, '123452');
  });

  test(
    'A session answers tool calls from the database, and reconnects',
    () async {
      await ai.start(const Duration(minutes: 30));
      await until(
        () => ai.status == AiSessionStatus.live && relay.received.isNotEmpty,
      );
      expect(relay.received.first['type'], 'hello');

      relay.sockets.single.add(
        jsonEncode({
          'type': 'call',
          'id': 'c1',
          'name': 'list_accounts',
          'arguments': {},
        }),
      );
      await until(() => relay.received.length == 2);
      final answer = relay.received[1];
      expect(answer['id'], 'c1');
      final text =
          (((answer['result'] as Map)['content'] as List).single
              as Map)['text'];
      expect(jsonDecode(text as String)['accounts'][0]['balance'], '500.00');

      final before = ai.endsAt!;
      ai.extend();
      expect(ai.endsAt!.difference(before), const Duration(minutes: 15));

      // The network drops: the session reconnects on its own.
      await relay.sockets.single.close(1011, 'gone');
      await until(
        () => relay.sockets.length == 2 && ai.status == AiSessionStatus.live,
      );

      await ai.stop();
      expect(ai.status, AiSessionStatus.off);
      await until(() => relay.sockets.last.closeCode != null);
    },
  );

  test(
    'A disconnected app leaves the list at once, though the relay lags',
    () async {
      relay.listed = [
        {
          'id': 'g1',
          'clientName': 'Claude',
          'canSuggest': true,
          'createdAt': 1790000000,
          'lastUsedAt': 1790000600000,
        },
      ];
      await ai.pairingCode(); // Registers the phone.
      await ai.refreshConnections();
      expect(
        ai.connections.single.lastUsedAt,
        DateTime.fromMillisecondsSinceEpoch(1790000600000),
      );

      await ai.disconnect(ai.connections.single);
      expect(ai.connections, isEmpty);
      // The relay still lists it for a while: it stays hidden.
      await ai.refreshConnections();
      expect(ai.connections, isEmpty);
    },
  );

  test('A phone reset elsewhere ends the session', () async {
    await ai.start(const Duration(minutes: 15));
    await until(
      () => ai.status == AiSessionStatus.live && relay.sockets.isNotEmpty,
    );
    await relay.sockets.single.close(4001, 'reset');
    await until(() => ai.status == AiSessionStatus.off);
    expect(ai.error, 'This phone was disconnected from the relay.');
  });
}
