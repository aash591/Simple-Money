"""Builds the Android launcher icon from assets_raw/app_icon_master.png.

Run from app/:  python tool/generate_launcher_icons.py

Writes, per density:
  drawable-*/ic_launcher_foreground.png   the wallet, inset into the adaptive
                                          icon's safe zone (white background
                                          comes from @color/ic_launcher_background)
  drawable-*/ic_launcher_monochrome.png   its silhouette, for themed icons
  drawable-*/ic_notification_foreground.png  the wallet small, behind
                                          ic_notification_app (status bar)
  mipmap-*/ic_launcher_wallet2.png        a white rounded tile, for Android 7

The launcher icon is called ic_launcher_wallet2 on purpose. ColorOS keeps the
icon it first drew for a given icon resource, through reinstalls and new
version codes; a new name is the one thing that makes it draw it again. Bump
the name (ic_launcher_wallet3, ...) together with the manifest whenever the
icon changes and the phone still shows the old one.
  mipmap-*/ic_app_art.png                 the bare transparent wallet, for the
                                          home screen widgets
  drawable-nodpi/splash_icon_light.png    the splash icon, as in the app's
  drawable-nodpi/splash_icon_dark.png     account-setup screen: the wallet on
                                          a white tile, or on frosted glass in
                                          dark mode, where white would glare

flutter_launcher_icons is not used for these: it would put the bare artwork
back full-bleed, which launchers stretch into a purple square.
"""

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

APP = Path(__file__).resolve().parent.parent
RES = APP / 'android/app/src/main/res'
MASTER = APP.parent / 'assets_raw/app_icon_master.png'

DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}

# Adaptive layers are 108dp, of which launchers show the middle 72dp, ColorOS
# included. The wallet's longest side takes 46% of the layer: about 50dp, 69%
# of the visible tile, in line with the icons around it. A launcher that draws
# all 108dp shows it smaller, never cropped.
ADAPTIVE_DP = 108
ADAPTIVE_ART = .46
# The legacy icon is 48dp: a white tile with the wallet at 70% of it.
LEGACY_DP = 48
LEGACY_ART = .70


def art(visible_only: bool = False) -> Image.Image:
    """The master artwork cropped to its bounds. The master has a faint glow
    around the wallet; [visible_only] crops to the wallet itself, so sizes
    given for it mean the wallet and not the glow."""
    image = Image.open(MASTER).convert('RGBA')
    alpha = image.getchannel('A')
    if visible_only:
        alpha = alpha.point(lambda v: 255 if v >= 64 else 0)
    return image.crop(alpha.getbbox())


def fit(source: Image.Image, canvas: int, share: float) -> Image.Image:
    """[source] scaled so its longest side is [share] of a square [canvas],
    centred on a transparent square."""
    scale = canvas * share / max(source.size)
    size = (round(source.width * scale), round(source.height * scale))
    scaled = source.resize(size, Image.LANCZOS)
    out = Image.new('RGBA', (canvas, canvas))
    out.alpha_composite(
        scaled, ((canvas - size[0]) // 2, (canvas - size[1]) // 2)
    )
    return out


def monochrome(foreground: Image.Image) -> Image.Image:
    """White silhouette; the white S and highlights are cut out of it, so the
    themed icon still reads as the wallet with its S."""
    out = Image.new('RGBA', foreground.size)
    pixels = foreground.load()
    target = out.load()
    for y in range(foreground.height):
        for x in range(foreground.width):
            r, g, b, a = pixels[x, y]
            light = min(r, g, b) > 170
            target[x, y] = (255, 255, 255, 0 if light else a)
    return out


def legacy(source: Image.Image, size: int) -> Image.Image:
    # Drawn at 4x and reduced, for smooth corners.
    big = size * 4
    tile = Image.new('RGBA', (big, big))
    inset = round(big / LEGACY_DP)  # The 1dp margin legacy icons keep.
    ImageDraw.Draw(tile).rounded_rectangle(
        (inset, inset, big - inset - 1, big - inset - 1),
        radius=round(big * .22),
        fill=(255, 255, 255, 255),
    )
    tile.alpha_composite(fit(source, big, LEGACY_ART))
    return tile.resize((size, size), Image.LANCZOS)


# The splash icon: the system draws a 288dp square; the tile is 160dp, its
# corners 28% (as BackupHero in the app), the logo 84% of it. Drawn at 4x.
SPLASH_PX = 288 * 4
TILE_PX = 160 * 4
LOGO_PX = round(TILE_PX * .84)
ACCENT = (128, 85, 232)


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new('L', (size * 2, size * 2), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * 2 - 1, size * 2 - 1), radius=radius * 2, fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def splash_icon(source: Image.Image, dark: bool) -> Image.Image:
    canvas = Image.new('RGBA', (SPLASH_PX, SPLASH_PX))
    left = (SPLASH_PX - TILE_PX) // 2
    box = (left, left)
    mask = rounded_mask(TILE_PX, round(TILE_PX * .28))
    if dark:
        # Frosted glass: a white veil, a little brighter at the top. No
        # outline: a bright rim around it reads as a stray border.
        veil = Image.new('RGBA', (TILE_PX, TILE_PX))
        px = veil.load()
        for y in range(TILE_PX):
            alpha = round(255 * (.17 - .09 * y / TILE_PX))
            for x in range(TILE_PX):
                px[x, y] = (255, 255, 255, alpha)
        veil.putalpha(ImageChops.multiply(veil.getchannel('A'), mask))
        canvas.alpha_composite(veil, box)
    else:
        # A soft accent glow below the white tile, as the app draws it.
        glow = Image.new('RGBA', (SPLASH_PX, SPLASH_PX))
        shape = Image.new('L', (SPLASH_PX, SPLASH_PX), 0)
        shape.paste(mask.point(lambda v: v * .16), (left, left + 32))
        glow.putalpha(shape.filter(ImageFilter.GaussianBlur(56)))
        glow.paste(Image.new('RGBA', glow.size, ACCENT + (0,)), mask=None)
        glow.putalpha(shape.filter(ImageFilter.GaussianBlur(56)))
        canvas.alpha_composite(glow)
        tile = Image.new('RGBA', (TILE_PX, TILE_PX), (255, 255, 255, 255))
        tile.putalpha(mask)
        canvas.alpha_composite(tile, box)
    canvas.alpha_composite(
        fit(source, LOGO_PX, 1),
        ((SPLASH_PX - LOGO_PX) // 2, (SPLASH_PX - LOGO_PX) // 2),
    )
    return canvas


def main() -> None:
    source = art(visible_only=True)
    full = art()
    for name, scale in DENSITIES.items():
        adaptive = round(ADAPTIVE_DP * scale)
        foreground = fit(source, adaptive, ADAPTIVE_ART)
        foreground.save(RES / f'drawable-{name}/ic_launcher_foreground.png')
        monochrome(foreground).save(
            RES / f'drawable-{name}/ic_launcher_monochrome.png'
        )
        size = round(LEGACY_DP * scale)
        legacy(source, size).save(RES / f'mipmap-{name}/ic_launcher_wallet2.png')
        fit(full, adaptive, .45).save(
            RES / f'drawable-{name}/ic_notification_foreground.png'
        )
        # The bare artwork, as the launcher icon was before.
        fit(source, size, 1).save(RES / f'mipmap-{name}/ic_app_art.png')
    out = RES / 'drawable-nodpi'
    out.mkdir(exist_ok=True)
    for dark in (False, True):
        splash_icon(full, dark).save(
            out / f"splash_icon_{'dark' if dark else 'light'}.png"
        )
    print('Launcher icons written to', RES)


if __name__ == '__main__':
    main()
