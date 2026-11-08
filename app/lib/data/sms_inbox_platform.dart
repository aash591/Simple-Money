import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

class InboxSms {
  const InboxSms(this.id, this.sms);
  final int id;
  final BankSms sms;
}

class SmsInboxPlatform {
  static const _channel = MethodChannel('simple_money/sms_inbox');
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<bool> hasPermission() async =>
      supported &&
      (await _channel.invokeMethod<bool>('hasPermission') ?? false);
  Future<bool> requestPermission() async =>
      supported &&
      (await _channel.invokeMethod<bool>('requestPermission') ?? false);
  Future<void> setRealtimeEnabled(bool enabled) async {
    if (!supported) return;
    await const MethodChannel('simple_money/sms_notifications')
        .invokeMethod<void>('enabled', enabled);
  }

  Future<List<InboxSms>> readPage({
    required int afterId,
    required int since,
  }) async {
    final rows =
        await _channel.invokeListMethod<dynamic>('readPage', {
          'afterId': afterId,
          'since': since,
          'limit': 200,
        }) ??
        [];
    return rows
        .map(
          (r) => InboxSms(
            r['id'] as int,
            BankSms(
              sender: r['sender'] as String,
              body: r['body'] as String,
              receivedAt: DateTime.fromMillisecondsSinceEpoch(
                r['receivedAt'] as int,
              ),
            ),
          ),
        )
        .toList();
  }
}
