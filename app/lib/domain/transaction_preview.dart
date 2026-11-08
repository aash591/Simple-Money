import 'transaction.dart';

/// Data requests for the existing transaction browser, independent of its UI.
class TransactionPreviewQuery {
  const TransactionPreviewQuery({
    required this.start,
    required this.end,
    required this.ready,
    required this.byCategory,
    this.search = '',
    this.type,
    this.accountId,
    this.categoryId,
    this.expandedGroups = const {},
    this.limit = 50,
  });
  final DateTime start, end;
  final bool? ready;
  final bool byCategory;
  final String search;
  final String? type;
  final int? accountId, categoryId;
  final Set<int> expandedGroups;
  final int limit;
}

class TransactionPreviewGroup {
  const TransactionPreviewGroup({
    this.categoryId,
    this.date,
    required this.count,
    required this.transactions,
    required this.totals,
  });
  final int? categoryId;
  final DateTime? date;
  final int count;
  final List<MoneyTransaction> transactions;
  final Map<(String, int), (int, int)> totals;
}

class TransactionPreviewData {
  const TransactionPreviewData({
    required this.groups,
    required this.count,
    required this.currencies,
    required this.summary,
    required this.filteredSummary,
    required this.categoryTotals,
  });
  final List<TransactionPreviewGroup> groups;
  final int count;
  final Map<(String, int), int> currencies;
  final Map<(String, int), (int, int)> summary, filteredSummary, categoryTotals;
  List<MoneyTransaction> get transactions => [
    for (final group in groups) ...group.transactions,
  ];
}
