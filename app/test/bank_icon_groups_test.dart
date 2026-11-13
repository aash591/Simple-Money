import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/app_icons.dart';
import 'package:simple_money/domain/bank_institution_icon.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/ui/sms/sms_suggestions.dart';
import 'package:simple_money/domain/brand_icons.dart';
import 'package:simple_money/domain/brand_dark_icons.dart';
import 'package:simple_money/domain/service_icon.dart';
import 'package:simple_money/ui/components/app_icon.dart';
import 'package:simple_money/ui/components/select_icon_screen.dart';
import 'package:simple_money/ui/components/settings_icon.dart';

void main() {
  testWidgets('brand WebPs render directly without a runtime tint', (
    tester,
  ) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: AppIcon(brandIconKey('telegram'), size: 48)),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.color, isNull);
      expect(image.colorBlendMode, isNull);
      expect(
        (image.image as AssetImage).assetName,
        brandIconAssetPath('telegram', brightness),
      );
    }
  });

  testWidgets('dark settings icon uses its companion WebP directly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(body: SettingsIcon(brandIconKey('github'), size: 48)),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.color, isNull);
    expect(
      (image.image as AssetImage).assetName,
      brandIconAssetPath('github', Brightness.dark),
    );
  });

  test('dark companions exist and use the same icon key', () {
    for (final key in darkBrandIconKeys) {
      expect(
        File(brandIconAssetPath(key, Brightness.dark)).existsSync(),
        true,
        reason: key,
      );
      expect(
        brandIconAssetPath(key, Brightness.light),
        'assets/icon_packs/brands/$key.webp',
      );
    }
    expect(
      brandIconAssetPath('openai', Brightness.dark),
      'assets/icon_packs/brands/openai_dark.webp',
    );
    expect(
      brandIconAssetPath('sbicard', Brightness.dark),
      'assets/icon_packs/brands/sbicard_dark.webp',
    );
    for (final key in ['equitas', 'btn', 'viindia']) {
      expect(
        brandIconAssetPath(key, Brightness.dark),
        'assets/icon_packs/brands/$key.webp',
      );
    }
  });

  test('bank catalog assigns every bank to a country', () {
    final banks = brandIcons.where((brand) => brand.isBank).toList();

    expect(banks, isNotEmpty);
    expect(
      banks,
      everyElement(predicate<BrandIcon>((bank) => bank.bankCountry != null)),
    );
    expect(
      banks
          .where((bank) => bank.bankCountry == 'India')
          .map((bank) => bank.title),
      containsAll([
        'HDFC Bank',
        'Federal Bank',
        'Bandhan Bank',
        'Bank of India',
        'IndusInd Bank',
        'Bank of Maharashtra',
        'Karur Vysya Bank',
        'Tamilnad Mercantile Bank',
        'South Indian Bank',
        'Karnataka Bank',
        'City Union Bank',
        'IDBI Bank',
        'CSB Bank',
        'Central Bank of India',
        'Punjab & Sind Bank',
        'Bajaj Finance',
      ]),
    );
    expect(
      banks
          .where((bank) => bank.bankCountry == 'Indonesia')
          .map((bank) => bank.title),
      containsAll(['BRI', 'BCA', 'BNI', 'BTN', 'Mandiri']),
    );
  });

  test('Bajaj Finance merchant aliases resolve to its brand icon', () {
    expect(serviceIcon('Bajaj Finance'), brandIconKey('bajajfinance'));
    expect(
      serviceIcon('BAJAJ FINSERV EMI PAYMENT'),
      brandIconKey('bajajfinance'),
    );
  });

  test('reviewed worldwide bank logos resolve and have bundled assets', () {
    const institutions = <String, String>{
      'CIB Egypt': 'cibegypt',
      'National Bank of Egypt': 'nationalbankofegypt',
      'Mellat Bank': 'mellatbank',
      'Orange Money': 'orangemoney',
      'Al Rajhi Bank': 'alrajhibank',
      'Bangkok Bank': 'bangkokbank',
      'First Abu Dhabi Bank': 'firstabudhabibank',
      'Navy Federal Credit Union': 'navyfederal',
      'GTBank': 'gtbank',
      'Zenith Bank': 'zenithbank',
    };
    for (final entry in institutions.entries) {
      expect(bankInstitutionIcon(entry.key), brandIconKey(entry.value));
      expect(
        File('assets/icon_packs/brands/${entry.value}.webp').lengthSync(),
        greaterThan(1000),
        reason: entry.key,
      );
    }
  });

  test('Indian card brands resolve from SMS and have bundled assets', () {
    PendingSmsImport sms(String bank, {bool card = true}) => PendingSmsImport(
      id: 'test',
      sender: 'TEST',
      body: '',
      receivedAt: DateTime(2026),
      data: {'bankName': bank, 'isCreditCard': card},
    );
    expect(smsBankIcon(sms('OneCard')), brandIconKey('onecard'));
    expect(smsBankIcon(sms('State Bank India')), brandIconKey('sbicard'));
    expect(
      smsBankIcon(sms('State Bank India', card: false)),
      brandIconKey('sbi'),
    );
    expect(smsBankIcon(sms('BOBCARD')), brandIconKey('bobcard'));
    expect(resolveBrandIcon(brandIconKey('onecard'))?.isPayment, true);
    expect(resolveBrandIcon(brandIconKey('sbicard'))?.isPayment, true);
  });

  test('common services and metro operators have selectable bundled marks', () {
    const keys = [
      'ola',
      'rapido',
      'nammayatri',
      'kseb',
      'kwa',
      'ksrtc',
      'irctc',
      'redbus',
      'bsnl',
      'viindia',
      'asianetbroadband',
      'kochimetro',
      'delhimetro',
      'nammametro',
      'chennaimetro',
      'hyderabadmetro',
      'mumbaimetro',
      'keralavision',
      'actfibernet',
      'excitel',
      'hathway',
      'tataplayfiber',
      'youbroadband',
    ];
    for (final key in keys) {
      expect(resolveBrandIcon(brandIconKey(key)), isNotNull, reason: key);
      expect(
        File('assets/icon_packs/brands/$key.webp').lengthSync(),
        greaterThan(1000),
        reason: key,
      );
    }
  });

  testWidgets('bank picker displays separate country sections', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SelectIconScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Banks'));
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const PageStorageKey<String>('icon-tab-banks')),
      matching: find.byType(Scrollable),
    );
    expect(find.text('Banks - India'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Banks - Indonesia'),
      500,
      scrollable: scrollable,
    );
    expect(find.text('Banks - Indonesia'), findsOneWidget);
    expect(find.text('Banks around the world'), findsNothing);
  });

  testWidgets('picker opens on the tab holding the current icon', (
    tester,
  ) async {
    // A unique key per case so each pump builds a fresh State, the way
    // pushing the picker as a new route does; the starting tab is chosen
    // once on open and deliberately doesn't chase later selection changes.
    Future<void> pumpWith(String? selectedKey) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SelectIconScreen(
            key: ValueKey(selectedKey),
            selectedKey: selectedKey,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // A bank icon opens on Banks, without the user hunting for it.
    await pumpWith(brandIconKey('hdfcbank'));
    expect(find.text('Banks - India'), findsOneWidget);

    // A service mark opens on Services.
    await pumpWith(brandIconKey('netflix'));
    expect(find.text('Services & subscriptions'), findsOneWidget);
    expect(find.text('Services'), findsOneWidget);

    // Category artwork (and no selection at all) opens on the icon set.
    await pumpWith('groceries');
    expect(find.text('Services & subscriptions'), findsNothing);
    expect(find.text('Banks - India'), findsNothing);
  });

  testWidgets('long pressing a brand icon shows its name', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SelectIconScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();

    await tester.longPress(find.bySemanticsLabel('Ola'));
    await tester.pump();
    expect(find.text('Ola'), findsOneWidget);
  });
}
