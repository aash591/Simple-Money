import 'package:flutter/material.dart';

import '../../domain/account.dart';
import '../../domain/category.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../components/app_icon.dart';
import '../components/choice_list_sheet.dart';
import '../components/feature_page.dart';
import '../more/accounts/edit_account_screen.dart';
import '../more/categories/edit_category_screen.dart';
import 'transaction_widgets.dart';

/// The account rows every "pick an account" step shows: each account with the
/// balance that decides which one to use, minus [excludeId] — a transfer's
/// other leg, which cannot also be this one.
List<ChoiceItem<int>> accountChoiceItems(
  AccountStore accountStore, {
  int? excludeId,
  String? currency,
  bool brokers = false,
}) => [
  for (final account in accountStore.accounts)
    // A broker holds money to invest, not to spend: only transfers (a
    // deposit or a withdrawal) may use one.
    if ((brokers || !account.isBroker) &&
        account.id != excludeId &&
        (currency == null ||
            (account.currency == currency && account.digits == 2)))
      ChoiceItem(
        value: account.id,
        icon: AppIcon(account.icon, size: 28),
        label: account.name,
        // The last digits first, when the account has them: two accounts of
        // one bank are told apart by them.
        subtitle: [
          if (account.lastDigits?.isNotEmpty == true)
            '•• ${account.lastDigits}',
          formatTransactionMoney(account.balanceMinor, account),
        ].join(' · '),
        chevron: true,
      ),
];

/// Pushes the existing "add account" screen and, since it pops with no
/// result, finds what it added by diffing the store's ids before and after
/// — so the choice-list sheet that triggered this can select it right away.
Future<Account?> addAccountAndSelect(
  BuildContext context,
  AccountStore accountStore, {
  String? initialName,
  String? initialIcon,
  String? initialCurrency,
  String? initialLastDigits,
  String? initialInstitution,
  AccountType initialType = AccountType.bank,
}) async {
  final before = accountStore.accounts.map((a) => a.id).toSet();
  await Navigator.of(context).push(
    FeatureRoute<void>(
      EditAccountScreen(
        store: accountStore,
        initialName: initialName,
        initialIcon: initialIcon,
        initialCurrency: initialCurrency,
        initialLastDigits: initialLastDigits,
        initialInstitution: initialInstitution,
        initialType: initialType,
      ),
    ),
  );
  final added = accountStore.accounts.where((a) => !before.contains(a.id));
  return added.isEmpty ? null : added.last;
}

/// Same idea as [addAccountAndSelect], for a category of the given type.
Future<Category?> addCategoryAndSelect(
  BuildContext context,
  CategoryStore categoryStore,
  CategoryType type, {
  int? parentId,
}) async {
  final before = categoryStore.categories.map((c) => c.id).toSet();
  await Navigator.of(context).push(
    FeatureRoute<void>(
      EditCategoryScreen(
        store: categoryStore,
        type: type,
        initialParentId: parentId,
      ),
    ),
  );
  final added = categoryStore.categories.where((c) => !before.contains(c.id));
  return added.isEmpty ? null : added.last;
}
