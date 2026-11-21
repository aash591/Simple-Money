import 'dart:convert';

/// A precious metal a person can hold. Weights are in grams and prices are
/// per gram of the purity held, so a metal holding is the same units × price
/// as any other.
enum MetalType {
  gold('Gold', 'gold', 'GC=F', [999, 916, 750, 585]),
  silver('Silver', 'silver', 'SI=F', [999, 925, 800]),
  platinum('Platinum', 'platinum', 'PL=F', [950, 900]),
  palladium('Palladium', 'palladium', 'PA=F', [999, 950]);

  const MetalType(this.label, this.id, this.futuresSymbol, this.purities);
  final String label, id;

  /// Yahoo's price for the metal, in US dollars per troy ounce.
  final String futuresSymbol;

  /// The purities offered, as parts per thousand of pure metal.
  final List<int> purities;

  static MetalType? parse(String? id) =>
      values.where((m) => m.id == id).firstOrNull;

  /// Carats for a fineness: the standard ones exactly, others in proportion.
  static double caratsOf(int fineness) => switch (fineness) {
    999 => 24,
    916 => 22,
    750 => 18,
    585 => 14,
    _ => fineness / 1000 * 24,
  };

  static String _plain(double v) {
    final r = (v * 10).round() / 10;
    return r == r.roundToDouble() ? '${r.round()}' : '$r';
  }

  /// How a purity reads: gold in carats (22K), the others as the number.
  String purityLabel(int fineness) =>
      this == gold ? '${_plain(caratsOf(fineness))}K' : '$fineness';

  /// What a person typed for the purity, as parts per thousand, or null when
  /// it isn't one. A K is carats, 1 to 24 ("22K"); a plain number is fineness,
  /// 1 to 999 ("916"). The same for every metal.
  int? parsePurity(String text) {
    final clean = text.trim().toLowerCase().replaceAll(' ', '');
    if (clean.endsWith('k')) {
      final carats = double.tryParse(clean.substring(0, clean.length - 1));
      if (carats == null || carats <= 0 || carats > 24) return null;
      return switch (carats) {
        24 => 999,
        22 => 916,
        18 => 750,
        14 => 585,
        _ => (carats / 24 * 1000).round(),
      };
    }
    final fineness = int.tryParse(clean);
    return fineness != null && fineness >= 1 && fineness <= 999
        ? fineness
        : null;
  }

  /// The same purity said the other way, shown under what was typed:
  /// "22K = 916" when typed in carats, "916 = 22K" when typed as fineness.
  String purityEquals(String typed, int fineness) {
    final carats = '${_plain(caratsOf(fineness))}K';
    return typed.trim().toLowerCase().endsWith('k')
        ? '$carats = $fineness'
        : '$fineness = $carats';
  }

  /// The purity most people hold: 22K gold, otherwise the first offered.
  int get defaultPurity => this == gold ? 916 : purities.first;

  /// The share of a gram that is pure metal: 999 counts as pure.
  static double fraction(int fineness) =>
      fineness == 999 ? 1.0 : fineness / 1000;
}

/// Grams in a troy ounce, the unit metals are quoted in.
const gramsPerTroyOunce = 31.1034768;

/// What a metal holding is, kept in the holding's details (JSON text).
class MetalDetails {
  const MetalDetails({required this.metal, required this.fineness});
  final MetalType metal;

  /// Parts per thousand of pure metal (916 for 22K gold).
  final int fineness;

  String get purityLabel => metal.purityLabel(fineness);

  /// "Gold · 22K".
  String get summary => '${metal.label} · $purityLabel';

  /// A symbol that is the same for the same metal and purity, so adding it
  /// again in an account adds to the holding instead of making a second.
  String get symbol => '${metal.id}-$fineness';

  Map<String, Object> toJson() => {'metal': metal.id, 'purity': fineness};

  /// The details in [meta], or null when it holds none.
  static MetalDetails? parse(String? meta) {
    if (meta == null) return null;
    try {
      final json = jsonDecode(meta) as Map;
      final metal = MetalType.parse(json['metal'] as String?);
      final purity = json['purity'];
      if (metal == null || purity is! int) return null;
      return MetalDetails(metal: metal, fineness: purity);
    } catch (_) {
      return null;
    }
  }
}
