import 'app_icons.dart';
import 'brand_icons.dart';

/// Resolve only bundled bank logos, with a generic bank icon as fallback.
String bankInstitutionIcon(String bankName, {bool creditCard = false}) {
  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final name = normalized(bankName);
  if (name == 'onecard') return brandIconKey('onecard');
  if (creditCard && (name == 'bobcard' || name == 'bankofbarodacard')) {
    return brandIconKey('bobcard');
  }
  if (creditCard &&
      (name == 'statebankofindia' ||
          name == 'statebankindia' ||
          name == 'sbicard' ||
          name == 'sbi')) {
    return brandIconKey('sbicard');
  }
  const aliases = {
    'kotakbank': 'kotakmahindrabank',
    'sbi': 'statebankofindia',
    'statebankindia': 'statebankofindia',
  };
  final wanted = aliases[name] ?? name;
  for (final institution in brandIcons) {
    if (normalized(institution.title) == wanted ||
        normalized(institution.key) == wanted) {
      return brandIconKey(institution.key);
    }
  }
  return 'bank';
}
