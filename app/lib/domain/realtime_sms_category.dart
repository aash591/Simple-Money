import '../data/repositories/sms_import_repository.dart';
import 'category.dart';
import 'sms_matching.dart';

/// What an unrecognised live SMS is filed under, by direction.
String realtimeFallbackCategoryName(bool credit) =>
    credit ? 'Other Income' : 'Other Expense';

/// Live SMS defaults follow the direction. A bank's transfer wording alone
/// does not establish that both accounts belong to the user. The parser's own
/// catch-all suggestion is named "Personal", which misleads, so it is treated
/// as "no match" and filed under Other Expense / Other Income instead.
Category? realtimeSmsCategory(PendingSmsImport sms, List<Category> categories) {
  final suggestion = sms.suggestedCategory?.name.toLowerCase();
  final matched = suggestion == 'personal'
      ? null
      : smsCategory(sms, categories);
  if (matched != null) return matched;
  final type = sms.credit ? CategoryType.income : CategoryType.expense;
  final fallback = realtimeFallbackCategoryName(sms.credit).toLowerCase();
  return categories
      .where((c) => c.type == type && c.name.trim().toLowerCase() == fallback)
      .firstOrNull;
}

/// Up to [limit] categories to offer as one-tap pills on a live SMS
/// notification, best first: the one it was filed under when that came from a
/// rule or a remembered merchant, the rule pack's own suggestion (and its
/// alternatives), then what the user files most often. The catch-all
/// fallback is never offered; leaving the notification alone keeps it.
List<Category> smsCategorySuggestions(
  PendingSmsImport sms,
  List<Category> categories, {
  Category? current,
  List<int> frequent = const [],
  int limit = 2,
}) {
  final type = sms.credit ? CategoryType.income : CategoryType.expense;
  final fallback = realtimeFallbackCategoryName(sms.credit).toLowerCase();
  final usable = categories
      .where(
        (c) =>
            c.id > 0 &&
            c.type == type &&
            !{fallback, 'personal'}.contains(c.name.trim().toLowerCase()),
      )
      .toList();
  final picks = <Category>[];
  void add(Category? category) {
    if (category != null &&
        usable.any((c) => c.id == category.id) &&
        !picks.any((c) => c.id == category.id)) {
      picks.add(category);
    }
  }

  add(current);
  final suggestion = sms.suggestedCategory;
  if (suggestion != null && suggestion.type == type.storageValue) {
    for (final name in [suggestion.name, ...suggestion.aliases]) {
      add(
        usable
            .where((c) => c.name.trim().toLowerCase() == name.toLowerCase())
            .firstOrNull,
      );
    }
  }
  for (final id in frequent) {
    add(usable.where((c) => c.id == id).firstOrNull);
  }
  // A new user has no history yet: offer the first plain categories.
  for (final category in usable.where((c) => c.parentId == null)) {
    add(category);
  }
  return picks.take(limit).toList();
}
