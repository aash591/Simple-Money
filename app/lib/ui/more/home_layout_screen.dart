import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../state/home_layout.dart';
import '../../state/security_controller.dart';
import '../components/feature_page.dart';
import '../components/more_popup_button.dart';
import '../components/reorder_lift.dart';
import '../home/home_cards.dart';
import '../theme/surface_style.dart' show appCardRadius;
import 'home_preview_data.dart';

/// Arranges Home: each card is drawn as it really looks, on example data.
/// Press and hold one to lift it and drag it into place; switch it off to
/// hide it.
class HomeLayoutScreen extends StatefulWidget {
  const HomeLayoutScreen({super.key, required this.layout});
  final HomeLayout layout;

  @override
  State<HomeLayoutScreen> createState() => _HomeLayoutScreenState();
}

class _HomeLayoutScreenState extends State<HomeLayoutScreen> {
  late final HomePreviewData _preview = HomePreviewData.create();
  HomeLayout get layout => widget.layout;

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FeaturePage(
    title: 'Home screen cards',
    actions: [
      ListenableBuilder(
        listenable: layout,
        builder: (context, _) => IgnorePointer(
          ignoring: layout.isDefault,
          child: Opacity(
            opacity: layout.isDefault ? .4 : 1,
            child: MorePopupButton<String>(
              items: const [
                MorePopupItem(
                  value: 'reset',
                  label: 'Reset to default',
                  icon: Icons.restart_alt_rounded,
                ),
              ],
              onSelected: (value) {
                if (value == 'reset') layout.reset();
              },
            ),
          ),
        ),
      ),
    ],
    // Example figures are shown plainly, whatever the privacy setting.
    child: SecurityScope(
      controller: _preview.security,
      child: ListenableBuilder(
        listenable: layout,
        builder: (context, _) {
          final text = Theme.of(context).textTheme;
          final order = layout.order;
          final example = _preview.context;
          return ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 32),
            buildDefaultDragHandles: false,
            header: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              child: Row(
                // Both labels stay flexible: at large text scales an
                // unconstrained hint squeezes the count into a column.
                children: [
                  Expanded(
                    child: Text(
                      '${layout.visible.length} of ${order.length} shown',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Press and hold to reorder',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: text.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            footer: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Text(
                'Cards show example figures. Empty cards hide themselves. '
                'Upcoming payments show only when due, loan payoff only while '
                'a loan is open.',
                style: text.bodySmall,
              ),
            ),
            onReorderStart: (_) => HapticFeedback.mediumImpact(),
            proxyDecorator: reorderLift,
            itemCount: order.length,
            onReorderItem: layout.move,
            itemBuilder: (context, index) {
              final id = order[index];
              return _Kept(
                key: ValueKey(id),
                child: ReorderableDelayedDragStartListener(
                  index: index,
                  child: Semantics(
                    customSemanticsActions: {
                      if (index > 0)
                        const CustomSemanticsAction(label: 'Move up'): () =>
                            layout.move(index, index - 1),
                      if (index < order.length - 1)
                        const CustomSemanticsAction(label: 'Move down'): () =>
                            layout.move(index, index + 1),
                    },
                    child: _Item(
                      id: id,
                      visible: layout.isVisible(id),
                      card: buildHomeCard(id, example),
                      onVisible: (value) => layout.setVisible(id, value),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

/// Keeps a preview built while it is scrolled out of view, as Home does
/// with its cards. Built again on the way back, each card replayed its
/// fade-in and its charts measured and drew themselves afresh, mid-scroll.
class _Kept extends StatefulWidget {
  const _Kept({super.key, required this.child});
  final Widget child;
  @override
  State<_Kept> createState() => _KeptState();
}

class _KeptState extends State<_Kept> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// One card as it looks on Home, under its name and an on/off switch.
class _Item extends StatelessWidget {
  const _Item({
    required this.id,
    required this.visible,
    required this.card,
    required this.onVisible,
  });
  final HomeCardId id;
  final bool visible;
  final Widget? card;
  final ValueChanged<bool> onVisible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      // A faint outline keeps each name, switch and card together as one
      // entry in the list.
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: theme.colorScheme.onSurface.withValues(alpha: .1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(id.label, style: theme.textTheme.titleSmall),
                        Text(id.description, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    label: 'Show ${id.label} on Home',
                    child: Switch.adaptive(
                      value: visible,
                      onChanged: onVisible,
                    ),
                  ),
                ],
              ),
            ),
            // A hidden card is dimmed by a veil of the page's colour laid
            // over it. Making the card itself see-through drew it off-screen
            // and blended it back on every frame of a scroll.
            TweenAnimationBuilder<double>(
              tween: Tween(end: visible ? 0 : .6),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 150),
              // Only an example: nothing on it can be tapped or read aloud.
              child: IgnorePointer(
                child: ExcludeSemantics(child: card ?? const SizedBox.shrink()),
              ),
              builder: (context, veil, child) => veil == 0
                  ? child!
                  : DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        color: theme.scaffoldBackgroundColor.withValues(
                          alpha: veil,
                        ),
                        borderRadius: BorderRadius.circular(appCardRadius),
                      ),
                      child: child,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
