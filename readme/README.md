# SimpleMoney (Flutter)

A simple, fast, clean, offline-first Android money manager, built with
Flutter. This is a from-scratch rewrite of the original Kotlin/Jetpack
Compose SimpleMoney app — the product goal is unchanged, only the technology
changed.

## Repository layout

The root contains shared documentation and design references. The complete
Flutter Android app lives in `app/`:

```text
app/
  lib/                 Flutter application code
  assets/              Bundled app assets
  test/                Flutter tests
  android/             Native Android project and Gradle configuration
  pubspec.yaml         App dependencies and asset configuration
README.md
FLUTTER_GUIDE.md
APP ICON.png
home.png
mockup 1.png
transactions.png
```

Open `app/` as the Flutter project in your IDE. Run Flutter commands from
that directory (with the Flutter SDK installed and available on your PATH):

```sh
cd app
flutter pub get
flutter run
```

On a fresh Windows machine, run `SetupEnvironment.bat` from the repository
root first. It installs missing tools in their standard locations, configures
the Android/Java environment for the current user, and restores the Flutter,
Dart, relay, and community dependencies. Paths are derived from the current
user and clone location; no machine-specific username or project path is used.

To check or build the app from the same directory, use `flutter analyze`,
`flutter test`, or `flutter build apk`.

In Android Studio, select **Run on all Android devices** and click Run. This
discovers connected Android phones (USB or wireless) and running emulators,
builds one debug APK, and launches it on each. It ignores the Flutter device
dropdown, including Windows. Devices must already be connected and authorized.
Click Run again after code changes. For IDE debugging and hot reload on one
device, select `main.dart` and choose that Android device in the dropdown.

**Run on all Android devices (release)** uses the same Flutter SDK, release
compilation options, application ID, and upload signing key as `build app:play`.
Both commands share `app/tool/android_production_build.ps1` and require
`secrets/android/key.properties`; they fail instead of falling back to debug signing.
The IDE launcher uses the current `app/pubspec.yaml` version without changing it.
`build app:play` bumps the version for the next Play Store upload.
The launcher installs a universal APK; the publishing command produces an AAB.
Google Play generates device-specific APKs and signs them with the Play App
Signing key, which can differ from the local upload key. This matches production
app behavior and build settings, not the exact Play-delivered file or signature.
Release installs preserve existing local app data; only profile builds seed
sample data on a fresh install.

The same launcher can be run from `app/` in PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/run_android_devices.ps1
```

## Current implementation

The More tab includes locally saved accounts and categories. Accounts can be
added, edited, reordered, and assigned a currency from the offline picker.
The Transactions tab is backed by the local ledger and includes period and
account summaries, search, account/type/date filters, and grouped expense,
income, and transfer history. Amounts are stored as integer minor units in
Drift/SQLite. New installations start with no accounts. Home shows saved monthly income,
spending, net savings, cumulative cash flow, top expense categories, current
account balances, and the five most recent transactions in the selected month.
The Home month label opens an anchored calendar dropdown with shared month/year
grids. Its right chevron slides to Transactions for that month; account and
transaction rows open their existing editors/details. Summaries refresh after
ledger changes and use SQLite aggregates, with transfers excluded from income
and spending. Subcategories roll up to their parent, with the top four categories
and an Others slice on the ring chart. Different currencies are selected
separately; no exchange conversion is performed. Reusable, data-driven charts
live in `app/lib/ui/components/charts/`. Backup & Sync now provides optional
automatic incremental Google Drive uploads with a persistent offline queue.
See [Google Drive setup and sync behavior](GOOGLE_DRIVE_SYNC.md). Snapshots and
restore are planned for a later update.

Run `flutter test` from `app/` for account persistence and widget-flow tests.
`flutter test tool/screenshots_test.dart` generates layout-review images under
`app/build/qa/`; optionally set `QA_FONT` to a local TTF for readable captures.

### Category icon workflow

The bundled default icon pack (`3d`) is one consistent soft 3D style, kept
under `assets/icon_packs/3d/` — named by style rather than by "category" so
an alternate downloadable pack can sit alongside it later without a rename.
Generate new artwork as a transparent 2x2 sheet containing exactly four
evenly spaced icons, then keep the source sheet under `icons/` (for example,
`icons/iconset5.png`). Crop the sheet into named 512x512 source icons under
`assets_raw/icon_packs_raw/3d/` (written as lossy WebP, like every other
bundled/master icon in this repo):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File app/tool/slice_2x2_category_sheet.ps1 `
  -SourcePath icons/iconset5.png `
  -Keys friends,partner,insurance,bonus `
  -OutputDirectory assets_raw/icon_packs_raw/3d
```

Add each key to `appIconKeys` in `app/lib/domain/app_icons.dart` and
export the complete set. The exporter downsizes the raw art to 128x128 and
encodes it as lossy WebP (q90, alpha_q100) with `cwebp` (the optional
`-CanvasSize 192` switch can be used if the app adopts larger assets later):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File app/tool/export_optimized_category_icons.ps1
```

Both this script and `slice_2x2_category_sheet.ps1` shell out to
`app/tool/bin/cwebp.exe`/`dwebp.exe` (GDI+ has no built-in WebP codec). These
binaries aren't checked in — download the Windows release from
https://storage.googleapis.com/downloads.webmproject.org/releases/webp/ and
place `cwebp.exe`/`dwebp.exe` in `app/tool/bin/` (gitignored).

Keep both the 512px raw crops and optimized app assets; Flutter bundles the
files from `app/assets/icon_packs/3d/`.

### Service, brand, and bank account icon workflow

Named services, merchants, banks, and payment providers use their real logos
in `app/assets/icon_packs/brands/`. Generic activities such as haircut and
salon belong in the soft 3D category pack above, even when SMS merchant names
automatically select them.

1. Search Google/Google Images for a high-quality original logo, then download
   the original file from its source rather than saving a search thumbnail.
   Prefer the provider's official SVG or brand kit; otherwise use a large
   transparent PNG, official Google Play artwork, or a reliable original-logo
   source. Verify the exact business and service: Kerala Vision TV and Kerala
   Vision Broadband artwork are not interchangeable. Retain downloaded sources
   under `icons/` (for example `icons/isp_sources/`).
2. Preserve the actual logo's shapes, proportions, and brand colors. Do not
   invent a replacement, hand-draw an approximate symbol, or use AI to redesign
   a brand logo. Enlarging a tiny raster crop does not create a high-quality
   source. Recreate the app asset by isolating and processing the original.
3. Fit the artwork into a square tile. Prefer the standalone logo/symbol with
   side text removed. If the name is needed for recognition, place the original
   wordmark underneath the symbol instead of keeping a long horizontal strip.
   Keep the complete mark, consistent clear padding, and enough visual size to
   read in transaction rows. Check that cropping leaves no neighboring letters.
4. Remove source backgrounds and unrelated slogans or app labels cleanly while
   preserving transparent edges and internal gaps. Avoid colored fringes,
   jagged edges, clipping, stretched artwork, and accidental background boxes.
   An intentional badge that forms part of the original mark may be retained.
5. Add reproducible source URLs and any crop, isolation, or stacking operations
   to `app/tool/fetch_brand_icons.mjs`. Export a transparent 256x256 lossy WebP
   at quality 90 and alpha quality 100. Retain the resulting master copy in
   `assets_raw/icon_packs_raw/brands/` as well as the bundled app asset. From `app/`,
   regenerate only the affected keys to avoid overwriting unrelated artwork:

   ```powershell
   node tool/fetch_brand_icons.mjs --only keralavision actfibernet excitel
   ```

6. Register stable `brand:<key>` identifiers through the fetch script's brand
   catalog and keep `app/lib/domain/brand_icons.dart` in sync. Banks must have
   their bank flag and country; payment providers must have their payment flag.
   If light and dark surfaces need different assets, add a `_dark.webp`
   companion and keep `generate_brand_dark_variants.mjs` and
   `brand_dark_icons.dart` in sync. Use source variants where available and
   preserve colored accents; do not apply a blanket runtime tint.
7. Document source links and processing choices in both brand `ATTRIBUTION.md`
   files. Update outdated notes when a source or treatment changes. Add merchant
   aliases to `service_icon.dart` where appropriate, covering SMS titles with
   spaces, punctuation, and payment suffixes without matching unrelated names.
   Preserve explicitly selected transaction icons. Category classification
   remains in the SMS parser package, separate from display icon matching.
8. Inspect the exported assets at actual transaction and picker sizes on both
   light and dark tiles before calling them finished. Inspect the final WebPs,
   not just the large downloaded source. Run the relevant icon catalog and
   transaction icon tests after registration or matching changes.

## The problem

Most money manager apps blend "what the money was for" with "where it came
from." For example, Food paid with Cash, Food paid with SBI Bank, and Food
paid with a Credit Card should all still be one category: **Food**. The
payment source and the category must stay separate.

## The core idea

Every transaction answers two simple questions:

1. What was the money for? → **Category** (Food, Shopping, Fuel, Travel, Bills, Health...)
2. Where did the money come from? → **Account** (Cash, SBI Bank, HDFC Bank, Credit Card, Wallet...)

Example: ₹500 Food paid from HDFC Bank, plus ₹200 Food paid from Cash, should
show total Food spending as ₹700 — summed across accounts.

Categories never belong to an account. A transfer between two accounts (e.g.
HDFC Bank → Cash) is its own transaction type, not an expense — it only moves
money between accounts, it doesn't count as spending.

## Product goal

Make money tracking much simpler than apps like Cashew. The app should feel:
fast, simple, clean, modern, easy to understand, smooth, private, offline
first. A user should be able to add a normal expense in a few seconds.

## Main UX goal

Adding an expense should be very simple. The normal flow:

1. Enter amount
2. Select category
3. Select account
4. Save

Do not show too many fields by default. Extra options — notes, tags,
attachments, recurring payments, and other advanced settings — stay under a
"More options" section.

## Main features

### Accounts

Where money is stored or paid from: Cash, SBI Bank, HDFC Bank, Credit Card,
Wallet, etc.

### Categories

What the money was used for: Food, Shopping, Fuel, Travel, Bills, Health,
etc. Categories must never belong to an account.

### Transactions

Support Expense, Income, and Transfer. A transfer (e.g. HDFC Bank → Cash) is
not an expense — it only moves money between accounts.

### Budgets

Core feature, not a paid add-on:

- Monthly total budget
- Category budgets (e.g. Food budget: ₹10,000/month)

### Reports

Make it easy to understand money both ways:

- By category, broken down by account — e.g. Food: ₹12,000 total, shown as
  Cash ₹2,000 / HDFC ₹5,000 / SBI ₹3,000 / Credit Card ₹2,000.
- By account, broken down by category — e.g. HDFC spending: ₹20,000, shown as
  Food ₹5,000 / Shopping ₹7,000 / Fuel ₹3,000 / Other ₹5,000.

### Home screen

Keep it simple — show only: total spent this month, total income, budget
remaining, main spending categories, account balances, recent transactions.
Do not crowd it.

## Design system

The app should look and feel premium, calm, and modern — closer to a clean
iOS app than a typical Android finance app, while still feeling native and
correct on Android.

- **Look**: flat, light surfaces with soft shadows instead of hard borders.
  Cards and buttons have generously rounded corners, never sharp edges.
- **Color**: one accent blue used for actions, highlights, and selection.
  Backgrounds are a soft off-white in light mode and a soft charcoal (not
  pure black) in dark mode. Both light and dark mode are fully supported and
  looked after equally — nothing is designed for only one.
- **Numbers**: money amounts are the hero of the screen — big, bold, and
  easy to read at a glance. Supporting text (labels, dates, subtitles) stays
  small and quiet so it doesn't compete.
- **Typography**: simple, clean system font. Just a few clear sizes — large
  for totals, medium for titles, small for labels — no decorative fonts.
- **Icons**: one consistent icon style throughout (simple outlined icons),
  used the same way for every category, account, and menu action.
- **Spacing**: generous breathing room around and between elements — the
  screen should never feel packed or cramped.
- **Motion**: animations are smooth and subtle, used to guide attention
  (like a page sliding in) — never flashy or distracting.
- **Consistency**: every screen reuses the same handful of building blocks
  (cards, buttons, list rows, icon tiles) so the whole app feels like one
  connected product, not separate screens stitched together. In particular:
  - **Empty states** (a list/feature with nothing in it yet) use
    `EmptyState` from `ui/components/empty_state.dart` — an icon, title,
    short message, and an "Add your first …" button. `NoResultsState` from
    the same file is the equivalent for a search with no matches. Don't
    hand-roll a new empty-state layout per screen.
  - **In-page search** (a search icon in the header that reveals a search
    field with Cancel, e.g. Debts, Loans, Subscriptions) uses
    `SearchableHeader`/`SearchField` from `ui/components/search_field.dart`
    inside `FeaturePage`'s `header:` slot. Don't build a one-off search
    `TextField` inline in the list.

## Performance goal

Feel fast even on cheaper Android phones: fast startup, low RAM usage, small
app size, smooth scrolling and animation, no unnecessary background services,
no unnecessary network requests. Aggregate totals (monthly spend, category
sums, budget progress) are computed in the database, not by loading every
transaction into memory.

## Offline first

The app must work fully without internet. Main data stays on the device.
Internet is used for optional Google Drive backup and daily exchange rates when
accounts use two or more currencies. Single-currency installs never request
exchange rates. Cached rates work offline; missing currencies are named and
converted totals are clearly marked incomplete.

Settings → Main currency controls combined account balances and Home summaries.
The choice (including precision and territory) stays on this device and is not
included in exports or Drive sync. Budgets, transactions and reminder amounts
keep their original currencies. Combined historical charts are estimates using
the latest cached rates, not transaction-date rates, and display the rate date
(with a notice after seven days). Individual-currency views remain available.

Rates come from the [Fawaz Ahmed Currency API](https://github.com/fawazahmed0/exchange-api),
using jsDelivr with a Cloudflare fallback. Requests include only the main currency
code, never ledger data. The device-local `exchange_rates` cache is excluded from
backup/sync. Refresh runs while the app is active or returns to the foreground;
it does not schedule a background service.

## Backup

Support Google Drive backup:

- Connect Google Drive
- Back up manually
- Enable automatic backup
- Restore data on a new phone

Backup contains: accounts, categories, transactions, budgets, and settings
needed for restore.

## Privacy

For v1: no account/login required, no backend required, no ads, no selling
user data. Financial data stays on-device unless the user enables backup.

## Tech stack

| Concern | Choice |
|---|---|
| Language / UI | Flutter, Dart |
| State management | Riverpod |
| Local database | Drift (SQLite) |
| Navigation | go_router |
| Preferences | shared_preferences |
| Background work (auto backup) | workmanager |
| Cloud backup | Google Drive API (`googleapis` + `google_sign_in`) |

Keep dependencies minimal. Do not add a custom backend, Firebase, or any
server-side database unless a real need appears later.

## Architecture

Organize UI by feature; keep shared pieces separate from feature-specific
ones:

```text
app/lib/
  main.dart
  app.dart                 app shell, theming, root router
  data/
    db/                     Drift database, tables, DAOs
    repositories/           account/category/transaction/budget repositories
    backup/                 Google Drive backup + restore
  domain/                   models and business rules (category totals, budgets)
  ui/
    components/             shared widgets used by multiple features
      charts/               reusable cash-flow and donut charts
    theme/                  colors, typography, shape, spacing, motion tokens
    home/                   home screen
    transactions/           list, add/edit flow, transaction widgets
    budgets/                budget screens
    more/                   More tab; every page it opens lives below
      accounts/              manage accounts
      categories/            category list, editor, icon picker
      debts/                 people, lent/borrowed balances
      loans/                 loans, EMIs, repayments
      settings/              settings, customization, security
        data/                export, import, delete
        sync/                Google Drive backup
      about/                 about, privacy policy, legal
  state/                    Riverpod providers per feature
```

A nested page owned by a feature lives under that feature's folder (e.g.
`ui/more/accounts`), not in `ui/components`.

## Version 1 scope

Build only the core experience: accounts, categories, add expense, add
income, transfers, transaction history, search, budgets, basic reports,
Google Drive backup, settings, light and dark mode. Do not try to build every
possible finance feature in v1.

## Main rule

Always prefer simplicity over adding more features. If a feature makes
normal money tracking slower or more confusing, hide it under advanced
options or leave it for a later version.

## Non-goals for v1

- Multi-currency conversion / currency-aware aggregate reports.
- Any account/login requirement or custom backend.
- Every possible finance feature — depth comes in later versions.

## Success

The app is successful if a new user can open it, understand it quickly, and
record an expense in a few seconds without needing a tutorial.

Haircut and salon category artwork comes from `icons/haircut_salon_sheet.png`.
The top-left scissors and top-right barber pole are registered as `haircut`
and `salon`; the lower quadrants are retained as alternate source artwork in
`icons/generated/haircut_salon/`. Slice the four quadrants using:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File app/tool/slice_2x2_category_sheet.ps1 -SourcePath icons/haircut_salon_sheet.png -Keys haircut,salon,haircut_alternate,salon_alternate -OutputDirectory icons/generated/haircut_salon
```

Copy the selected `haircut.webp` and `salon.webp` masters into
`assets_raw/icon_packs_raw/3d/`, then run the category exporter. These are soft 3D
category icons; Meesho and Disney+ remain in the separate brand pack.
