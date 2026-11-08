import 'package:flutter/material.dart';

import '../../../state/appearance_controller.dart';
import '../../../state/pro_controller.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/watch_ad.dart';
import '../../components/feature_page.dart';
import '../../components/menu_list.dart';
import '../../theme/app_theme.dart';
import '../pro/pro_screen.dart';

class CustomizationScreen extends StatelessWidget {
  const CustomizationScreen({super.key});

  /// The first row: free, a short ad each time one is picked (Purple, the
  /// default, never takes one).
  static const freeColors = <String, Color>{
    'Purple': accent,
    'Blue': Color(0xff087cff),
    'Pink': Color(0xffce397e),
    'Red': Color(0xffd63e42),
  };

  /// The second row, with Pro; the colour picker ends it.
  static const proColors = <String, Color>{
    'Orange': Color(0xffc46514),
    'Green': Color(0xff16834c),
    'Teal': Color(0xff008580),
  };

  static const colors = {...freeColors, ...proColors};

  @override
  Widget build(BuildContext context) {
    final settings = AppearanceScope.of(context);
    final text = Theme.of(context).textTheme;
    return FeaturePage(
      title: 'Customization',
      child: ListenableBuilder(
        listenable: ProController.instance,
        builder: (context, _) {
          final pro = ProController.instance.featuresUnlocked;
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 32),
            children: [
              const _SectionHeader(
                'Style',
                'Every style works in light and dark.',
              ),
              MenuGroup(
                children: [
                  for (final style in AppStyle.values)
                    Semantics(
                      selected: settings.style == style,
                      button: true,
                      child: MenuRow(
                        icon: switch (style) {
                          AppStyle.glassy => Icons.blur_on_rounded,
                          AppStyle.simple => Icons.layers_outlined,
                          AppStyle.aurora => Icons.auto_awesome_outlined,
                        },
                        title: switch (style) {
                          AppStyle.glassy => 'Glassy',
                          AppStyle.simple => 'Simple',
                          AppStyle.aurora => 'Aurora Glass',
                        },
                        subtitle: switch (style) {
                          AppStyle.glassy =>
                            'Subtle frost and translucent surfaces',
                          AppStyle.simple => 'Solid surfaces and clean details',
                          AppStyle.aurora =>
                            'Luminous edges and pools of your accent color',
                        },
                        onTap: () => _pickStyle(context, settings, style),
                        trailing: Icon(
                          settings.style == style
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          color: settings.style == style
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: appCardGap),
              const _SectionHeader(
                'Theme',
                'Pick how SimpleMoney looks, or follow your device.',
              ),
              MenuGroup(
                children: [
                  for (final choice in _ThemeChoice.values)
                    _ModeRow(choice: choice, settings: settings),
                ],
              ),
              const SizedBox(height: appCardGap),
              const _SectionHeader(
                'Accent color',
                'Make SimpleMoney yours. Purple is the default.',
              ),
              MoneyCard(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (final entry in freeColors.entries)
                          _AccentSwatch(
                            name: entry.key,
                            color: entry.value,
                            selected: settings.accentColor == entry.value,
                            onTap: () => _pickFree(context, settings, entry),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (final entry in proColors.entries)
                          _AccentSwatch(
                            name: entry.key,
                            color: entry.value,
                            locked: !pro,
                            selected: settings.accentColor == entry.value,
                            onTap: () => pro
                                ? settings.setAccent(entry.value)
                                : _offerPro(context),
                          ),
                        _PaletteSwatch(
                          locked: !pro,
                          custom: colors.containsValue(settings.accentColor)
                              ? null
                              : settings.accentColor,
                          onTap: () => pro
                              ? _pickCustom(context, settings)
                              : _offerPro(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                pro
                    ? 'Every color is yours, and the last one picks any shade.'
                    : 'First row: free, with a short ad each time you switch. '
                          'Second row and your own color: Pro.',
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Saved on this phone. Applies across the app.',
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }

  /// A style other than the default (Glassy) takes a short ad each time it is
  /// picked, like a first-row colour; Pro never sees one.
  static Future<void> _pickStyle(
    BuildContext context,
    AppearanceController settings,
    AppStyle style,
  ) async {
    if (settings.style == style) return;
    if (style != AppStyle.glassy && !ProController.instance.isPro) {
      void openPro() =>
          Navigator.of(context).push(FeatureRoute<void>(const ProScreen()));
      final watch = await showConfirmationAlert(
        context,
        title: 'Watch a short ad to switch style',
        message:
            'Styles other than Glassy show a short ad each time you switch. '
            'With Pro, use every style, with no ads.',
        confirmLabel: 'Watch ad',
        extraActionLabel: 'Get Pro instead',
        onExtraAction: openPro,
        destructive: false,
      );
      if (!watch || !context.mounted) return;
      // Offline, or the user declined: the style stays as it was.
      if (!await watchAd(context)) return;
    }
    await settings.setStyle(style);
  }

  /// A first-row colour: free, after a short ad unless it's the default or
  /// this is Pro.
  static Future<void> _pickFree(
    BuildContext context,
    AppearanceController settings,
    MapEntry<String, Color> entry,
  ) async {
    if (settings.accentColor == entry.value) return;
    if (entry.value != accent && !ProController.instance.featuresUnlocked) {
      void openPro() =>
          Navigator.of(context).push(FeatureRoute<void>(const ProScreen()));
      final watch = await showConfirmationAlert(
        context,
        title: 'Watch a short ad to switch color',
        message:
            'Free colors show a short ad each time you switch. With Pro, use '
            'every color, with no ads.',
        confirmLabel: 'Watch ad',
        extraActionLabel: 'Get Pro instead',
        onExtraAction: openPro,
        destructive: false,
      );
      if (!watch || !context.mounted) return;
      // Offline, or the user declined: the color stays as it was.
      if (!await watchAd(context)) return;
    }
    await settings.setAccent(entry.value);
  }

  static Future<void> _offerPro(BuildContext context) async {
    if (await showConfirmationAlert(
          context,
          title: 'A Pro color',
          message:
              'Pro unlocks every color and a picker for any shade, with no '
              'ads.',
          confirmLabel: 'See Pro',
          cancelLabel: 'Not now',
          destructive: false,
        ) &&
        context.mounted) {
      await Navigator.of(context).push(FeatureRoute<void>(const ProScreen()));
    }
  }

  static Future<void> _pickCustom(
    BuildContext context,
    AppearanceController settings,
  ) async {
    final picked = await showAdaptiveSheet<Color>(
      context,
      builder: (_) => _AccentPicker(initial: settings.accentColor),
    );
    if (picked != null) await settings.setAccent(picked);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, this.subtitle);
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

/// What the Theme list offers: the three modes, and dark with true-black
/// cards, which is dark mode plus [AppearanceController.black].
enum _ThemeChoice {
  system(ThemeMode.system, false),
  light(ThemeMode.light, false),
  dark(ThemeMode.dark, false),
  black(ThemeMode.dark, true);

  const _ThemeChoice(this.mode, this.blackStyle);
  final ThemeMode mode;
  final bool blackStyle;

  bool selectedIn(AppearanceController settings) =>
      settings.value == mode &&
      (mode != ThemeMode.dark || settings.black == blackStyle);

  (String, String, IconData) get details => switch (this) {
    system => (
      'Use device setting',
      'Match your system theme',
      Icons.brightness_auto_rounded,
    ),
    light => ('Light', 'Always bright', Icons.light_mode_rounded),
    dark => ('Dark', 'Always dim', Icons.dark_mode_rounded),
    black => (
      'Black',
      'True black, easy on OLED screens',
      Icons.nightlight_rounded,
    ),
  };
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.choice, required this.settings});
  final _ThemeChoice choice;
  final AppearanceController settings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = choice.selectedIn(settings);
    final (label, description, icon) = choice.details;
    return Semantics(
      button: true,
      selected: selected,
      child: MenuRow(
        icon: icon,
        title: label,
        subtitle: description,
        onTap: () => settings.setMode(choice.mode, black: choice.blackStyle),
        trailing: Icon(
          selected ? Icons.check_circle_rounded : Icons.circle_outlined,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A round swatch; the ring sits outside it, so selection reads at a glance
/// without hiding the colour behind a tick.
class _Ring extends StatelessWidget {
  const _Ring({
    required this.color,
    required this.selected,
    required this.child,
    this.fill,
  });
  final Color color;
  final bool selected;
  final Widget? child;

  /// Paints the swatch instead of [color], e.g. a rainbow.
  final Gradient? fill;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    width: 54,
    height: 54,
    padding: EdgeInsets.all(selected ? 4 : 0),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: selected ? color : Colors.transparent,
        width: 2,
      ),
    ),
    child: Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill == null ? color : null,
        gradient: fill,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: .35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    ),
  );
}

/// A small lock in a swatch's corner, for a Pro colour.
class _Lock extends StatelessWidget {
  const _Lock();

  @override
  Widget build(BuildContext context) => Positioned(
    right: -2,
    bottom: -2,
    child: Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.lock_rounded,
        size: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
    this.locked = false,
  });
  final String name;
  final Color color;
  final bool selected, locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: locked ? '$name accent, Pro' : '$name accent',
    child: Tooltip(
      message: name,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _Ring(
              color: color,
              selected: selected,
              child: selected
                  ? const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 22,
                    )
                  : null,
            ),
            if (locked) const _Lock(),
          ],
        ),
      ),
    ),
  );
}

/// The last swatch: a rainbow that opens the colour picker, or the colour
/// picked there.
class _PaletteSwatch extends StatelessWidget {
  const _PaletteSwatch({
    required this.locked,
    required this.custom,
    required this.onTap,
  });
  final bool locked;

  /// The accent when it was picked here rather than from a swatch.
  final Color? custom;
  final VoidCallback onTap;

  static const rainbow = SweepGradient(
    colors: [
      Color(0xffe53935),
      Color(0xfffb8c00),
      Color(0xfffdd835),
      Color(0xff43a047),
      Color(0xff00acc1),
      Color(0xff1e88e5),
      Color(0xff8e24aa),
      Color(0xffe53935),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final custom = this.custom;
    return Semantics(
      button: true,
      selected: custom != null,
      label: locked ? 'Your own color, Pro' : 'Your own color',
      child: Tooltip(
        message: 'Your own color',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _Ring(
                color: custom ?? const Color(0xff8e24aa),
                selected: custom != null,
                fill: custom == null ? rainbow : null,
                child: Icon(
                  custom == null ? Icons.palette_rounded : Icons.check_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              if (locked) const _Lock(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Any hue, at a strength that stays readable as an accent: white text
/// reads on it, and it shows on both light and dark backgrounds. So no
/// black, white or greys.
class _AccentPicker extends StatefulWidget {
  const _AccentPicker({required this.initial});
  final Color initial;

  @override
  State<_AccentPicker> createState() => _AccentPickerState();
}

class _AccentPickerState extends State<_AccentPicker> {
  static const _saturation = .72;
  static const _lightest = .52, _darkest = .36;

  late double _hue = HSLColor.fromColor(widget.initial).hue;
  late double _shade =
      ((HSLColor.fromColor(widget.initial).lightness - _darkest) /
              (_lightest - _darkest))
          .clamp(0.0, 1.0);

  Color _at(double hue, double shade) => HSLColor.fromAHSL(
    1,
    hue,
    _saturation,
    _darkest + (_lightest - _darkest) * shade,
  ).toColor();

  Color get _color => _at(_hue, _shade);

  Widget _track(List<Color> colors, double value, ValueChanged<double> set) =>
      SizedBox(
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 14,
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                gradient: LinearGradient(colors: colors),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 0,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                thumbColor: Colors.white,
                overlayColor: _color.withValues(alpha: .15),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 11,
                  elevation: 3,
                ),
              ),
              child: Slider(value: value, onChanged: set),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SheetPage(
      header: const SheetHeader('Your own color'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _color,
                boxShadow: [
                  BoxShadow(
                    color: _color.withValues(alpha: .4),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.check_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('Color', style: text.labelLarge),
          _track(
            [for (var h = 0; h <= 360; h += 30) _at(h.toDouble(), _shade)],
            _hue / 360,
            (v) => setState(() => _hue = v * 360),
          ),
          Text('Shade', style: text.labelLarge),
          _track(
            [_at(_hue, 0), _at(_hue, 1)],
            _shade,
            (v) => setState(() => _shade = v),
          ),
          const SizedBox(height: 4),
          Text(
            'Only shades that stay easy to read, in light and dark.',
            style: text.bodySmall,
          ),
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: () => Navigator.pop(context),
        primaryLabel: 'Use this color',
        onPrimary: () => Navigator.pop(context, _color),
      ),
    );
  }
}
