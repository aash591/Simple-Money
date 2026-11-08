import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../domain/account.dart';

final _creditCard = RegExp(
  r'\bcredit\s*card\b|\bSBI\s*card\b|\bSuperCard\b',
  caseSensitive: false,
);
final _money = RegExp(
  r'(?:INR|Rs\.?|₹)\s*([+-]?\d[\d,]*(?:\.\d{1,2})?)(?![\d,]|\.\d)',
  caseSensitive: false,
);
final _balance = RegExp(
  r'\b(?:avl\.?|avail\.?|available|current|closing|clear)?\s*(?:balance\b|bal\.?)\s*(?:is\s*)?[:=.-]?\s*(?:INR|Rs\.?|₹)\s*([+-]?\d[\d,]*(?:\.\d{1,2})?)(?![\d,]|\.\d)',
  caseSensitive: false,
);
final _account = RegExp(
  r'(?:\ba\s*[/\\]\s*c|\bac\b|\baccount|\bacct|\b(?:one|credit|debit|super)\s*card|\bcard)\s*(?:(?:no\.?|number)\s*)?(?:ending\s*(?:with|in)?\s*)?[:.(\s]*[xX*•-]*(\d{4,})\b',
  caseSensitive: false,
);
final _unsafe = RegExp(
  r'\b(?:OTP|one.time.password|declined|failed|unsuccessful|pending|initiated|requested|scheduled|will|due|statement|offer|apply|reward\s*points\s+(?:have\s+been\s+)?credited|converted\s+into\s+EMI)\b',
  caseSensitive: false,
);
final _availableLimit = RegExp(
  r'\b(?:avl\.?|avail\.?|available)\s+(?:credit\s+)?limit\b\s*(?:is\s*)?[:=.-]?\s*(?:INR|Rs\.?|₹)\s*(\d[\d,]*(?:\.\d{1,2})?)(?![\d,]|\.\d)',
  caseSensitive: false,
);
final _totalLimit = RegExp(
  r'\b(?:total\s+(?:credit\s+)?limit|credit\s+limit)\b\s*(?:is|:|=)?\s*(?:INR|Rs\.?|₹)\s*(\d[\d,]*(?:\.\d{1,2})?)(?![\d,]|\.\d)',
  caseSensitive: false,
);
final _revisedTotalLimit = RegExp(
  r'\bcredit\s+limit\b[^\n]*?\b(?:revised\s+to|set\s+to)\s*(?:INR|Rs\.?|₹)\s*(\d[\d,]*(?:\.\d{1,2})?)(?![\d,]|\.\d)',
  caseSensitive: false,
);

final _reference = RegExp(
  r'\b(?:ref(?:erence)?(?:\s*(?:no\.?|number))?|UTR)\s*[:.#-]?\s*([A-Z0-9]{6,35})\b',
  caseSensitive: false,
);
final _digit = RegExp(r'\d');
final _debitCard = RegExp(r'\bdebit\s*card\b', caseSensitive: false);
final _card = RegExp(r'\bcard\b', caseSensitive: false);
final _merchantPayment = RegExp(
  r'\bpayment\s+of\s+(?:INR|Rs\.?|₹)\s*\d[\d,.]*\s+at\b',
  caseSensitive: false,
);
final _cardCredit = RegExp(
  r'\bcredited\b|\bpayment\b.*\b(?:received|processed)\b|\breceived\s+(?:a\s+)?payment\b|\brefund(?:ed)?\b',
  caseSensitive: false,
);
final _credited = RegExp(r'\bcredited\b', caseSensitive: false);
final _completed = RegExp(
  r'\b(?:spent|debited|withdrawn)\b|\b(?:charged|used|paid|purchase(?:d)?|made\s+a\s+payment|transaction\s+(?:of|for))\b|\bpayment\s+of\b[\s\S]*\bat\b[\s\S]*\bprocessed\b',
  caseSensitive: false,
);
final _moved = RegExp(
  r'\b(?:credited|debited|withdrawn|spent)\b',
  caseSensitive: false,
);
final _figureBefore = RegExp(
  r'\b(?:balance|bal|limit)\b[^.!]*$',
  caseSensitive: false,
);
final _merchant = RegExp(
  r'\bat\s+(.+?)(?=\s+on\b|[.\n]|$)',
  caseSensitive: false,
);
final _upi = RegExp(r'\bUPI\b', caseSensitive: false);

String? _lastBody, _lastSender;
Map<String, dynamic>? _lastMetadata;

/// Host metadata keeps the portable rule pack's contract unchanged.
///
/// Parsing, balance snapshots and queueing all ask about the same message in
/// turn, so the most recent answer is reused.
Map<String, dynamic> smsMetadata(String body, {String? sender}) {
  if (identical(body, _lastBody) && sender == _lastSender) {
    return _lastMetadata!;
  }
  final metadata = Map<String, dynamic>.unmodifiable(_metadata(body, sender));
  _lastBody = body;
  _lastSender = sender;
  return _lastMetadata = metadata;
}

Map<String, dynamic> _metadata(String body, String? sender) {
  final references = _reference
      .allMatches(body)
      .map((m) => m.group(1)!.toUpperCase())
      .where(_digit.hasMatch)
      .toSet();
  final card =
      _creditCard.hasMatch(body) ||
      (!_debitCard.hasMatch(body) &&
          ({
                'ONECRD',
                'ONECARD',
                'SBICRD',
              }.contains(normalizeRuleSender(sender ?? '')) ||
              (_card.hasMatch(body) && _availableLimit.hasMatch(body))));
  final merchantPayment = _merchantPayment.hasMatch(body);
  final balance = card ? null : _balance.firstMatch(body);
  final limit = card ? _availableLimit.firstMatch(body) : null;
  final total = card
      ? _totalLimit
                .allMatches(body)
                .where(
                  (m) =>
                      limit == null ||
                      m.start < limit.start ||
                      m.start >= limit.end,
                )
                .firstOrNull ??
            _revisedTotalLimit.firstMatch(body)
      : null;
  return {
    if (references.length == 1) 'bankReference': references.single,
    'isCreditCard': card,
    if (card && merchantPayment) 'direction': 'debit',
    if (total != null)
      'creditLimitMinor': parseAccountAmount(
        total.group(1)!.replaceAll(',', ''),
        2,
      ),
    if (limit != null)
      'availableCreditLimitMinor': parseAccountAmount(
        limit.group(1)!.replaceAll(',', ''),
        2,
      ),
    if (balance != null)
      'balanceMinor': parseAccountAmount(
        balance.group(1)!.replaceAll(',', ''),
        2,
      ),
    if (card && !merchantPayment && _cardCredit.hasMatch(body))
      'direction': 'credit',
  };
}

final _textSenderStart = RegExp(r'^[A-Z]');
final _movement = RegExp(
  r'\b(?:credited|debited|withdrawn|spent|paid|charged|purchased?|received|sent|transferred|deposited|refund(?:ed)?|transaction\s+(?:of|for))\b',
  caseSensitive: false,
);

/// Reasons the engine gives when it could not read a message, as opposed to
/// reading it and deciding it is not a transaction (OTP, offer, failed...).
const _unreadReasons = {
  'noMatchingFormat',
  'unregisteredSender',
  'ambiguousMatches',
};

final _otp = RegExp(
  r'\b(?:OTP|one.time.password|verification\s+code)\b',
  caseSensitive: false,
);

/// True for a one-time password, from any sender, known bank or not.
bool looksLikeOtp(BankSms sms) => _otp.hasMatch(sms.body);

/// True for a text sender such as AD-SBIINB: never a personal number or a
/// promotional -P header.
bool isBusinessSender(BankSms sms) {
  final sender = normalizeRuleSender(sms.sender);
  return sender != null && _textSenderStart.hasMatch(sender);
}

/// True when [sms] reads like a completed payment the parser missed: a text
/// sender (never a personal number or a promotional -P header), an amount, a
/// money-movement verb and none of the offer, OTP or pending wording.
bool looksLikeMissedTransaction(BankSms sms, PortableParseResult result) {
  if (result.candidate != null || !_unreadReasons.contains(result.reason)) {
    return false;
  }
  return isBusinessSender(sms) &&
      _money.hasMatch(sms.body) &&
      _movement.hasMatch(sms.body) &&
      !_unsafe.hasMatch(sms.body);
}

/// Additional completed formats, restricted to registered Indian senders.
class BankSmsParser extends PortableSmsEngine {
  BankSmsParser(RuntimeRulePack pack) : super(pack) {
    for (final rule in pack.toJson()['rules'] as List) {
      if (rule['country'] != 'IN') continue;
      for (final sender in rule['senders'] as List) {
        _banks[sender as String] = rule['bankName'] as String;
      }
    }
    if (_banks.isNotEmpty) _banks.addAll(hostOnlySenders);
  }

  /// Observed card-only sender families missing from the portable Indian pack.
  static const hostOnlySenders = {
    'RBLBNK': 'RBL Bank',
    'RBLCRD': 'RBL Bank',
    'SPRCRD': 'RBL Bank',
  };
  final Map<String, String> _banks = {};

  Map<String, dynamic>? balanceSnapshot(BankSms sms) {
    final bank = _banks[normalizeRuleSender(sms.sender)];
    if (bank == null) return null;
    final account = _account.firstMatch(sms.body)?.group(1);
    if (account == null) return null;
    final metadata = smsMetadata(sms.body, sender: sms.sender);
    if ((metadata['balanceMinor'] == null &&
            metadata['availableCreditLimitMinor'] == null &&
            metadata['creditLimitMinor'] == null) ||
        _unsafe.hasMatch(sms.body)) {
      return null;
    }
    return {
      ...metadata,
      'bankName': bank,
      'countryCode': 'IN',
      'currencyCode': 'INR',
      'accountLast4': account.substring(account.length - 4),
    };
  }

  @override
  PortableParseResult parse(BankSms sms) {
    final result = super.parse(sms);
    final existing = result.candidate;
    // Most inbox messages come from unregistered senders; return them before
    // any host metadata is computed.
    if (existing == null &&
        ((result.reason != 'noMatchingFormat' &&
                !(result.reason == 'unregisteredSender' &&
                    _banks.containsKey(normalizeRuleSender(sms.sender)))) ||
            _unsafe.hasMatch(sms.body))) {
      return result;
    }
    final metadata = smsMetadata(sms.body, sender: sms.sender);
    final account = _account.firstMatch(sms.body)?.group(1);
    if (existing != null) {
      final direction = metadata['direction'] == 'credit'
          ? SmsDirection.credit
          : existing.direction;
      final candidate = SmsTransactionCandidate(
        amountMinor: existing.amountMinor,
        currencyCode: existing.currencyCode,
        direction: direction,
        channel: existing.channel,
        occurredAt: existing.occurredAt,
        bankName: existing.bankName,
        countryCode: existing.countryCode,
        accountLast4:
            existing.accountLast4 ?? account?.substring(account.length - 4),
        reference: existing.reference,
        counterparty: existing.counterparty,
        // The engine already categorized it; only a new direction changes that.
        category: direction == existing.direction ? existing.category : null,
      );
      return PortableParseResult(
        classification: result.classification,
        decision: result.decision,
        reason: result.reason,
        packVersion: result.packVersion,
        ruleId: result.ruleId,
        candidate: direction == existing.direction
            ? candidate
            : enrichCandidate(sms, candidate),
      );
    }
    final bank = _banks[normalizeRuleSender(sms.sender)];
    final amounts = _money.allMatches(sms.body).toList();
    final card = metadata['isCreditCard'] == true;
    final credit =
        metadata['direction'] == 'credit' || _credited.hasMatch(sms.body);
    final completed = _completed.hasMatch(sms.body);
    if (bank == null ||
        amounts.isEmpty ||
        (!credit && !completed) ||
        (!card && !_moved.hasMatch(sms.body))) {
      return result;
    }
    // Balance/limit figures must never become the transaction amount.
    final amountMatch = amounts.first;
    if (_figureBefore.hasMatch(sms.body.substring(0, amountMatch.start))) {
      return result;
    }
    final amount = parseAccountAmount(
      amountMatch.group(1)!.replaceAll(',', ''),
      2,
    );
    if (amount == null || amount <= 0) return result;
    final merchant = _merchant.firstMatch(sms.body)?.group(1)?.trim();
    return PortableParseResult(
      classification: RuleClassification.completed,
      decision: SmsDecision.review,
      reason: 'completedNeedsReview',
      packVersion: packVersion,
      ruleId: card ? 'in.host.credit_card' : 'in.host.bank_transaction',
      candidate: enrichCandidate(
        sms,
        SmsTransactionCandidate(
          amountMinor: amount,
          currencyCode: 'INR',
          direction: credit ? SmsDirection.credit : SmsDirection.debit,
          channel: card
              ? SmsPaymentChannel.card
              : _upi.hasMatch(sms.body)
              ? SmsPaymentChannel.upi
              : SmsPaymentChannel.bankTransfer,
          occurredAt: sms.receivedAt,
          bankName: bank,
          countryCode: 'IN',
          accountLast4: account?.substring(account.length - 4),
          counterparty: merchant,
        ),
      ),
    );
  }
}
