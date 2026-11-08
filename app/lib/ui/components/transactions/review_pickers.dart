import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/category.dart';
import '../../../domain/loan.dart';
import '../../../state/category_store.dart';
import '../../transactions/quick_add_helpers.dart';
import '../../transactions/transaction_widgets.dart';
import '../adaptive_sheet.dart';
import '../app_icon.dart';
import '../choice_list_sheet.dart';

/// Opens a picker sheet the way Add transaction opens its sheet, so the
/// pickers share its size and entrance.
Future<T?> _showPickerSheet<T>(BuildContext context, WidgetBuilder builder) =>
    showAdaptiveSheet<T>(
      context,
      entrance: SheetEntrance.fadeRise,
      dismissible: false,
      topClearance: 62,
      avoidKeyboard: false,
      builder: builder,
    );

/// Rows at the top of Choose category that aren't categories: money that
/// moved between the user's own accounts, or went to a loan. Their values
/// can't clash with a category's id, a draft category's, or Add transaction's
/// other rows.
const transferChoice = -901, cardRepaymentChoice = -902, loanChoice = -903;

/// Which of those rows a category sheet offers.
class CategoryShortcuts {
  const CategoryShortcuts({
    this.transfer = false,
    this.cardRepayment = false,
    this.loans = const [],
  });
  final bool transfer, cardRepayment;

  /// Open loans a payment can go to.
  final List<Loan> loans;

  /// The rows, in the order they lead the sheet.
  List<ChoiceItem<int>> get items => [
    if (transfer)
      ChoiceItem(
        value: transferChoice,
        icon: AppIcon('bank_transfer', size: 28),
        label: 'Transfer',
        chevron: true,
      ),
    if (loans.isNotEmpty)
      ChoiceItem(
        value: loanChoice,
        icon: AppIcon('bank', size: 28),
        label: 'Loan repayment',
        chevron: true,
      ),
    if (cardRepayment)
      ChoiceItem(
        value: cardRepaymentChoice,
        icon: AppIcon('bank_card', size: 28),
        label: 'Credit card repayment',
        chevron: true,
      ),
  ];

  /// [categories]' top level as the sheet lists it. A card repayment is a
  /// transfer to the card, so its row stands in for the category of that
  /// name; with no card to pay, the category itself leads instead.
  List<Category> topLevel(Iterable<Category> categories) {
    final top = categories.where((c) => c.parentId == null);
    bool isCardRepayment(Category c) =>
        c.name.toLowerCase() == 'credit card repayment';
    return [
      if (!cardRepayment) ...top.where(isCardRepayment),
      ...top.where((c) => !isCardRepayment(c)),
    ];
  }
}

/// The credit cards a repayment in [currency] can go to.
List<Account> repayableCards(
  Iterable<Account> accounts,
  String currency,
  int digits,
) => [
  for (final a in accounts)
    if (a.type == AccountType.creditCard &&
        a.archivedAt == null &&
        a.currency == currency &&
        a.digits == digits)
      a,
];

/// A loan's row in a list of loans: what it is and what is left on it.
ChoiceItem<int> loanChoiceItem(Loan loan) => ChoiceItem(
  value: loan.id,
  icon: AppIcon(loan.icon, size: 28),
  label: loan.title,
  subtitle:
      '${formatAccountMoney(loan.outstanding, currency: loan.terms.currency, digits: loan.terms.digits)} left',
  chevron: true,
);

/// What a review sheet's category picker answered: a category, or one of
/// the [CategoryShortcuts] rows.
class CategoryPick {
  const CategoryPick.category(int this.categoryId)
    : transfer = false,
      cardRepayment = false,
      loanId = null;
  const CategoryPick.transfer()
    : categoryId = null,
      transfer = true,
      cardRepayment = false,
      loanId = null;
  const CategoryPick.cardRepayment()
    : categoryId = null,
      transfer = false,
      cardRepayment = true,
      loanId = null;
  const CategoryPick.loan(int this.loanId)
    : categoryId = null,
      transfer = false,
      cardRepayment = false;
  final int? categoryId, loanId;
  final bool transfer, cardRepayment;
}

/// A review sheet's category picker: Add transaction's Choose category step
/// and its subcategory step, without the amount summary, under [title].
/// Pops what was chosen.
Future<CategoryPick?> showReviewCategoryPicker(
  BuildContext context, {
  required String title,
  required Iterable<Category> categories,
  required CategoryStore store,
  required CategoryType type,
  required int? selected,
  CategoryShortcuts shortcuts = const CategoryShortcuts(),
}) => _showPickerSheet<CategoryPick>(
  context,
  (_) => _CategoryPicker(
    title: title,
    categories: categories.where((c) => c.type == type).toList(),
    store: store,
    type: type,
    shortcuts: shortcuts,
  ),
);

/// A review sheet's account picker: Add transaction's Pay from step.
/// [items] carry the caller's own rules for which accounts fit.
Future<int?> showReviewAccountPicker(
  BuildContext context, {
  required String title,
  required String heading,
  required List<ChoiceItem<int>> items,
  required int? selected,
  required Future<int?> Function(BuildContext context) onAdd,
}) => _showPickerSheet<int>(
  context,
  (context) => ChoicePickerPage<int>(
    header: SheetHeader.flow(title, onBack: () => Navigator.pop(context)),
    heading: heading,
    items: items,
    selected: selected,
    onSelected: (id) => Navigator.pop(context, id),
    searchHint: 'Search accounts',
    addLabel: 'Add account',
    onAdd: onAdd,
  ),
);

class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({
    required this.title,
    required this.categories,
    required this.store,
    required this.type,
    required this.shortcuts,
  });
  final String title;
  final List<Category> categories;
  final CategoryStore store;
  final CategoryType type;
  final CategoryShortcuts shortcuts;

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  /// The category whose subcategories are showing; null on the first page.
  int? parentId;

  /// Showing the loans after Loan repayment.
  bool loans = false;
  bool forward = true;
  late final categories = [...widget.categories];

  bool get income => widget.type == CategoryType.income;

  Category? byId(int? id) => categories.where((c) => c.id == id).firstOrNull;

  /// Re-reads the store after an add so the new category is listed.
  Future<int?> add(BuildContext context, {int? parentId}) async {
    final created = await addCategoryAndSelect(
      context,
      widget.store,
      widget.type,
      parentId: parentId,
    );
    if (created != null && mounted) {
      setState(() => categories.add(created));
    }
    return created?.id;
  }

  void back() {
    if (parentId == null && !loans) {
      Navigator.pop(context);
    } else {
      setState(() {
        forward = false;
        parentId = null;
        loans = false;
      });
    }
  }

  /// Like Add transaction: a top-level choice opens its subcategories,
  /// which offer "Use … only"; a subcategory is the answer.
  void choose(int id) {
    if (id == transferChoice) {
      Navigator.pop(context, const CategoryPick.transfer());
      return;
    }
    if (id == cardRepaymentChoice) {
      Navigator.pop(context, const CategoryPick.cardRepayment());
      return;
    }
    if (id == loanChoice) {
      setState(() {
        forward = true;
        loans = true;
      });
      return;
    }
    final category = byId(id);
    if (category == null) return;
    if (parentId != null || category.parentId != null) {
      Navigator.pop(context, CategoryPick.category(id));
      return;
    }
    setState(() {
      forward = true;
      parentId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final parent = byId(parentId);
    final header = SheetHeader.flow(widget.title, onBack: back);
    final shortcuts = widget.shortcuts;
    final page = loans
        ? ChoicePickerPage<int>(
            key: const ValueKey('loans'),
            header: header,
            heading: 'Which loan?',
            fillHeight: true,
            items: [for (final loan in shortcuts.loans) loanChoiceItem(loan)],
            selected: null,
            onSelected: (id) => Navigator.pop(context, CategoryPick.loan(id)),
            searchHint: 'Search loans',
          )
        : parent == null
        ? ChoicePickerPage<int>(
            key: const ValueKey('categories'),
            header: header,
            heading: income ? 'Choose source' : 'Choose category',
            fillHeight: true,
            items: [
              ...shortcuts.items,
              for (final category in shortcuts.topLevel(categories)) ...[
                ChoiceItem(
                  value: category.id,
                  icon: AppIcon(category.icon, size: 28),
                  label: category.name,
                  chevron: true,
                ),
                // Subcategories show only while searching (e.g. "fuel").
                for (final sub in categories.where(
                  (c) => c.parentId == category.id,
                ))
                  ChoiceItem(
                    value: sub.id,
                    icon: AppIcon(sub.icon, size: 28),
                    label: sub.name,
                    indent: true,
                    searchOnly: true,
                    chevron: true,
                  ),
              ],
            ],
            selected: null,
            onSelected: choose,
            searchHint: income ? 'Search sources' : 'Search categories',
            addLabel: income ? 'Add source' : 'Add category',
            onAdd: (context) => add(context),
          )
        : ChoicePickerPage<int>(
            key: ValueKey(parent.id),
            header: header,
            heading: 'Choose subcategory',
            fillHeight: true,
            items: [
              ChoiceItem(
                value: parent.id,
                icon: AppIcon(parent.icon, size: 28),
                label: 'Use ${parent.name} only',
                chevron: true,
              ),
              for (final category in categories.where(
                (c) => c.parentId == parent.id,
              ))
                ChoiceItem(
                  value: category.id,
                  icon: AppIcon(category.icon, size: 28),
                  label: category.name,
                  chevron: true,
                ),
            ],
            selected: null,
            onSelected: choose,
            searchHint: 'Search subcategories',
            addLabel: 'Add subcategory',
            onAdd: (context) => add(context, parentId: parent.id),
          );
    return PopScope(
      // System back steps back like the arrow; it only closes the sheet
      // from the first page.
      canPop: parentId == null && !loans,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: StepSlider(
        stepKey: loans ? -1 : parentId ?? 0,
        forward: forward,
        child: page,
      ),
    );
  }
}
