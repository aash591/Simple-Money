import 'app_icons.dart';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../data/repositories/sms_import_repository.dart';
import 'account.dart';
import 'category.dart';
import 'party_category.dart';

/// Resolve the package's category output to a local category. No SMS patterns
/// or merchant classifications belong in the Flutter application.
Category? smsCategory(PendingSmsImport sms, List<Category> categories) {
  if (sms.requiresTransfer || sms.needsCategoryConfirmation) return null;
  final merchant = sms.credit ? null : foodDeliveryMerchant(sms.body);
  if (merchant != null) {
    final parents = categories
        .where(
          (c) =>
              c.parentId == null &&
              c.type == CategoryType.expense &&
              ['food', 'food & beverage'].contains(c.name.toLowerCase()),
        )
        .map((c) => c.id)
        .toSet();
    final child = categories
        .where(
          (c) =>
              c.type == CategoryType.expense &&
              parents.contains(c.parentId) &&
              c.name.toLowerCase() == merchant.toLowerCase(),
        )
        .firstOrNull;
    if (child != null) return child;
    if (parents.isNotEmpty) {
      return Category(
        id: merchant == 'Swiggy' ? -1001 : -1002,
        name: merchant,
        type: CategoryType.expense,
        parentId: parents.first,
        icon: brandIconKey(merchant.toLowerCase()),
      );
    }
  }
  final suggestion = sms.suggestedCategory;
  if (suggestion == null) return null;
  final type = sms.credit ? CategoryType.income : CategoryType.expense;
  if (suggestion.type != type.storageValue) return null;
  return resolveSuggestedCategory(suggestion, categories);
}

/// Suggest cash only when there is one unambiguous active destination.
Account? smsCashAccount(PendingSmsImport sms, List<Account> accounts) {
  final candidates = accounts
      .where(
        (a) =>
            a.type == AccountType.cash &&
            a.archivedAt == null &&
            a.currency == sms.currency &&
            a.digits == 2,
      )
      .toList();
  return candidates.length == 1 ? candidates.single : null;
}
