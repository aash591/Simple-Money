/// A validated UPI QR payload. Old phone drafts remain readable for review only.
class UpiRecipient {
  const UpiRecipient._({
    this.uri,
    this.phone,
    this.rawQr,
    this.emvAddress,
    this.emvAmount,
    required this.name,
  });
  final Uri? uri;
  final String? rawQr;

  /// Set for bank/merchant EMVCo QR codes (`000201…`), which are not
  /// `upi://` links. Their CRC covers the amount, so they pass through as is.
  final String? emvAddress, emvAmount;
  bool get isEmv => emvAddress != null;

  /// Compatibility with drafts saved before phone entry was removed.
  final String? phone;
  final String name;
  bool get isLegacyPhone => phone != null;
  String get address => phone ?? emvAddress ?? uri!.queryParameters['pa']!;
  String get amount => emvAmount ?? uri?.queryParameters['am'] ?? '';
  bool get amountLocked =>
      isEmv || (uri?.queryParameters.containsKey('sign') ?? false);

  /// Reads an EMVCo merchant QR; null when [input] is not one.
  static UpiRecipient? _parseEmv(String input) {
    final text = input.trim();
    if (!text.startsWith('000201')) return null;
    final fields = _tlv(text);
    if (fields == null) {
      throw const FormatException('Scan a UPI payment QR code.');
    }
    final crc = fields['63'];
    if (crc == null ||
        crc.toUpperCase() !=
            _crc16(text.substring(0, text.length - 4)).toRadixString(16)
                .toUpperCase()
                .padLeft(4, '0')) {
      throw const FormatException('This QR code looks damaged. Scan it again.');
    }
    final vpa = RegExp(r'^[a-zA-Z0-9.\-_]+@[a-zA-Z0-9.\-_]+$');
    String? address;
    for (var tag = 26; tag <= 51 && address == null; tag++) {
      final template = fields[tag.toString().padLeft(2, '0')];
      final sub = template == null ? null : _tlv(template);
      if (sub == null) continue;
      for (final value in sub.values) {
        if (vpa.hasMatch(value)) {
          address = value;
          break;
        }
      }
    }
    if (address == null) {
      throw const FormatException('This QR has no valid UPI ID.');
    }
    final cur = fields['53'];
    if (cur != null && cur != '356') {
      throw const FormatException('Only INR payments are supported.');
    }
    final amount = fields['54'];
    if (amount == null || upiAmountMinor(amount) == null) {
      throw const FormatException(
        'Scan this QR directly in your UPI app; it has no amount.',
      );
    }
    final name = fields['59']?.trim() ?? '';
    return UpiRecipient._(
      rawQr: text,
      emvAddress: address,
      emvAmount: amount,
      name: name.isEmpty ? address : name,
    );
  }

  static Map<String, String>? _tlv(String s) {
    final out = <String, String>{};
    var i = 0;
    while (i < s.length) {
      if (i + 4 > s.length) return null;
      final len = int.tryParse(s.substring(i + 2, i + 4));
      if (len == null || i + 4 + len > s.length) return null;
      out.putIfAbsent(s.substring(i, i + 2), () => s.substring(i + 4, i + 4 + len));
      i += 4 + len;
    }
    return out;
  }

  /// CRC-16/CCITT-FALSE over [s], as EMVCo specifies.
  static int _crc16(String s) {
    var crc = 0xFFFF;
    for (final unit in s.codeUnits) {
      crc ^= (unit & 0xFF) << 8;
      for (var b = 0; b < 8; b++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
        crc &= 0xFFFF;
      }
    }
    return crc;
  }

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
    final emv = _parseEmv(input);
    if (emv != null) return emv;
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
    // Signed and EMV QR data must be handed off unchanged.
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
