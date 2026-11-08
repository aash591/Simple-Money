import 'dart:ui';

import 'package:flutter/material.dart';

import 'glass_button.dart';

/// A pill-shaped glass search field: a semi-transparent body over a light
/// blur of whatever scrolls behind it, with a faint sheen and the
/// light-catching [GlassRim]. No drop shadow.
///
/// The blur joins the nearest [BackdropGroup], so the field and a glass pill
/// beside it (as in [SearchableHeader]) share a single blur pass.
///
/// Named `SearchField` rather than `SearchBar` because Flutter's own
/// `material.dart` already exports a `SearchBar` widget; reusing that name
/// would collide wherever this component and `material.dart` are both
/// imported, which is everywhere.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hintText = 'Search',
    this.autofocus = false,
    this.focusNode,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  /// Opens the keyboard as soon as the field appears — for a search field
  /// that's toggled on by a search icon rather than always on screen.
  final bool autofocus;

  /// Lets a caller check focus (e.g. to unfocus on a back press before
  /// closing the field itself) or drive it externally. Optional — a plain
  /// always-visible search field has no need to observe its own focus.
  final FocusNode? focusNode;

  /// The height of the field, and of the Cancel pill beside it.
  static const height = 38.0;

  /// The glass body shared by the field and its Cancel pill: the page's
  /// surface colour, see-through enough to show the blur behind it.
  static Color fill(BuildContext context) {
    final theme = Theme.of(context);
    return theme.colorScheme.surface.withValues(
      alpha: theme.brightness == Brightness.dark ? .55 : .62,
    );
  }

  /// A small sigma: just enough to soften what shows through, and cheap.
  static const blurSigma = 6.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final muted = dark
        ? theme.colorScheme.onSurfaceVariant
        : const Color(0xff77777f);
    const radius = BorderRadius.all(Radius.circular(height / 2));
    final body = fill(context);
    return Container(
      constraints: const BoxConstraints(minHeight: height),
      decoration: const BoxDecoration(borderRadius: radius),
      foregroundDecoration: GlassRim(dark: dark, solid: false, radius: radius),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter.grouped(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // The same faint sheen over the top half as a glass key.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                    Colors.white.withValues(alpha: dark ? .04 : .3),
                    body,
                  ),
                  body,
                ],
                stops: const [0, .5],
              ),
            ),
            child: _field(muted),
          ),
        ),
      ),
    );
  }

  Widget _field(Color muted) => TextField(
    controller: controller,
    onChanged: onChanged,
    autofocus: autofocus,
    focusNode: focusNode,
    textInputAction: TextInputAction.search,
    textAlignVertical: TextAlignVertical.center,
    style: const TextStyle(fontSize: 15),
    decoration: InputDecoration(
      isDense: true,
      filled: false,
      hintText: hintText,
      hintStyle: TextStyle(fontSize: 15, color: muted),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      prefixIcon: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Icon(Icons.search_rounded, size: 19, color: muted),
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 0),
      // Always occupies the same slot (rather than being added/removed
      // with the text), so the field's height and width never shift as
      // the user types — only its visibility and hit-testing toggle.
      suffixIcon: Visibility(
        visible: controller.text.isNotEmpty,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: IconButton(
          tooltip: 'Clear search',
          icon: Icon(Icons.close_rounded, size: 16, color: muted),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          visualDensity: VisualDensity.compact,
          onPressed: () {
            controller.clear();
            onChanged('');
          },
        ),
      ),
      suffixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 0),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
    ),
  );
}

/// A page's header that gives way to a [SearchField] and a Cancel pill while
/// [searching]: the field wipes in from the search icon's end without
/// squeezing its text, the header fades out, and the height eases between
/// the two. The page owns [searching] and the field's controller and focus.
class SearchableHeader extends StatelessWidget {
  const SearchableHeader({
    super.key,
    required this.searching,
    required this.header,
    required this.controller,
    required this.onChanged,
    required this.onCancel,
    this.focusNode,
    this.hintText = 'Search',
    this.fieldKey,
    this.padding = const EdgeInsets.fromLTRB(18, 9, 18, 11),
  });
  final bool searching;

  /// Shown while not searching, usually with the button that starts one.
  final Widget header;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onCancel;
  final FocusNode? focusNode;
  final String hintText;
  final Key? fieldKey;

  /// Around the search field and Cancel. Centres them on the line a header's
  /// buttons sit on.
  final EdgeInsetsGeometry padding;

  static const _searchKey = ValueKey('search-header');
  static const _headerKey = ValueKey('normal-header');

  /// Static so its identity is stable across rebuilds: [AnimatedSwitcher]
  /// re-runs every live transition whenever the builder changes, and this
  /// header rebuilds on each keystroke.
  static Widget _buildTransition(Widget child, Animation<double> animation) {
    final curved = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
    if (child.key == _searchKey) {
      return AnimatedBuilder(
        animation: curved,
        child: child,
        builder: (context, child) =>
            ClipRect(clipper: _SearchRevealClipper(curved.value), child: child),
      );
    }
    return FadeTransition(opacity: curved, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 320);
    return ClipRect(
      child: AnimatedSize(
        duration: duration,
        curve: Curves.easeInOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: duration,
          reverseDuration: duration,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: [
              for (final child in previousChildren)
                Positioned(left: 0, top: 0, right: 0, child: child),
              ?currentChild,
            ],
          ),
          transitionBuilder: _buildTransition,
          child: searching
              ? Padding(
                  key: _searchKey,
                  padding: padding,
                  // One blur pass for the field and Cancel together.
                  child: BackdropGroup(
                    child: Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: SearchField.height,
                            child: SearchField(
                              key: fieldKey,
                              controller: controller,
                              focusNode: focusNode,
                              onChanged: onChanged,
                              hintText: hintText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GlassButton(
                          onPressed: onCancel,
                          height: SearchField.height,
                          fill: SearchField.fill(context),
                          blur: SearchField.blurSigma,
                          textStyle: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                )
              : KeyedSubtree(key: _headerKey, child: header),
        ),
      ),
    );
  }
}

/// Reveals the field from the search icon's side without squeezing its text.
class _SearchRevealClipper extends CustomClipper<Rect> {
  const _SearchRevealClipper(this.progress);
  final double progress;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    size.width * (1 - progress),
    0,
    size.width * progress,
    size.height,
  );
  @override
  bool shouldReclip(_SearchRevealClipper oldClipper) =>
      oldClipper.progress != progress;
}
