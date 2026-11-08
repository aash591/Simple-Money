import 'package:flutter/material.dart';

import '../theme/sheet_colors.dart';
import '../theme/app_typography.dart';
import 'common.dart';
import 'glass_button.dart';

/// The shared shell the Subscription, Loan and Debt pages are all built from.
///
/// Those three track different things and offer different actions, but they
/// answer the same three questions in the same order — what is this and what
/// does it cost ([DetailHero]), what do I know about it ([DetailFacts]), and
/// what has actually happened ([DetailHistoryCard]). Keeping the pieces here
/// means a payment row looks the same whether it settled a loan, a debt or a
/// subscription, so learning one page teaches all three.

/// The identity of the thing and its one headline figure.
class DetailHero extends StatelessWidget {
  const DetailHero({
    super.key,
    required this.leading,
    required this.title,
    required this.amount,
    this.caption,
    this.amountColor,
    this.banner,
    this.subtitle,
    this.footer,
  });

  /// The icon or avatar that names it — an `AppIcon`, a `PersonAvatar`.
  final Widget leading;
  final String title, amount;
  final String? subtitle;
  final Widget? footer;

  /// The unit the amount is in ("/ month"), or what it represents.
  final String? caption;
  final Color? amountColor;

  /// A [DetailBanner] for a state worth saying out loud — paused, settled.
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return MoneyCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Column(
        children: [
          leading,
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              amount,
              style: AppTypography.amount.copyWith(color: amountColor),
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(
              caption!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
          ],
          if (banner != null) ...[const SizedBox(height: 12), banner!],
          if (footer != null) ...[const SizedBox(height: 20), footer!],
        ],
      ),
    );
  }
}

/// Section status sits beside its heading, wrapping below for larger text.
class DetailSectionHeading extends StatelessWidget {
  const DetailSectionHeading(this.title, {super.key, this.status});
  final String title;
  final Widget? status;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final heading = SectionTitle(title);
      if (status == null) return heading;
      if (constraints.maxWidth < 300 ||
          MediaQuery.textScalerOf(context).scale(14) > 19) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [heading, const SizedBox(height: 8), status!],
        );
      }
      return Row(
        children: [
          Expanded(child: heading),
          const SizedBox(width: 12),
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: status!),
          ),
        ],
      );
    },
  );
}

/// Full-width, icon-led actions shared by payment detail pages.
class DetailActions extends StatelessWidget {
  const DetailActions({
    super.key,
    required this.primaryLabel,
    required this.primaryIcon,
    required this.onPrimary,
    this.secondaryLabel,
    this.secondaryIcon,
    this.onSecondary,
  }) : assert(secondaryLabel == null || secondaryIcon != null);

  final String primaryLabel;
  final IconData primaryIcon;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final IconData? secondaryIcon;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
    Widget content(String label, IconData icon) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(child: Text(label, textAlign: TextAlign.center)),
        const SizedBox(width: 8),
        Icon(icon, size: 20),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassButton(
          onPressed: onPrimary,
          color: SheetColors.of(context).primary,
          textStyle: textStyle,
          child: content(primaryLabel, primaryIcon),
        ),
        if (secondaryLabel != null) ...[
          const SizedBox(height: 10),
          GlassButton(
            onPressed: onSecondary,
            textStyle: textStyle,
            child: content(secondaryLabel!, secondaryIcon!),
          ),
        ],
      ],
    );
  }
}

/// A tinted pill for a state the page should lead with.
class DetailBanner extends StatelessWidget {
  const DetailBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

/// One labelled fact: what it is on the left, what it says on the right.
class DetailFact {
  const DetailFact(
    this.label,
    this.value, {
    this.caption,
    this.valueColor,
    this.leading,
    this.emphasized = false,
    this.quiet = false,
  });
  final String label, value;

  /// A second line under the label — the account a payment came from.
  final String? caption;
  final Color? valueColor;

  /// An icon beside the value — a category's, or an account's logo.
  final Widget? leading;

  /// The figure a section adds up to.
  final bool emphasized;

  /// A value saying there is nothing here yet, like "Not set".
  final bool quiet;
}

/// A card of [DetailFact]s, hairline-separated.
class DetailFacts extends StatelessWidget {
  const DetailFacts({super.key, required this.facts});
  final List<DetailFact> facts;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final bodyMedium = Theme.of(context).textTheme.bodyMedium;
    return MoneyCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      child: Column(
        children: [
          for (final (i, fact) in facts.indexed) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: MergeSemantics(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              fact.label,
                              style: bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (fact.caption != null)
                              Text(
                                fact.caption!,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.muted),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (fact.leading case final leading?) ...[
                              leading,
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Text(
                                fact.value,
                                textAlign: TextAlign.end,
                                style: bodyMedium?.copyWith(
                                  fontWeight: fact.emphasized
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color:
                                      fact.valueColor ??
                                      (fact.quiet ? colors.muted : colors.text),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (i != facts.length - 1)
              Divider(height: 1, color: colors.divider),
          ],
        ],
      ),
    );
  }
}

/// The circular icon that leads a history row.
class DetailIconTile extends StatelessWidget {
  const DetailIconTile(IconData this.icon, {super.key, required this.color})
    : number = null;

  /// A serial number in place of an icon, for a list read in order.
  const DetailIconTile.number(int this.number, {super.key, required this.color})
    : icon = null;
  final IconData? icon;
  final int? number;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color.withValues(alpha: .12),
    ),
    child: icon != null
        ? Icon(icon, size: 18, color: color)
        // Three digits still fit: a loan can run to 600 payments.
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ),
  );
}

/// One thing that happened: a payment made, a loan drawn, money lent.
class DetailEntry {
  const DetailEntry({
    required this.leading,
    required this.title,
    required this.amount,
    this.caption,
    this.badge,
    this.amountCaption,
    this.amountColor,
    this.onTap,
  });

  /// A [DetailIconTile], an `AppIcon`, or a `PersonAvatar`.
  final Widget leading;
  final String title, amount;

  /// The line under the title: date, account, note.
  final String? caption;

  /// A short qualifier beside the title — "EMI 4", "Next".
  final String? badge;

  /// A second line under the amount — what a payment leaves outstanding.
  final String? amountCaption;
  final Color? amountColor;
  final VoidCallback? onTap;
}

/// The transactions card: everything that has happened to this thing, in one
/// card, newest first. The same row wherever it appears.
class DetailHistoryCard extends StatelessWidget {
  const DetailHistoryCard({
    super.key,
    required this.entries,
    this.footer,
    this.empty,
  });
  final List<DetailEntry> entries;

  /// A quiet summing-up under the rows — "6 payments · ₹3,894 so far".
  final String? footer;

  /// Shown instead of the card when there is nothing yet.
  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    if (entries.isEmpty) return empty ?? const SizedBox.shrink();
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 68,
                endIndent: 18,
                color: colors.divider,
              ),
            DetailHistoryTile(entries[i]),
          ],
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      footer!,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.muted),
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

/// One row of [DetailHistoryCard]. Public so a long history can build these
/// lazily in a sliver instead of all at once inside a card; [first] and
/// [last] then draw the card's rounded ends around the run.
class DetailHistoryTile extends StatelessWidget {
  const DetailHistoryTile(
    this.entry, {
    super.key,
    this.first = false,
    this.last = false,
    this.grouped = false,
  });
  final DetailEntry entry;

  /// Set when this tile draws its own surface rather than sitting inside a
  /// [DetailHistoryCard] — see [first] and [last].
  final bool grouped;
  final bool first, last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    const radius = Radius.circular(24);
    final row = Material(
      color: grouped ? colors.card : Colors.transparent,
      borderRadius: grouped
          ? BorderRadius.vertical(
              top: first ? radius : Radius.zero,
              bottom: last ? radius : Radius.zero,
            )
          : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: entry.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              entry.leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          entry.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (entry.badge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: colors.primary.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              entry.badge!,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: colors.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (entry.caption != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        entry.caption!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        entry.amount,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: entry.amountColor,
                        ),
                      ),
                    ),
                    if (entry.amountCaption != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.amountCaption!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return grouped
        ? Padding(
            padding: EdgeInsets.only(bottom: last ? 8 : 0),
            child: row,
          )
        : row;
  }
}

/// The "nothing here yet" card, shaped like the history card it replaces.
class DetailEmpty extends StatelessWidget {
  const DetailEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title, message;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return MoneyCard(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
      child: Column(
        children: [
          Icon(icon, size: 30, color: colors.muted),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(height: 1.5, color: colors.muted),
          ),
        ],
      ),
    );
  }
}
