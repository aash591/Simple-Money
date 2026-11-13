import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import 'agent_suggestion_repository.dart';
import 'agent_tools.dart';
import '../../state/pro_controller.dart';

/// The session notification and the relay credential, on the Android side
/// (AiSession.kt).
class AiSessionPlatform {
  static const _channel = MethodChannel('simple_money/ai_session');

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Shows or updates the session notification. False when Android refused
  /// to start it (the app was in the background).
  Future<bool> show({
    required DateTime endsAt,
    required bool connected,
    required int suggestions,
  }) async =>
      await _channel.invokeMethod<bool>('show', {
        'endsAt': endsAt.millisecondsSinceEpoch,
        'connected': connected,
        'suggestions': suggestions,
      }) ??
      false;

  Future<void> hide() => _channel.invokeMethod<void>('hide');

  Future<String?> readCredential() =>
      _channel.invokeMethod<String>('readCredential');

  Future<void> writeCredential(String? value) =>
      _channel.invokeMethod<void>('writeCredential', value);

  /// The notification's "+15 min" ([extend]) and "Stop" ([stop]) buttons.
  void onActions({required VoidCallback extend, required VoidCallback stop}) =>
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'extend') extend();
        if (call.method == 'stop') stop();
      });
}

class AiRelayException implements Exception {
  const AiRelayException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An AI app the user connected, as the relay lists it.
class AiConnection {
  const AiConnection(
    this.id,
    this.clientName,
    this.canSuggest,
    this.createdAt, [
    this.lastUsedAt,
  ]);
  final String id, clientName;

  /// Whether it may create suggestions, or only read.
  final bool canSuggest;
  final DateTime createdAt;

  /// When it last asked something; null if it never has. An app removed on
  /// its own side never tells the relay, so this is how the user can tell.
  final DateTime? lastUsedAt;
}

/// The relay's phone API (relay/README.md). Registers this install once and
/// keeps its credential outside backups.
class AiRelayClient {
  AiRelayClient(this.baseUrl, this.platform, {http.Client? client})
    : _http = client ?? http.Client();
  final String baseUrl;
  final AiSessionPlatform platform;
  final http.Client _http;
  ({String id, String secret})? _device;

  /// This install's registration with this relay, registering first if needed.
  Future<({String id, String secret})> device() async {
    if (_device case final device?) return device;
    final saved = await platform.readCredential();
    if (saved != null) {
      final json = jsonDecode(saved) as Map<String, dynamic>;
      // A credential belongs to the relay that issued it.
      if (json['relay'] == baseUrl) {
        return _device = (
          id: json['deviceId'] as String,
          secret: json['secret'] as String,
        );
      }
    }
    final response = await _http.post(Uri.parse('$baseUrl/device'));
    final json = _checked(response) as Map<String, dynamic>;
    final device = (
      id: json['deviceId'] as String,
      secret: json['secret'] as String,
    );
    await platform.writeCredential(
      jsonEncode({
        'relay': baseUrl,
        'deviceId': device.id,
        'secret': device.secret,
      }),
    );
    return _device = device;
  }

  Future<Map<String, String>> _auth() async {
    final d = await device();
    return {'Authorization': 'Device ${d.id}.${d.secret}'};
  }

  /// A one-time code for signing an AI app in. [advertised] is the tool list
  /// and instructions, so the app sees the tools before the first session.
  Future<({String code, DateTime expiresAt})> pair(
    Map<String, Object?> advertised, {
    String? keep,
  }) async {
    // [keep]: the code on show. The relay keeps it while it's live, so a copy
    // the user already pasted somewhere still works.
    final query = keep == null ? '' : '?keep=$keep';
    final json = _checked(
      await _http.post(
        Uri.parse('$baseUrl/device/pair$query'),
        headers: {...await _auth(), 'Content-Type': 'application/json'},
        body: jsonEncode(advertised),
      ),
    ) as Map<String, dynamic>;
    final pairing = (
      code: json['code'] as String,
      expiresAt: DateTime.now().add(
        Duration(seconds: json['expiresIn'] as int),
      ),
    );
    await _save(pairing);
    return pairing;
  }

  /// The code from the last [pair], while it has a minute or more left. A new
  /// code replaces the old one on the relay, so the old one is shown again
  /// rather than replaced: the user may already have copied it.
  Future<({String code, DateTime expiresAt})?> lastPairing() async {
    final saved = await platform.readCredential();
    if (saved == null) return null;
    final json = jsonDecode(saved) as Map<String, dynamic>;
    if (json['relay'] != baseUrl || json['pairCode'] is! String) return null;
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      json['pairExpires'] as int,
    );
    if (expiresAt.difference(DateTime.now()) < const Duration(minutes: 1)) {
      return null;
    }
    return (code: json['pairCode'] as String, expiresAt: expiresAt);
  }

  /// The phone's live code on the relay, or null once it's used or expired.
  /// Throws if the relay can't say (an older relay, or no connection).
  Future<String?> liveCode() async {
    final response = await _http.get(
      Uri.parse('$baseUrl/device/pair'),
      headers: await _auth(),
    );
    if (response.statusCode == 404 || response.statusCode == 405) {
      throw const AiRelayException('This relay can’t check codes.');
    }
    return (_checked(response) as Map<String, dynamic>)['code'] as String?;
  }

  /// Drops the saved code, once an AI app has used it.
  Future<void> forgetPairing() => _save(null);

  Future<void> _save(({String code, DateTime expiresAt})? pairing) async {
    final d = await device();
    await platform.writeCredential(
      jsonEncode({
        'relay': baseUrl,
        'deviceId': d.id,
        'secret': d.secret,
        if (pairing != null) ...{
          'pairCode': pairing.code,
          'pairExpires': pairing.expiresAt.millisecondsSinceEpoch,
        },
      }),
    );
  }

  Future<List<AiConnection>> connections() async {
    if (await platform.readCredential() == null && _device == null) return [];
    final json = _checked(
      await _http.get(
        Uri.parse('$baseUrl/device/connections'),
        headers: await _auth(),
      ),
    ) as Map<String, dynamic>;
    return [
      for (final c in json['connections'] as List)
        AiConnection(
          c['id'] as String,
          c['clientName'] as String,
          c['canSuggest'] as bool? ?? false,
          DateTime.fromMillisecondsSinceEpoch((c['createdAt'] as int) * 1000),
          switch (c['lastUsedAt']) {
            final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
            _ => null,
          },
        ),
    ];
  }

  Future<void> revoke(String id) async => _checked(
    await _http.delete(
      Uri.parse('$baseUrl/device/connections/$id'),
      headers: await _auth(),
    ),
  );

  /// Signs every AI app out and forgets this phone; the next pairing
  /// registers afresh.
  Future<void> reset() async {
    if (_device == null && await platform.readCredential() == null) return;
    _checked(
      await _http.delete(Uri.parse('$baseUrl/device'), headers: await _auth()),
    );
    _device = null;
    await platform.writeCredential(null);
  }

  Future<WebSocket> connect() async => WebSocket.connect(
    '${baseUrl.replaceFirst('http', 'ws')}/device/connect',
    headers: await _auth(),
  );

  Object? _checked(http.Response response) {
    if (response.statusCode == 401) {
      // The relay forgot this phone (it was reset elsewhere): start over.
      _device = null;
      unawaited(platform.writeCredential(null));
      throw const AiRelayException(
        'The relay no longer knows this phone. Try again to register it.',
      );
    }
    if (response.statusCode >= 300) {
      throw AiRelayException('The relay answered ${response.statusCode}.');
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }
}

enum AiSessionStatus { off, connecting, live }

/// The AI assistant: which relay to use, pairing codes, connected apps, and
/// the timed session during which AI apps can reach this phone. Outside a
/// session nothing can.
class AiSessionController extends ChangeNotifier {
  AiSessionController({
    required this.database,
    AiSessionPlatform? platform,
    this.httpClient,
    AgentTools? tools,
  }) : platform = platform ?? AiSessionPlatform() {
    this.tools =
        tools ??
        AgentTools(
          database,
          onSuggestionsChanged: refreshSuggestions,
          // Debug builds aren't from Play, so Pro can't be bought there.
          canUsePro: () => kDebugMode || ProController.instance.aiUnlocked,
        );
    this.platform.onActions(extend: extend, stop: stop);
  }
  final AppDatabase database;
  final AiSessionPlatform platform;
  final http.Client? httpClient;
  late final AgentTools tools;

  /// Set at build time with `--dart-define=AI_RELAY_URL=https://…`.
  static const builtInRelay = String.fromEnvironment('AI_RELAY_URL');
  static const _relayKey = 'ai.relay_url';
  static const extension = Duration(minutes: 15);
  static const _pingEvery = Duration(seconds: 25);

  String? _relayUrl;
  String? get relayUrl => _relayUrl;
  String? get connectorUrl => _relayUrl == null ? null : '$_relayUrl/mcp';
  AiRelayClient? _client;
  AiRelayClient? get _relay => _relayUrl == null
      ? null
      : _client ??= AiRelayClient(_relayUrl!, platform, client: httpClient);

  AiSessionStatus status = AiSessionStatus.off;
  DateTime? endsAt;
  String? error;
  List<AiConnection> connections = [];
  int pendingSuggestions = 0;

  /// The pairing code on show, kept until it expires or an AI app uses it.
  ({String code, DateTime expiresAt})? _pairing;
  ({String code, DateTime expiresAt})? get pairing =>
      _pairing != null && _pairing!.expiresAt.isAfter(DateTime.now())
      ? _pairing
      : null;
  bool _disposed = false;
  bool _connectionsLoaded = false;

  WebSocket? _socket;
  Timer? _endTimer;
  Completer<void>? _wake;
  int _run = 0;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _relayUrl = normalizeRelayUrl(prefs.getString(_relayKey) ?? builtInRelay);
    _pairing = await _relay?.lastPairing().catchError((_) => null);
    await refreshSuggestions();
    _notify();
  }

  /// `https://host[/path]`, without a trailing slash or `/mcp`. Plain http
  /// only for a relay on this computer or the emulator's host, for testing.
  static String? normalizeRelayUrl(String input) {
    final url = input
        .trim()
        .replaceFirst(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'/mcp$'), '');
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    final local = {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
    return uri.scheme == 'https' || (uri.scheme == 'http' && local)
        ? url
        : null;
  }

  /// Switches relays. The old relay's registration doesn't carry over, so
  /// every AI app must be connected again.
  Future<void> setRelayUrl(String input) async {
    final url = normalizeRelayUrl(input);
    if (url == null) throw const AiRelayException('Use an https:// address.');
    if (url == _relayUrl) return;
    await stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_relayKey, url);
    await platform.writeCredential(null);
    _relayUrl = url;
    _client = null;
    _pairing = null;
    connections = [];
    _notify();
  }

  Map<String, Object?> get _advertised => {
    'tools': tools.definitions,
    'instructions': AgentTools.instructions,
  };

  /// The code to show: the current one while it has a minute or more left,
  /// otherwise a new one.
  Future<({String code, DateTime expiresAt})> pairingCode() async {
    final relay =
        _relay ?? (throw const AiRelayException('Set a relay first.'));
    final shown = pairing?.code ?? (await relay.lastPairing())?.code;
    final code = await relay.pair(_advertised, keep: shown);
    _pairing = code;
    pairedAt = null;
    _notify();
    return code;
  }

  /// When an AI app last used this phone's code, for a "Connected" note
  /// while the connected-apps list catches up.
  DateTime? pairedAt;

  /// Drops the code on show once the relay says it's used or expired.
  Future<void> checkPairing() async {
    final relay = _relay;
    final shown = _pairing;
    if (relay == null || shown == null) return;
    try {
      if (await relay.liveCode() == shown.code) return;
    } catch (_) {
      return; // Can't tell: keep showing it until it expires.
    }
    _pairing = null;
    if (shown.expiresAt.isAfter(DateTime.now())) pairedAt = DateTime.now();
    await relay.forgetPairing();
    _notify();
  }

  Future<void> refreshConnections() async {
    final relay = _relay;
    if (relay == null) return;
    await checkPairing();
    try {
      final before = _connectionsLoaded
          ? connections.map((c) => c.id).toSet()
          : null;
      _revoked.removeWhere(
        (_, at) => DateTime.now().difference(at) > const Duration(minutes: 2),
      );
      connections = [
        for (final c in await relay.connections())
          if (!_revoked.containsKey(c.id)) c,
      ];
      _connectionsLoaded = true;
      error = null;
      // A new app signed in, so the code on show has been used.
      if (_pairing != null &&
          before != null &&
          connections.any((c) => !before.contains(c.id))) {
        _pairing = null;
        await relay.forgetPairing();
      }
    } catch (e) {
      error = _describe(e);
    }
    _notify();
  }

  Future<void> disconnect(AiConnection connection) async {
    await _relay?.revoke(connection.id);
    // The relay's list takes up to a minute to drop it; hide it now.
    _revoked[connection.id] = DateTime.now();
    connections = [
      for (final c in connections)
        if (c.id != connection.id) c,
    ];
    _notify();
    await refreshConnections();
  }

  /// Apps disconnected here, hidden while the relay's list catches up.
  final _revoked = <String, DateTime>{};

  /// Signs every AI app out and forgets this phone on the relay.
  Future<void> disconnectAll() async {
    await stop();
    await _relay?.reset();
    connections = [];
    _pairing = null;
    _notify();
  }

  Future<void> refreshSuggestions() async {
    pendingSuggestions = await tools.suggestions.pendingCount();
    _notify();
    _showNotification();
  }

  // ── The session. ──

  Future<void> start(Duration length) async {
    if (_relay == null) throw const AiRelayException('Set a relay first.');
    endsAt = DateTime.now().add(length);
    _armEnd();
    if (status != AiSessionStatus.off) {
      _showNotification();
      return;
    }
    error = null;
    status = AiSessionStatus.connecting;
    _notify();
    _showNotification();
    unawaited(_loop(++_run));
  }

  void extend() {
    if (status == AiSessionStatus.off) return;
    final from = endsAt != null && endsAt!.isAfter(DateTime.now())
        ? endsAt!
        : DateTime.now();
    endsAt = from.add(extension);
    _armEnd();
    _notify();
    _showNotification();
  }

  Future<void> stop() async {
    if (status == AiSessionStatus.off) return;
    _run++;
    status = AiSessionStatus.off;
    endsAt = null;
    _endTimer?.cancel();
    if (_wake case final wake? when !wake.isCompleted) wake.complete();
    await _socket?.close(1000, 'session ended');
    _socket = null;
    if (platform.supported) await platform.hide();
    _notify();
  }

  void _armEnd() {
    _endTimer?.cancel();
    _endTimer = Timer(endsAt!.difference(DateTime.now()), stop);
  }

  /// Keeps one connection open until the session ends, reconnecting with
  /// growing pauses when the network drops.
  Future<void> _loop(int run) async {
    var pause = const Duration(seconds: 1);
    while (run == _run) {
      Timer? ping;
      try {
        final socket = await _relay!.connect();
        if (run != _run) {
          await socket.close(1000);
          return;
        }
        _socket = socket;
        socket.add(jsonEncode({'type': 'hello', ..._advertised}));
        status = AiSessionStatus.live;
        error = null;
        pause = const Duration(seconds: 1);
        _notify();
        _showNotification();
        var answered = DateTime.now();
        ping = Timer.periodic(_pingEvery, (_) {
          // No pong for two rounds: the network is gone without saying so.
          if (DateTime.now().difference(answered) > _pingEvery * 2.5) {
            socket.close(4100, 'no pong');
          } else {
            socket.add('ping');
          }
        });
        await for (final message in socket) {
          answered = DateTime.now();
          if (message is String && message != 'pong') {
            unawaited(_answer(socket, message));
          }
        }
        // Replaced by another connection of this phone, or the phone was
        // reset: this session is over.
        if (socket.closeCode == 4000 || socket.closeCode == 4001) {
          error = socket.closeCode == 4001
              ? 'This phone was disconnected from the relay.'
              : null;
          await stop();
          return;
        }
      } catch (e) {
        error = _describe(e);
      } finally {
        ping?.cancel();
        _socket = null;
      }
      if (run != _run) return;
      status = AiSessionStatus.connecting;
      _notify();
      _showNotification();
      _wake = Completer<void>();
      await Future.any([Future<void>.delayed(pause), _wake!.future]);
      pause = Duration(seconds: math.min(pause.inSeconds * 2, 30));
    }
  }

  Future<void> _answer(WebSocket socket, String message) async {
    final Map<String, dynamic> call;
    try {
      call = jsonDecode(message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (call['type'] != 'call') return;
    final name = call['name'] as String? ?? '';
    final watch = Stopwatch()..start();
    final result = await tools.call(
      name,
      Map<String, Object?>.from(call['arguments'] as Map? ?? const {}),
      // The relay names the app; an older one doesn't, but with a single
      // connected app it can only have been that one.
      client:
          call['client'] as String? ??
          (connections.length == 1 ? connections.first.clientName : null),
    );
    // In debug builds, which tools ran and how long they took: the
    // question and the answer stay out of the log.
    assert(() {
      debugPrint(
        'AI call $name: ${result['isError'] == true ? 'error' : 'ok'} in '
        '${watch.elapsedMilliseconds} ms'
        '${socket.closeCode == null ? '' : ' (connection closed, not sent)'}',
      );
      return true;
    }());
    if (socket.closeCode == null) {
      socket.add(
        jsonEncode({'type': 'result', 'id': call['id'], 'result': result}),
      );
    }
  }

  void _showNotification() {
    final until = endsAt;
    if (status == AiSessionStatus.off || until == null || !platform.supported) {
      return;
    }
    unawaited(
      platform
          .show(
            endsAt: until,
            connected: status == AiSessionStatus.live,
            suggestions: pendingSuggestions,
          )
          .catchError((_) => false),
    );
  }

  static String _describe(Object error) => switch (error) {
    AiRelayException(:final message) => message,
    SocketException() ||
    WebSocketException() ||
    HttpException() => 'Can’t reach the relay. Check your connection.',
    _ => describeAgentError(error),
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
