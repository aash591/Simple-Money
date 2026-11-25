import 'package:flutter/material.dart';

import '../../../../data/notification_access_platform.dart';
import '../../../components/common.dart';
import '../../../theme/sheet_colors.dart';

/// A notification as it looked on the phone: the app's icon, its name and how
/// long ago (at the right edge), the bold heading, and the text.
///
/// One widget for both places a notification is shown while teaching: at the
/// top of the teach sheet (the default, in the sheet's colours), and as each
/// row of the list of notifications on the phone ([onPage]), where it is a
/// card of the app's own style that can be tapped and says whether it is
/// [read] yet.
class NotificationPreview extends StatelessWidget {
  const NotificationPreview(
    this.notification, {
    super.key,
    this.now,
    this.onPage = false,
    this.onTap,
    this.read,
    this.maxLines,
  });
  final CapturedNotification notification;

  /// Replaced in tests.
  final DateTime? now;

  /// In a list on a page, drawn as the app's card, not in a sheet's colours.
  final bool onPage;

  /// Makes it a tappable row, as in the list of notifications.
  final VoidCallback? onTap;

  /// For a taught app: whether its rules read this notification yet. Shown as
  /// a tag; an unread one is highlighted. Null (no tag) for an app not taught.
  final bool? read;

  /// How many lines of the text to show (and two of the heading), for a list.
  /// All of it when null.
  final int? maxLines;

  /// "just now", "28 minutes ago", "3 hours ago", "2 days ago".
  static String ago(DateTime when, DateTime now) {
    final minutes = now.difference(when).inMinutes;
    if (minutes < 1) return 'just now';
    if (minutes < 60) {
      return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} ago';
    }
    final hours = now.difference(when).inHours;
    if (hours < 24) return '$hours ${hours == 1 ? 'hour' : 'hours'} ago';
    final days = now.difference(when).inDays;
    return '$days ${days == 1 ? 'day' : 'days'} ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sheet = onPage ? null : SheetColors.of(context);
    final text = sheet?.text ?? theme.colorScheme.onSurface;
    final muted = sheet?.muted ?? theme.colorScheme.onSurfaceVariant;
    final primary = sheet?.primary ?? theme.colorScheme.primary;
    final done = sheet?.income ?? Colors.green.shade600;
    final n = notification;
    final icon = n.icon;

    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The app's own icon; its first letter when Android gave none.
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox.square(
            dimension: 36,
            child: icon != null
                ? Image.memory(icon, fit: BoxFit.cover, gaplessPlayback: true)
                : ColoredBox(
                    color: primary.withValues(alpha: .18),
                    child: Center(
                      child: Text(
                        n.label.isEmpty ? '?' : n.label[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: primary,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The app on the left, how long ago at the right edge.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      n.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: muted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    ago(n.receivedAt, now ?? DateTime.now()),
                    style: TextStyle(fontSize: 12.5, color: muted),
                  ),
                ],
              ),
              if (n.title.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  n.title,
                  maxLines: maxLines == null ? null : 2,
                  overflow: maxLines == null ? null : TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: text,
                  ),
                ),
              ],
              if (n.text.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  n.text,
                  maxLines: maxLines,
                  overflow: maxLines == null ? null : TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, height: 1.3, color: text),
                ),
              ],
              // Whether the rules read this kind of notification yet.
              if (read != null) ...[
                const SizedBox(height: 8),
                _Tag(
                  read! ? 'Read' : 'Not read yet',
                  tone: read! ? done : primary,
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final body = onPage
        // A card of the app's own style; an unread one is featured.
        ? MoneyCard(
            featured: read == false,
            padding: EdgeInsets.zero,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: content,
                ),
              ),
            ),
          )
        : Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: sheet!.control,
              borderRadius: BorderRadius.circular(18),
            ),
            child: content,
          );
    return Semantics(
      container: true,
      button: onTap != null,
      label: 'Notification from ${n.label}',
      child: KeyedSubtree(
        // Told apart from the one at the top of the teach sheet.
        key: Key(onPage ? 'notification-card' : 'notification-preview'),
        child: body,
      ),
    );
  }
}

/// A small pill: "Read" or "Not read yet".
class _Tag extends StatelessWidget {
  const _Tag(this.label, {required this.tone});
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tone),
    ),
  );
}
