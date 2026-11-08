// The whole path, live: this app's session and tools, a relay running
// locally (`npm run dev` in relay/), and an MCP client signing in with a
// pairing code. Skipped unless RELAY_URL is set, e.g.
//   RELAY_URL=http://localhost:8787 flutter test test/ai_relay_live_test.dart
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

void main() {
  final relay = Platform.environment['RELAY_URL'];

  test(
    'An MCP client reads this phone’s accounts through the relay',
    () async {
      HttpOverrides.global = null;
      final db = AppDatabase(NativeDatabase.memory());
      await AccountRepository(db).save(
        name: 'Live HDFC',
        currency: 'INR',
        digits: 2,
        openingBalance: 123456,
      );
      final ai = AiSessionController(database: db, platform: _Platform());
      try {
        await ai.load();
        await ai.setRelayUrl(relay!);
        final pairing = await ai.pairingCode();
        await ai.start(const Duration(minutes: 5));
        for (var i = 0; i < 250 && ai.status != AiSessionStatus.live; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(ai.status, AiSessionStatus.live);

        final ask = await Process.run('node', [
          '../relay/scripts/ask.mjs',
          relay,
          pairing.code,
          'list_accounts',
        ]);
        expect(ask.exitCode, 0, reason: '${ask.stdout}\n${ask.stderr}');
        final answer = jsonDecode(ask.stdout as String) as Map<String, dynamic>;
        expect(
          answer['tools'],
          containsAll(['list_accounts', 'suggest_parser_rule']),
        );
        final text =
            ((answer['result']['content'] as List).single as Map)['text'];
        expect(jsonDecode(text as String)['accounts'], [
          containsPair('name', 'Live HDFC'),
        ]);
        expect(jsonDecode(text)['accounts'][0]['balance'], '1234.56');

        await ai.disconnectAll();
      } finally {
        ai.dispose();
        await db.close();
      }
    },
    skip: relay == null ? 'Set RELAY_URL to run against a local relay' : false,
  );
}
