import 'dart:convert';

import '../models.dart';
import 'compiler.dart';

/// Full notification identity; amount and merchant alone are never sufficient.
String smsNotificationIdentity(BankSms sms) => jsonEncode([
  normalizeRuleSender(sms.sender),
  normalizeRuleText(sms.body, const ['ascii']),
]);

/// Carrier retries observed within 30 seconds, including whitespace-only changes.
bool isRepeatedSmsNotification(BankSms first, BankSms second) =>
    first.receivedAt.difference(second.receivedAt).abs() <=
        const Duration(seconds: 30) &&
    smsNotificationIdentity(first) == smsNotificationIdentity(second);
