/// A platform-supplied message. The engine never reads the inbox.
class BankSms {
  const BankSms({
    required this.sender,
    required this.body,
    required this.receivedAt,
  });

  final String sender;
  final String body;
  final DateTime receivedAt;
}

enum SmsDirection { debit, credit }

/// Accounting meaning is separate from the direction on the notified account.
enum SmsAccountingTreatment { income, expense, transfer }

enum SmsPaymentChannel { atm, upi, card, bankTransfer, wallet, other }

/// The portable engine produces review or ignored results only.
enum SmsDecision { review, ignored }

/// Portable suggestion. Hosts resolve this stable ID to their local categories.
class SmsSuggestedCategory {
  const SmsSuggestedCategory({
    required this.id,
    required this.name,
    required this.type,
    required this.ruleId,
    this.isFallback = false,
    this.aliases = const [],
  });
  final String id, name, type, ruleId;
  final bool isFallback;
  final List<String> aliases;
  bool get isCreditCardRepayment => id == 'credit_card_repayment';
  bool get isAtmWithdrawal => id == 'atm_withdrawal';
  bool get isAtmDeposit => id == 'atm_deposit';
  bool get needsCategoryConfirmation => id == 'nach_debit';
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'ruleId': ruleId,
    'isFallback': isFallback,
    'aliases': aliases,
  };
  factory SmsSuggestedCategory.fromJson(Map<String, dynamic> json) =>
      SmsSuggestedCategory(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        ruleId: json['ruleId'] as String,
        isFallback: json['isFallback'] as bool? ?? false,
        aliases: (json['aliases'] as List? ?? []).cast<String>(),
      );
}

/// Extracted movement for the host application's review flow.
class SmsTransactionCandidate {
  const SmsTransactionCandidate({
    required this.amountMinor,
    required this.direction,
    required this.occurredAt,
    required this.currencyCode,
    this.channel = SmsPaymentChannel.other,
    this.bankName,
    this.countryCode,
    this.accountLast4,
    this.reference,
    this.counterparty,
    this.category,
  });

  final int amountMinor;
  final String currencyCode;
  final SmsDirection direction;
  final SmsPaymentChannel channel;
  final DateTime occurredAt;
  final String? bankName;
  final String? countryCode;
  final String? accountLast4;
  final String? reference;
  final String? counterparty;
  final SmsSuggestedCategory? category;

  bool get isCreditCardRepayment => category?.isCreditCardRepayment ?? false;
  bool get isAtmWithdrawal =>
      direction == SmsDirection.debit && (category?.isAtmWithdrawal ?? false);

  bool get isAtmDeposit =>
      direction == SmsDirection.credit && (category?.isAtmDeposit ?? false);

  SmsAccountingTreatment get accountingTreatment =>
      isCreditCardRepayment || isAtmWithdrawal || isAtmDeposit
      ? SmsAccountingTreatment.transfer
      : direction == SmsDirection.credit
      ? SmsAccountingTreatment.income
      : SmsAccountingTreatment.expense;

  Map<String, dynamic> toJson() => {
    'amountMinor': amountMinor,
    'currencyCode': currencyCode,
    'direction': direction.name,
    'channel': channel.name,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'bankName': bankName,
    'countryCode': countryCode,
    'accountLast4': accountLast4,
    'reference': reference,
    'counterparty': counterparty,
    if (category != null) 'category': category!.toJson(),
    if (accountingTreatment == SmsAccountingTreatment.transfer)
      'accountingTreatment': accountingTreatment.name,
  };

  factory SmsTransactionCandidate.fromJson(Map<String, dynamic> json) =>
      SmsTransactionCandidate(
        amountMinor: json['amountMinor'] as int,
        direction: SmsDirection.values.byName(json['direction'] as String),
        occurredAt: DateTime.parse(json['occurredAt'] as String),
        currencyCode: json['currencyCode'] as String,
        channel: SmsPaymentChannel.values.byName(
          json['channel'] as String? ?? 'other',
        ),
        bankName: json['bankName'] as String?,
        countryCode: json['countryCode'] as String?,
        accountLast4: json['accountLast4'] as String?,
        reference: json['reference'] as String?,
        counterparty: json['counterparty'] as String?,
        category: json['category'] == null
            ? null
            : SmsSuggestedCategory.fromJson(
                Map<String, dynamic>.from(json['category'] as Map),
              ),
      );
}
