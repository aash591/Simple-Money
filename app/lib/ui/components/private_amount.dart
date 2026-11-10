import 'package:flutter/material.dart';

import '../../state/security_controller.dart';

/// Hidden content is absent from rendering, semantics and hit testing.
///
/// Revealing is shared across the whole app: once an amount is shown (after
/// whatever the Security settings ask for), every amount stays shown until
/// one is hidden again, the privacy settings change, or the app leaves the
/// foreground. It is never saved.
class PrivateAmount extends StatefulWidget {
  const PrivateAmount({
    super.key,
    required this.label,
    required this.child,
    this.maskStyle,
    this.height = 40,
  });
  final String label;
  final Widget child;
  final TextStyle? maskStyle;
  final double height;

  static DateTime? _revealedAt;

  /// True for a moment after the eye was pressed to show amounts, so an
  /// amount that appears then can roll into view, and one that appears for
  /// any other reason (a new account, a refresh) just shows.
  static bool get justRevealed =>
      _revealedAt != null &&
      DateTime.now().difference(_revealedAt!) < const Duration(seconds: 1);

  @override
  State<PrivateAmount> createState() => _PrivateAmountState();
}

class _PrivateAmountState extends State<PrivateAmount>
    with WidgetsBindingObserver {
  /// Whether amounts are shown, for every [PrivateAmount] at once.
  static final _shown = ValueNotifier<bool>(false);
  static int? _sharedRevision;
  static int _mounted = 0;

  bool _pending = false;

  @override
  void initState() {
    super.initState();
    _mounted++;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revision = SecurityScope.maybeOf(context)?.amountPrivacyRevision;
    // A change to the privacy settings hides everything again.
    if (_sharedRevision != null && _sharedRevision != revision) {
      _hideAll();
    }
    _sharedRevision = revision;
  }

  /// Setting a notifier mid-build would rebuild its listeners then, so wait
  /// for the frame to end.
  void _hideAll() {
    if (!_shown.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _shown.value = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _shown.value = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // With no amount left on screen anywhere, nothing stays revealed.
    if (--_mounted == 0) {
      _shown.value = false;
      _sharedRevision = null;
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_shown.value) {
      _shown.value = false;
      return;
    }
    if (_pending) return;
    final security = SecurityScope.maybeOf(context);
    setState(() => _pending = true);
    final allowed = security == null
        ? true
        : await security.authorizeAmountReveal();
    if (!mounted) return;
    setState(() => _pending = false);
    _sharedRevision = security?.amountPrivacyRevision;
    if (allowed) PrivateAmount._revealedAt = DateTime.now();
    _shown.value = allowed;
    if (!allowed && security.error != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(security.error!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    // With hiding turned off in Security, amounts are plain: no dots, no eye.
    if (SecurityScope.maybeOf(context)?.hideAmounts == false) {
      return SizedBox(
        height: widget.height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: widget.child,
          ),
        ),
      );
    }
    return _masked(context);
  }

  Widget _masked(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _shown,
    builder: (context, visible, _) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _pending ? () {} : _toggle,
      child: SizedBox(
        height: widget.height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: visible
                    ? widget.child
                    : Text(
                        '\u2022\u2022\u2022\u2022\u2022\u2022',
                        maxLines: 1,
                        semanticsLabel: 'Amount hidden',
                        style:
                            widget.maskStyle ??
                            Theme.of(context).textTheme.headlineSmall,
                      ),
              ),
            ),
            IconButton(
              tooltip:
                  '${visible ? 'Hide' : 'Show'} ${widget.label.toLowerCase()}',
              onPressed: _pending ? null : _toggle,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(
                visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 16,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
