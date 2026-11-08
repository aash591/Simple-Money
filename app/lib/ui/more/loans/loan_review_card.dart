import 'package:flutter/material.dart';

import '../../components/adaptive_sheet.dart';
import '../../theme/sheet_colors.dart';

/// Tells a fact which column of a [LoanReviewGrid] it sits in, so the
/// second column can hug the card's trailing edge.
class _GridColumn extends InheritedWidget {
  const _GridColumn({required this.end, required super.child});
  final bool end;

  static bool endOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GridColumn>()?.end ?? false;

  @override
  bool updateShouldNotify(_GridColumn old) => old.end != end;
}

/// Whether [context] sits in the trailing column of a [LoanReviewGrid].
bool loanReviewTrailing(BuildContext context) => _GridColumn.endOf(context);

/// A labelled value. Values wrap rather than hiding an amount or date with
/// ellipses; [chevron] reserves room for a [LoanFactTile]'s chevron.
class LoanReviewFact extends StatelessWidget {
  const LoanReviewFact({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.emphasized = false,
    this.chevron = false,
    this.alignToColumn = true,
  });
  final String label;
  final String value;
  final String? caption;
  final bool emphasized;
  final bool chevron;

  /// Whether a fact in the trailing grid column aligns to its trailing edge.
  final bool alignToColumn;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final end = alignToColumn && _GridColumn.endOf(context);
    final align = end ? TextAlign.end : TextAlign.start;
    // The tile's chevron sits top right; keep a right-aligned label clear.
    final inset = EdgeInsets.only(right: chevron ? 22 : 0);
    final valueText = Text(
      value,
      textAlign: align,
      style: TextStyle(
        fontSize: 17,
        fontWeight: emphasized ? FontWeight.w700 : FontWeight.w600,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: end
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Padding(
              padding: inset,
              child: Text(
                label,
                textAlign: align,
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
            ),
            const SizedBox(height: 6),
            valueText,
            if (caption != null) ...[
              const SizedBox(height: 2),
              Padding(
                padding: inset,
                child: Text(
                  caption!,
                  textAlign: align,
                  style: TextStyle(fontSize: 13, color: colors.muted),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Two balanced columns with content-driven heights; the second column is
/// aligned to the trailing edge. Narrow widths and large text use one.
class LoanReviewGrid extends StatelessWidget {
  const LoanReviewGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final single =
          constraints.maxWidth < 280 ||
          MediaQuery.textScalerOf(context).scale(14) > 18;
      return Column(
        children: [
          for (var i = 0; i < children.length; i += single ? 1 : 2) ...[
            if (i > 0) const SizedBox(height: 12),
            if (single)
              SizedBox(width: double.infinity, child: children[i])
            else
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: children[i]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: i + 1 < children.length
                          ? _GridColumn(end: true, child: children[i + 1])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
          ],
        ],
      );
    },
  );
}

/// A [LoanReviewFact] on its own rounded surface. When [onTap] is set the
/// tile opens something, marked by a chevron at its top right.
class LoanFactTile extends StatelessWidget {
  const LoanFactTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.emphasized = false,
    this.onTap,
    this.tooltip,
  });
  final String label;
  final String value;
  final String? caption;
  final bool emphasized;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final tile = Material(
      color: colors.card,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: LoanReviewFact(
                label: label,
                value: value,
                caption: caption,
                emphasized: emphasized,
                chevron: onTap != null,
                alignToColumn: false,
              ),
            ),
            if (onTap != null)
              Positioned(
                top: 10,
                right: 8,
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.muted,
                ),
              ),
          ],
        ),
      ),
    );
    return tooltip == null ? tile : Tooltip(message: tooltip!, child: tile);
  }
}

/// The loan at a glance: who it is, how much was borrowed and how much of
/// the principal is repaid. Shared by the review and the loan details.
/// Passing [onEditName] or [onEditAmount] adds an edit button to that line.
class LoanSummaryCard extends StatelessWidget {
  const LoanSummaryCard({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    required this.amount,
    required this.progress,
    required this.repaid,
    required this.remaining,
    this.onEditName,
    this.onEditAmount,
  });
  final Widget leading;
  final String title;
  final String? subtitle;
  final String amount, repaid, remaining;
  final double progress;
  final VoidCallback? onEditName, onEditAmount;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final text = Theme.of(context).textTheme;

    Widget legend(String label, String value, Color color) => Builder(
      builder: (context) {
        final end = loanReviewTrailing(context);
        final swatch = Container(
          width: 10,
          height: 10,
          margin: EdgeInsets.only(
            top: 12,
            left: end ? 8 : 0,
            right: end ? 0 : 8,
          ),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        );
        final fact = Flexible(
          child: LoanReviewFact(label: label, value: value),
        );
        return Row(
          mainAxisAlignment: end
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: end ? [fact, swatch] : [swatch, fact],
        );
      },
    );

    return SheetCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: text.titleMedium),
                      if (subtitle != null)
                        Text(subtitle!, style: text.bodySmall),
                    ],
                  ),
                ),
                if (onEditName != null)
                  IconButton(
                    tooltip: 'Edit loan name',
                    onPressed: onEditName,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Loan amount',
                        style: TextStyle(fontSize: 14, color: colors.muted),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          amount,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.6,
                            color: colors.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (onEditAmount != null)
                  IconButton(
                    tooltip: 'Change loan amount',
                    onPressed: onEditAmount,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Semantics(
              label: 'Principal repaid',
              value: '${(progress * 100).round()}%',
              child: ExcludeSemantics(
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(8),
                  color: colors.income,
                  backgroundColor: colors.outline,
                ),
              ),
            ),
            const SizedBox(height: 8),
            LoanReviewGrid(
              children: [
                legend('Principal repaid', repaid, colors.income),
                legend('Principal remaining', remaining, colors.outline),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Principal only · excludes interest and fees',
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
