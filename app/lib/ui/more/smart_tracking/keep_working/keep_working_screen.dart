import 'package:flutter/material.dart';

import '../../../../data/keep_alive_platform.dart';
import '../../../../data/keep_alive_phones.dart';
import '../../../components/card_action.dart';
import '../../../components/feature_page.dart';
import '../../../components/info_guide.dart';
import '../../../components/menu_list.dart';
import 'keep_working_guide.dart';

/// Smart tracking › Keep it working: the settings that stop Android, and the
/// phone maker's own battery manager, from putting SimpleMoney to sleep,
/// which would stop bank messages arriving. Steps still to do come first,
/// each with one button that opens the page that fixes it; finished ones
/// follow. What an app can't read is marked done by the user. The ⓘ page
/// says where each setting is on this phone.
class KeepWorkingScreen extends StatefulWidget {
  const KeepWorkingScreen({super.key, this.platform});

  /// Replaced in tests.
  final KeepAlivePlatform? platform;

  @override
  State<KeepWorkingScreen> createState() => _KeepWorkingScreenState();
}

class _KeepWorkingScreenState extends State<KeepWorkingScreen>
    with WidgetsBindingObserver {
  late final KeepAlivePlatform _platform =
      widget.platform ?? KeepAlivePlatform();
  KeepAliveState? _state;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Android's settings, a step may now be done.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final state = await _platform.state();
      if (mounted) {
        setState(() {
          _state = state;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t check your settings.');
    }
  }

  Future<void> _open(String id) async {
    try {
      await _platform.open(id);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t open Android settings.');
    }
  }

  Future<void> _confirm(String id, bool done) async {
    await _platform.setConfirmed(id, done);
    await _load();
  }

  static const _icons = {
    'battery': Icons.battery_charging_full_rounded,
    'background': Icons.sync_rounded,
    'access': Icons.lock_open_rounded,
    'autostart': Icons.rocket_launch_rounded,
  };

  /// A step still to do: a filled tile, and its one action as a pill.
  Widget _openRow(ThemeData theme, KeepStep step) => MenuRow(
    icon: _icons[step.id] ?? Icons.tune_rounded,
    title: step.title,
    subtitle: step.todo,
    highlight: true,
    onTap: () => _open(step.id),
    trailing: CardAction(
      label: step.id == 'battery' ? 'Allow' : 'Open',
      icon: step.id == 'battery'
          ? Icons.check_rounded
          : Icons.open_in_new_rounded,
      color: theme.colorScheme.primary,
      onTap: () => _open(step.id),
    ),
  );

  /// For what the phone can't say, or says differently from its maker's own
  /// switch: a plain button for the user's word that it is done. It sits
  /// under the step's text.
  Widget _confirmButton(ThemeData theme, KeepStep step) => Padding(
    // Level with the step's text: past its icon tile.
    padding: const EdgeInsets.only(left: 70, right: 16, bottom: 14),
    child: Align(
      alignment: Alignment.centerLeft,
      child: CardAction(
        key: Key('confirm-${step.id}'),
        label: 'I’ve done this',
        icon: Icons.check_rounded,
        color: theme.colorScheme.onSurfaceVariant,
        onTap: () => _confirm(step.id, true),
      ),
    ),
  );

  Widget _doneRow(ThemeData theme, KeepStatus status) => MenuRow(
    icon: _icons[status.step.id] ?? Icons.tune_rounded,
    title: status.step.title,
    subtitle: status.byUser ? 'Done · you said so' : 'Done',
    onTap: () => _open(status.step.id),
    trailing: status.byUser
        ? CardAction(
            key: Key('undo-${status.step.id}'),
            label: 'Undo',
            icon: Icons.undo_rounded,
            color: theme.colorScheme.onSurfaceVariant,
            outlined: true,
            onTap: () => _confirm(status.step.id, false),
          )
        : Icon(
            Icons.check_circle_rounded,
            size: 22,
            color: Colors.green.shade600,
          ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _state;
    final left = state?.left ?? 0;
    final todo = [
      for (final s in state?.steps ?? const <KeepStatus>[])
        if (!s.done) s,
    ];
    final done = [
      for (final s in state?.steps ?? const <KeepStatus>[])
        if (s.done) s,
    ];
    return FeaturePage(
      title: 'Keep it working',
      actions: [
        if (state != null)
          InfoGuideButton(
            keepWorkingGuideFor(
              state.family,
              access: state.steps.any((s) => s.step.id == 'access'),
            ),
          ),
      ],
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
                child: Text(
                  state == null
                      ? 'Android stops apps that run in the background, and '
                            'then transactions stop arriving.'
                      : left == 0
                      ? 'All set. Android will keep SimpleMoney running.'
                      : 'Android stops apps that run in the background, and '
                            'then transactions stop arriving. '
                            '$left ${left == 1 ? 'step' : 'steps'} left.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
                  child: Text(_error!, style: theme.textTheme.bodyMedium),
                ),
              if (todo.isNotEmpty) ...[
                MenuGroup(
                  label: 'To do',
                  children: [
                    // One block per step, so the button isn't split from it
                    // by the group's divider.
                    for (final s in todo)
                      Column(
                        children: [
                          _openRow(theme, s.step),
                          if (s.confirmable) _confirmButton(theme, s.step),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
              if (done.isNotEmpty)
                MenuGroup(
                  label: 'Done',
                  children: [for (final s in done) _doneRow(theme, s)],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
