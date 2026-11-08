import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/currency_scope.dart';
import '../../components/app_icon.dart';
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
    return AnimatedScale(
      scale: pressed ? .985 : 1,
      duration: Duration(
        milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 160,
      ),
      curve: Curves.easeOutCubic,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(appCardRadius),
          border: Border.all(
            color: widget.selected
                ? colors.primary.withValues(alpha: .45)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: MoneyCard(
          color: widget.selected
              ? Color.alphaBlend(
                  colors.primary.withValues(alpha: .045),
                  colors.surface,
                )
              : null,
          padding: EdgeInsets.zero,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(appCardRadius),
            clipBehavior: Clip.antiAlias,
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
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        AppIcon(account.icon, size: 36),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                account.name,
                                style: text.titleMedium,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 3),
                              Text(account.type.label, style: text.bodySmall),
                            ],
                          ),
                        ),
                        ?leading,
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Icon(
                              switch (account.type) {
                                AccountType.bank =>
                                  Icons.account_balance_outlined,
                                AccountType.creditCard =>
                                  Icons.credit_card_outlined,
                                AccountType.cash =>
                                  Icons.account_balance_wallet_outlined,
                              },
                              size: 20,
                              color: colors.onSurfaceVariant,
                              semanticLabel: account.type.label,
                            ),
                            if (account.lastDigits != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                '\u2022\u2022 ${account.lastDigits}',
                                style: text.bodySmall?.copyWith(
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ],
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
                          backgroundColor: colors.primary.withValues(alpha: .1),
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
