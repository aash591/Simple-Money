import 'package:flutter/material.dart';

import 'empty_art.dart';

/// The one "nothing here yet" page for list screens (Accounts, Categories,
/// Debts, Loans, Recurring payments): hand-drawn 3D artwork resting in a glass
/// lens that overlaps a dashed panel, a short title, one line on what the
/// page is for, and an optional button to add the first item — or, through
/// [actions], a few buttons of the page's own.
///
/// [icon] picks the artwork (see [emptyArtFor]); [art] names it directly.
///
/// Fills the space it's given and sits a little above centre, scrolling
/// only when large text or a short screen needs it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.art,
    this.actionLabel,
    this.onAction,
    this.actions = const [],
  });
  final IconData icon;
  final EmptyArt? art;
  final String title, message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Full-width buttons under the panel, in place of the add button.
  final List<Widget> actions;

  static const _lens = 124.0;

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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.topCenter,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: _lens * .45),
                      child: DashedNotchPanel(
                        padding: const EdgeInsets.fromLTRB(
                          24,
                          _lens * .55 + 24,
                          24,
                          34,
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: Column(
                            children: [
                              Text(
                                title,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 10),
                              ConstrainedBox(
                                // Keeps lines a comfortable length on wide
                                // screens so the message wraps evenly.
                                constraints: const BoxConstraints(
                                  maxWidth: 300,
                                ),
                                child: Text(
                                  message,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    height: 1.55,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    GlassLens(
                      size: _lens,
                      child: EmptyArtwork(
                        art ?? emptyArtFor(icon),
                        size: _lens * .54,
                      ),
                    ),
                  ],
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 32),
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
                  const SizedBox(height: 32),
                  for (final (n, action) in actions.indexed) ...[
                    if (n > 0) const SizedBox(height: 10),
                    SizedBox(width: double.infinity, child: action),
                  ],
                ],
              ],
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GlassLens(
            size: 96,
            child: EmptyArtwork(EmptyArt.search, size: 52),
          ),
          const SizedBox(height: 22),
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
