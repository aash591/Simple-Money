import 'package:flutter/material.dart';

import 'dart:io';

import '../../../data/aurora_wallpaper.dart';
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
    return FeaturePage(
      title: 'Customization',
      child: ListenableBuilder(
        listenable: ProController.instance,
        builder: (context, _) {
          final pro = ProController.instance.featuresUnlocked;
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 32),
            children: [
              if (!pro && settings.nextPreviewEnd != null)
                _PreviewNotice(end: settings.nextPreviewEnd!),
              const _SectionHeader('Style', ''),
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
                        proBadge:
                            !pro && style != AppearanceController.freeStyle,
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
              if (settings.style == AppStyle.aurora) ...[
                const SizedBox(height: appCardGap),
                _AuroraBackground(settings: settings),
              ],
              const SizedBox(height: appCardGap),
              const _SectionHeader('Theme', ''),
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
                            onTap: () =>
                                _pickColor(context, settings, entry.value),
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
                            pro: !pro,
                            selected: settings.accentColor == entry.value,
                            onTap: () =>
                                _pickColor(context, settings, entry.value),
                          ),
                        _PaletteSwatch(
                          locked: !pro,
                          custom: colors.containsValue(settings.accentColor)
                              ? null
                              : settings.accentColor,
                          onTap: () => _pickCustom(context, settings),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Every change takes a short ad unless this is Pro. [preview] says the
  /// look is a Pro one, so the ad buys an hour of it, not a keeper.
  static Future<bool> _watchFor(
    BuildContext context, {
    required String what,
    required bool preview,
  }) async {
    if (ProController.instance.featuresUnlocked) return true;
    void openPro() =>
        Navigator.of(context).push(FeatureRoute<void>(const ProScreen()));
    final watch = await showConfirmationAlert(
      context,
      title: 'Watch a short ad to change $what',
      message: preview
          ? 'This is a Pro look. Watch a short ad to use it for an hour, '
                'then it goes back to your free look. Pro keeps it for good, '
                'with no ads.'
          : 'Each change shows a short ad. With Pro, no ads.',
      confirmLabel: 'Watch ad',
      extraActionLabel: 'Get Pro instead',
      onExtraAction: openPro,
      destructive: false,
    );
    if (!watch || !context.mounted) return false;
    // Offline, or the user declined: nothing changes.
    return watchAd(context);
  }

  static Future<void> _pickStyle(
    BuildContext context,
    AppearanceController settings,
    AppStyle style,
  ) async {
    if (settings.style == style) return;
    final free = style == AppearanceController.freeStyle;
    if (!await _watchFor(context, what: 'style', preview: !free)) return;
    await settings.setStyle(
      style,
      preview: !free && !ProController.instance.featuresUnlocked,
    );
    // Aurora is made for dark: switch to it so the real look shows at once.
    if (style == AppStyle.aurora &&
        (settings.value != ThemeMode.dark || settings.black)) {
      await settings.setMode(ThemeMode.dark);
    }
  }

  /// A colour from either row. The first row (and Purple, the default) is
  /// free; the rest, and any shade, are a Pro look tried for an hour.
  static Future<void> _pickColor(
    BuildContext context,
    AppearanceController settings,
    Color color,
  ) async {
    if (settings.accentColor == color) return;
    final free = freeColors.containsValue(color);
    if (color != accent &&
        !await _watchFor(context, what: 'color', preview: !free)) {
      return;
    }
    await settings.setAccent(
      color,
      preview: !free && !ProController.instance.featuresUnlocked,
    );
  }

  static Future<void> _pickCustom(
    BuildContext context,
    AppearanceController settings,
  ) async {
    final picked = await showAdaptiveSheet<Color>(
      context,
      builder: (_) => _AccentPicker(initial: settings.accentColor),
    );
    if (picked == null || !context.mounted) return;
    await _pickColor(context, settings, picked);
  }
}

/// While a Pro look is being tried: what it is, how long is left, and the
/// way to keep it.
class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({required this.end});
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = end.difference(DateTime.now());
    final minutes = left.inMinutes + (left.inSeconds % 60 > 0 ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: appCardGap),
      child: MoneyCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.timer_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Trying a Pro look. It goes back to your free look in '
                '${minutes < 1 ? 'under a minute' : '$minutes min'}.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context)
                      .push(FeatureRoute<void>(const ProScreen())),
              child: const Text('Keep it'),
            ),
          ],
        ),
      ),
    );
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
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ],
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
/// A small "PRO" tag on the corner of a Pro look.
class _ProBadge extends StatelessWidget {
  const _ProBadge();

  @override
  Widget build(BuildContext context) => const Positioned(
    right: -6,
    bottom: -4,
    child: IgnorePointer(child: MenuProBadge()),
  );
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
    this.pro = false,
  });
  final String name;
  final Color color;
  final bool selected, pro;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '$name accent',
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
            if (pro) const _ProBadge(),
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
              if (locked) const _ProBadge(),
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

/// What sits behind the Aurora style: its own glow, or a picture of the
/// user's choosing, such as the wallpaper from their home screen.
class _AuroraBackground extends StatelessWidget {
  const _AuroraBackground({required this.settings});
  final AppearanceController settings;

  Future<void> _choose(BuildContext context) async {
    final previous = settings.wallpaperPath;
    final path = await AuroraWallpaper.choose();
    if (path == null || !context.mounted) return;
    if (!await CustomizationScreen._watchFor(
      context,
      what: 'background',
      preview: true,
    )) {
      await AuroraWallpaper.tidy(keep: previous);
      return;
    }
    await settings.setWallpaper(
      path,
      preview: !ProController.instance.featuresUnlocked,
    );
    if (previous != null) await AuroraWallpaper.tidy(keep: path);
  }

  Future<void> _useGlow() async {
    await settings.setWallpaper(null);
    await AuroraWallpaper.tidy();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final picture = settings.wallpaperPath;
    Widget check(bool on) => Icon(
      on ? Icons.check_circle_rounded : Icons.circle_outlined,
      color: on ? scheme.primary : scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(
          'Aurora background',
          'Use the glow, or a picture such as your home screen wallpaper.',
        ),
        MenuGroup(
          children: [
            Semantics(
              selected: picture == null,
              button: true,
              child: MenuRow(
                icon: Icons.auto_awesome_outlined,
                title: 'Aurora glow',
                subtitle: 'Pools of your accent color',
                onTap: picture == null ? null : _useGlow,
                trailing: check(picture == null),
              ),
            ),
            Semantics(
              selected: picture != null,
              button: true,
              child: MenuRow(
                icon: Icons.wallpaper_outlined,
                title: picture == null ? 'Choose a picture' : 'Change picture',
                subtitle: 'Pick your wallpaper or any photo from your phone',
                onTap: () => _choose(context),
                trailing: picture == null
                    ? check(false)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(picture),
                          width: 36,
                          height: 36,
                          fit: BoxFit.cover,
                          cacheWidth: 108,
                          errorBuilder: (_, _, _) => check(true),
                        ),
                      ),
              ),
            ),
            if (picture != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Dim the picture',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Text(
                          '${(settings.wallpaperDim * 100).round()}%',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    Slider(
                      value: settings.wallpaperDim,
                      max: .85,
                      divisions: 17,
                      label: '${(settings.wallpaperDim * 100).round()}%',
                      onChanged: settings.setWallpaperDim,
                    ),
                    Text(
                      'Darker (or lighter, in light mode) keeps text easy to read.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
