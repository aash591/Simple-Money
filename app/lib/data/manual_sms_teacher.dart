import 'dart:developer' as developer;

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../domain/currency.dart';
import '../domain/currency_digits.dart';
import 'agent/agent_rules.dart';
import 'agent/agent_suggestion_repository.dart';
import 'agent/sms_labeler.dart';
import 'bank_sms_parser.dart';
import 'db/app_database.dart';
import 'user_sms_rules.dart';
import 'notification_access_platform.dart';
import 'repositories/sms_import_repository.dart';
import 'sms_sender_role.dart';

/// What the person marked in one message, by tapping its words.
class SmsLabels {
  const SmsLabels({
    required this.amount,
    required this.moneyOut,
    required this.currency,
    this.account,
    this.payee,
  });

  /// Exactly as written in the message, e.g. "2,476.00".
  final String amount;
  final String? account, payee;

  /// Money left the person's account.
  final bool moneyOut;

  /// ISO code of the amount, e.g. INR.
  final String currency;
}

/// Teaches the app one SMS by hand: builds a rule from what the person
/// marked, checks it reads that message (and others like it), and saves it
/// as an approved suggestion, so More â€º AI suggestions keeps it with Undo.
/// The same path an AI app's `label_sms` takes, without the AI.
class ManualSmsTeacher {
  ManualSmsTeacher(this.database);
  final AppDatabase database;

  /// Who taught it, shown where suggestions name their AI app.
  static const source = 'You';

  /// Saves a rule for [message] read with [labels]. [others] are more
  /// messages from the same sender, tried too: the count that this rule
  /// also reads comes back. Throws [SmsTeachException] with a line for the
  /// person when it can't be taught this way.
  ///
  /// With [replacingRuleId] this teaches the same message again: that rule is
  /// left out of the clash check, and removed as soon as the new one is saved.
  /// If the new one can't be taught, nothing changes.
  Future<int> teach(
    BankSms message,
    SmsLabels labels, {
    List<BankSms> others = const [],
    String? country,
    String? appName,
    int? accountId,
    int? replacingRuleId,
  }) async {
    // An app's notification is read with a fixed word in front: see
    // [notificationRuleAnchor].
    if (appName != null) {
      BankSms ruleText(BankSms m) => BankSms(
        sender: m.sender,
        body: notificationRuleText(m.body),
        receivedAt: m.receivedAt,
      );
      message = ruleText(message);
      others = [for (final m in others) ruleText(m)];
    }
    final sender = normalizeRuleSender(message.sender);
    if (sender == null) {
      throw const SmsTeachException(
        'This sender canâ€™t be taught. It needs a sender ID, like HDFCBK.',
      );
    }
    // A rule the person taught before already reads this message: marking it
    // again replaces that rule. Left in place it would read the message
    // first, and the new one never could.
    replacingRuleId ??= (await ruleReading(message))?.id;
    // An account chosen up front, for an app whose notifications carry no
    // account number: every one goes to it, so the app holds the money.
    final assigned = accountId != null && labels.account == null;
    // A message that names the account is the bank's own; one that doesn't
    // is from a shop or biller, which is who was paid.
    final role = labels.account != null || assigned
        ? SmsSenderRole.bank
        : SmsSenderRole.merchant;
    // A bank the app doesn't know needs a name: its SMS usually signs off
    // with one ("â€¦ -Zyx Bank"). A shop's rule is named after the shop.
    // [appName] is given for an app's notification: the rule is the app's,
    // whoever each payment was to.
    final bankName =
        appName ??
        (role.holdsMoney
            ? (_signOff(message.body) ?? sender)
            : (labels.payee ?? sender));
    final ruleCountry = country ?? _countryOf(labels.currency);
    final Map<String, Object?> format;
    try {
      format = buildLabeledFormat(
        text: message.body,
        amount: labels.amount,
        account: labels.account,
        payee: labels.payee,
        direction: labels.moneyOut ? 'debit' : 'credit',
        channel: RegExp(r'\bupi\b', caseSensitive: false).hasMatch(message.body)
            ? 'upi'
            : 'other',
        role: role,
        senderName: bankName,
        country: ruleCountry,
        currency: labels.currency,
      );
    } on ArgumentError catch (e) {
      throw SmsTeachException(_plain('${e.message}'));
    }
    final rules = AgentRuleLab(database);
    final pool = [
      message,
      for (final m in others)
        if (normalizeRuleSender(m.sender) == sender && m.body != message.body)
          m,
    ].take(20).toList();
    final RuleTrial trial;
    try {
      trial = await rules.trial(
        bankName: bankName,
        senders: [sender],
        format: Map<String, dynamic>.from(format),
        samples: [for (final m in pool) RuleSample(m.body, sender: sender)],
        ignoringRuleId: replacingRuleId,
      );
    } on ArgumentError catch (e) {
      throw SmsTeachException(_plain('${e.message}'));
    }
    if (!trial.results.first.matched) {
      throw const SmsTeachException(
        'The marked words didnâ€™t read this message. Try marking them again.',
      );
    }
    final read = [
      for (final (i, r) in trial.results.indexed)
        if (r.matched) pool[i],
    ];
    final AgentSuggestionDraft draft;
    try {
      draft = await rules.prepare(
        bankName: bankName,
        senders: [sender],
        format: Map<String, dynamic>.from(format),
        samples: [for (final m in read) RuleSample(m.body, sender: sender)],
        reason: 'Taught by hand from a $sender message.',
        accountAssigned: assigned,
        ignoringRuleId: replacingRuleId,
        // An app's notification can leave the account and category to the
        // review, as a shop's SMS does.
        allowChoosing: appName != null,
      );
    } on ArgumentError catch (e) {
      throw SmsTeachException(_plain('${e.message}'));
    }
    final suggestions = AgentSuggestionRepository(database);
    final batch = await suggestions.add([
      AgentSuggestionDraft(
        kind: draft.kind,
        target: draft.target,
        payload: {...draft.payload, 'source': source},
        before: draft.before,
        summary: draft.summary,
        detail: draft.detail,
        reason: draft.reason,
      ),
    ]);
    final saved = (await suggestions.load(
      statuses: {AgentSuggestionStatus.pending},
    )).where((s) => s.batchId == batch);
    for (final s in saved) {
      final error = await suggestions.apply(s.id);
      if (error != null) throw SmsTeachException(error);
    }
    // Saved: the rule it replaces goes now, so the two never read side by
    // side.
    if (replacingRuleId != null) {
      await UserSmsRuleRepository(database).delete(replacingRuleId);
    }
    if (assigned) {
      await SmsImportRepository(database).linkBank(
        smsBankKey({
          'countryCode': ruleCountry,
          'bankName': draft.payload['bankName'],
          'currencyCode': labels.currency,
          'accountLast4': null,
        }),
        accountId,
        labels.currency,
      );
    }
    return read.length;
  }

  /// The rule the person taught (or that was shared with them) that reads
  /// [message] now, or null: what a report of a taught message is about.
  Future<UserSmsRule?> ruleReading(BankSms message) async {
    final sender = normalizeRuleSender(message.sender);
    if (sender == null) return null;
    try {
      final saved = [
        for (final r in await UserSmsRuleRepository(database).load())
          if (r.senders.contains(sender)) r,
      ];
      if (saved.isEmpty) return null;
      final read = BankSmsParser(await compileUserSmsRules(saved))
          .parse(message);
      for (final r in saved) {
        if (read.ruleId ==
            userSmsRuleId(r.bankName, r.id, country: ruleCountry(r.format))) {
          return r;
        }
      }
    } catch (_) {
      // Taught as a new rule, as before.
    }
    return null;
  }

  /// The name an SMS ends with, as in "â€¦ -Fincare SFB".
  static String? _signOff(String body) =>
      RegExp(r'[-â€“]\s*([A-Za-z][A-Za-z .&]{1,38}?)\.?\s*$')
          .firstMatch(body)
          ?.group(1)
          ?.trim();

  /// The country of a message in [currency], for the rule's number style and
  /// category words: the phone's own country when it uses that currency, else
  /// the one most people mean (a rupee is India's, not Bhutan's).
  static String _countryOf(String currency, {String? region}) {
    final uses = currencyTerritories[currency] ?? const <String>[];
    final home = region ?? Currency.deviceRegion();
    if (home != null && uses.contains(home)) return home;
    return switch (currency) {
          'INR' => 'IN',
          'USD' => 'US',
          'EUR' => 'DE',
          'GBP' => 'GB',
          'AED' => 'AE',
          'SAR' => 'SA',
          'AUD' => 'AU',
          'CAD' => 'CA',
          'SGD' => 'SG',
          'CHF' => 'CH',
          'NZD' => 'NZ',
          _ => uses.firstOrNull,
        } ??
        'IN';
  }

  /// Visible for tests.
  static String countryOfForTest(String currency, {String? region}) =>
      _countryOf(currency, region: region);

  /// The rule builder's reasons are written for an AI; these are for people.
  static String _plain(String reason) {
    if (reason.contains('never gives the account')) {
      // A shop's or biller's message: no account to mark, and nothing in it
      // says what the money was for.
      return 'This message doesnâ€™t say what the money was for, and a shop '
          'never gives your account. Teach the bankâ€™s own SMS for this '
          'payment instead.';
    }
    if (reason.contains('names no account') ||
        reason.contains('choosing both') ||
        reason.contains('choose both')) {
      return 'Mark the account number too, so the app knows where the money '
          'went.';
    }
    if (reason.contains('isnâ€™t in the message')) {
      return 'That value isnâ€™t in the message. Tap the words again.';
    }
    if (reason.contains('overlap')) {
      return 'Two marks overlap. Tap a word again to clear it.';
    }
    if (reason.contains('need words between') ||
        reason.contains('right after other text') ||
        reason.contains('runs into other digits') ||
        reason.contains('no words before')) {
      return 'The marked words sit too close to other numbers. Mark fewer, '
          'like just the amount and the account.';
    }
    if (reason.contains('clashes')) {
      return 'A rule for this bank already reads it another way.';
    }
    // Not one of the known cases: say what the rule builder said, so it
    // can be fixed, rather than a line that tells nothing.
    developer.log('teach: $reason', name: 'sms');
    final short = reason.length > 160
        ? '${reason.substring(0, 160)}â€¦'
        : reason;
    return 'This message canâ€™t be taught this way. $short';
  }
}

class SmsTeachException implements Exception {
  const SmsTeachException(this.message);
  final String message;
  @override
  String toString() => message;
}
