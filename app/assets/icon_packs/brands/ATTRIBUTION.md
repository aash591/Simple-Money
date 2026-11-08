# Brand icon sources

CRED uses the original transparent vertical light/dark SVG logos from its
[official brand kit](https://newsroom.cred.club/brand/), preserving the complete
shield and wordmark in both theme variants.

Prime Video uses the transparent blue logo from
[Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Prime_Video_logo_(2024).svg),
preserving the source paths and color without an app-icon background.

JioHotstar uses the transparent star symbol from
[Dashboard Icons](https://github.com/homarr-labs/dashboard-icons/blob/main/png/jiohotstar.png).
ZEE5 uses the mark paths from its
[official SVG](https://www.zee5.com/images/ZEE5_logo.svg?ver=7.1.7), with the
full-canvas background removed and monochrome black/white theme variants.
These are transparent mark-only WebPs; no rectangular logo backgrounds are bundled.

The mark-only bank assets use high-resolution transparent symbol artwork from
[CompaniesLogo](https://companieslogo.com/) where available. The BCA, BTN, and
Mandiri vectors are isolated from original logo SVGs hosted by
[Wikimedia Commons](https://commons.wikimedia.org/); their wordmark paths are
excluded from the generated assets.

The mark-only `uco`, `ksfe`, and `manappuram` vectors were reconstructed from
high-resolution original logo references found through image search. The
`keralagramin` SVG embeds isolated source artwork from the same research.

The added service marks use original artwork, resized onto transparent 256 px
WebP canvases. [Ola](https://commons.wikimedia.org/wiki/File:Ola_Cabs_logo.svg),
[KSEB](https://commons.wikimedia.org/wiki/File:KSEB_Logo_2022.svg),
[redBus](https://commons.wikimedia.org/wiki/File:RedBus_Logo_(2015-present).svg),
[BSNL](https://commons.wikimedia.org/wiki/File:BSNL_logo_with_slogan.svg),
[Vi](https://commons.wikimedia.org/wiki/File:Vodafone_Idea_logo_(2026).svg),
[Kochi Metro](https://commons.wikimedia.org/wiki/File:Kochi_Metro_logo.png),
[Delhi Metro](https://commons.wikimedia.org/wiki/File:Delhi_Metro_logo.svg),
[Namma Metro](https://commons.wikimedia.org/wiki/File:Namma_metro_icon.svg),
[Chennai Metro](https://commons.wikimedia.org/wiki/File:Chennai_Metro_logo.svg),
[Hyderabad Metro](https://commons.wikimedia.org/wiki/File:Seal_of_Hyderabad_Metro_Rail.svg),
and [Mumbai Metro](https://commons.wikimedia.org/wiki/File:Mumbai_metro_Logo.png)
come from Wikimedia Commons. Their individual file pages contain the source
and reuse terms. [Rapido](https://rapido.bike/images/NewLogo.svg),
[Namma Yatri](https://www.nammayatri.in/WebsiteIcon.svg),
[Kerala Water Authority](https://kwa.kerala.gov.in/wp-content/uploads/2020/07/og_logo.webp),
[IRCTC](https://www.irctc.com/), and
[Asianet Broadband](https://asianetbroadband.in/wp-content/uploads/2024/01/AF_logo.png)
come from the providers' websites; the IRCTC emblem is the inline SVG in its
site header. These files identify a provider and do not imply endorsement.
The [Kerala KSRTC](https://play.google.com/store/apps/details?id=com.keralasrtc.app)
badge is from its official app listing. The BSNL asset uses the globe and
arrows from the linked vector. Asianet uses a transparent PNG from its site.

The Equitas and Kotak 811 marks were recreated from high-resolution bank and
press references. Amazon and Kotak Mahindra use transparent symbol assets from
CompaniesLogo. The OpenAI Blossom follows OpenAI's current official design
guidelines and uses a mark-only Wikimedia vector. Flipkart, Microsoft, Adobe,
Domino's, and Myntra are transparent mark-only reconstructions; no wordmark
fallbacks are offered in the picker.

All other SVGs in this directory are from [Simple Icons](https://github.com/simple-icons/simple-icons), licensed CC0.
Brand names and marks remain their respective owners' trademarks and are used
only to identify a user's selected financial institution or service.

OneCard and BOBCARD use their official Google Play app icons: [OneCard](https://play.google.com/store/apps/details?id=com.creditcard.onecard) and [BOBCARD](https://play.google.com/store/apps/details?id=com.bob.fe). SBI Card uses a [transparent Wikimedia vector](https://commons.wikimedia.org/wiki/File:SBI_Card_logo.svg); its original symbol, SBI letters, and Card letters are stacked to fit the square icon. These sources are resized to the same 256 px WebP canvas as the other brand assets.

Simple Icons' catalog colors are baked into their normal WebP files; the app
does not tint them at render time. The small set of `*_dark.webp` companions
is explicitly selected and treated per logo in
`tool/generate_brand_dark_variants.mjs` after checking the normal marks on
the picker's dark tile. Readable originals, including Equitas and BTN, are
used in both themes. Selected companions use a white reverse while retaining
each mark's distinctive accents. This follows the dark-use
patterns in [Visa's standards](https://corporate.visa.com/en/about-visa/brand.html),
[Samsung Pay's guidelines](https://developer.paypal.com/braintree/files/samsung-pay-brand-guidelines.pdf),
[BCA's identity manual](https://www.bca.co.id/-/media/Feature/Card/List-Card/Tentang-BCA/Brand-Assets/PDF/Corporate-Identity-Manual--CIM--BCA.pdf),
and [Amazon's reverse-logo examples](https://developer.amazon.com/en-US/alexa/branding/echo-guidelines/identity-guidelines/logo-guidelines).
Jio's companion uses the [Reliance media kit](https://www.beta-prod.ril.com/news-media/resource-center/media-kit/jio) monochrome artwork, with its circle changed to the blue of the normal Jio asset and its letters kept white.
PayPal keeps its dark-blue mark on a white badge, in line with [PayPal's logo guidance](https://www.paypalobjects.com/webstatic/en_US/developer/docs/pdf/PayPalX_Interface_Guide_Edition1_1.pdf).

Meesho uses the transparent symbol SVG from
[CompaniesLogo](https://companieslogo.com/meesho/logo/).
Disney+ uses the transparent original logo from
[Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Disney%2B_2024.svg).
Both use transparent 256px lossy WebP canvases (quality 90, alpha quality 100).
Regenerate only these assets with `node tool/fetch_brand_icons.mjs --only meesho disneyplus`
from `app/`, and retain copies in `assets_raw/icon_packs_raw/brands/`.

## Indian internet providers

These original logos are sourced from the providers' own websites:
- [Kerala Vision Broadband](https://keralavisionisp.com/) (`assets/logo-Dnpp9r7N.png`).
- [ACT Fibernet](https://www.actcorp.in/) (`themes/custom/actcorp/logo.svg`); the visible white canvas is removed, preserving the mark and clipping path.
- [Excitel](https://www.excitel.com/) (`wp-content/uploads/2022/07/logo-excitel.png`).
- [Hathway](https://www.hathway.com/) (`home_images/logo.svg`).
- [Tata Play Fiber](https://www.tataplayfiber.com/) (`themes/custom/tpf_combine/logo.svg`); monochrome black for light surfaces, original white for dark surfaces.
- [YOU Broadband](https://youbroadband.in/) (`images/logo.png`), preserving its original badge artwork.

Assets use 256px lossy WebP (q90, alpha_q100); copies are retained under
`assets_raw/icon_packs_raw/brands/`. Regenerate from `app/`:
`node tool/fetch_brand_icons.mjs --only keralavision actfibernet excitel hathway tataplayfiber youbroadband`.

Kerala Vision and Excitel now use only their original standalone symbols,
isolated from the horizontal source artwork. ACT uses only its original A
path (excluding the C and T). Symbol isolation is reproducible in the fetch
script, allowing these marks to fill square tiles without tiny side text.

The latest Kerala Vision and Excitel assets are clean vector reconstructions
of their symbols in `MARK_ONLY_SVGS`, replacing the earlier raster crops.
Kerala Vision's metallic ring is simplified to a flat outline for small tiles.
ACT retains its complete official ACT wordmark on a transparent square canvas,
replacing the isolated A. These treatments supersede the earlier crop notes.

Latest source correction: hand-drawn Kerala Vision and Excitel reconstructions
have been removed. Kerala Vision uses the 512px original emblem from its
[Google Play listing](https://play.google.com/store/apps/details?id=com.nexge.kcclvoip),
with the cyan background and Voice label excluded. Excitel uses the original
symbol isolated from its [3840px official banner](https://www.excitel.com/wp-content/uploads/2025/04/Excitel_1920x720_2-1-1.png),
rendered in the official orange. Original downloads are retained in
`icons/isp_sources/`; crop/background processing is in the fetch script.
This supersedes the reconstruction notes above.
