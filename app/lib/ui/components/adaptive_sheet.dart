import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/physics.dart';

import '../theme/app_motion.dart';
import '../theme/app_theme.dart' show usesGlass;
import 'app_back_button.dart';
import 'common.dart' show MoneyCard;

import '../theme/sheet_colors.dart';
import '../theme/surface_style.dart';
import 'secondary_header.dart';
import 'sheet_scroll_indicator.dart';
import 'modal_transition.dart';
import 'frosted_modal_surface.dart';

/// Sheet presentation styles. Both use the shared fade-and-rise motion.
enum SheetEntrance {
  /// Fades in while rising just 24dp — the main transaction sheet, which
  /// should feel like it settles into place rather than travels.
  fadeRise,

  /// Slides up by its own height — the smaller pickers stacked above it.
  slideUp,
}

/// Opens [builder] in an [AdaptiveSheetRoute].
Future<T?> showAdaptiveSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  SheetEntrance entrance = SheetEntrance.slideUp,
  bool dismissible = true,
  double maxHeightFactor = 1,
  double topClearance = 0,
  bool avoidKeyboard = true,
  bool? floating,
}) => Navigator.of(context).push(
  AdaptiveSheetRoute<T>(
    builder: builder,
    entrance: entrance,
    floating: floating,
    dismissible: dismissible,
    maxHeightFactor: maxHeightFactor,
    topClearance: topClearance,
    avoidKeyboard: avoidKeyboard,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  ),
);

/// A full-width sheet anchored to the bottom of the screen, exactly as tall
/// as its content but never taller than the space below the status bar
/// (and above the keyboard), over a clear barrier. Content that outgrows
/// it scrolls. It can be dragged down to close: past 72dp or on a fast
/// fling it dismisses, otherwise it springs back into place.
class AdaptiveSheetRoute<T> extends PopupRoute<T> {
  AdaptiveSheetRoute({
    required this.builder,
    this.entrance = SheetEntrance.slideUp,
    this._dismissible = true,
    this.maxHeightFactor = 1,
    this.topClearance = 0,
    bool avoidKeyboard = true,
    this._floating,
    this.barrierLabel,
  }) : _avoidKeyboard = ValueNotifier(avoidKeyboard);

  /// How many sheets are open (or closing). The home tab bar hides while any
  /// is, because its white glass would otherwise show through the frost.
  static final open = ValueNotifier<int>(0);
  bool _counted = false;

  void _uncount() {
    if (!_counted) return;
    _counted = false;
    open.value--;
  }

  @override
  TickerFuture didPush() {
    _counted = true;
    open.value++;
    return super.didPush();
  }

  @override
  bool didPop(T? result) {
    _uncount();
    return super.didPop(result);
  }

  final WidgetBuilder builder;
  final SheetEntrance entrance;
  final bool? _floating;

  /// Whether the sheet is inset from the sides and bottom as a rounded card
  /// (the transaction sheet's look) rather than docked edge to edge. Every
  /// sheet floats, so they all share the same margins, unless set explicitly.
  bool get floating => _floating ?? true;

  /// The tallest the sheet may be, as a fraction of the screen height.
  final double maxHeightFactor;

  /// Extra space kept free between the status bar and the sheet's top edge,
  /// so a tall sheet stops short of something worth keeping in view.
  final double topClearance;

  final ValueNotifier<bool> _avoidKeyboard;

  /// Whether the sheet lifts above the on-screen keyboard. The content can
  /// change it as it goes: the transaction sheet only lifts on steps with a
  /// text field of its own, so it stays put when a text-entry sheet stacked
  /// above it raises the keyboard.
  bool get avoidKeyboard => _avoidKeyboard.value;
  set avoidKeyboard(bool value) => _avoidKeyboard.value = value;

  bool _dismissible;

  @override
  final String? barrierLabel;

  @override
  Color get barrierColor => Colors.transparent;

  @override
  Curve get barrierCurve => Curves.easeOut;

  @override
  bool get barrierDismissible => _dismissible;

  /// Lets the content decide, as it changes, whether tapping the scrim
  /// closes the sheet — a read-only view may, a half-filled form may not.
  set dismissible(bool value) {
    if (value == _dismissible) return;
    _dismissible = value;
    changedInternalState();
  }

  @override
  Duration get transitionDuration => ModalTransition.duration;

  @override
  Duration get reverseTransitionDuration => ModalTransition.reverseDuration;

  /// The sheet route [context] was built in, if it is one.
  static AdaptiveSheetRoute<Object?>? of(BuildContext context) {
    final route = ModalRoute.of(context);
    return route is AdaptiveSheetRoute ? route : null;
  }

  @override
  void dispose() {
    _uncount();
    _avoidKeyboard.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _SheetFrame(route: this, animation: animation);
}

class _SheetFrame extends StatefulWidget {
  const _SheetFrame({required this.route, required this.animation});
  final AdaptiveSheetRoute<Object?> route;
  final Animation<double> animation;

  @override
  State<_SheetFrame> createState() => _SheetFrameState();
}

class _SheetFrameState extends State<_SheetFrame>
    with SingleTickerProviderStateMixin {
  static const _dismissDistance = 72.0;
  static const _dismissVelocity = 700.0;
  // Only gestures beginning in the handle/title/heading area can dismiss.
  static const _dismissDragAreaHeight = 120.0;
  bool _canDismissDrag = false;
  static const _maxWidth = 640.0;

  /// How far the sheet is currently dragged below its resting position.
  late final _drag = AnimationController.unbounded(vsync: this);

  /// Built once, so the frame rebuilding — every frame of the keyboard
  /// sliding in, say — doesn't rebuild the whole content with it.
  late final Widget _content = Builder(builder: widget.route.builder);

  @override
  void initState() {
    super.initState();
    widget.route._avoidKeyboard.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.route._avoidKeyboard.removeListener(_rebuild);
    _drag.dispose();
    super.dispose();
  }

  void _rebuild() => setState(() {});

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_canDismissDrag) return;
    _drag.value = math.max(0, _drag.value + details.primaryDelta!);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_canDismissDrag) return;
    _canDismissDrag = false;
    final flung = (details.primaryVelocity ?? 0) > _dismissVelocity;
    // A plain pop, not maybePop: dragging down always closes the whole
    // sheet, even from a step whose back button would only step back.
    if ((flung || _drag.value > _dismissDistance) && widget.route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      _settle(details.primaryVelocity ?? 0);
    }
  }

  /// Springs back into place, carrying on from the speed it was let go at.
  void _settle([double velocity = 0]) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _drag.value = 0;
      return;
    }
    _drag.animateWith(
      SpringSimulation(AppMotion.settle, _drag.value, 0, velocity),
    );
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final media = MediaQuery.of(context);
    final colors = SheetColors.of(context);
    final keyboard = route.avoidKeyboard ? media.viewInsets.bottom : 0.0;
    final bottomSafe = route.avoidKeyboard
        ? media.padding.bottom
        : media.viewPadding.bottom;
    final floating = route.floating;
    final inset = floating ? 8.0 : 0.0;
    final bottomInset = floating ? bottomSafe + 4.0 : 0.0;
    final maxHeight = math.min(
      media.size.height -
          media.padding.top -
          route.topClearance -
          keyboard -
          inset -
          bottomInset,
      media.size.height * route.maxHeightFactor,
    );

    final sheet = FrostedModalSurface(
      borderRadius: floating
          ? BorderRadius.circular(36)
          : const BorderRadius.vertical(top: Radius.circular(36)),
      child: Padding(
        padding: EdgeInsets.only(bottom: floating ? 0 : bottomSafe),
        // The frame has already accounted for the system insets, so the
        // content lays out as if there were none.
        child: MediaQuery(
          data: media
              .removePadding(removeTop: true, removeBottom: true)
              .removeViewInsets(removeBottom: true),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DragHandle(color: colors.outline),
              Flexible(child: _content),
            ],
          ),
        ),
      ),
    );

    final moving = ModalTransition(
      animation: widget.animation,
      child: AnimatedBuilder(
        animation: _drag,
        builder: (context, child) =>
            Transform.translate(offset: Offset(0, _drag.value), child: child),
        child: GestureDetector(
          onVerticalDragDown: (details) {
            _canDismissDrag =
                details.localPosition.dy >= 0 &&
                details.localPosition.dy <= _dismissDragAreaHeight;
          },
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          onVerticalDragCancel: () {
            _canDismissDrag = false;
            _settle();
          },
          // Opening, closing and dragging only move the sheet, so it is
          // painted once and its layer moved, instead of repainting the
          // blur, the glass rim and every control on each frame.
          child: RepaintBoundary(child: sheet),
        ),
      ),
    );

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          inset,
          inset,
          inset,
          keyboard + bottomInset,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: _maxWidth,
            maxHeight: maxHeight,
          ),
          child: SizedBox(width: double.infinity, child: moving),
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 20,
    child: Center(
      child: Container(
        width: 42,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

/// How a step sheet's header names the flow it belongs to ("Add expense"):
/// quiet and small, because the step's own [SheetStepHeading] is what the
/// eye should land on. See [SheetHeader.flow].
TextStyle sheetFlowTitleStyle(BuildContext context) => TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
  letterSpacing: 0,
  color: SheetColors.of(context).muted,
);

/// Shared secondary-page title bar for sheet pages.
class SheetHeader extends StatelessWidget {
  const SheetHeader(
    this.title, {
    super.key,
    this.onBack,
    this.trailing,
    this.titleStyle,
    this.centered,
  }) : _flow = false;

  /// The header of one step of a multi-step flow, where [title] names the
  /// flow itself — "Add expense" — on every step rather than the step. It
  /// is drawn quieter than a page title, because the step's own
  /// [SheetStepHeading] leads the content below it.
  const SheetHeader.flow(this.title, {super.key, this.onBack, this.trailing})
    : titleStyle = null,
      centered = false,
      _flow = true;

  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;
  final TextStyle? titleStyle;

  /// A small, centred title. By default a sheet's first page (no back arrow
  /// or action) is centred, so every sheet opens with the same title.
  final bool? centered;
  final bool _flow;

  @override
  Widget build(BuildContext context) => SecondaryHeader(
    title: title,
    centered: centered ?? (onBack == null && trailing == null && !_flow),
    titleStyle: titleStyle ?? (_flow ? sheetFlowTitleStyle(context) : null),
    leading: onBack == null ? null : AppBackButton(onPressed: onBack),
    actions: [?trailing],
  );
}

/// What the current step asks for — "What is the amount?", "Pay from" — at
/// the top of the content it introduces rather than in the header, so the
/// header can go on naming the flow (see [SheetHeader.flow]) the whole way
/// through. [subtitle] adds a muted line under it for context, such as who
/// is being paid.
class SheetStepHeading extends StatelessWidget {
  const SheetStepHeading(this.text, {super.key, this.subtitle});
  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              height: 1.3,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: colors.text,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.35, color: colors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// One page of a sheet: its header, a body that scrolls only once the sheet
/// reaches its maximum height, and bottom actions that never scroll away.
class SheetPage extends StatefulWidget {
  const SheetPage({
    super.key,
    required this.header,
    required this.body,
    this.actions,
    this.startAtBottom = false,
    this.bodyPadding = const EdgeInsets.fromLTRB(16, 4, 16, 8),
  });
  final Widget header;
  final Widget body;
  final Widget? actions;

  /// Keeps the active keypad or calendar visible below a tall summary.
  final bool startAtBottom;
  final EdgeInsets bodyPadding;

  @override
  State<SheetPage> createState() => _SheetPageState();
}

class _SheetPageState extends State<SheetPage> {
  final _scroll = ScrollController(keepScrollOffset: false);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      widget.header,
      Flexible(
        child: SheetScrollIndicator(
          child: SingleChildScrollView(
            controller: _scroll,
            // Reversing the viewport anchors its initial position at the
            // bottom without a visible post-layout jump. The body's reading
            // order stays unchanged, and users can scroll back to the summary.
            reverse: widget.startAtBottom,
            padding: widget.actions == null
                ? widget.bodyPadding.copyWith(bottom: 16)
                : widget.bodyPadding,
            child: widget.body,
          ),
        ),
      ),
      ?widget.actions,
    ],
  );
}

/// The white, softly raised rounded card that groups rows inside a sheet. It is a
/// [Material], so rows inside can show ink ripples and selection tints.
class SheetCard extends StatelessWidget {
  const SheetCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // On the glass styles the card is the same see-through, rimmed surface as
    // every other card (frosted over a picture), not a solid grey slab.
    if (usesGlass(context)) {
      return MoneyCard(
        padding: EdgeInsets.zero,
        child: Material(type: MaterialType.transparency, child: child),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(appCardRadius),
        boxShadow: appCardShadows(Theme.of(context).brightness),
      ),
      child: Material(
        color: SheetColors.of(context).card,
        borderRadius: BorderRadius.circular(appCardRadius),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

/// The icon tile at the start of a sheet row: a Material [icon] in [color],
/// or any [child] (such as an `AppIcon`) — no background, no shadow, just
/// the icon itself in its own square slot.
class SheetIconTile extends StatelessWidget {
  const SheetIconTile({
    super.key,
    this.icon,
    this.child,
    this.color,
    this.size = 42,
  }) : assert(icon != null || child != null);
  final IconData? icon;
  final Widget? child;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final tint = color ?? colors.primary;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      child: icon != null ? Icon(icon, size: size * .48, color: tint) : child,
    );
  }
}
