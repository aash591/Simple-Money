import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../state/sms_import_store.dart';
import 'bank_sms_parser.dart';
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
  const ReportableSms(this.id, this.sms, this.kind, this.reason, this.parsed);

  /// Same identity as a queued import: sender, body and receive time.
  final String id;
  final BankSms sms;
  final ReportableKind kind;

  /// The engine's reason, sent with a report so rules can be prioritised.
  final String reason;

  /// What the parser read, for [ReportableKind.detected].
  final SmsTransactionCandidate? parsed;
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
  ReportableSmsRepository({Future<PortableSmsEngine> Function()? engineLoader})
    : _engineLoader = engineLoader ?? loadBundledSmsEngine;
  final Future<PortableSmsEngine> Function() _engineLoader;

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
  Future<void> report(
    List<ReportableSms> messages, {
    String note = '',
    String contact = '',
  }) async {
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
          },
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_contactKey, contact);
    await _add(_reportedKey, messages.map((m) => m.id));
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
