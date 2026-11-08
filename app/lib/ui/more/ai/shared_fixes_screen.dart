import 'package:flutter/material.dart';

import '../../../data/community/community_fixes.dart';
import '../../components/common.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';

/// Fixes other people shared, in use on this phone. One that reads messages
/// wrong can be turned off, which also tells the server.
class SharedFixesScreen extends StatefulWidget {
  const SharedFixesScreen({
    super.key,
    required this.community,
    this.onRulesChanged,
  });
  final CommunitySync community;

  /// Reads the inbox again after a shared SMS format was turned off or on.
  final VoidCallback? onRulesChanged;

  @override
  State<SharedFixesScreen> createState() => _SharedFixesScreenState();
}

class _SharedFixesScreenState extends State<SharedFixesScreen> {
  List<CommunityFix>? _fixes;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<CommunityFix> fixes;
    try {
      fixes = await widget.community.repository.load(includeOff: true);
    } catch (_) {
      fixes = const [];
    }
    if (mounted) setState(() => _fixes = fixes);
  }

  Future<void> _set(CommunityFix fix, bool on) async {
    setState(() => _busy.add(fix.hash));
    if (on) {
      await widget.community.turnOn(fix.hash);
    } else {
      await widget.community.turnOff(fix.hash);
    }
    if (fix.kind == CommunityKind.smsRule) widget.onRulesChanged?.call();
    await _load();
    if (mounted) setState(() => _busy.remove(fix.hash));
  }

  @override
  Widget build(BuildContext context) =>
      FeaturePage(title: 'Shared fixes', child: _body(context));

  Widget _body(BuildContext context) {
    final fixes = _fixes;
    if (fixes == null) return const Center(child: CircularProgressIndicator());
    if (fixes.isEmpty) {
      return const EmptyState(
        icon: Icons.groups_outlined,
        title: 'Nothing shared yet',
        message: 'Fixes other people share show up here.',
      );
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            'Fixes other people shared. Turn one off if it reads your SMS or statement wrong.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        MoneyCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, fix) in fixes.indexed) ...[
                if (i > 0) const Divider(height: 1, indent: 16),
                SwitchListTile(
                  value: !fix.off,
                  onChanged: _busy.contains(fix.hash)
                      ? null
                      : (on) => _set(fix, on),
                  title: Text(fix.title, maxLines: 2),
                  subtitle: Text(
                    fix.kind == CommunityKind.smsRule
                        ? 'Bank SMS'
                        : 'Statement',
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
