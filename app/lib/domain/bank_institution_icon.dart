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
    'aaib': 'arabafricanbank',
    'bankcentralepopulaire': 'bcpgroup',
    'bcp': 'bcpgroup',
    'bdl': 'bdlalgeria',
    'bny': 'bnymellon',
    'bsi': 'banksyariahindonesia',
    'cpa': 'cpaalgeria',
    'firstrand': 'fnbsa',
    'firstnationalbank': 'fnbsa',
    'mcb': 'mcbmauritius',
    'standardbanksouthafrica': 'standardbanksa',
    'kotakbank': 'kotakmahindrabank',
    'sbi': 'statebankofindia',
    'statebankindia': 'statebankofindia',
    // Brokers people know by another name.
    'kotaksecurities': 'kotakneo',
    'hdfcsky': 'hdfcsecurities',
    'hdfcsec': 'hdfcsecurities',
    'icicisecurities': 'icicidirect',
    'angelbroking': 'angelone',
    'ibkr': 'interactivebrokers',
    'etradefrommorganstanley': 'etrade',
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

/// The bundled logo for a broker or bank typed in by hand, or null when there
/// is none. Matches the whole name ("Zerodha") and also a name that contains
/// a known one ("Zerodha Kite", "Fidelity Investments"); the longest known
/// name wins, and names under four letters never match inside a longer one,
/// so "Ally" doesn't light up on "Totally".
String? matchingInstitutionIcon(String typed) {
  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final name = normalized(typed);
  if (name.length < 3) return null;
  final exact = bankInstitutionIcon(typed);
  if (exact != 'bank') return exact;
  String? best;
  var bestLength = 0;
  for (final institution in brandIcons) {
    for (final candidate in {
      normalized(institution.title),
      normalized(institution.key),
    }) {
      if (candidate.length >= 4 &&
          candidate.length > bestLength &&
          name.contains(candidate)) {
        best = institution.key;
        bestLength = candidate.length;
      }
    }
  }
  return best == null ? null : brandIconKey(best);
}

/// The name to offer when [iconKey] is a brand logo (a bank, a broker or a
/// service), or null for any other icon. Kept within the 40 letters an
/// account name allows.
String? nameForIcon(String? iconKey) {
  final title = resolveBrandIcon(iconKey)?.title;
  if (title == null) return null;
  return title.length > 40 ? title.substring(0, 40).trimRight() : title;
}
