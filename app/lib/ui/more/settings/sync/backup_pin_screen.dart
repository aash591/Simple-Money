import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../data/backup/backup_encryption.dart';
import '../../../components/action_buttons.dart';
import '../../../components/app_back_button.dart';
import '../../../components/feature_page.dart';
import '../../../welcome/privacy_card.dart';

/// [join]: entering the PIN the account's other phones already use.
enum BackupPinPurpose { enable, unlock, disable, join }

/// Opens the backup PIN flow as a full screen and returns whether it
/// finished. Used from Settings, while restoring, and in first-time setup.
Future<bool> showBackupPinFlow(
  BuildContext context, {
  required BackupPinPurpose purpose,
  required Future<void> Function(String pin) onSubmit,

  /// Offers "Not now" on the first step, for a flow that is optional.
  bool optional = false,
}) async =>
    await Navigator.of(context).push<bool>(
      FeatureRoute<bool>(
        BackupPinScreen(
          purpose: purpose,
          onSubmit: onSubmit,
          optional: optional,
        ),
      ),
    ) ??
    false;

enum _Step { intro, choose, confirm }

/// Setting a backup PIN takes three short steps (why, choose, confirm);
/// entering or removing one is a single step.
class BackupPinScreen extends StatefulWidget {
  const BackupPinScreen({
    super.key,
    required this.purpose,
    required this.onSubmit,
    this.optional = false,
  });
  final BackupPinPurpose purpose;
  final Future<void> Function(String pin) onSubmit;
  final bool optional;

  @override
  State<BackupPinScreen> createState() => _BackupPinScreenState();
}

class _BackupPinScreenState extends State<BackupPinScreen> {
  final _pin = TextEditingController();
  final _confirmation = TextEditingController();
  bool _remembered = false, _visible = false, _busy = false;
  String? _error;
  late _Step _step = _setup ? _Step.intro : _Step.choose;

  bool get _setup => widget.purpose == BackupPinPurpose.enable;
  bool get _pinValid => BackupEncryption.validPin(_pin.text);
  bool get _mismatch =>
      _confirmation.text.length == 6 && _confirmation.text != _pin.text;
  bool get _canFinish =>
      _pinValid &&
      (!_setup || (_confirmation.text == _pin.text && _remembered));

  void _go(_Step step) => setState(() {
    _step = step;
    _error = null;
  });

  void _back() {
    if (_busy) return;
    if (_step == _Step.confirm) {
      _confirmation.clear();
      _remembered = false;
      _go(_Step.choose);
    } else if (_step == _Step.choose && _setup) {
      _go(_Step.intro);
    } else {
      Navigator.pop(context, false);
    }
  }

  Future<void> _submit() async {
    if (_busy || !_canFinish) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_pin.text);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (error) {
          BackupEncryptionException(:final message) => message,
          StateError(:final message) => message,
          _ => 'Could not complete this step. Your data is safe on this phone. Try again.',
        };
      });
    }
  }

  @override
  void dispose() {
    _pin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  bool get _first => _step == (_setup ? _Step.intro : _Step.choose);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = _page(theme);
    return PopScope(
      canPop: !_busy && _first,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      // The same page as the first-run setup: a soft wash of the accent at
      // the top, step dots, a picture, centred words and one wide button.
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.center,
              colors: [
                theme.colorScheme.primary.withValues(alpha: .1),
                theme.scaffoldBackgroundColor,
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  children: [
                    _header(),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 200),
                        child: KeyedSubtree(
                          key: ValueKey(_step),
                          child: LayoutBuilder(
                            builder: (context, box) => SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: box.maxHeight,
                                ),
                                child: Align(
                                  alignment: const Alignment(0, -1),
                                  child: page.content,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: page.action,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Step dots in the middle, the back arrow at the left (a cross on the
  /// first step), and Not now at the right when setup is optional.
  Widget _header() => SizedBox(
    height: 64,
    child: Stack(
      alignment: Alignment.center,
      children: [
        if (_setup) _Dots(index: _step.index, count: 3),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: AppBackButton(
              close: _first,
              onPressed: _busy ? null : _back,
            ),
          ),
        ),
        if (_setup && widget.optional && _step == _Step.intro)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now'),
              ),
            ),
          ),
      ],
    ),
  );

  ({Widget content, Widget action}) _page(ThemeData theme) {
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget content({
      required IconData icon,
      required String title,
      required String message,
      List<Widget> body = const [],
    }) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HeroSlot(child: RoundIcon(icon)),
        const SizedBox(height: 24),
        Text(title, textAlign: TextAlign.center, style: text.headlineMedium),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: muted, height: 1.5),
        ),
        if (body.isNotEmpty) const SizedBox(height: 24),
        ...body,
        const SizedBox(height: 16),
      ],
    );

    switch (_step) {
      case _Step.intro:
        return (
          content: content(
            icon: Icons.lock_outline_rounded,
            title: 'Protect your Drive backups',
            message: 'Add a PIN so only you can open your backups, even in your own Google Drive.',
            body: const [
              PrivacyCard(
                title: 'Good to know',
                points: [
                  'Backups are encrypted with your PIN before they leave this phone',
                  'You will enter it when signing in again or restoring on a new phone',
                  'SimpleMoney never sees your PIN and cannot recover it. If it is lost, those backups stay locked',
                ],
              ),
            ],
          ),
          action: PillButton(
            label: 'Continue',
            onPressed: () => _go(_Step.choose),
          ),
        );
      case _Step.choose:
        final title = switch (widget.purpose) {
          BackupPinPurpose.enable => 'Choose a backup PIN',
          BackupPinPurpose.unlock => 'Enter your backup PIN',
          BackupPinPurpose.disable => 'Turn off backup encryption?',
          BackupPinPurpose.join => 'Enter your other phone\'s PIN',
        };
        final message = switch (widget.purpose) {
          BackupPinPurpose.enable => '6 letters or numbers, and case-sensitive. A mix of both is harder to guess.',
          BackupPinPurpose.unlock => 'Use the PIN you chose for this backup. If you forgot it, data already on your phone stays available, but this encrypted backup cannot be restored.',
          BackupPinPurpose.disable => 'Enter your current PIN. Your synced data on Google Drive will no longer be encrypted, from this phone and your other phones.',
          BackupPinPurpose.join => 'Your other phone keeps synced data locked with a PIN. Enter the same PIN to sync with it again.',
        };
        return (
          content: content(
            icon: _setup ? Icons.pin_outlined : Icons.key_rounded,
            title: title,
            message: message,
            body: [
              _PinBoxes(
                controller: _pin,
                visible: _visible,
                enabled: !_busy,
                autofocus: true,
                label: 'Backup PIN',
                onChanged: () => setState(() => _error = null),
                onSubmitted: () {
                  if (!_setup) {
                    _submit();
                  } else if (_pinValid) {
                    _go(_Step.confirm);
                  }
                },
                onToggle: () => setState(() => _visible = !_visible),
              ),
            ],
          ),
          action: PillButton(
            label: _setup
                ? 'Continue'
                : _busy
                ? 'Please wait…'
                : switch (widget.purpose) {
                    BackupPinPurpose.unlock => 'Unlock backup',
                    BackupPinPurpose.join => 'Unlock sync',
                    _ => 'Turn off encryption',
                  },
            loading: _busy,
            onPressed: _setup
                ? (_pinValid ? () => _go(_Step.confirm) : null)
                : (_canFinish && !_busy ? _submit : null),
          ),
        );
      case _Step.confirm:
        return (
          content: content(
            icon: Icons.verified_user_outlined,
            title: 'Confirm your PIN',
            message:
                'Enter it once more so a typo does not lock you out later.',
            body: [
              _PinBoxes(
                controller: _confirmation,
                visible: _visible,
                enabled: !_busy,
                autofocus: true,
                label: 'Confirm PIN',
                onChanged: () => setState(() => _error = null),
                onSubmitted: _submit,
                onToggle: () => setState(() => _visible = !_visible),
              ),
              if (_mismatch) ...[
                const SizedBox(height: 10),
                Text(
                  'The PINs do not match.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 18),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _remembered,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _remembered = value == true),
                title: const Text(
                  'I have saved my PIN and understand it cannot be recovered.',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Your synced data on Google Drive is encrypted from now on. Your other phones will ask for this PIN once.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
          action: PillButton(
            label: _busy ? 'Please wait…' : 'Turn on encryption',
            loading: _busy,
            onPressed: _canFinish && !_busy ? _submit : null,
          ),
        );
    }
  }
}

/// Step dots, drawn as the first-run setup draws them.
class _Dots extends StatelessWidget {
  const _Dots({required this.index, required this.count});
  final int index, count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Step ${index + 1} of $count',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: i == index ? 18 : 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: i == index
                    ? colors.primary
                    : colors.onSurface.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}

/// Six boxes filled as the PIN is typed. A real, invisible text field sits
/// over them, so the keyboard, paste and accessibility work as usual.
class _PinBoxes extends StatelessWidget {
  const _PinBoxes({
    required this.controller,
    required this.visible,
    required this.enabled,
    required this.autofocus,
    required this.label,
    required this.onChanged,
    required this.onSubmitted,
    required this.onToggle,
  });
  final TextEditingController controller;
  final bool visible, enabled, autofocus;
  final String label;
  final VoidCallback onChanged, onToggle, onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final value = controller.text;
            return SizedBox(
              height: 56,
              child: Stack(
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < 6; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: scheme.onSurface.withValues(alpha: .06),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: i == value.length && enabled
                                    ? scheme.primary
                                    : scheme.onSurface.withValues(alpha: .12),
                                width: i == value.length && enabled ? 2 : 1,
                              ),
                            ),
                            child: Text(
                              i < value.length
                                  ? (visible ? value[i] : '•')
                                  : '',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Positioned.fill(
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      autofocus: autofocus,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      keyboardType: TextInputType.visiblePassword,
                      textCapitalization: TextCapitalization.none,
                      maxLength: 6,
                      showCursor: false,
                      enableInteractiveSelection: false,
                      style: const TextStyle(color: Colors.transparent),
                      cursorColor: Colors.transparent,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp('[a-zA-Z0-9]'),
                        ),
                      ],
                      onChanged: (_) => onChanged(),
                      onSubmitted: (_) => onSubmitted(),
                      decoration: InputDecoration(
                        counterText: '',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        fillColor: Colors.transparent,
                        filled: false,
                        semanticCounterText: '${value.length} of 6',
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: enabled ? onToggle : null,
            icon: Icon(
              visible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 18,
            ),
            label: Text(visible ? 'Hide PIN' : 'Show PIN'),
          ),
        ),
      ],
    );
  }
}
