import 'package:flutter/material.dart';

import '../../state/security_controller.dart';

/// Hidden content is absent from rendering, semantics and hit testing.
/// Reveal state is never saved and is cleared when the app leaves foreground.
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
  @override
  State<PrivateAmount> createState() => _PrivateAmountState();
}

class _PrivateAmountState extends State<PrivateAmount>
    with WidgetsBindingObserver {
  bool _visible = false, _pending = false;
  int? _revision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revision = SecurityScope.maybeOf(context)?.amountPrivacyRevision;
    if (_revision != revision) _visible = false;
    _revision = revision;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _visible) {
      setState(() => _visible = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_visible) {
      setState(() => _visible = false);
      return;
    }
    if (_pending) return;
    final security = SecurityScope.maybeOf(context);
    setState(() => _pending = true);
    final allowed = security == null
        ? true
        : await security.authorizeAmountReveal();
    if (!mounted) return;
    setState(() {
      _pending = false;
      _revision = security?.amountPrivacyRevision;
      _visible = allowed;
    });
    if (!allowed && security.error != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(security.error!)));
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
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
              child: _visible
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
                '${_visible ? 'Hide' : 'Show'} ${widget.label.toLowerCase()}',
            onPressed: _pending ? null : _toggle,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: Icon(
              _visible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 16,
            ),
          ),
        ],
      ),
    ),
  );
}
