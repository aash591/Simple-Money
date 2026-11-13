import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Flutter cannot sample the launcher behind a transparent Android activity.
/// Report only the frosted surface's bounds to the Android compositor.
class NativeModalBlur extends SingleChildRenderObjectWidget {
  const NativeModalBlur({
    super.key,
    required super.child,
    required this.radius,
  });
  final double radius;
  static bool enabled = false;
  static const channel = MethodChannel('simple_money/modal_blur');

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ModalBlurBounds(MediaQuery.devicePixelRatioOf(context), radius);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    final bounds = renderObject as _ModalBlurBounds;
    bounds.density = MediaQuery.devicePixelRatioOf(context);
    bounds.radius = radius;
  }
}

class _ModalBlurBounds extends RenderProxyBox {
  _ModalBlurBounds(this.density, this.radius);
  double density;
  double radius;
  Rect? previous;
  bool tracking = false;

  Future<void> send(Map<String, Object> data) async {
    try {
      await NativeModalBlur.channel.invokeMethod<void>('bounds', data);
    } on MissingPluginException {
      // Other platforms use the Flutter BackdropFilter.
    } on PlatformException {
      // The native activity may already have closed.
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!NativeModalBlur.enabled || tracking) return;
    tracking = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => report());
  }

  void report() {
    if (!attached || !NativeModalBlur.enabled) {
      tracking = false;
      return;
    }
    // Observe animation frames without requesting extra frames of our own.
    SchedulerBinding.instance.addPostFrameCallback((_) => report());
    final logical = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & size,
    );
    // In whole physical pixels: each update makes Android redo the window's
    // background, so sub-pixel steps at the end of an easing are skipped.
    final rect = Rect.fromLTRB(
      (logical.left * density).roundToDouble(),
      (logical.top * density).roundToDouble(),
      (logical.right * density).roundToDouble(),
      (logical.bottom * density).roundToDouble(),
    );
    if (rect == previous) return;
    previous = rect;
    send({
      'id': identityHashCode(this),
      'left': rect.left,
      'top': rect.top,
      'right': rect.right,
      'bottom': rect.bottom,
      'radius': radius * density,
    });
  }

  @override
  void detach() {
    if (previous != null) send({'id': identityHashCode(this), 'remove': true});
    previous = null;
    super.detach();
  }
}
