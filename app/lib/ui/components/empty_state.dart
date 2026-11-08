import 'package:flutter/material.dart';

import 'common.dart';

/// The one "nothing here yet" page for list screens (Accounts, Categories,
/// Debts, Loans, Subscriptions): a haloed icon, a short title, one line on
/// what the page is for, and an optional button to add the first item —
/// or, through [actions], a few buttons of the page's own.
///
/// Fills the space it's given and sits a little above centre, scrolling
/// only when large text or a short screen needs it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.actions = const [],
  });
  final IconData icon;
  final String title, message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Full-width buttons under the message, in place of the add button.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 100),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight
                ? (constraints.maxHeight - 124).clamp(0, double.infinity)
                : 0,
          ),
          child: Align(
            alignment: const Alignment(0, -.35),
            child: MoneyCard(
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Halo(icon),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    // Keeps lines a comfortable length on wide screens so the
                    // message wraps evenly instead of leaving one orphan word.
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.55,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: onAction,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(actionLabel!),
                      ),
                    ),
                  ] else if (actions.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    for (final (n, action) in actions.indexed) ...[
                      if (n > 0) const SizedBox(height: 10),
                      SizedBox(width: double.infinity, child: action),
                    ],
                  ] else
                    const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when a search on a list screen finds nothing.
class NoResultsState extends StatelessWidget {
  const NoResultsState(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 42, color: muted),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Try a different word or check the spelling.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

/// A soft double ring behind the icon, tinted with the primary colour.
class _Halo extends StatelessWidget {
  const _Halo(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      width: 108,
      height: 108,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: primary.withValues(alpha: .05),
      ),
      child: Container(
        width: 76,
        height: 76,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary.withValues(alpha: .12),
        ),
        child: Icon(icon, size: 36, color: primary),
      ),
    );
  }
}
