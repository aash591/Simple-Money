import 'brand_icons.dart';

/// Match service names while allowing spaces and punctuation in saved titles.
String? serviceIcon(String name) {
  final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (const {
    'primevideo',
    'amazonprimevideo',
    'amazonprime',
  }.contains(normalized)) {
    return 'brand:primevideo';
  }
  if (const {
    'hotstar',
    'jiohotstar',
    'disneyhotstar',
    'disneyplushotstar',
  }.contains(normalized)) {
    return 'brand:jiohotstar';
  }
  // Merchant titles can include a branch, payment suffix, or order number.
  final words = name.toLowerCase();
  const internetProviders = <String, String>{
    r'\bkerala\s*vision\b': 'keralavision',
    r'\bact\s*(?:fiber\s*net|fibre\s*net|broadband)\b|\batria\s+convergence\b':
        'actfibernet',
    r'\bexcitel\b': 'excitel',
    r'\bhathway\b': 'hathway',
    r'\btata\s*(?:play|sky)\s*(?:fiber|fibre|broadband)\b': 'tataplayfiber',
    r'\byou\s*broadband\b': 'youbroadband',
    r'\basianet\s*(?:broadband|fiber|fibre)\b': 'asianetbroadband',
    r'\bairtel\s*(?:xstream|fiber|fibre|broadband)\b': 'airtel',
    r'\bjio\s*(?:air\s*)?(?:fiber|fibre)\b': 'jio',
    r'\bbsnl\s*(?:bharat\s*)?(?:fiber|fibre|broadband|ftth)\b': 'bsnl',
  };
  for (final provider in internetProviders.entries) {
    if (RegExp(provider.key).hasMatch(words)) return 'brand:${provider.value}';
  }
  if (RegExp(r'\bmeesho\b').hasMatch(words)) return 'brand:meesho';
  if (RegExp(r'\bbajaj\s*(?:finance|finserv)\b').hasMatch(words)) {
    return 'brand:bajajfinance';
  }
  if (RegExp(r'\bdisney\s*(?:\+|plus)\b|\bdisney\s*\+').hasMatch(words)) {
    if (normalized.contains('hotstar')) return 'brand:jiohotstar';
    return 'brand:disneyplus';
  }
  if (RegExp(r'\bhair\s*cut(?:ting)?\b|\bbarber(?:s)?\b').hasMatch(words)) {
    return 'haircut';
  }
  if (RegExp(
    r'\bsalo[on]+\b|\bhair(?:\s*(?:care|studio|spa|dresser|dressing))?\b',
  ).hasMatch(words)) {
    return 'salon';
  }
  for (final brand in brandIcons) {
    if (brand.isBank || brand.isPayment) continue;
    if (normalized == brand.key ||
        normalized ==
            brand.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')) {
      return 'brand:${brand.key}';
    }
  }
  return null;
}
