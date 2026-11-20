import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/currency_scope.dart';
import '../../components/account_tile.dart';
import '../../components/common.dart';

/// Shared presentation for saved accounts and SMS account previews.
class AccountCard extends StatefulWidget {
  const AccountCard({
    super.key,
    required this.account,
    this.onTap,
    this.leading,
    this.handle,
    this.scope,
    this.balanceKnown = true,
    this.subtitle,
    this.showTransactionCount = true,
    this.balanceEditor,
    this.creditLimitEditor,
    this.selected = false,
    this.actions,
  });
  final Account account;
  final VoidCallback? onTap;

  final Widget? leading;

  /// A drag handle, in the card's bottom-right corner.
  final Widget? handle;
  final CurrencyScope? scope;
  final bool balanceKnown;
  final String? subtitle;
  final bool showTransactionCount;
  final Widget? balanceEditor;
  final Widget? creditLimitEditor;
  final bool selected;
  final Widget? actions;

  @override
  State<AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<AccountCard> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final onTap = widget.onTap;
    final leading = widget.leading;
    final handle = widget.handle;
    final scope = widget.scope;
    final balanceKnown = widget.balanceKnown;
    final subtitle = widget.subtitle;
    final showTransactionCount = widget.showTransactionCount;
    final balanceEditor = widget.balanceEditor;
    final creditLimitEditor = widget.creditLimitEditor;
    final actions = widget.actions;
    final text = Theme.of(context).textTheme;
    final card = account.type == AccountType.creditCard;
    final used = account.creditUtilization;
    String money(int? value) => value == null
        ? 'Set limit'
        : formatAccountMoney(
            value,
            digits: account.digits,
            currency: account.currency,
          );
    final colors = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(appCardRadius));
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedScale(
      scale: pressed ? .985 : 1,
      duration: Duration(
        milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 160,
      ),
      curve: Curves.easeOutCubic,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: widget.selected
                ? colors.primary.withValues(alpha: .45)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: MoneyCard(
          padding: EdgeInsets.zero,
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            // The same soft tint as the account cards on Home.
            child: Ink(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colors.primary.withValues(
                      alpha: widget.selected
                          ? (dark ? .24 : .16)
                          : (dark ? .16 : .10),
                    ),
                    colors.onSurface.withValues(alpha: dark ? .05 : .025),
                  ],
                ),
              ),
              child: InkWell(
                onTap: onTap,
                onTapDown: onTap == null
                    ? null
                    : (_) => setState(() => pressed = true),
                onTapUp: onTap == null
                    ? null
                    : (_) => setState(() => pressed = false),
                onTapCancel: () => setState(() => pressed = false),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          AccountLogo(account.icon),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // The kind-of-account icon shares the name's
                                // line, so the two sit level.
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        account.name,
                                        style: text.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    ?leading,
                                    const SizedBox(width: 8),
                                    if (account.hasDebitCard) ...[
                                      Icon(
                                        debitCardIcon,
                                        size: 20,
                                        color: colors.onSurfaceVariant,
                                        semanticLabel: 'Debit card',
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    Icon(
                                      accountTypeIcon(account.type),
                                      size: 20,
                                      color: colors.onSurfaceVariant,
                                      semanticLabel: account.type.label,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        account.type.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.bodySmall,
                                      ),
                                    ),
                                    if (account.lastDigits != null) ...[
                                      const SizedBox(width: 8),
                                      Text(
                                        '•••• ${account.lastDigits}',
                                        style: text.bodySmall?.copyWith(
                                          letterSpacing: .4,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Text(
                        card
                            ? 'Available limit'
                            : 'Balance \u00b7 ${account.currency}',
                        style: text.bodySmall,
                      ),
                      const SizedBox(height: 5),
                      balanceEditor ??
                          Text(
                            card
                                ? money(account.availableCreditLimitMinor)
                                : balanceKnown
                                ? account.formattedBalance
                                : 'Set balance',
                            style: text.headlineSmall?.copyWith(
                              color: !card && !balanceKnown
                                  ? colors.onSurface.withValues(alpha: .38)
                                  : null,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -.5,
                            ),
                          ),
                      if (!card && balanceKnown)
                        _AccountEquivalent(account: account, scope: scope),
                      if (card) ...[
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Text('Credit limit', style: text.bodySmall),
                            const SizedBox(width: 8),
                            Expanded(
                              child:
                                  creditLimitEditor ??
                                  Text(
                                    money(account.creditLimitMinor),
                                    textAlign: TextAlign.end,
                                    style: text.labelLarge,
                                  ),
                            ),
                          ],
                        ),
                        if (used != null) ...[
                          const SizedBox(height: 10),
                          LinearProgressIndicator(
                            value: used,
                            minHeight: 4,
                            backgroundColor: colors.primary.withValues(
                              alpha: .1,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ],
                      ],
                      if (subtitle != null ||
                          showTransactionCount ||
                          card ||
                          handle != null) ...[
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                spacing: 12,
                                runSpacing: 6,
                                children: [
                                  if (subtitle != null || showTransactionCount)
                                    Text(
                                      subtitle ??
                                          '${account.transactionCount} ${account.transactionCount == 1 ? 'transaction' : 'transactions'}',
                                      style: text.bodySmall,
                                    ),
                                  if (card)
                                    Text(
                                      used == null
                                          ? 'Utilization unavailable'
                                          : '${(used * 100).toStringAsFixed(1)}% used',
                                      style: text.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                            ?handle,
                          ],
                        ),
                      ],
                      if (actions != null) ...[
                        const SizedBox(height: 12),
                        actions,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountEquivalent extends StatelessWidget {
  const _AccountEquivalent({required this.account, required this.scope});
  final Account account;
  final CurrencyScope? scope;
  @override
  Widget build(BuildContext context) {
    final scope = this.scope;
    if (scope is! CombinedCurrency || account.currency == scope.code) {
      return const SizedBox.shrink();
    }
    final converted = scope.convert(
      account.balanceMinor,
      account.currency,
      account.digits,
    );
    final amount = converted == null
        ? null
        : formatAccountMoney(
            converted,
            currency: scope.code,
            digits: scope.digits,
          );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        amount == null ? 'Rate unavailable' : '≈ $amount',
        semanticsLabel: amount == null ? null : 'Approximately $amount',
        textAlign: TextAlign.end,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
