import 'package:flutter/material.dart';

import '../../components/app_back_button.dart';
import '../../components/tab_header.dart';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/monetization_config.dart';
import '../../../state/ad_gate.dart';
import '../../../state/pro_controller.dart';
import '../../components/action_buttons.dart';
import '../../components/app_toast.dart';

class ProScreen extends StatefulWidget {
  const ProScreen({super.key});

  @override
  State<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends State<ProScreen> {
  final _pro = ProController.instance;
  var _selected = ProPlanKind.yearly;
  bool _restoring = false;
  late final _privacyOptions = AdGate.instance.privacyOptionsRequired();

  @override
  void initState() {
    super.initState();
    if (_pro.plans.isEmpty) _pro.loadPlans();
  }

  ProPlan? _plan(ProPlanKind kind) =>
      _pro.plans.where((p) => p.kind == kind).firstOrNull;

  /// How much yearly saves over twelve months of monthly, as a whole percent.
  int? get _yearlySaving {
    final yearly = _plan(ProPlanKind.yearly);
    final monthly = _plan(ProPlanKind.monthly);
    if (yearly == null ||
        monthly == null ||
        yearly.product.currencyCode != monthly.product.currencyCode ||
        monthly.rawPrice <= 0) {
      return null;
    }
    final saving = (1 - yearly.rawPrice / (monthly.rawPrice * 12)) * 100;
    return saving >= 5 ? saving.round() : null;
  }

  Future<void> _restore() async {
    setState(() => _restoring = true);
    final owned = await _pro.restore();
    if (!mounted) return;
    setState(() => _restoring = false);
    showAppToast(
      context,
      owned ? 'Pro restored' : 'No Pro purchase found on this Google account',
    );
  }

  Future<void> _manage() async {
    final info = await PackageInfo.fromPlatform();
    await launchUrl(
      Uri.https('play.google.com', '/store/account/subscriptions', {
        'sku': MonetizationConfig.subscriptionId,
        'package': info.packageName,
      }),
      mode: LaunchMode.externalApplication,
    );
  }

  /// The hero's height below the status bar: shorter on a small phone, so
  /// the plans aren't pushed out of sight.
  static double _heroHeightFor(double screen) =>
      (screen * .3).clamp(200.0, 268.0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.paddingOf(context);
    final heroHeight = _heroHeightFor(MediaQuery.sizeOf(context).height);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light status bar icons over the coloured hero.
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: ListenableBuilder(
          listenable: _pro,
          builder: (context, _) {
            final plans = _ordered;
            final selected = plans.isEmpty
                ? null
                : (_plan(_selected) ?? plans.first);
            final buying =
                !_pro.isPro && selected != null && !_pro.loadingPlans;
            return Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: insets.top + heroHeight + 40,
                  child: _Hero(
                    compact: heroHeight < 240,
                    owned: _pro.isPro,
                    topInset: insets.top,
                    onBack: () => Navigator.maybePop(context),
                  ),
                ),
                Positioned.fill(
                  top: insets.top + heroHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(32),
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(22, 26, 22, 16),
                            children: _pro.isPro
                                ? _owned(context)
                                : _offer(context, plans, selected),
                          ),
                        ),
                        _bottomBar(
                          context,
                          buying ? selected : null,
                          insets.bottom,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// What Pro gives: a short name and one plain line each, in its own
  /// colour.
  static const _perks = [
    _Perk(
      Icons.auto_awesome_rounded,
      Color(0xff7c4dff),
      'AI assistant',
      'Ask Claude or ChatGPT about your money',
    ),
    _Perk(
      Icons.pie_chart_rounded,
      Color(0xff0f9d7a),
      'Unlimited budgets',
      'Add as many as you like',
    ),
    _Perk(
      Icons.palette_rounded,
      Color(0xffe0457b),
      'All colors',
      'Every accent, plus your own shade',
    ),
    _Perk(
      Icons.web_asset_off_rounded,
      Color(0xffe8830c),
      'No ads',
      'Never see an ad',
    ),
    _Perk(
      Icons.favorite_rounded,
      Color(0xff2f80ed),
      'Support development',
      'Helps keep SimpleMoney updated',
    ),
  ];

  List<Widget> _owned(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
      Text(
        _pro.ownsLifetime
            ? 'You’re a lifetime supporter'
            : 'You’re a supporter',
        style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      Text('Everything below is yours. Thank you!', style: text.bodyMedium),
      const SizedBox(height: 18),
      for (final perk in _perks) perk.owned(),
    ];
  }

  /// The plans in the order they're offered: yearly, monthly, lifetime.
  List<ProPlan> get _ordered => [
    for (final kind in [
      ProPlanKind.yearly,
      ProPlanKind.monthly,
      ProPlanKind.lifetime,
    ])
      ?_plan(kind),
  ];

  /// What twelve months of monthly would cost, in the plan's currency: the
  /// price yearly is struck against.
  String? _fullYear() {
    final monthly = _plan(ProPlanKind.monthly);
    if (_yearlySaving == null || monthly == null) return null;
    return NumberFormat.currency(
      symbol: monthly.product.currencySymbol,
      decimalDigits: 2,
    ).format(monthly.rawPrice * 12);
  }

  /// One plain line under the button: what is charged, and when.
  String _terms(ProPlan plan) {
    if (plan.kind == ProPlanKind.lifetime) {
      return 'One payment of ${plan.price} · Yours for good';
    }
    final period = plan.kind == ProPlanKind.yearly ? 'year' : 'month';
    final trial = plan.trialLabel;
    return trial == null
        ? '${plan.price} per $period · Cancel anytime'
        : '${trial[0].toUpperCase()}${trial.substring(1)}, then '
              '${plan.price} per $period · Cancel anytime';
  }

  List<Widget> _offer(
    BuildContext context,
    List<ProPlan> plans,
    ProPlan? selected,
  ) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final saving = _yearlySaving;
    return [
      if (!ProController.aiNeedsPro) const _FreeForNow(),
      for (final perk in _perks) perk,
      const SizedBox(height: 22),
      if (_pro.loadingPlans)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (plans.isEmpty)
        Row(
          children: [
            Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _pro.storeAvailable
                    ? 'Pro isn’t available right now.'
                    : 'Google Play isn’t available on this device.',
                style: text.bodyMedium,
              ),
            ),
            if (_pro.storeAvailable)
              TextButton(
                onPressed: _pro.loadPlans,
                child: const Text('Try again'),
              ),
          ],
        )
      else ...[
        for (final plan in plans)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PlanRow(
              plan: plan,
              selected: plan.kind == selected!.kind,
              struck: plan.kind == ProPlanKind.yearly ? _fullYear() : null,
              badge: plan.kind == ProPlanKind.yearly && saving != null
                  ? 'Save $saving%'
                  : null,
              onTap: () => setState(() => _selected = plan.kind),
            ),
          ),
      ],
      const SizedBox(height: 6),
      Text(
        'Subscriptions renew automatically. Cancel anytime in Google Play.',
        textAlign: TextAlign.center,
        style: text.bodySmall,
      ),
      FutureBuilder<bool>(
        future: _privacyOptions,
        builder: (context, snapshot) => snapshot.data != true
            ? const SizedBox.shrink()
            : TextButton(
                onPressed: AdGate.instance.showPrivacyOptions,
                child: const Text('Ad privacy choices'),
              ),
      ),
    ];
  }

  /// Pinned at the bottom: the button for [plan], or Manage for a
  /// subscriber, and Restore.
  Widget _bottomBar(BuildContext context, ProPlan? plan, double inset) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 10, 22, inset + 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pro.error case final error? when !_pro.isPro)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error,
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          if (_pro.pending && !_pro.isPro)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Payment processing. Pro turns on once Google Play confirms.',
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ),
          if (plan != null) ...[
            _GradientButton(
              label: plan.trialLabel != null
                  ? 'Start free trial'
                  : plan.kind == ProPlanKind.lifetime
                  ? 'Get lifetime'
                  : 'Continue',
              loading: _pro.purchasing,
              onPressed: _pro.purchasing || _pro.pending
                  ? null
                  : () => _pro.buy(plan),
            ),
            const SizedBox(height: 8),
            Text(
              _terms(plan),
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ] else if (_pro.isPro && !_pro.ownsLifetime)
            PillButton(
              label: 'Manage subscription',
              primary: false,
              onPressed: _manage,
            ),
          if (!_pro.isPro)
            Center(
              child: TextButton(
                onPressed: _restoring || !_pro.storeAvailable ? null : _restore,
                child: Text(_restoring ? 'Checking…' : 'Restore purchases'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The top of the page: a rich gradient reaching under the status bar, with
/// the crown, the name and its promise.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.compact,
    required this.owned,
    required this.topInset,
    required this.onBack,
  });
  final bool owned, compact;
  final double topInset;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final deep = Color.lerp(scheme.primary, Colors.black, .45)!;
    final violet = Color.lerp(scheme.primary, const Color(0xff8b5cf6), .7)!;
    Widget glow(double size, Color color) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: .55), color.withValues(alpha: 0)],
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [deep, scheme.primary, violet],
        ),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(top: -60, right: -40, child: glow(240, Colors.white)),
          Positioned(bottom: -30, left: -70, child: glow(220, violet)),
          Padding(
            padding: EdgeInsets.only(top: topInset),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      TabHeader.sideMargin - GlassCircleButton.edgeInset,
                      4,
                      0,
                      4,
                    ),
                    child: AppBackButton(onPressed: onBack),
                  ),
                ),
                Container(
                  width: compact ? 56 : 76,
                  height: compact ? 56 : 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: .18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .45),
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    owned
                        ? Icons.verified_rounded
                        : Icons.workspace_premium_rounded,
                    size: compact ? 30 : 40,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: compact ? 10 : 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'SimpleMoney',
                          style: text.headlineMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.5,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'PRO',
                            style: text.titleMedium?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    owned
                        ? 'Thank you for keeping SimpleMoney growing'
                        : 'Get more from SimpleMoney',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(
                      color: Colors.white.withValues(alpha: .9),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A perk: a tinted rounded square, a bold line and a quiet one.
/// While Pro's features are open to everyone, say so, so nobody wonders
/// what they'd be paying for.
class _FreeForNow extends StatelessWidget {
  const _FreeForNow();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final green = dark ? Colors.greenAccent : Colors.green.shade800;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(Icons.card_giftcard_rounded, size: 20, color: green),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'The AI assistant is free for now. Pro supports the app.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: green, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  const _Perk(
    this.icon,
    this.color,
    this.title,
    this.subtitle, {
    this.unlocked = false,
  });
  final IconData icon;

  /// The perk's own colour: its icon tile and its title.
  final Color color;
  final String title, subtitle;

  /// Owned already: a tick at the end.
  final bool unlocked;

  _Perk owned() => _Perk(icon, color, title, subtitle, unlocked: true);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The same hue, set to read on the page: deeper on white, lighter on
    // black.
    final titleColor = dark
        ? Color.lerp(color, Colors.white, .35)!
        : Color.lerp(color, Colors.black, .25)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(color, Colors.white, .18)!,
                  Color.lerp(color, Colors.black, .12)!,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: .30),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 23),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleMedium?.copyWith(
                    color: titleColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (unlocked) ...[
            const SizedBox(width: 8),
            const Icon(Icons.check_circle_rounded, color: Colors.green),
          ],
        ],
      ),
    );
  }
}

/// One plan: its name and price, the chosen one outlined and tinted.
class _PlanRow extends StatelessWidget {
  const _PlanRow({
    required this.plan,
    required this.selected,
    required this.onTap,
    this.struck,
    this.badge,
  });
  final ProPlan plan;
  final bool selected;
  final VoidCallback onTap;

  /// The price this one is struck against, when it saves money.
  final String? struck;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final name = switch (plan.kind) {
      ProPlanKind.yearly => 'Yearly',
      ProPlanKind.monthly => 'Monthly',
      ProPlanKind.lifetime => 'Lifetime',
    };
    final note = switch (plan.kind) {
      ProPlanKind.lifetime => 'Pay once, keep it for good',
      _ => plan.trialLabel,
    };
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: dark ? .16 : .07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            name,
                            style: text.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (badge case final badge?)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: .16),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                badge,
                                style: text.labelSmall?.copyWith(
                                  color: dark
                                      ? Colors.greenAccent
                                      : Colors.green.shade800,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (note != null) ...[
                        const SizedBox(height: 2),
                        Text(note, style: text.bodySmall),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (struck != null)
                      Text(
                        struck!,
                        style: text.bodySmall?.copyWith(
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                    Text(
                      plan.price,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The buy button: the hero's gradient, so the page ends where it began.
class _GradientButton extends StatelessWidget {
  const _GradientButton({
    required this.label,
    required this.onPressed,
    this.loading = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final violet = Color.lerp(scheme.primary, const Color(0xff8b5cf6), .7)!;
    final enabled = onPressed != null && !loading;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Opacity(
        opacity: onPressed == null && !loading ? .5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(colors: [scheme.primary, violet]),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: .35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: enabled ? onPressed : null,
              child: SizedBox(
                height: 56,
                child: Center(
                  child: loading
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : ExcludeSemantics(
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
