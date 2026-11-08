import 'package:drift/drift.dart';

import '../../domain/currency_scope.dart';

/// Every ledger aggregate reads transactions joined to the account that owns
/// them, because the account decides the row's currency.
const ledgerSource =
    'FROM transactions t JOIN accounts a ON a.id = t.account_id';

/// The WHERE clause those aggregates share: a half-open date range, the
/// currency scope when it names one, and the debt exclusion — lending,
/// borrowing and paying debts back move balances but are neither income nor
/// spending. Pair it with [ledgerArgs], which supplies the `?`s in order.
String ledgerFilter(CurrencyScope scope) =>
    't.date >= ? AND t.date < ? '
    '${scope is SingleCurrency ? 'AND a.currency = ? AND a.digits = ? ' : ''}'
    'AND NOT EXISTS (SELECT 1 FROM categories dc '
    "WHERE dc.id = t.category_id AND dc.type = 'debt_loan')";

/// The variables [ledgerFilter] expects, for the range [from] (inclusive) to
/// [to] (exclusive).
List<Variable> ledgerArgs(CurrencyScope scope, DateTime from, DateTime to) => [
  Variable(from.millisecondsSinceEpoch),
  Variable(to.millisecondsSinceEpoch),
  if (scope is SingleCurrency) ...[
    Variable(scope.code),
    Variable(scope.digits),
  ],
];
