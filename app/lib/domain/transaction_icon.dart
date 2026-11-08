import 'brand_icons.dart';
import 'category.dart';
import 'service_icon.dart';
import 'transaction.dart';

/// Resolve existing transactions at display time, without overwriting choices.
String? transactionIcon(MoneyTransaction transaction, Category? category) {
  if (transaction.icon != null) return transaction.icon;
  final title = (transaction.title ?? '').toLowerCase();
  final normalized = title.replaceAll(RegExp(r'[^a-z0-9]'), '');
  final categoryName = category?.name.toLowerCase().trim();

  // These aliases distinguish services whose SMS names differ from the catalog.
  final service = serviceIcon(title);
  if (service != null) return service;
  if (categoryName == 'public transport' ||
      categoryName == 'train' ||
      categoryName == 'bus' ||
      categoryName == 'cab') {
    if (normalized.contains('irctc')) return 'brand:irctc';
    if (normalized.startsWith('indianrail')) return 'train';
    if (normalized.contains('ksrtc') || normalized.startsWith('keralastat')) {
      return 'brand:ksrtc';
    }
  }
  for (final brand in brandIcons) {
    final name = brand.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    // Exact matching avoids mistaking a person's name or payment intermediary
    // for the merchant. The account's bank is deliberately not consulted.
    if (normalized.isNotEmpty &&
        (normalized == name || normalized == brand.key)) {
      return 'brand:${brand.key}';
    }
  }
  if (categoryName == 'fuel' &&
      (category?.icon == null || category?.icon == 'car_battery')) {
    return 'fuel';
  }
  if (category == null || categoryName == 'transfers') return 'bank_transfer';
  return category.icon;
}
