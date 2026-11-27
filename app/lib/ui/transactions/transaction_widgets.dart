import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/app_typography.dart';

import 'package:intl/intl.dart' hide TextDirection;

import '../../domain/account.dart';
import '../components/adaptive_sheet.dart';
import '../components/app_icon.dart';
import '../components/modal_transition.dart';
import '../theme/sheet_colors.dart';

/// "Mar 18, 2026".
String formatTransactionDate(DateTime date) =>
    DateFormat('MMM d, yyyy').format(date);

/// The note shown under an account's name on a saved transaction when that
/// account is no longer in use — "Archived on Mar 18, 2026". Null while the
/// account is still active, or unknown, which the row already says in its
/// value. It is worth saying on the entry itself: the account is gone from
/// every list, so without this its name here looks like a mistake.
String? archivedCaption(Account? account) {
  final at = account?.archivedAt;
  return at == null ? null : 'Archived on ${formatTransactionDate(at)}';
}

/// [minor] as money in [account]'s currency (rupees while none is known).
String formatTransactionMoney(int minor, Account? account) =>
    formatAccountMoney(
      minor,
      digits: account?.digits ?? 2,
      currency: account?.currency ?? 'INR',
    );

/// Units of [to]'s currency per one unit of [from]'s, as "1 SAR = 22.2717 INR".
///
/// Derived from the two amounts a transfer actually moved, so it is the rate
/// that really applied rather than any published one — and, unlike a figure
/// recomputed from today's table, it never changes after the fact. Shown to
/// four decimals with trailing zeroes trimmed: a rate is not an amount, so
/// neither currency's precision governs it.
String formatExchangeRate(
  int fromMinor,
  Account? from,
  int toMinor,
  Account? to,
) {
  final fromUnits = fromMinor / math.pow(10, from?.digits ?? 2);
  final toUnits = toMinor / math.pow(10, to?.digits ?? 2);
  if (fromUnits == 0) return '';
  final text = (toUnits / fromUnits).toStringAsFixed(4);
  final trimmed = text.contains('.')
      ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : text;
  return '1 ${from?.currency ?? 'INR'} = $trimmed ${to?.currency ?? 'INR'}';
}

/// Slides between sheet pages horizontally — a forward page enters from the
/// right while the old one leaves to the left, going back mirrors it — as
/// the sheet's height eases to fit the new page, all in one 350ms motion.
/// There is deliberately no cross-fade. When [modal] is set, the new page
/// instead fades and rises into place — the same settling motion as a
/// freshly opened sheet — used when a tap on a field jumps straight to
/// editing it rather than stepping through the wizard.
class StepSlider extends StatefulWidget {
  const StepSlider({
    super.key,
    required this.stepKey,
    required this.forward,
    required this.child,
    this.modal = false,
  });

  /// Identifies the page [child] shows; changing it starts a slide.
  final Object stepKey;
  final bool forward;
  final Widget child;
  final bool modal;

  @override
  State<StepSlider> createState() => _StepSliderState();
}

class _StepSliderState extends State<StepSlider>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 350);

  late final _controller =
      AnimationController(vsync: this, duration: _duration, value: 1)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && _outgoing != null) {
            setState(() => _outgoing = null);
          }
        });
  late final _sizeProgress = CurvedAnimation(
    parent: _controller,
    curve: Curves.fastOutSlowIn,
  );
  GlobalKey _pageKey = GlobalKey();
  GlobalKey? _outgoingPageKey;
  Widget? _outgoing;
  Object? _outgoingKey;
  var _forward = true;
  var _modal = false;

  /// The height shown when the current step began, which the slide eases
  /// from.
  double? _fromHeight;

  @override
  void didUpdateWidget(StepSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stepKey == widget.stepKey) return;
    _outgoingPageKey = _pageKey;
    _pageKey = GlobalKey();
    if (MediaQuery.disableAnimationsOf(context)) {
      _outgoing = null;
      return;
    }
    _outgoing = oldWidget.child;
    _outgoingKey = oldWidget.stepKey;
    _forward = widget.forward;
    _modal = widget.modal;
    final box = context.findRenderObject();
    _fromHeight = box is RenderBox && box.hasSize ? box.size.height : null;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _sizeProgress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: _StepSize(
      progress: _sizeProgress,
      fromHeight: _fromHeight,
      child: LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            // Keep each page's mounted state when it moves into the outgoing
            // layer, including its scroll offset and search field state.
            // Each page is its own layer, so sliding or fading it moves
            // pixels already painted rather than repainting the page — and
            // the sheet resizing around it doesn't repaint it either.
            final outgoing = _outgoing == null
                ? null
                : KeyedSubtree(
                    key: _outgoingPageKey,
                    child: RepaintBoundary(child: _outgoing!),
                  );
            final current = KeyedSubtree(
              key: _pageKey,
              child: RepaintBoundary(child: widget.child),
            );
            final t = Curves.fastOutSlowIn.transform(_controller.value);
            final direction = _forward ? 1.0 : -1.0;
            final incoming = _modal
                ? Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, ModalTransition.riseDistance * (1 - t)),
                      child: current,
                    ),
                  )
                : FractionalTranslation(
                    translation: Offset(
                      outgoing == null ? 0 : direction * (1 - t),
                      0,
                    ),
                    child: current,
                  );
            return Stack(
              children: [
                // In a modal change the leaving page is gone at once, and
                // only the new one fades in over its place: fading both
                // drew two offscreen layers a frame, which Snapdragon phones
                // are slowest at, for a difference hard to see.
                if (outgoing != null && !_modal)
                  Positioned(
                    key: ValueKey(_outgoingKey),
                    top: 0,
                    left: 0,
                    right: 0,
                    // The leaving page keeps its state but cannot receive
                    // focus or input while it slides away.
                    child: IgnorePointer(
                      child: ExcludeFocus(
                        child: ExcludeSemantics(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight,
                            ),
                            child: FractionalTranslation(
                              translation: Offset(-direction * t, 0),
                              child: outgoing,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                KeyedSubtree(key: ValueKey(widget.stepKey), child: incoming),
              ],
            );
          },
        ),
      ),
    ),
  );
}

/// As tall as its child, except while a step slides in: then it eases from
/// [fromHeight] to the new page's height by [progress].
///
/// Not an [AnimatedSize]: that eases every change in height, so when the
/// keyboard closed the page lagged behind the sheet and the whole sheet
/// dipped and came back. Here only a step change is eased; anything else
/// (the keyboard, a search narrowing the list) follows at once.
class _StepSize extends SingleChildRenderObjectWidget {
  const _StepSize({
    required this.progress,
    required this.fromHeight,
    super.child,
  });
  final Animation<double> progress;
  final double? fromHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderStepSize(progress, fromHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderStepSize renderObject) =>
      renderObject
        ..progress = progress
        ..fromHeight = fromHeight;
}

class _RenderStepSize extends RenderProxyBox {
  _RenderStepSize(this._progress, this._fromHeight);

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (value == _progress) return;
    if (attached) {
      _progress.removeListener(markNeedsLayout);
      value.addListener(markNeedsLayout);
    }
    _progress = value;
    markNeedsLayout();
  }

  double? _fromHeight;
  set fromHeight(double? value) {
    if (value == _fromHeight) return;
    _fromHeight = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    var height = child.size.height;
    final from = _fromHeight;
    if (from != null && _progress.status == AnimationStatus.forward) {
      height = from + (height - from) * _progress.value;
    }
    size = constraints.constrain(Size(child.size.width, height));
  }
}

/// A tinted action card with its icon in a white circle, a title and an
/// optional one-line description.
class TypeChoiceCard extends StatelessWidget {
  const TypeChoiceCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.compact = false,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;

  /// Icon and title only, for a pair sharing one row.
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // In dark mode the tint goes over the plain surface rather than the
    // white-lifted sheet card, which washes it out to a foggy grey; a
    // stronger tint keeps it as bright but in the action's own colour.
    final fill = dark
        ? Color.alphaBlend(
            color.withValues(alpha: .14),
            Theme.of(context).colorScheme.surface,
          )
        : Color.alphaBlend(color.withValues(alpha: .15), Colors.white);
    final radius = BorderRadius.circular(18);
    return DecoratedBox(
      // Light mode: a soft coloured shadow and edge lift the card off the
      // tinted sheet.
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: dark
            ? null
            : [
                BoxShadow(
                  color: color.withValues(alpha: .16),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                  spreadRadius: -4,
                ),
              ],
      ),
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: dark
              ? BorderSide.none
              : BorderSide(color: color.withValues(alpha: .28)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(compact ? 12 : 16),
            child: Row(
              children: [
                Container(
                  width: compact ? 40 : 48,
                  height: compact ? 40 : 48,
                  decoration: BoxDecoration(
                    color: dark ? color.withValues(alpha: .14) : colors.card,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 24),
                ),
                SizedBox(width: compact ? 10 : 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: dark ? null : FontWeight.w500,
                            color: dark
                                ? colors.muted
                                : Color.alphaBlend(
                                    Colors.black.withValues(alpha: .25),
                                    colors.muted,
                                  ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, color: color),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Softly raised surface focused on the amount being entered.
class AmountDisplayCard extends StatelessWidget {
  const AmountDisplayCard({
    super.key,
    required this.amount,
    this.empty = false,
  });
  final String amount;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Semantics(
      liveRegion: true,
      child: SheetCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                amount,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 46,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -1,
                  color: empty ? colors.muted : colors.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A big centered colored amount with a small caption under it — the top
/// of the Confirm and View pages.
/// Right-aligned calculation tape, with swipe access to older operands.
class CalculationHistory extends StatefulWidget {
  const CalculationHistory({super.key, required this.text});
  final String text;

  @override
  State<CalculationHistory> createState() => _CalculationHistoryState();
}

class _CalculationHistoryState extends State<CalculationHistory> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant CalculationHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        colors: const [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: [0, 12 / bounds.width, 1 - 12 / bounds.width, 1],
      ).createShader(bounds),
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: SheetColors.of(context).text,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AmountHero extends StatelessWidget {
  const AmountHero({
    super.key,
    required this.amount,
    required this.caption,
    required this.color,
    this.captionColor,
  });
  final String amount;
  final String caption;
  final Color color;
  final Color? captionColor;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          amount,
          maxLines: 1,
          style: AppTypography.amount.copyWith(color: color),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        caption,
        style: TextStyle(
          fontSize: 13,
          color: captionColor ?? SheetColors.of(context).muted,
        ),
      ),
    ],
  );
}

/// The white card of [TransactionDetailRow]s, with a divider between rows
/// that starts where the row text does, not under the icons.
class TransactionDetailsCard extends StatelessWidget {
  const TransactionDetailsCard({super.key, required this.rows});
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final divider = SheetColors.of(context).divider;
    return SheetCard(
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(height: 1, thickness: 1, indent: 66, color: divider),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// One row of a details card: a 42dp circular icon, a small muted label
/// over its value, and — when it can be tapped — a chevron. [placeholder]
/// shows the value as a muted prompt ("Add a note") rather than content.
///
/// A multi-line value with no [onTap] (a note) opens out in full when tapped,
/// and folds back on a second tap.
class TransactionDetailRow extends StatefulWidget {
  const TransactionDetailRow({
    super.key,
    required this.leading,
    required this.label,
    required this.value,
    this.caption,
    this.trailing,
    this.placeholder = false,
    this.valueColor,
    this.maxLines = 1,
    this.onTap,
  });
  final Widget leading;
  final String label;
  final String value;

  /// A quiet note under [value] qualifying it — that the account it names has
  /// been archived, say. Kept apart from the value so the name still reads as
  /// the name.
  final String? caption;

  /// A quiet figure at the end of the row — an account's balance, say — set
  /// apart from [value] rather than crowded into it.
  final String? trailing;
  final bool placeholder;
  final Color? valueColor;
  final int maxLines;
  final VoidCallback? onTap;

  @override
  State<TransactionDetailRow> createState() => _TransactionDetailRowState();
}

class _TransactionDetailRowState extends State<TransactionDetailRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final leading = widget.leading,
        label = widget.label,
        value = widget.value,
        caption = widget.caption,
        trailing = widget.trailing,
        placeholder = widget.placeholder,
        valueColor = widget.valueColor,
        maxLines = widget.maxLines,
        onTap = widget.onTap;
    final expandable = onTap == null && maxLines > 1;
    final colors = SheetColors.of(context);
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 68),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          // A value that runs over several lines (a note) keeps its icon at
          // the top, beside the label, instead of floating mid-way down.
          crossAxisAlignment: maxLines > 1
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.2,
                      color: colors.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    maxLines: _expanded ? null : maxLines,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      fontWeight: placeholder
                          ? FontWeight.w500
                          : FontWeight.w600,
                      color:
                          valueColor ??
                          (placeholder ? colors.muted : colors.text),
                    ),
                  ),
                  if (caption != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              // Takes only the width its text needs, so it sits at the
              // row's right edge and balances line up down the card.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  trailing,
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: colors.muted,
                  ),
                ),
              ),
            ],
            if (onTap != null) ...[
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 20, color: colors.muted),
            ],
          ],
        ),
      ),
    );
    if (expandable) {
      return InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: content,
        ),
      );
    }
    if (onTap == null) return MergeSemantics(child: content);
    return InkWell(onTap: onTap, child: content);
  }
}

/// A details-card row with a switch, laid out like [TransactionDetailRow].
class TransactionSwitchRow extends StatelessWidget {
  const TransactionSwitchRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.on,
    required this.onChanged,
  });
  final IconData icon;
  final String label, value;
  final bool on;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!on),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          child: Row(
            children: [
              SheetIconTile(icon: icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(fontSize: 12.5, color: colors.muted),
                    ),
                  ],
                ),
              ),
              Switch(value: on, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// A details-card row typed into directly: the same icon, small label and
/// value layout as [TransactionDetailRow], with the value as a borderless
/// text field. It never takes focus by itself, so the keyboard only opens
/// when the row is tapped — and anywhere on the row will do.
class TransactionTextRow extends StatefulWidget {
  const TransactionTextRow({
    super.key,
    required this.icon,
    required this.label,
    required this.hintText,
    required this.maxLength,
    required this.onChanged,
    this.initialValue = '',
    this.controller,
    this.keyboardType,
    this.multiline = false,
    this.enabled = true,
    this.leading,
    this.onIconTap,
    this.iconTooltip = 'Change icon',
    this.suggestions,
  });
  final IconData icon;

  /// Replaces the plain [icon] tile, e.g. with chosen artwork.
  final Widget? leading;

  /// Makes the icon tile its own tap target, apart from the text field.
  final VoidCallback? onIconTap;
  final String iconTooltip;
  final String label, hintText, initialValue;
  final int maxLength;
  final ValueChanged<String> onChanged;

  /// Supply one to edit a value the caller also changes itself; without it
  /// the row keeps its own, starting from [initialValue].
  final TextEditingController? controller;

  /// Defaults to plain text (or multiline text when [multiline] is set).
  final TextInputType? keyboardType;
  final bool multiline, enabled;

  /// Past values that fit what's typed so far, offered as chips under the
  /// field while it has focus. Picking one fills the field with it.
  final List<String> Function(String text)? suggestions;

  @override
  State<TransactionTextRow> createState() => _TransactionTextRowState();
}

class _TransactionTextRowState extends State<TransactionTextRow> {
  late final _controller =
      widget.controller ?? TextEditingController(text: widget.initialValue);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Always needed for the clear button's visibility, not just suggestions.
    _controller.addListener(_refresh);
    if (widget.suggestions != null) _focus.addListener(_refresh);
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    if (widget.controller == null) _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  List<String> get _suggestions {
    final suggest = widget.suggestions;
    if (suggest == null || !widget.enabled || !_focus.hasFocus) return const [];
    return suggest(_controller.text);
  }

  void _pick(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged(value);
  }

  void _clear() {
    if (_controller.text.isEmpty) return;
    _controller.clear();
    widget.onChanged('');
    if (widget.enabled) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled ? _focus.requestFocus : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            // A multi-line note keeps its icon at the top, beside the label.
            crossAxisAlignment: widget.multiline
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              if (widget.onIconTap == null)
                widget.leading ?? SheetIconTile(icon: widget.icon)
              else
                Tooltip(
                  message: widget.iconTooltip,
                  child: InkWell(
                    onTap: widget.enabled ? widget.onIconTap : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        widget.leading ?? SheetIconTile(icon: widget.icon),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.primary,
                              border: Border.all(color: colors.card, width: 2),
                            ),
                            child: const Icon(
                              Icons.edit_rounded,
                              size: 9,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.2,
                        color: colors.muted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _controller,
                      focusNode: _focus,
                      enabled: widget.enabled,
                      onChanged: widget.onChanged,
                      maxLength: widget.maxLength,
                      // The limit still applies; the counter would only add
                      // clutter to a one-line row.
                      buildCounter: (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                      minLines: 1,
                      maxLines: widget.multiline ? 4 : 1,
                      keyboardType:
                          widget.keyboardType ??
                          (widget.multiline
                              ? TextInputType.multiline
                              : TextInputType.text),
                      textInputAction: widget.multiline
                          ? TextInputAction.newline
                          : TextInputAction.done,
                      textCapitalization: TextCapitalization.sentences,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                      ),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        hintText: widget.hintText,
                        hintStyle: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: colors.muted,
                        ),
                        suffixIcon:
                            widget.enabled && _controller.text.isNotEmpty
                            ? Tooltip(
                                message: 'Clear',
                                child: InkResponse(
                                  onTap: _clear,
                                  radius: 16,
                                  child: Icon(
                                    Icons.cancel_rounded,
                                    size: 18,
                                    color: colors.muted,
                                  ),
                                ),
                              )
                            : null,
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                      ),
                    ),
                    if (widget.suggestions != null)
                      AnimatedSize(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 200),
                        curve: Curves.fastOutSlowIn,
                        alignment: Alignment.topLeft,
                        child: SuggestionChips(
                          values: _suggestions,
                          onPick: _pick,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row of past values under a [TransactionTextRow], scrolled sideways
/// when they don't fit. Counted as part of the field it serves, so tapping
/// one never takes the focus (and keyboard) away from it.
class SuggestionChips extends StatelessWidget {
  const SuggestionChips({
    super.key,
    required this.values,
    required this.onPick,
  });
  final List<String> values;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox(width: double.infinity);
    final colors = SheetColors.of(context);
    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              for (final value in values)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Material(
                    color: colors.primary.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => onPick(value),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.history_rounded,
                              size: 15,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              value,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: colors.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A category's or account's own artwork in a [SheetIconTile], or a plain
/// [fallback] icon while nothing is chosen.
class EntityIconTile extends StatelessWidget {
  const EntityIconTile({
    super.key,
    required this.chosen,
    required this.iconKey,
    required this.fallback,
  });
  final bool chosen;
  final String? iconKey;
  final IconData fallback;

  @override
  Widget build(BuildContext context) => chosen
      ? SheetIconTile(child: AppIcon(iconKey, size: 28))
      : SheetIconTile(icon: fallback);
}
