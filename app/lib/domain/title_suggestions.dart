import 'transaction.dart';

/// Titles typed on past expenses and income, offered back while a new one is
/// typed so a regular ("Coffee", "Rent") is one tap rather than a retype.
///
/// Built once from the ledger; [suggest] is then cheap enough to call on
/// every keystroke. Titles are matched case-insensitively and each one is
/// offered once, in the casing it was last saved with.
class TitleSuggestions {
  TitleSuggestions(Iterable<MoneyTransaction> transactions) {
    for (final transaction in transactions) {
      if (transaction.type == TransactionType.transfer) continue;
      final title = transaction.title?.trim();
      if (title == null || title.isEmpty) continue;
      final key = title.toLowerCase();
      final entry = _entries[(transaction.type, key)] ??= _TitleUse(key);
      entry.count++;
      if (!transaction.date.isBefore(entry.lastUsed)) {
        entry
          ..title = title
          ..lastUsed = transaction.date;
      }
      final categoryId = transaction.categoryId;
      if (categoryId != null) {
        entry.categoryCounts[categoryId] =
            (entry.categoryCounts[categoryId] ?? 0) + 1;
      }
    }
  }

  final _entries = <(TransactionType, String), _TitleUse>{};

  /// Up to [limit] past titles of [type] that [query] could be the start of.
  ///
  /// A title that starts with the query comes before one where only a later
  /// word does ("Uber" before "Pay Uber"). Within that, titles used before
  /// with [categoryId] come first, then the most used, then the most recent.
  /// A blank query offers the favourites for [categoryId] alone, and a title
  /// already typed in full is never offered back.
  List<String> suggest(
    String query, {
    required TransactionType type,
    int? categoryId,
    int limit = 5,
  }) {
    final needle = query.trim().toLowerCase();
    final matches = <(int, _TitleUse)>[];
    for (final MapEntry(key: (entryType, key), value: entry)
        in _entries.entries) {
      if (entryType != type || key == needle) continue;
      final int rank;
      if (needle.isEmpty) {
        // Without anything typed, only what fits this category is relevant.
        if (categoryId == null ||
            !entry.categoryCounts.containsKey(categoryId)) {
          continue;
        }
        rank = 0;
      } else if (key.startsWith(needle)) {
        rank = 0;
      } else if (key.contains(' $needle')) {
        rank = 1;
      } else {
        continue;
      }
      matches.add((rank, entry));
    }
    int inCategory(_TitleUse entry) =>
        categoryId == null ? 0 : entry.categoryCounts[categoryId] ?? 0;
    matches.sort((a, b) {
      final (rankA, entryA) = a;
      final (rankB, entryB) = b;
      if (rankA != rankB) return rankA.compareTo(rankB);
      final byCategory = inCategory(entryB).compareTo(inCategory(entryA));
      if (byCategory != 0) return byCategory;
      final byCount = entryB.count.compareTo(entryA.count);
      if (byCount != 0) return byCount;
      return entryB.lastUsed.compareTo(entryA.lastUsed);
    });
    return [for (final (_, entry) in matches.take(limit)) entry.title];
  }
}

class _TitleUse {
  _TitleUse(this.title);
  String title;
  var count = 0;
  var lastUsed = DateTime.fromMillisecondsSinceEpoch(0);
  final categoryCounts = <int, int>{};
}
