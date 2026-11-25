import 'package:flutter/material.dart';

import '../../../../data/keep_alive_platform.dart';
import '../../../components/feature_page.dart';
import '../../../components/menu_list.dart';
import 'keep_working_screen.dart';

/// The Keep it working card on Smart tracking: how many Android settings are
/// still to do, so tracking is not stopped in the background. It tells its
/// screen the count, so the card can sit at the top while there is something
/// to do and drop to the bottom once everything is done.
class KeepWorkingCard extends StatefulWidget {
  const KeepWorkingCard({super.key, this.platform, this.onLeftChanged});

  /// Replaced in tests.
  final KeepAlivePlatform? platform;

  /// Steps still to do, each time the phone's settings are read.
  final ValueChanged<int>? onLeftChanged;

  @override
  State<KeepWorkingCard> createState() => _KeepWorkingCardState();
}

class _KeepWorkingCardState extends State<KeepWorkingCard>
    with WidgetsBindingObserver {
  late final KeepAlivePlatform _platform =
      widget.platform ?? KeepAlivePlatform();
  KeepAliveState? _state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final state = await _platform.state();
      if (!mounted) return;
      setState(() => _state = state);
      widget.onLeftChanged?.call(state.left);
    } catch (_) {
      /* Keep the plain card. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = _state?.left ?? 0;
    return MenuGroup(
      children: [
        MenuRow(
          icon: Icons.bolt_rounded,
          title: 'Keep it working',
          subtitle: _state != null && left == 0
              ? 'All set. Android will keep tracking running'
              : 'Stop Android from pausing your tracking',
          trailing: left > 0
              ? Text(
                  '$left left',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              : null,
          onTap: () async {
            await Navigator.of(context).push(
              FeatureRoute<void>(KeepWorkingScreen(platform: widget.platform)),
            );
            await _refresh();
          },
        ),
      ],
    );
  }
}
