import 'package:flutter/material.dart';

import '../../components/reminder_card.dart';

export '../../components/reminder_card.dart';

/// A titled run of [ReminderCard]s for whatever falls due within the week.
/// Shows the first three, links to the full list past that, and hides itself
/// when nothing is due. Reloads on returning to the app, since "due soon"
/// moves with the calendar.
class ReminderSection extends StatefulWidget {
  const ReminderSection({
    super.key,
    required this.title,
    required this.listenable,
    required this.onResume,
    required this.cards,
    required this.viewAllLabel,
    required this.onViewAll,
  });
  final String title;
  final Listenable listenable;
  final VoidCallback onResume;

  /// Every card due, soonest first.
  final List<Widget> Function(BuildContext context) cards;
  final String Function(int count) viewAllLabel;
  final VoidCallback onViewAll;

  /// How far ahead Home looks for payments.
  static DateTime get horizon {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 6);
  }

  @override
  State<ReminderSection> createState() => _ReminderSectionState();
}

class _ReminderSectionState extends State<ReminderSection>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.onResume();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.listenable,
    builder: (context, _) {
      final cards = widget.cards(context);
      if (cards.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 18),
          Text(widget.title, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          ...cards.take(3),
          if (cards.length > 3)
            TextButton(
              onPressed: widget.onViewAll,
              child: Text(widget.viewAllLabel(cards.length)),
            ),
        ],
      );
    },
  );
}
