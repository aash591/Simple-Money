import 'package:flutter/material.dart';

import '../../../data/agent/agent_accounts.dart';
import '../../../domain/account.dart';
import '../accounts/account_card.dart';

/// A suggested account change drawn with the same [AccountCard] the Accounts
/// screen uses: the account as it would look once approved, and for a merge
/// both accounts, the one that goes above the one that keeps it all.
///
/// Returns null from [maybe] when the accounts it names are gone (a merge or
/// delete already applied), so the suggestion falls back to its text.
class AccountSuggestionPreview extends StatelessWidget {
  const AccountSuggestionPreview._({
    required this.action,
    required this.cards,
    required this.changes,
  });

  static AccountSuggestionPreview? maybe({
    required Map<String, Object?> payload,
    required List<String> detail,
    required Account? Function(int? id) accountOf,
  }) {
    final action = AgentAccountAction.fromToolName(
      payload['action'] as String?,
    );
    if (action == null) return null;
    final current = accountOf(payload['accountId'] as int?);
    int? minor(String key) => payload[key] as int?;
    switch (action) {
      case AgentAccountAction.create:
        final digits = payload['digits'] as int? ?? 2;
        return AccountSuggestionPreview._(
          action: action,
          changes: const [],
          cards: [
            (
              Account(
                id: -1,
                name: payload['name'] as String? ?? '',
                currency: payload['currency'] as String? ?? 'INR',
                digits: digits,
                icon: payload['icon'] as String?,
                type: AccountType.values.byName(
                  payload['type'] as String? ?? 'bank',
                ),
                lastDigits: payload['lastDigits'] as String?,
                institution: payload['institution'] as String?,
                isBroker: payload['broker'] == true,
                placeId: payload['place'] as String?,
                balanceMinor: minor('balance') ?? 0,
                creditLimitMinor: minor('creditLimit'),
                availableCreditLimitMinor: minor('availableCredit'),
              ),
              null,
            ),
          ],
        );
      case AgentAccountAction.update:
        if (current == null) return null;
        final currency = payload['currency'] as String? ?? current.currency;
        return AccountSuggestionPreview._(
          action: action,
          changes: detail,
          cards: [
            (
              Account(
                id: current.id,
                name: payload['name'] as String? ?? current.name,
                currency: currency,
                territory: current.territory,
                digits: payload['digits'] as int? ?? current.digits,
                icon: payload['icon'] as String? ?? current.icon,
                type: switch (payload['type']) {
                  final String t => AccountType.values.byName(t),
                  _ => current.type,
                },
                lastDigits:
                    payload['lastDigits'] as String? ?? current.lastDigits,
                institution:
                    payload['institution'] as String? ?? current.institution,
                isBroker: current.isBroker,
                placeId: current.placeId,
                balanceMinor: current.balanceMinor,
                hasDebitCard: current.hasDebitCard,
                transactionCount: current.transactionCount,
                creditLimitMinor: payload.containsKey('creditLimit')
                    ? minor('creditLimit')
                    : current.creditLimitMinor,
                availableCreditLimitMinor:
                    payload.containsKey('availableCredit')
                    ? minor('availableCredit')
                    : current.availableCreditLimitMinor,
              ),
              null,
            ),
          ],
        );
      case AgentAccountAction.adjustBalance:
        if (current == null) return null;
        return AccountSuggestionPreview._(
          action: action,
          changes: detail,
          cards: [(_withBalance(current, minor('balance') ?? 0), null)],
        );
      case AgentAccountAction.archive ||
          AgentAccountAction.restore ||
          AgentAccountAction.delete:
        if (current == null) return null;
        return AccountSuggestionPreview._(
          action: action,
          changes: detail,
          cards: [(current, null)],
        );
      case AgentAccountAction.merge:
        final into = accountOf(payload['mergeIntoId'] as int?);
        if (current == null || into == null) return null;
        return AccountSuggestionPreview._(
          action: action,
          changes: const [],
          cards: [
            (current, 'Removed'),
            (
              _withBalance(
                into,
                into.balanceMinor + current.balanceMinor,
                count: into.transactionCount + current.transactionCount,
              ),
              'Keeps everything',
            ),
          ],
        );
    }
  }

  final AgentAccountAction action;

  /// Each card with an optional caption above it.
  final List<(Account, String?)> cards;

  /// The lines naming what changes, under the card.
  final List<String> changes;

  static Account _withBalance(Account a, int balance, {int? count}) => Account(
    id: a.id,
    name: a.name,
    currency: a.currency,
    territory: a.territory,
    icon: a.icon,
    digits: a.digits,
    balanceMinor: balance,
    transactionCount: count ?? a.transactionCount,
    hasDebitCard: a.hasDebitCard,
    archivedAt: a.archivedAt,
    type: a.type,
    lastDigits: a.lastDigits,
    institution: a.institution,
    isBroker: a.isBroker,
    placeId: a.placeId,
    creditLimitMinor: a.creditLimitMinor,
    availableCreditLimitMinor: a.availableCreditLimitMinor,
    balanceReportedAt: a.balanceReportedAt,
  );

  IconData get _icon => switch (action) {
    AgentAccountAction.create => Icons.add_card_rounded,
    AgentAccountAction.update => Icons.edit_outlined,
    AgentAccountAction.adjustBalance => Icons.account_balance_wallet_outlined,
    AgentAccountAction.archive => Icons.archive_outlined,
    AgentAccountAction.restore => Icons.unarchive_outlined,
    AgentAccountAction.merge => Icons.merge_rounded,
    AgentAccountAction.delete => Icons.delete_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grave = action == AgentAccountAction.delete;
    final accent = grave ? scheme.error : scheme.primary;
    final caption = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
          child: Row(
            children: [
              Icon(_icon, size: 20, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  action.label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: grave ? scheme.error : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final (index, (account, label)) in cards.indexed) ...[
          if (index > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Icon(
                Icons.arrow_downward_rounded,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
            ),
          if (label != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Text(label, style: caption),
            ),
          Opacity(
            opacity: (action == AgentAccountAction.merge && index == 0) || grave
                ? .6
                : 1,
            child: AccountCard(
              account: account,
              showTransactionCount: action != AgentAccountAction.create,
            ),
          ),
        ],
        if (changes.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final line in changes)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
              child: Text(line, style: theme.textTheme.bodyMedium),
            ),
        ],
      ],
    );
  }
}
