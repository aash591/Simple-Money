import 'package:flutter/material.dart';

import '../../../domain/account_place.dart';
import '../../../state/account_store.dart';
import '../../components/common.dart';
import '../../components/empty_art.dart';
import '../../components/feature_page.dart';
import '../../theme/app_theme.dart' show usesGlass;
import 'add_broker_screen.dart';

/// First step of adding an investment account: where the investments are
/// held (see [AccountPlace]). Then that place's own details form. Pops with
/// the new account's id once it is saved.
///
/// Every place in [AccountPlace.selectable] appears here; each needs its own
/// details form in [_open].
class SelectPlaceScreen extends StatelessWidget {
  const SelectPlaceScreen({super.key, required this.accounts});
  final AccountStore accounts;

  Future<void> _open(BuildContext context, AccountPlace place) async {
    final id = await switch (place) {
      AccountPlace.broker => Navigator.of(
        context,
      ).push(FeatureRoute<int>(AddBrokerScreen(accounts: accounts))),
    };
    if (id != null && context.mounted) Navigator.of(context).pop<int>(id);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return FeaturePage(
      title: 'Account type',
      // The top half introduces the step; the choices start at the middle.
      child: Column(
        children: [
          const Expanded(
            child: StepIntro(
              title: 'Where do you hold it?',
              message: 'Choose where your investments are kept, then add what you own there.',
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 32),
              children: [_choices(context, text, scheme)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _choices(BuildContext context, TextTheme text, ColorScheme scheme) =>
      MoneyCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (final (index, place) in AccountPlace.selectable.indexed) ...[
              if (index > 0)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18),
                  child: Divider(height: 1),
                ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  key: Key('place-${place.name}'),
                  onTap: () => _open(context, place),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        IconTile(place.icon, size: 40),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(place.label, style: text.titleMedium),
                              const SizedBox(height: 2),
                              Text(
                                place.description,
                                style: text.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
}

/// The top half of a choice screen: the artwork the Portfolio's empty page uses,
/// and one line on what this step is for.
class StepIntro extends StatelessWidget {
  const StepIntro({super.key, required this.title, required this.message});
  final String title, message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final art = usesGlass(context)
        ? const EmptyArtwork(EmptyArt.chart, size: 112)
        : const GlassLens(
            size: 112,
            child: EmptyArtwork(EmptyArt.chart, size: 60),
          );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            art,
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
