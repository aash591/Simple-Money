import 'package:flutter/material.dart';

/// A card's one quick action: a soft pill in [color] that sits level with the
/// chips beside it, so it reads as part of the card rather than a form button.
///
/// [outlined] drops the fill for a bordered pill — used for actions still to
/// do (an unticked "Mark paid"), so they don't read as a done-state badge.
class CardAction extends StatelessWidget {
  const CardAction({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.outlined = false,
    this.iconAtEnd = false,
  });
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final bool outlined;
  final bool iconAtEnd;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final shade = enabled ? color : color.withValues(alpha: .45);
    return Semantics(
      button: true,
      enabled: enabled,
      child: Material(
        color: outlined ? Colors.transparent : shade.withValues(alpha: .12),
        shape: outlined
            ? StadiumBorder(
                side: BorderSide(
                  color: shade.withValues(alpha: .6),
                  width: 1.2,
                ),
              )
            : const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashColor: color.withValues(alpha: .16),
          highlightColor: color.withValues(alpha: .08),
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: EdgeInsets.fromLTRB(
              iconAtEnd ? 14 : 10,
              7,
              iconAtEnd ? 10 : 14,
              7,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!iconAtEnd) ...[
                  Icon(icon, size: 16, color: shade),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: shade,
                  ),
                ),
                if (iconAtEnd) ...[
                  const SizedBox(width: 6),
                  Icon(icon, size: 16, color: shade),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
