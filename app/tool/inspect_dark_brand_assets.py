import re
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

app = Path(__file__).resolve().parents[1]
catalog = (app / 'lib/domain/brand_icons.dart').read_text()
keys = []
for entry in catalog.split('  BrandIcon(')[1:]:
    if 'isOriginal: true' in entry:
        keys.append(re.search(r"'([^']+)'", entry).group(1))

font = ImageFont.truetype('C:/Windows/Fonts/arial.ttf', 13)
for page, start in enumerate(range(0, len(keys), 40), 1):
    sheet = Image.new('RGB', (800, 600), '#101315')
    draw = ImageDraw.Draw(sheet)
    for index, key in enumerate(keys[start:start + 40]):
        x = (index % 8) * 100
        y = (index // 8) * 120
        draw.rounded_rectangle((x + 5, y + 5, x + 95, y + 95), 8, fill='#454b50')
        icon = Image.open(app / 'assets/icon_packs/brands' / f'{key}.webp').convert('RGBA')
        icon.thumbnail((78, 78), Image.Resampling.LANCZOS)
        tile = Image.new('RGBA', (90, 90), (0, 0, 0, 0))
        tile.alpha_composite(icon, ((90 - icon.width) // 2, (90 - icon.height) // 2))
        sheet.paste(tile, (x + 5, y + 5), tile)
        draw.text((x + 3, y + 98), key[:13], font=font, fill='white')
    sheet.save(app / 'tool' / f'brand-light-on-dark-{page}.png')
    print(page, keys[start:start + 40])

# Simple Icons now have their catalog color baked into the WebP.
simple = []
for entry in catalog.split('  BrandIcon(')[1:]:
    if 'isOriginal: true' in entry:
        continue
    key = re.search(r"'([^']+)'", entry).group(1)
    simple.append(key)

for page, start in enumerate(range(0, len(simple), 40), 1):
    sheet = Image.new('RGB', (800, 600), '#101315')
    draw = ImageDraw.Draw(sheet)
    for index, key in enumerate(simple[start:start + 40]):
        x = (index % 8) * 100
        y = (index // 8) * 120
        draw.rounded_rectangle((x + 5, y + 5, x + 95, y + 95), 8, fill='#454b50')
        icon = Image.open(app / 'assets/icon_packs/brands' / f'{key}.webp').convert('RGBA')
        icon.thumbnail((78, 78), Image.Resampling.LANCZOS)
        tile = Image.new('RGBA', (90, 90), (0, 0, 0, 0))
        tile.alpha_composite(icon, ((90 - icon.width) // 2, (90 - icon.height) // 2))
        sheet.paste(tile, (x + 5, y + 5), tile)
        draw.text((x + 3, y + 98), key[:13], font=font, fill='white')
    sheet.save(app / 'tool' / f'brand-simple-on-dark-{page}.png')
    print('simple', page, simple[start:start + 40])

variants = [line.strip().strip("',") for line in
            (app / 'lib/domain/brand_dark_icons.dart').read_text().splitlines()
            if line.lstrip().startswith("'")]
sheet = Image.new('RGB', (800, ((len(variants) + 7) // 8) * 120), '#101315')
draw = ImageDraw.Draw(sheet)
for index, key in enumerate(variants):
    x = (index % 8) * 100
    y = (index // 8) * 120
    draw.rounded_rectangle((x + 5, y + 5, x + 95, y + 95), 8, fill='#454b50')
    icon = Image.open(app / 'assets/icon_packs/brands' / f'{key}_dark.webp').convert('RGBA')
    icon.thumbnail((78, 78), Image.Resampling.LANCZOS)
    tile = Image.new('RGBA', (90, 90), (0, 0, 0, 0))
    tile.alpha_composite(icon, ((90 - icon.width) // 2, (90 - icon.height) // 2))
    sheet.paste(tile, (x + 5, y + 5), tile)
    draw.text((x + 3, y + 98), key[:13], font=font, fill='white')
sheet.save(app / 'tool/brand-selected-dark.png')
