/// Recognizes merchant names, including payment handles such as swiggyupi.
/// Conflicting merchant names are deliberately left for manual review.
String? foodDeliveryMerchant(String text) {
  final names = <String>[];
  for (final name in ['Swiggy', 'Zomato']) {
    if (RegExp(
      '\\b${name.toLowerCase()}',
      caseSensitive: false,
    ).hasMatch(text)) {
      names.add(name);
    }
  }
  return names.length == 1 ? names.single : null;
}
