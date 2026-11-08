import 'brand_icons.dart';
import 'wordmark_brands.dart';

/// The bundled default icon pack — soft 3D illustrated artwork. Lives
/// alongside any future downloadable pack under `assets/icon_packs/<id>/`,
/// so a pack switch is a directory swap rather than a rename.
const _defaultIconPackDir = 'assets/icon_packs/3d';

/// Soft 3D icons the user can pick for an account (and, later, a category)
/// via `SelectIconScreen`. Converted from the illustrated icon set in
/// the supplied iconset1-4 sheets. The best non-duplicate artwork is
/// recreated as individual transparent lossless WebP assets at
/// `$_defaultIconPackDir/{key}.webp`. Theme-aware depth is drawn cheaply by
/// `AppIcon`, so the app only has to bundle one optimized image per icon.
///
/// Only these string keys are ever persisted, never a raw asset path: the
/// path is a rendering detail, and keeping the key stable lets the
/// underlying image change (re-exported, re-colored, swapped to a different
/// pack) without a data migration.
const appIconKeys = <String>[
  // Money
  'wallet_one',
  'bank',
  'atm',
  'bank_card',
  'bank_transfer',
  'credit',
  'deposit',
  'income_one',
  'paper_money_two',
  'stock_market',
  'emergency_fund',
  // Food & drink
  'fork_spoon',
  'hamburger',
  'coffee_machine',
  'tea',
  'cake_one',
  'popcorn_one',
  // Shopping
  'shopping_bag',
  'shopping_cart_one',
  'gift_box',
  'kids_toys',
  'clothes_short_sleeve',
  'lipstick_one',
  // Transport
  'car',
  'car_battery',
  'fuel',
  'taxi',
  'auto_rickshaw',
  'bus_two',
  'subway',
  'train',
  'airplane',
  'parking',
  'luggage',
  'travel_trip',
  // Home
  'home_two',
  'homestay',
  'sofa_two',
  'washing_machine',
  'hair_dryer',
  'water_rate',
  'lightning',
  'wifi',
  'phone',
  // Health
  'hospital_two',
  'medicine_bottle',
  'medicine_chest',
  'wellness',
  // Learning & leisure
  'school',
  'book_one',
  'movie',
  'music_one',
  'game_handle',
  // Other
  'baby',
  'calendar',
  'delivery',
  'oil_industry',
  'shield',
  // Expanded food & household categories
  'groceries',
  'restaurant',
  'snacks',
  'drinks',
  'fruit',
  'vegetables',
  'bakery',
  'dairy',
  'meat',
  'fish',
  'eggs',
  'cooking',
  'spices',
  'sugar',
  'dessert',
  'fruits',
  // Fashion, care & technology
  'shoes',
  'accessories',
  'beauty',
  'personal_care',
  'perfume',
  'skincare',
  'hair_care',
  'haircut',
  'salon',
  'jewelry',
  'electronics',
  'laptop',
  'camera',
  'headphones',
  'smartwatch',
  'television',
  'printer',
  'office_supplies',
  // Home, bills & activities
  'home_decor',
  'cleaning',
  'tools',
  'garden',
  'rent',
  'mobile_recharge',
  'subscriptions',
  'news',
  'sports',
  'gym',
  'bicycle',
  'hotel',
  'toll',
  'doctor',
  'family',
  'pets',
  'friends',
  'partner',
  'insurance',
  'person',
  'charity',
  // Income & finance
  'savings',
  'investment',
  'tax',
  'business',
  'freelance',
  'bonus',
  'salary',
];

/// The default icon for a new account.
const defaultAccountIcon = 'wallet_one';

/// A dedicated illustration for the aggregate account selector.  It is kept
/// separate from [appIconKeys] because it represents the "all accounts"
/// choice rather than an icon a user can assign to one account.
const allAccountsIconAsset = '$_defaultIconPackDir/all_accounts.webp';

/// The default icon for a new category.
const defaultCategoryIcon = 'shopping_bag';

/// The bundled asset path for [key], falling back to the default icon when
/// [key] is null or unrecognized (e.g. removed in a future icon pack).
String appIconAsset(String? key) {
  final resolved = appIconKeys.contains(key) ? key : defaultAccountIcon;
  return '$_defaultIconPackDir/$resolved.webp';
}

// --- Brand/merchant icons (Netflix, Uber, ...) ---
//
// A different kind of icon from the category set above: these must render
// in their own official mark and color rather than the app's illustrated
// style (see tool/fetch_brand_icons.mjs for why), so they're kept in a
// separate list (domain/brand_icons.dart) and distinguished by a "brand:"
// prefix on the stored key — one nullable String field on Account still
// covers both kinds without a second database column.

const _brandKeyPrefix = 'brand:';

/// The key to persist for a brand icon, e.g. `brandIconKey('netflix')`.
String brandIconKey(String key) => '$_brandKeyPrefix$key';

/// The matching [BrandIcon] if [key] names one, else null (including for
/// plain category keys, which never carry the "brand:" prefix).
BrandIcon? resolveBrandIcon(String? key) {
  if (key == null || !key.startsWith(_brandKeyPrefix)) return null;
  final wanted = key.substring(_brandKeyPrefix.length);
  for (final brand in brandIcons) {
    if (brand.key == wanted) return brand;
  }
  return null;
}

// --- Text-wordmark brands (Amazon, Microsoft, ...) ---
//
// Brands with no safely-licensable logo file — see domain/wordmark_brands.dart
// for why these are kept apart from the brand-icon set above rather than
// merged into it.

const _wordmarkKeyPrefix = 'mark:';

/// The key to persist for a wordmark brand, e.g. `wordmarkBrandKey('amazon')`.
String wordmarkBrandKey(String key) => '$_wordmarkKeyPrefix$key';

/// The matching [WordmarkBrand] if [key] names one, else null.
WordmarkBrand? resolveWordmarkBrand(String? key) {
  if (key == null || !key.startsWith(_wordmarkKeyPrefix)) return null;
  final wanted = key.substring(_wordmarkKeyPrefix.length);
  for (final brand in wordmarkBrands) {
    if (brand.key == wanted) return brand;
  }
  return null;
}
