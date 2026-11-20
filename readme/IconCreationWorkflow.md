# SimpleMoney Icon Rules and Workflows

Extracted from [README.md](README.md). There are two icon packs:

| Pack | Location | Use |
|---|---|---|
| `3d` (category pack) | `app/assets/icon_packs/3d/` | Generic categories and activities (food, haircut, salon, insurance…) |
| `logos` | `app/assets/icon_packs/logos/` | Real logos of named services, merchants, banks, payment providers |

Generic activities such as haircut and salon belong in the 3D pack, even when
SMS merchant names automatically select them. Named businesses (Meesho,
Disney+, Kerala Vision…) belong in the brands pack.

General style: one consistent icon style across the app, used the same way for
every category, account, and menu action.

---

## 1. Category icon workflow (3D pack)

The default pack (`3d`) is one consistent soft 3D style. It is named by style,
not by "category", so an alternate downloadable pack can sit alongside it later
without a rename.

### Rules
- Generate artwork as a **transparent 2x2 sheet with exactly four evenly spaced
  icons**.
- Keep the source sheet under `icons/` (e.g. `icons/iconset5.png`).
- Raw crops are **512x512**, stored as lossy WebP in
  `assets_raw/icon_packs_raw/3d/`.
- Optimized app assets are **128x128** lossy WebP (q90, alpha_q100), bundled
  from `app/assets/icon_packs/3d/`. Optional `-CanvasSize 192` if larger assets
  are adopted later.
- Keep **both** the 512px raw crops and the optimized app assets.

### Steps
1. Slice the sheet into named crops:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File app/tool/slice_2x2_category_sheet.ps1 `
     -SourcePath icons/iconset5.png `
     -Keys friends,partner,insurance,bonus `
     -OutputDirectory assets_raw/icon_packs_raw/3d
   ```

2. Add each key to `appIconKeys` in `app/lib/domain/app_icons.dart` and export
   the complete set.
3. Export optimized icons:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File app/tool/export_optimized_category_icons.ps1
   ```

### WebP tooling
Both scripts shell out to `app/tool/bin/cwebp.exe` / `dwebp.exe` (GDI+ has no
WebP codec). These binaries are **not checked in** (gitignored). Download the
Windows release from
https://storage.googleapis.com/downloads.webmproject.org/releases/webp/ and
place them in `app/tool/bin/`.

### Example: haircut and salon
Artwork comes from `icons/haircut_salon_sheet.png`. Top-left scissors →
`haircut`, top-right barber pole → `salon`. The lower quadrants are kept as
alternate source art in `icons/generated/haircut_salon/`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File app/tool/slice_2x2_category_sheet.ps1 -SourcePath icons/haircut_salon_sheet.png -Keys haircut,salon,haircut_alternate,salon_alternate -OutputDirectory icons/generated/haircut_salon
```

Copy the selected `haircut.webp` and `salon.webp` masters into
`assets_raw/icon_packs_raw/3d/`, then run the category exporter.

---

## 2. Service, brand, and bank account icon workflow (brands pack)

### Rules
- Use the **real logo**. Never invent a replacement, hand-draw an approximation,
  or use AI to redesign a brand logo.
- Preserve the logo's shapes, proportions, and brand colors.
- **Square-tile composition is mandatory:** for a horizontal bank or brand
  lockup, make the main symbol large enough to fill the square. If that symbol
  is not clearly recognizable by itself, place the shortest official wordmark
  **underneath** it at a readable size. Never keep the symbol and wordmark
  side-by-side, shrink the full horizontal lockup into the tile, or accept an
  export where the identifying artwork occupies only a small part of the box.
- Enlarging a tiny raster crop does not make a high-quality source; recreate the
  asset by isolating and processing the original.
- Verify the exact business and service (Kerala Vision TV and Kerala Vision
  Broadband artwork are not interchangeable).
- Final asset: **transparent 256x256 lossy WebP, quality 90, alpha quality 100**.
- Keep a master copy in `assets_raw/icon_packs_raw/logos/` as well as the
  bundled asset in `app/assets/icon_packs/logos/`.
- Bank assets are grouped by normalized country under
  `brands/banks/<country>/` in both trees (for example,
  `brands/banks/united_states/`). Merchant, service, and payment-only assets
  are grouped under `brands/brands/`. Normal and `_dark.webp` companions share
  the same directory. When introducing the first bank for a new country, add
  that country directory to the Flutter asset list in `app/pubspec.yaml`.

### Steps
1. **Source**: search Google/Google Images for a high-quality original logo and
   download the original file from its source, not a search thumbnail. Prefer
   the official SVG or brand kit; otherwise a large transparent PNG, official
   Google Play artwork, or a reliable original-logo source. Retain downloads
   under `icons/` (e.g. `icons/isp_sources/`).
2. **Fit to a square tile, main symbol only**: when the source is a horizontal
   lockup (symbol + wordmark side by side, often with a second-language name,
   e.g. Siam Commercial Bank's "SCB / ไทยพาณิชย์" beside its gold Bodhi-leaf
   symbol), **crop out only the recognizable main logo symbol** and fit that
   into the square. Never shrink the whole wide lockup into the square, because
   the symbol becomes tiny and the text unreadable. Drop the side text, slogans
   and any plain presentation tile or background box that is not part of the
   mark. Use the crop-box (`BANK_MARK_CROPS`) or an `isolateBankMark` rule in
   `fetch_brand_icons.mjs` so this stays reproducible. Only if the symbol alone
   isn't recognizable, place the original wordmark *underneath* the symbol
   rather than keeping a long horizontal strip. Keep the
   complete mark, consistent clear padding, and enough visual size to read in
   transaction rows. Make sure cropping leaves no neighboring letters.
   This symbol-first or symbol-over-wordmark composition is the required
   treatment for every wide bank/brand lockup, not an optional styling choice.
   **Never crop a small or low-resolution raster (e.g. a lockup JPG) down to its
   symbol**: the symbol ends up tiny and blurry, the cut clips its edges, and
   the anti-aliased background leaves a white fringe on dark tiles (Saraswat
   Bank was rejected for this). If no large/vector source exists, skip the bank
   and keep the generic bank icon.
3. **Clean up**: remove source backgrounds and unrelated slogans or app labels
   cleanly, preserving transparent edges and internal gaps. Avoid colored
   fringes, jagged edges, clipping, stretched artwork, and accidental
   background boxes. An intentional badge that is part of the original mark may
   stay.
4. **Make it reproducible**: add source URLs and any crop, isolation, or
   stacking operations to `app/tool/fetch_brand_icons.mjs`. From `app/`,
   regenerate only the affected keys to avoid overwriting unrelated artwork:

   ```powershell
   node tool/fetch_brand_icons.mjs --only keralavision actfibernet excitel
   ```

5. **Register**: add stable `brand:<key>` identifiers via the fetch script's
   brand catalog and keep `app/lib/domain/brand_icons.dart` in sync.
   - Banks must have their **bank flag and country**.
   - Payment providers must have their **payment flag**.
6. **Dark variants**: if light and dark surfaces need different assets, add a
   `_dark.webp` companion and keep `generate_brand_dark_variants.mjs` and
   `brand_dark_icons.dart` in sync. Use source variants where available and
   preserve colored accents; **no blanket runtime tint**.
7. **Document**: record source links and processing choices in **both** brand
   `ATTRIBUTION.md` files, and update outdated notes when a source or treatment
   changes.
8. **Merchant matching**: add merchant aliases to `service_icon.dart` where
   appropriate, covering SMS titles with spaces, punctuation, and payment
   suffixes without matching unrelated names. Preserve explicitly selected
   transaction icons. Category classification stays in the SMS parser package,
   separate from display icon matching.
9. **Verify**: inspect the exported assets at actual transaction and picker
   sizes on both light and dark tiles, and inspect the final WebPs, not just the
   large downloaded source. Run the relevant icon catalog and transaction icon
   tests after registration or matching changes.

---

## Quick checklist

- [ ] Right pack chosen (generic → `3d`, named brand → `brands`)
- [ ] Source kept under `icons/`; raw master kept under `assets_raw/icon_packs_raw/`
- [ ] Correct size/format (3D: 128px WebP; brands: 256px WebP; q90, alpha_q100)
- [ ] Key registered (`app_icons.dart` or `brand_icons.dart` / fetch script catalog)
- [ ] Dark variant + `brand_dark_icons.dart` updated if needed
- [ ] `ATTRIBUTION.md` (both) updated for brands
- [ ] `service_icon.dart` aliases added if SMS merchant matching is needed
- [ ] No white fringe or clipped edges on the dark tile; no crops from small rasters
- [ ] Checked at real sizes on light and dark; icon tests pass
