import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/loan.dart';
import '../../components/app_icon.dart';
import '../../components/transactions/transaction_list_row.dart';
import '../../components/transactions/transaction_row.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/transaction_widgets.dart';
import '../loans/loan_widgets.dart';

/// A suggested loan as it would stand once approved: what it is, how far
/// along, which account pays, and each payment beside the transaction it
/// was matched to.
class LoanSuggestionPreview extends StatefulWidget {
  const LoanSuggestionPreview({
    super.key,
    required this.payload,
    required this.pending,
    required this.accountOf,
    required this.rowFor,
    this.onUpdatesBalance,
  });
  final Map<String, Object?> payload;

  /// Still to be decided: what approving would do to balances is shown.
  final bool pending;

  /// An account by id; null when accounts couldn't be loaded.
  final Account? Function(int? id) accountOf;

  /// Sets whether payments the ledger lacks come out of the paying account.
  final ValueChanged<bool>? onUpdatesBalance;

  /// The row for a saved transaction, or null when it can't be shown.
  final Widget? Function(int transactionId) rowFor;

  @override
  State<LoanSuggestionPreview> createState() => _LoanSuggestionPreviewState();
}

class _LoanSuggestionPreviewState extends State<LoanSuggestionPreview> {
  /// Rows shown before "Show all", so a long loan doesn't fill the screen.
  static const _collapsed = 3;

  bool _expanded = false;

  List<Map> get _payments => (widget.payload['payments'] as List).cast<Map>();

  /// The loan as approving it would leave it.
  late final Loan _loan = Loan(
    id: 0,
    accountId: widget.payload['accountId'] as int?,
    terms: LoanTerms.fromJson(
      Map<String, dynamic>.from(widget.payload['terms'] as Map),
    ),
    events: [
      for (final (i, p) in _payments.indexed)
        LoanEvent(
          id: i + 1,
          kind: p['part'] == true
              ? LoanEventKind.partPayment
              : LoanEventKind.emi,
          date: DateTime.parse(p['date'] as String),
          principal: (p['amount'] as int) - (p['interest'] as int),
          interest: p['interest'] as int,
          fee: p['fee'] as int,
        ),
    ],
  );

  String _money(int minor) => loanMoney(_loan.terms, minor);

  Account? get _paidFrom => widget.accountOf(_loan.accountId);

  /// What approving moves each account by. Whatever is matched to a saved
  /// transaction moves nothing: the ledger already counted it.
  Map<int, int> get _moves {
    final moves = <int, int>{};
    void move(int account, int minor) =>
        moves[account] = (moves[account] ?? 0) + minor;
    final terms = _loan.terms;
    final payload = widget.payload;
    final paying = _loan.accountId;
    if (paying != null) {
      for (final p in _payments) {
        if (p['transactionId'] != null) continue;
        final total = (p['amount'] as int) + (p['fee'] as int);
        // A bank message waiting for review is saved into its own account.
        if (p['smsAccount'] case final int account) {
          move(account, -total);
        } else if (p['offLedger'] != true) {
          move(paying, -total);
        }
      }
      if (terms.chargesMinor > 0 &&
          !terms.chargesDeducted &&
          payload['adoptCharges'] == null) {
        move(paying, -terms.chargesMinor);
      }
    }
    if (payload['receivedIn'] case final int into
        when payload['adoptDisbursal'] == null) {
      move(
        into,
        terms.principal - (terms.chargesDeducted ? terms.chargesMinor : 0),
      );
    }
    return moves;
  }

  List<Widget> _rows(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = SheetColors.of(context);
    final terms = _loan.terms;
    final payments = _payments;
    final fixed = terms.mode == LoanRepaymentMode.emi;
    Widget payment(int index) {
      final p = payments[index];
      final total = (p['amount'] as int) + (p['fee'] as int);
      final date = DateTime.parse(p['date'] as String);
      if (p['transactionId'] case final int id) {
        return widget.rowFor(id) ??
            TransactionRow(
              icon: AppIcon(_loan.icon),
              title: 'Saved payment',
              subtitle: 'In your accounts',
              amount: '- ${_money(total)}',
              amountColor: colors.expense,
              stamp: transactionStamp(date, showDate: true),
            );
      }
      if (p['smsAccount'] case final int account) {
        return TransactionRow(
          icon: Icon(
            Icons.sms_outlined,
            color: scheme.onSurfaceVariant,
            size: 28,
          ),
          title: 'Bank message',
          subtitle:
              'Saves to ${widget.accountOf(account)?.name ?? 'your account'}',
          amount: '- ${_money(total)}',
          amountColor: colors.expense,
          stamp: transactionStamp(date, showDate: true),
        );
      }
      final adds = p['offLedger'] != true;
      final emiNumber = payments
          .take(index + 1)
          .where((x) => x['part'] != true)
          .length;
      return TransactionRow(
        icon: Icon(
          adds ? Icons.add_circle_outline_rounded : Icons.history_rounded,
          color: scheme.onSurfaceVariant,
          size: 28,
        ),
        title: p['part'] == true
            ? 'Part-payment'
            : '${fixed ? 'EMI' : 'Payment'} $emiNumber',
        subtitle: adds
            ? 'Adds to ${_paidFrom?.name ?? 'your account'}'
            : 'Counted as paid',
        amount: '- ${_money(total)}',
        amountColor: adds ? colors.expense : scheme.onSurfaceVariant,
        stamp: transactionStamp(date, showDate: true),
      );
    }

    // Newest first, as every list of transactions is. What the start took
    // over from the ledger comes last.
    return [
      for (var i = payments.length - 1; i >= 0; i--) payment(i),
      for (final key in ['adoptCharges', 'adoptDisbursal'])
        if (widget.payload[key] case final int id) ?widget.rowFor(id),
    ];
  }

  /// Each account's balance now and after, or that none will move.
  List<Widget> _balances() {
    final moves = _moves;
    if (moves.isEmpty) {
      return [
        LoanValue('${_paidFrom?.name ?? 'Account'} balance', 'Stays the same'),
      ];
    }
    return [
      for (final MapEntry(key: id, :value) in moves.entries)
        if (value != 0)
          () {
            final account = widget.accountOf(id);
            String shown(int minor) => account == null
                ? _money(minor)
                : formatAccountMoney(
                    minor,
                    digits: account.digits,
                    currency: account.currency,
                  );
            return LoanValue(
              '${account?.name ?? 'Account'} balance',
              account == null
                  ? '${value < 0 ? 'Down' : 'Up'} ${shown(value.abs())}'
                  : '${shown(account.balanceMinor)} → '
                        '${shown(account.balanceMinor + value)}',
            );
          }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loan = _loan;
    final terms = loan.terms;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final rows = _rows(context);
    final payments = _payments;
    final unmatched = payments.where(
      (p) => p['transactionId'] == null && p['smsId'] == null,
    );
    final found = payments.length - unmatched.length;
    final missing = unmatched.length;
    final updates = unmatched.any((p) => p['offLedger'] != true);
    final hidden = rows.length - _collapsed > 1 && !_expanded;
    const inset = EdgeInsets.symmetric(horizontal: 16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: inset,
          child: Row(
            children: [
              BadgedAppIcon(
                loan.icon,
                badgeKey: loan.icon == terms.icon ? null : terms.icon,
                size: 48,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loan.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text('New loan · ${terms.mode.label}', style: muted),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: inset,
          child: _Progress(loan: loan),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: inset,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoanValue('Loan amount', _money(terms.principal)),
              LoanValue(
                'Interest',
                !terms.rateKnown
                    ? 'Not stated'
                    : terms.rate == 0
                    ? 'No interest'
                    : '${terms.rate}% a year',
              ),
              if (loan.emi > 0)
                LoanValue(
                  'Monthly EMI',
                  [
                    _money(loan.emi),
                    if (terms.months > 0) '${terms.months} months',
                  ].join(' · '),
                ),
              if (loan.charges > 0) LoanValue('Charges', _money(loan.charges)),
              if (loan.emi > 0 && !loan.closed)
                LoanValue('Next EMI', loanDate(loan.nextDue)),
              _PaidFromRow(
                account: _paidFrom,
                name: widget.payload['paidFrom'] as String?,
              ),
              if (widget.pending) ..._balances(),
            ],
          ),
        ),
        if (widget.pending && missing > 0)
          TransactionSwitchRow(
            icon: Icons.account_balance_wallet_outlined,
            label: 'Update account balance',
            value: updates
                ? 'Takes ${missing == 1 ? 'the missing payment' : '$missing missing payments'} '
                      'out of ${_paidFrom?.name ?? 'your account'}'
                : 'Only tracked here',
            on: updates,
            onChanged: widget.onUpdatesBalance,
          ),
        if (rows.isNotEmpty) ...[
          const Divider(height: 24),
          Padding(
            padding: inset,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Payments',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (payments.isNotEmpty)
                  Text('$found of ${payments.length} found', style: muted),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: hidden ? rows.take(_collapsed).toList() : rows,
            ),
          ),
          if (rows.length - _collapsed > 1)
            Center(
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? 'Show less' : 'Show all ${rows.length}',
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// What is left to repay, with a bar once anything has been.
class _Progress extends StatelessWidget {
  const _Progress({required this.loan});
  final Loan loan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    final terms = loan.terms;
    final left = loan.outstanding;
    final repaid = terms.principal - left;
    final fraction = repaid / terms.principal;
    final label = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget amount(String name, int value, CrossAxisAlignment side) => Column(
      crossAxisAlignment: side,
      children: [
        Text(name, style: label),
        const SizedBox(height: 2),
        Text(
          loanMoney(terms, value),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          runSpacing: 8,
          spacing: 16,
          children: [
            amount('Left to repay', left, CrossAxisAlignment.start),
            if (repaid > 0) amount('Repaid', repaid, CrossAxisAlignment.end),
          ],
        ),
        if (repaid > 0) ...[
          const SizedBox(height: 10),
          Semantics(
            label: 'Principal repayment progress',
            // A rounded 100% must not imply a small balance is cleared.
            value: '${(fraction * 100).floor()}% repaid',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                color: colors.income,
                backgroundColor: colors.primary.withValues(alpha: 0.18),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The paying account, with the icon the account lists show.
class _PaidFromRow extends StatelessWidget {
  const _PaidFromRow({required this.account, required this.name});
  final Account? account;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = this.account;
    final shown = account?.name ?? name;
    if (shown == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text('Paid from', style: theme.textTheme.bodySmall),
          const SizedBox(width: 16),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (account != null) ...[
                  AppIcon(account.icon, size: 28),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    shown,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
