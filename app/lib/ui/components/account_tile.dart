import 'package:flutter/material.dart';

import '../../domain/account.dart';
import '../theme/app_theme.dart';
import 'animated_amount.dart';
import 'app_icon.dart';
import 'private_amount.dart';

/// What kind of account it is, as an icon.
IconData accountTypeIcon(AccountType type) => switch (type) {
  AccountType.bank => Icons.account_balance_outlined,
  AccountType.creditCard => Icons.credit_card_outlined,
  AccountType.cash => Icons.account_balance_wallet_outlined,
};

/// Shown beside [accountTypeIcon] for an account a debit card is used on.
const debitCardIcon = Icons.contactless_outlined;

/// The line under an account's name: the digits that tell two accounts of a
/// bank apart, otherwise what kind of account it is.
String accountDetailLine(Account account) => account.lastDigits == null
    ? account.type.label
    : '\u2022\u2022\u2022\u2022 ${account.lastDigits}';

/// The logo in a white disc, so dark and colourful marks read the same on
/// the tinted panel.
class AccountLogo extends StatelessWidget {
  const AccountLogo(this.icon, {super.key});
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: scheme.onSurface.withValues(alpha: .06)),
      ),
      child: AppIcon(icon, size: 28),
    );
  }
}

/// One account in the swipeable strip: logo, name and the digits that tell
/// two accounts apart across the top, the balance big underneath. Money owed
/// shows in red.
class AccountTile extends StatelessWidget {
  const AccountTile({
    super.key,
    required this.account,
    this.onTap,
    this.width = 232,
    this.dense = false,
  });
  final Account account;

  /// Null leaves the card plain: no ripple and no chevron.
  final VoidCallback? onTap;

  /// Its width; null fills whatever space it is given.
  final double? width;

  /// Less padding and spacing, for where the card heads a page rather than
  /// sitting in a strip.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final owes = account.balanceMinor < 0;
    final amount = formatAccountMoney(
      account.balanceMinor,
      digits: account.digits,
      currency: account.currency,
    );
    const radius = BorderRadius.all(Radius.circular(22));
    final amountStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -.5,
      color: owes ? coral : null,
    );
    return SizedBox(
      width: width,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: scheme.onSurface.withValues(alpha: .06)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary.withValues(alpha: dark ? .16 : .10),
              scheme.onSurface.withValues(alpha: dark ? .05 : .025),
            ],
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: dense
                ? const EdgeInsets.fromLTRB(14, 12, 12, 12)
                : const EdgeInsets.fromLTRB(16, 16, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AccountLogo(account.icon),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // The icon shares the name's line, so the two sit
                          // level rather than the icon floating between rows.
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  account.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Tappable cards point onward; a plain one (an
                              // account's own page) shows its kind instead.
                              if (onTap != null)
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 22,
                                  color: scheme.onSurfaceVariant,
                                )
                              else ...[
                                if (account.hasDebitCard) ...[
                                  Icon(
                                    debitCardIcon,
                                    size: 20,
                                    color: scheme.onSurfaceVariant,
                                    semanticLabel: 'Debit card',
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Icon(
                                  accountTypeIcon(account.type),
                                  size: 20,
                                  color: scheme.onSurfaceVariant,
                                  semanticLabel: account.type.label,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            accountDetailLine(account),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              letterSpacing: .4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: dense ? 10 : 22),
                Text(
                  owes ? 'You owe' : 'Balance',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 2),
                PrivateAmount(
                  height: 34,
                  label: '${account.name} balance',
                  maskStyle: amountStyle,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                      label: owes
                          ? '${account.name} owes ${amount.substring(1)}'
                          : amount,
                      excludeSemantics: true,
                      child: AnimatedAmount(
                        value: account.balanceMinor,
                        format: (minor) => formatAccountMoney(
                          minor,
                          digits: account.digits,
                          currency: account.currency,
                        ),
                        style: amountStyle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
