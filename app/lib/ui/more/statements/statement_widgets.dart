/// Pieces shared by every statement import screen.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class StatementSectionLabel extends StatelessWidget {
  const StatementSectionLabel(
    this.text, {
    super.key,
    this.action,
    this.onAction,
  });
  final String text;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: .6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 22, 6, 6),
      child: Row(
        children: [
          Expanded(child: Text(text.toUpperCase(), style: style)),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}

class StatementRowDivider extends StatelessWidget {
  const StatementRowDivider({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(left: 64, right: 18),
    child: Divider(height: 1),
  );
}

/// A row naming something and the choice made for it; tap to change it.
/// Without [onTap] it only states what was found.
class StatementPickerRow extends StatelessWidget {
  const StatementPickerRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.missing,
    required this.onTap,
  });
  final Widget icon;
  final String title, value;
  final bool missing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              SizedBox(width: 30, height: 30, child: Center(child: icon)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      value,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 15,
                        color: missing ? coral : null,
                      ),
                    ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
