import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../state/home_layout.dart';
import '../components/common.dart';
import '../components/feature_page.dart';
import '../components/more_popup_button.dart';
import 'home_card_preview.dart';

/// Arranges Home: drag a card to move it, switch it off to hide it.
class HomeLayoutScreen extends StatelessWidget {
  const HomeLayoutScreen({super.key, required this.layout});
  final HomeLayout layout;

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
    child: ListenableBuilder(
      listenable: layout,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        final order = layout.order;
        return ReorderableListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
          buildDefaultDragHandles: false,
          header: Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${layout.visible.length} of ${order.length} shown',
                    style: text.bodySmall,
                  ),
                ),
                Text('Drag to reorder', style: text.bodySmall),
              ],
            ),
          ),
          footer: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Empty cards hide themselves. Upcoming payments show only when due, loan payoff only while a loan is open.',
              style: text.bodySmall,
            ),
          ),
          proxyDecorator: (child, index, animation) =>
              Material(color: Colors.transparent, elevation: 0, child: child),
          itemCount: order.length,
          onReorderItem: layout.move,
          itemBuilder: (context, index) => Padding(
            key: ValueKey(order[index]),
            padding: const EdgeInsets.only(bottom: 12),
            child: _CardRow(layout: layout, index: index),
          ),
        );
      },
    ),
  );
}

class _CardRow extends StatelessWidget {
  const _CardRow({required this.layout, required this.index});
  final HomeLayout layout;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = layout.order;
    final id = order[index];
    final visible = layout.isVisible(id);
    final muted = theme.colorScheme.onSurfaceVariant;
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: Semantics(
                    label: 'Reorder ${id.label}',
                    customSemanticsActions: {
                      if (index > 0)
                        const CustomSemanticsAction(label: 'Move up'): () =>
                            layout.move(index, index - 1),
                      if (index < order.length - 1)
                        const CustomSemanticsAction(label: 'Move down'): () =>
                            layout.move(index, index + 1),
                    },
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.drag_indicator_rounded, color: muted),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(id.label, style: theme.textTheme.titleSmall),
                ),
                const SizedBox(width: 8),
                Semantics(
                  label: 'Show ${id.label} on Home',
                  child: Switch.adaptive(
                    value: visible,
                    onChanged: (value) => layout.setVisible(id, value),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          AnimatedOpacity(
            opacity: visible ? 1 : .4,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: HomeCardPreview(id: id),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Text(
              visible ? 'Example preview' : 'Hidden on Home ? example preview',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
