/// A validated UPI QR payload. Old phone drafts remain readable for review only.
class UpiRecipient {
  const UpiRecipient._({this.uri, this.phone, this.rawQr, required this.name});
  final Uri? uri;
  final String? rawQr;

  /// Compatibility with drafts saved before phone entry was removed.
  final String? phone;
  final String name;
  bool get isLegacyPhone => phone != null;
  String get address => phone ?? uri!.queryParameters['pa']!;
  String get amount => uri?.queryParameters['am'] ?? '';
  bool get amountLocked => uri?.queryParameters.containsKey('sign') ?? false;

  /// True for a [name] worth offering as a transaction title by itself —
  /// an actual person or shop ("Ashique M", "Dhanya Store"), not the bare
  /// address and not a payment app's generic stand-in for a name it never
  /// learned ("PhonePe Merchant", "BharatPe Merchant", "Paytm").
  bool get hasMeaningfulName => name != address && !_isGenericLabel(name);

  /// Common UPI apps' own name, alone or paired with "Merchant" — filled in
  /// by the app itself, not the merchant, so it names nothing worth a title.
  static const _genericBrands = {
    'phonepe',
    'bharatpe',
    'bharat pay',
    'paytm',
    'google pay',
    'gpay',
    'amazon pay',
    'mobikwik',
    'freecharge',
    'razorpay',
    'cred',
    'whatsapp pay',
    'upi',
  };

  static bool _isGenericLabel(String name) {
    final normalized = name.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    if (normalized.isEmpty) return true;
    if (RegExp(r'\bmerchant\b').hasMatch(normalized)) return true;
    return _genericBrands.contains(normalized);
  }

  factory UpiRecipient.parse(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'upi' ||
        uri.host != 'pay' ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      throw const FormatException('Scan a UPI payment QR code.');
    }
    if (uri.queryParametersAll.values.any((values) => values.length != 1)) {
      throw const FormatException(
        'This QR contains conflicting payment details.',
      );
    }
    final p = uri.queryParameters;
    if (!RegExp(r'^[a-zA-Z0-9.\-_]+@[a-zA-Z0-9.\-_]+$')
        .hasMatch(p['pa'] ?? '')) {
      throw const FormatException('This QR has no valid UPI ID.');
    }
    if (p.containsKey('cu') && p['cu'] != 'INR') {
      throw const FormatException('Only INR payments are supported.');
    }
    if (p.containsKey('am') && upiAmountMinor(p['am']!) == null) {
      throw const FormatException('This QR contains an invalid amount.');
    }
    if (p.containsKey('sign') && !p.containsKey('am')) {
      throw const FormatException(
        'Scan this signed QR directly in your UPI app; it has no amount.',
      );
    }
    return UpiRecipient._(
      uri: uri,
      rawQr: input.trim(),
      name: (p['pn']?.trim().isNotEmpty ?? false) ? p['pn']!.trim() : p['pa']!,
    );
  }

  factory UpiRecipient._fromLegacyPhone(String input, {String? name}) {
    var number = input.replaceAll(RegExp(r'[\s()\-]'), '');
    if (number.startsWith('+91')) number = number.substring(3);
    if (number.length == 12 && number.startsWith('91')) {
      number = number.substring(2);
    }
    if (number.length == 11 && number.startsWith('0')) {
      number = number.substring(1);
    }
    if (!RegExp(r'^[6-9][0-9]{9}$').hasMatch(number)) {
      throw const FormatException(
        'Enter a valid 10-digit Indian mobile number.',
      );
    }
    return UpiRecipient._(
      phone: number,
      name: name?.trim().isNotEmpty == true ? name!.trim() : number,
    );
  }

  String paymentUri(String amountText) {
    if (isLegacyPhone) {
      throw StateError('Scan a UPI QR code to start a new payment.');
    }
    if (upiAmountMinor(amountText) == null) {
      throw const FormatException('Enter a valid amount.');
    }
    // Signed QR data must be handed off unchanged.
    if (amountLocked) {
      if (upiAmountMinor(amountText) != upiAmountMinor(amount)) {
        throw const FormatException('The amount in this QR cannot be changed.');
      }
      return rawQr!;
    }
    if (upiAmountMinor(amount) == upiAmountMinor(amountText)) return rawQr!;

    // Edit only the amount. Rebuilding queryParameters rewrites the encoding
    // of every QR field, including provider references. Do not invent merchant
    // codes, transaction references, initiation modes or organisation IDs.
    final question = rawQr!.indexOf('?');
    final parts = rawQr!.substring(question + 1).split('&');
    var replaced = false;
    for (var i = 0; i < parts.length; i++) {
      final key = parts[i].split('=').first;
      if (Uri.decodeQueryComponent(key) == 'am') {
        parts[i] = '$key=${Uri.encodeQueryComponent(amountText)}';
        replaced = true;
      }
    }
    if (!replaced) parts.add('am=${Uri.encodeQueryComponent(amountText)}');
    if (!uri!.queryParameters.containsKey('cu')) parts.add('cu=INR');
    return '${rawQr!.substring(0, question + 1)}${parts.join('&')}';
  }
}

int? upiAmountMinor(String text) {
  if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(text)) return null;
  final parts = text.split('.');
  final value =
      int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
  return value > 0 ? value : null;
}

class PendingUpiPayment {
  const PendingUpiPayment({
    required this.id,
    required this.recipient,
    required this.amountText,
    required this.categoryId,
    required this.accountId,
    required this.date,
    this.place,
    this.title,
    this.note,
    this.isTransfer = false,
    this.toAccountId,
  });
  final String id;
  final UpiRecipient recipient;
  final String amountText;
  final int? categoryId, accountId;
  final bool isTransfer;
  final int? toAccountId;
  final DateTime date;

  /// Approximate locality captured around launch, never looked up on review.
  final String? place;

  /// Typed by hand, or carried over from an earlier payment to the same
  /// address — the merchant name itself goes in the transaction's note, not
  /// here. Null while nothing has been typed.
  final String? title;
  final String? note;

  /// Marks [title] as "not passed", distinct from an explicit `null` that
  /// clears it — [place]'s `place ?? this.place` pattern can't tell those
  /// apart, and a cleared title must actually stay cleared.
  static const _unset = Object();

  PendingUpiPayment copyWith({
    bool? isTransfer,
    Object? toAccountId = _unset,
    String? amountText,
    int? categoryId,
    int? accountId,
    String? place,
    Object? title = _unset,
    Object? note = _unset,
  }) => PendingUpiPayment(
    id: id,
    isTransfer: isTransfer ?? this.isTransfer,
    toAccountId: identical(toAccountId, _unset)
        ? this.toAccountId
        : toAccountId as int?,
    recipient: recipient,
    amountText: amountText ?? this.amountText,
    categoryId: categoryId ?? this.categoryId,
    accountId: accountId ?? this.accountId,
    date: date,
    place: place ?? this.place,
    title: identical(title, _unset) ? this.title : title as String?,
    note: identical(note, _unset) ? this.note : note as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'isTransfer': isTransfer,
    'toAccountId': toAccountId,
    'uri': recipient.rawQr,
    'phone': recipient.phone,
    'name': recipient.name,
    'amount': amountText,
    'categoryId': categoryId,
    'accountId': accountId,
    'date': date.toIso8601String(),
    'place': place,
    'title': title,
    'note': note,
  };
  factory PendingUpiPayment.fromJson(Map<String, dynamic> json) =>
      PendingUpiPayment(
        id: json['id'] as String,
        isTransfer: json['isTransfer'] as bool? ?? false,
        toAccountId: json['toAccountId'] as int?,
        recipient: json['phone'] != null
            ? UpiRecipient._fromLegacyPhone(
                json['phone'] as String,
                name: json['name'] as String,
              )
            : UpiRecipient.parse(json['uri'] as String),
        amountText: json['amount'] as String,
        categoryId: json['categoryId'] as int?,
        accountId: json['accountId'] as int?,
        date: DateTime.parse(json['date'] as String),
        place: json['place'] as String?,
        title: json['title'] as String?,
        note: json['note'] as String?,
      );
}
