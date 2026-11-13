import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../state/sms_import_store.dart';
import 'bank_sms_parser.dart';
import 'community/community_fixes.dart';
import 'sms_inbox_platform.dart';

enum ReportableKind {
  /// Reads like a payment, but no rule could parse it.
  missed,

  /// Parsed as a transaction, though possibly wrongly.
  detected,

  /// Any other message from a bank or business sender.
  other,
}

/// A business SMS the user may report, with what the parser made of it.
class ReportableSms {
  const ReportableSms(
    this.id,
    this.sms,
    this.kind,
    this.reason,
    this.parsed, {
    this.bank,
  });

  /// Same identity as a queued import: sender, body and receive time.
  final String id;
  final BankSms sms;
  final ReportableKind kind;

  /// The engine's reason, sent with a report so rules can be prioritised.
  final String reason;

  /// What the parser read, for [ReportableKind.detected].
  final SmsTransactionCandidate? parsed;

  /// The bank its sender belongs to, as far as the app knows: what the
  /// parser read, or the bank a rule registers the sender under.
  final String? bank;
}

String _fingerprint(BankSms sms) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          sms.sender,
          sms.body,
          sms.receivedAt.millisecondsSinceEpoch,
        ]),
      ),
    )
    .toString();

List<ReportableSms> _classify(
  PortableSmsEngine engine,
  List<BankSms> messages,
) {
  final found = <ReportableSms>[];
  for (final sms in messages) {
    // Personal numbers and promotional headers are never listed.
    if (!isBusinessSender(sms)) continue;
    final result = engine.parse(sms);
    final kind = result.candidate != null
        ? ReportableKind.detected
        : looksLikeMissedTransaction(sms, result)
        ? ReportableKind.missed
        : ReportableKind.other;
    // Nor are one-time passwords, which are worth nothing to a report.
    if (kind == ReportableKind.other &&
        (result.classification == RuleClassification.security ||
            looksLikeOtp(sms))) {
      continue;
    }
    found.add(
      ReportableSms(
        _fingerprint(sms),
        sms,
        kind,
        result.reason,
        result.candidate,
        bank:
            result.candidate?.bankName ??
            (engine is BankSmsParser ? engine.bankFor(sms.sender) : null),
      ),
    );
  }
  found.sort((a, b) => b.sms.receivedAt.compareTo(a.sms.receivedAt));
  return found;
}

/// Classifies pages of SMS on a background isolate that receives the engine
/// once, replying to each page with its reportable messages.
void _classifier((SendPort, PortableSmsEngine) setup) {
  final (reply, engine) = setup;
  final pages = ReceivePort();
  reply.send(pages.sendPort);
  pages.listen((page) => reply.send(_classify(engine, page as List<BankSms>)));
}

/// Lists business SMS for reporting, remembers which were reported or
/// hidden, and sends reports encrypted to the developer.
class ReportableSmsRepository {
  /// [engineLoader] defaults to the bundled packs alone, so a report shows
  /// what the shipped rules miss.
  ReportableSmsRepository({
    Future<PortableSmsEngine> Function()? engineLoader,
    this._client,
    String? baseUrl,
  }) : _engineLoader = engineLoader ?? loadBundledSmsEngine,
       _baseUrl = baseUrl ?? communityUrl;
  final Future<PortableSmsEngine> Function() _engineLoader;

  /// For tests; otherwise each upload opens its own.
  final http.Client? _client;
  final String _baseUrl;

  static const _channel = MethodChannel('simple_money/help_improve');
  static const _reportedKey = 'help_improve.reported';
  static const _contactKey = 'help_improve.contact';

  /// Old enough to cover a few statement cycles without reading years of SMS.
  static const window = Duration(days: 180);

  final inbox = SmsInboxPlatform();

  /// Reads the inbox a page at a time and yields each page's reportable
  /// messages as soon as they're classified, so the list fills in while the
  /// rest is still being read. Cancelling stops the background isolate.
  Stream<List<ReportableSms>> scan({Duration window = window}) async* {
    final since = DateTime.now().subtract(window).millisecondsSinceEpoch;
    var page = await inbox.readPage(afterId: 0, since: since);
    if (page.isEmpty) return;
    final engine = await _engineLoader();
    final replies = ReceivePort();
    final worker = await Isolate.spawn(_classifier, (replies.sendPort, engine));
    final results = StreamIterator(replies);
    Future<List<InboxSms>>? next;
    try {
      await results.moveNext();
      final pages = results.current as SendPort;
      while (page.isNotEmpty) {
        pages.send([for (final row in page) row.sms]);
        final afterId = page.last.id;
        // Read the next page while this one is classified.
        next = inbox.readPage(afterId: afterId, since: since);
        await results.moveNext();
        yield results.current as List<ReportableSms>;
        page = await next;
        next = null;
      }
    } finally {
      // Left unread when the screen closes mid-scan.
      next?.ignore();
      worker.kill();
      await results.cancel();
    }
  }

  Future<Set<String>> reportedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_reportedKey) ?? const []).toSet();
  }

  /// The contact given last time, offered again so it needn't be retyped.
  Future<String> savedContact() async =>
      (await SharedPreferences.getInstance()).getString(_contactKey) ?? '';

  /// Uploads [messages] as one encrypted archive, with the user's optional
  /// [note] and [contact], then marks them reported.
  /// Throws [PlatformException] when delivery is not confirmed.
  ///
  /// [fix] is the shared fix (its hash) that read them, when reported from
  /// Shared fixes.
  ///
  /// [bank] is the bank or app the messages are from, as the user typed it;
  /// otherwise each message names the bank the parser read, if any. Each
  /// also names its country: the parser's, or the one picked at setup.
  Future<void> report(
    List<ReportableSms> messages, {
    String note = '',
    String contact = '',
    String bank = '',
    String? fix,
  }) async {
    final home = await _setupCountry();
    String? bankOf(ReportableSms m) =>
        bank.trim().isNotEmpty ? bank.trim() : m.bank;
    String? countryOf(ReportableSms m) => m.parsed?.countryCode ?? home;
    await _channel.invokeMethod<int>('report', {
      'messages': [
        for (final m in messages)
          {
            'address': m.sms.sender,
            'body': m.sms.body,
            'dateMs': m.sms.receivedAt.millisecondsSinceEpoch,
            'reason': m.reason,
            'kind': m.kind.name,
            if (m.parsed case final parsed?) 'parsed': jsonEncode(parsed),
            if (note.isNotEmpty) 'note': note,
            if (contact.isNotEmpty) 'contact': contact,
            'bank': ?bankOf(m),
            'country': ?countryOf(m),
            'fix': ?fix,
          },
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_contactKey, contact);
    await _add(_reportedKey, messages.map((m) => m.id));
    // The encrypted copy is delivered. This readable copy is for the
    // developer's dashboard, and its failure never fails the report.
    unawaited(
      _shareForDashboard(
        messages,
        note: note,
        contact: contact,
        bankOf: bankOf,
        countryOf: countryOf,
        fix: fix,
      ),
    );
  }

  /// The country picked at setup (from the time zone, or changed later).
  static Future<String?> _setupCountry() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        'main_currency',
      );
      if (saved == null) return null;
      final territory = (jsonDecode(saved) as Map)['territory'];
      return territory is String && RegExp(r'^[A-Z]{2}$').hasMatch(territory)
          ? territory
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Sends the reported messages as they are to the community server, 50 at
  /// a time. Best effort: offline or refused just means no dashboard copy.
  Future<void> _shareForDashboard(
    List<ReportableSms> messages, {
    required String note,
    required String contact,
    required String? Function(ReportableSms) bankOf,
    required String? Function(ReportableSms) countryOf,
    String? fix,
  }) async {
    final client = _client ?? http.Client();
    try {
      final prefs = await SharedPreferences.getInstance();
      final install = await communityInstallId(prefs);
      String? version;
      try {
        final info = await PackageInfo.fromPlatform();
        version = '${info.version}+${info.buildNumber}';
      } catch (_) {}
      for (var at = 0; at < messages.length; at += 50) {
        final chunk = messages.skip(at).take(50);
        await client
            .post(
              Uri.parse('$_baseUrl/v1/sms-reports'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'install': install,
                'appVersion': ?version,
                if (note.isNotEmpty) 'note': note,
                if (contact.isNotEmpty) 'contact': contact,
                'messages': [
                  for (final m in chunk)
                    {
                      'address': m.sms.sender,
                      'body': m.sms.body,
                      'dateMs': m.sms.receivedAt.millisecondsSinceEpoch,
                      'kind': m.kind.name,
                      'reason': m.reason,
                      'parsed': ?m.parsed,
                      'bank': ?bankOf(m),
                      'country': ?countryOf(m),
                      'fix': ?fix,
                    },
                ],
              }),
            )
            .timeout(const Duration(seconds: 20));
      }
    } catch (_) {
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');

  Future<void> _add(String key, Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      key,
      {...?prefs.getStringList(key), ...ids}.toList(),
    );
  }
}
