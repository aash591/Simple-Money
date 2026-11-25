import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../data/agent/ai_session.dart';
import '../../components/action_buttons.dart';
import '../../components/app_toast.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/feature_page.dart';
import '../../components/info_guide.dart';
import '../../components/segmented_pill.dart';
import '../../components/text_entry_alert.dart';
import 'ai_assistant_guide.dart';
import '../pro/pro_screen.dart';
import '../../../state/pro_controller.dart';

/// Connect Claude or ChatGPT, run a timed AI session and see connected apps.
/// What they suggest is reviewed from More › AI suggestions.
class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({super.key, required this.controller});
  final AiSessionController controller;

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen>
    with WidgetsBindingObserver {
  AiSessionController get _ai => widget.controller;

  /// Showing how to add an app: when there are none, or one is being added.
  bool get _settingUp =>
      _adding || _ai.connections.isEmpty || _ai.pairing != null;
  int _minutes = 30;
  Timer? _tick;
  bool _busy = false;
  bool _adding = false;
  String? _error;

  /// Shown under Get pairing code, where the user is looking.
  String? _pairError;
  bool _pairBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ai.refreshConnections();
    _ai.refreshSuggestions();
    // Counts down the pairing code and the session.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    super.dispose();
  }

  /// Back from Claude or ChatGPT: the code may just have been used.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _ai.refreshConnections();
  }

  Future<void> _do(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = e is AiRelayException
          ? e.message
          : 'Something went wrong. Try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _editRelay() async {
    final value = await showTextEntryAlert(
      context,
      title: 'Relay address',
      message: 'The https:// address Claude and ChatGPT connect through.',
      initialValue: _ai.relayUrl ?? '',
      hintText: 'https://simplemoney-ai-relay.you.workers.dev',
      maxLength: 200,
      keyboardType: TextInputType.url,
      allowEmpty: true,
    );
    if (value == null || !mounted) return;
    if (_ai.relayUrl != null &&
        _ai.connections.isNotEmpty &&
        !await showConfirmationAlert(
          context,
          title: 'Change relay?',
          message: 'Connected AI apps will need to be added again.',
          confirmLabel: 'Change',
        )) {
      return;
    }
    await _do(() => _ai.setRelayUrl(value));
  }

  Future<void> _copy(String text, {String label = 'Copied'}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showAppToast(context, label, icon: Icons.copy_rounded);
  }

  Future<void> _getPairingCode() async {
    if (_pairBusy) return;
    setState(() {
      _pairBusy = true;
      _pairError = null;
    });
    try {
      // Copied straight away, so a paste in Claude or ChatGPT gets this code.
      final pairing = await _ai.pairingCode();
      await Clipboard.setData(ClipboardData(text: pairing.code));
      // An app that signs in asks for data right away, so a session must be
      // on; users rarely think to tap Start first.
      final started = _ai.status == AiSessionStatus.off;
      if (started) await _ai.start(Duration(minutes: _minutes));
      if (mounted) {
        showAppToast(
          context,
          started ? 'Code copied · session started' : 'Code copied',
          icon: Icons.copy_rounded,
        );
      }
    } catch (e) {
      _pairError = e is AiRelayException
          ? e.message
          : 'Couldn’t get a code. Check your internet and try again.';
    }
    if (mounted) setState(() => _pairBusy = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _ai,
    builder: (context, _) => FeaturePage(
      title: 'Claude / ChatGPT',
      actions: const [InfoGuideButton(aiAssistantGuide)],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
        children: [
          ListenableBuilder(
            listenable: ProController.instance,
            builder: (context, _) => ProController.instance.aiUnlocked
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: appCardGap),
                    child: _proNote(context),
                  ),
          ),
          if (_ai.relayUrl == null)
            _noRelay(context)
          else ...[
            // The blocks in the order they're used. While connecting, each
            // step is numbered, with its title outside above it.
            if (_settingUp) ...[
              _stepLabel(1, 'Add SimpleMoney in Claude or ChatGPT'),
              _address(context),
              const SizedBox(height: appCardGap + 6),
              _stepLabel(2, 'When it asks for a code, come back and tap'),
            ],
            _apps(context),
            SizedBox(height: appCardGap + (_settingUp ? 6 : 0)),
            if (_settingUp) _stepLabel(3, 'Start a session, then ask away'),
            MoneyCard(child: _session(context)),
          ],
          if (_error ?? _ai.error case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  /// What's free and what Pro adds, for someone without Pro.
  Widget _proNote(BuildContext context) {
    final theme = Theme.of(context);
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(appCardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () =>
              Navigator.of(context).push(FeatureRoute<void>(const ProScreen())),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
            child: Row(
              children: [
                const IconTile(Icons.workspace_premium_rounded, size: 38),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Questions and fixes are Pro',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      _muted(
                        context,
                        'Teaching SimpleMoney a new bank SMS or statement is '
                        'free.',
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _noRelay(BuildContext context) => MoneyCard(
    child: Column(
      children: [
        const AiLogos(size: 48),
        const SizedBox(height: 14),
        Text(
          'Connect a relay first',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        _muted(context, 'Claude and ChatGPT connect through it.', center: true),
        const SizedBox(height: 16),
        PillButton(label: 'Enter relay address', onPressed: _editRelay),
      ],
    ),
  );

  Widget _session(BuildContext context) {
    final theme = Theme.of(context);
    final on = _ai.status != AiSessionStatus.off;
    final live = _ai.status == AiSessionStatus.live;
    final left = _ai.endsAt?.difference(DateTime.now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const AiLogos(size: 34),
            const Spacer(),
            _Status(
              color: live
                  ? Colors.green
                  : on
                  ? Colors.orange
                  : theme.colorScheme.onSurfaceVariant,
              label: live
                  ? 'Live'
                  : on
                  ? 'Connecting…'
                  : 'Off',
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (on) ...[
          Text(
            left == null || left.isNegative
                ? 'Ending…'
                : '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          _muted(
            context,
            'left · until ${DateFormat.jm().format(_ai.endsAt!)}',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: PillButton(
                  label: 'Stop',
                  primary: false,
                  onPressed: () => _do(_ai.stop),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PillButton(label: '+15 min', onPressed: _ai.extend),
              ),
            ],
          ),
        ] else ...[
          Text(
            'Start a session',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          _muted(context, 'The AI can help only while it’s on.'),
          const SizedBox(height: 14),
          SegmentedPill<int>(
            segments: const [
              PillSegment(15, '15 min'),
              PillSegment(30, '30 min'),
              PillSegment(60, '1 hour'),
            ],
            value: _minutes,
            onChanged: (m) => setState(() => _minutes = m),
          ),
          const SizedBox(height: 12),
          PillButton(
            label: 'Start',
            loading: _busy,
            onPressed: () => _do(() => _ai.start(Duration(minutes: _minutes))),
          ),
        ],
      ],
    );
  }

  /// A step's title, outside and above its block.
  Widget _stepLabel(int number, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: _Step(number, text),
  );

  /// Step 1: the address to add in Claude or ChatGPT.
  Widget _address(BuildContext context) {
    final theme = Theme.of(context);
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(appCardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _copy(_ai.connectorUrl!),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _ai.connectorUrl!.replaceFirst('https://', ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.copy_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                  semanticLabel: 'Copy address',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Connected apps, and how to add one: open by itself when there are none.
  Widget _apps(BuildContext context) {
    final theme = Theme.of(context);
    final apps = _ai.connections;
    final adding = _settingUp;
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (apps.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Connected apps',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  onPressed: _ai.refreshConnections,
                ),
              ],
            ),
          for (final c in apps)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  AiAppLogo(c.clientName, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.clientName, style: theme.textTheme.titleSmall),
                        _muted(
                          context,
                          '${c.canSuggest ? 'Can suggest' : 'Read only'} · '
                          '${_lastUsed(c.lastUsedAt)}',
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Disconnect ${c.clientName}',
                    color: theme.colorScheme.error,
                    icon: const Icon(Icons.link_off_rounded),
                    onPressed: _busy ? null : () => _disconnect(c),
                  ),
                ],
              ),
            ),
          if (adding) ...[
            if (apps.isNotEmpty) const Divider(height: 28),
            _addApp(context),
          ] else ...[
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => _adding = true),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Connect another'),
                ),
                const Spacer(),
                if (apps.length > 1)
                  TextButton(
                    onPressed: _busy ? null : _disconnectAll,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    child: const Text('Disconnect all'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _addApp(BuildContext context) {
    final theme = Theme.of(context);
    final pairing = _ai.pairing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_ai.pairedAt case final at?
            when pairing == null &&
                DateTime.now().difference(at) < const Duration(minutes: 2))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: Colors.green,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: _muted(
                    context,
                    'Connected. It shows up here in a minute.',
                  ),
                ),
              ],
            ),
          ),
        if (pairing == null) ...[
          PillButton(
            label: 'Get pairing code',
            primary: false,
            loading: _pairBusy,
            onPressed: _getPairingCode,
          ),
          if (_pairError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ),
        ] else
          Material(
            color: theme.colorScheme.primary.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _copy(pairing.code, label: 'Code copied'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${pairing.code.substring(0, 3)} ${pairing.code.substring(3)}',
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: 4,
                          ),
                          semanticsLabel: pairing.code.split('').join(' '),
                        ),
                        const SizedBox(width: 10),
                        Icon(
                          Icons.copy_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                          semanticLabel: 'Copy code',
                        ),
                      ],
                    ),
                    _muted(
                      context,
                      'Copied. Paste it now · '
                      '${pairing.expiresAt.difference(DateTime.now()).inSeconds ~/ 60 + 1} min left',
                      center: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        Center(
          child: TextButton(
            onPressed: () => openInfoGuide(context, aiAssistantGuide),
            child: const Text('How to connect'),
          ),
        ),
      ],
    );
  }

  /// How long an app has been quiet: a removed one goes stale here.
  static String _lastUsed(DateTime? at) {
    if (at == null) return 'Not used yet';
    final ago = DateTime.now().difference(at);
    if (ago.inMinutes < 2) return 'Used just now';
    if (ago.inHours < 1) return 'Used ${ago.inMinutes} min ago';
    if (ago.inDays < 1) return 'Used ${ago.inHours} h ago';
    if (ago.inDays == 1) return 'Used yesterday';
    return 'Not used in ${ago.inDays} days';
  }

  Future<void> _disconnect(AiConnection c) async {
    if (await showConfirmationAlert(
      context,
      title: 'Disconnect ${c.clientName}?',
      message: 'You can connect it again anytime.',
      confirmLabel: 'Disconnect',
    )) {
      await _do(() => _ai.disconnect(c));
    }
  }

  Future<void> _disconnectAll() async {
    if (await showConfirmationAlert(
      context,
      title: 'Disconnect all apps?',
      message: 'All AI apps will be signed out.',
      confirmLabel: 'Disconnect all',
    )) {
      await _do(_ai.disconnectAll);
    }
  }

  static Widget _muted(
    BuildContext context,
    String text, {
    bool center = false,
  }) => Text(
    text,
    textAlign: center ? TextAlign.center : null,
    style: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
  );
}

class _Status extends StatelessWidget {
  const _Status({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);
  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: theme.colorScheme.primary.withValues(alpha: .12),
          child: Text(
            '$number',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}
