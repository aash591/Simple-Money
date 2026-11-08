import 'package:flutter/material.dart';

import '../../../domain/loan.dart';
import '../../components/common.dart';
import '../../theme/sheet_colors.dart';
import 'loan_widgets.dart';

/// Principal progress for active loans in one currency, including balances
/// entered at setup. Interest payments never count as principal repaid.
class LoanProgressCard extends StatelessWidget {
  const LoanProgressCard({super.key, required this.loans});
  final List<Loan> loans;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final terms = loans.first.terms;
    final borrowed = loans.fold(0, (sum, loan) => sum + loan.terms.principal);
    final remaining = loans.fold(0, (sum, loan) => sum + loan.outstanding);
    final repaid = (borrowed - remaining).clamp(0, borrowed);
    final fraction = borrowed == 0 ? 0.0 : repaid / borrowed;
    // A rounded 100% must not imply that a small remaining balance is cleared.
    final percent = (fraction * 100).floor();
    Widget amount(String label, int value, Color color) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 9,
            height: 9,
            margin: const EdgeInsets.only(top: 5, right: 9),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(
                  loanMoney(terms, value),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final chart = Semantics(
      label: 'Principal repayment progress',
      value: '$percent% repaid',
      child: ExcludeSemantics(
        child: SizedBox(
          width: 124,
          height: 124,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CircularProgressIndicator(
                  value: fraction,
                  strokeWidth: 12,
                  color: colors.income,
                  backgroundColor: colors.primary.withValues(alpha: 0.18),
                  strokeCap: StrokeCap.round,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$percent%',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text('repaid', style: TextStyle(fontSize: 13)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        amount('Principal repaid', repaid, colors.income),
        amount(
          'Principal remaining',
          remaining,
          colors.primary.withValues(alpha: 0.45),
        ),
      ],
    );
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Loan repayment progress',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '${loans.length} active ${loans.length == 1 ? 'loan' : 'loans'} · ${terms.currency}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 300 ||
                  MediaQuery.textScalerOf(context).scale(14) > 18) {
                return Column(
                  children: [
                    Center(child: chart),
                    const SizedBox(height: 20),
                    legend,
                  ],
                );
              }
              return Row(
                children: [
                  chart,
                  const SizedBox(width: 24),
                  Expanded(child: legend),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            'Principal only · interest and fees are separate',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
