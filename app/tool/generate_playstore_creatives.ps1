param(
  [string]$CaptureDirectory = (Join-Path $PSScriptRoot '..\..\assets_raw\playstoreAssets\captures'),
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\assets_raw\playstoreAssets')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$masterIcon = Join-Path $PSScriptRoot '..\..\assets_raw\app_icon_master.png'
$backgroundLight = Join-Path $OutputDirectory 'backgrounds\gold-chart-light.png'
$backgroundDark = Join-Path $OutputDirectory 'backgrounds\gold-chart-aurora.png'
$featureBackground = Join-Path $OutputDirectory 'backgrounds\gold-chart-feature.png'
foreach ($required in @($masterIcon, $backgroundLight, $backgroundDark, $featureBackground)) {
  if (-not (Test-Path -LiteralPath $required)) { throw "Missing creative source: $required" }
}

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class PlayStoreCreativeGenerator {
  private static readonly Color Purple = Color.FromArgb(255, 128, 85, 232);
  private static readonly Color DeepPurple = Color.FromArgb(255, 42, 19, 82);
  private static readonly Color Ink = Color.FromArgb(255, 29, 24, 39);
  private static readonly Color Muted = Color.FromArgb(255, 92, 83, 108);
  private static readonly Color Green = Color.FromArgb(255, 36, 181, 116);
  private static readonly Color Paper = Color.FromArgb(255, 251, 250, 252);

  private static GraphicsPath RoundRect(RectangleF rect, float radius) {
    float diameter = radius * 2;
    var path = new GraphicsPath();
    path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
    path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
    path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
    path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
    path.CloseFigure();
    return path;
  }

  private static Graphics Canvas(Bitmap bitmap) {
    var g = Graphics.FromImage(bitmap);
    g.SmoothingMode = SmoothingMode.AntiAlias;
    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
    g.CompositingQuality = CompositingQuality.HighQuality;
    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
    return g;
  }

  private static void DrawRibbon(Graphics g, PointF[] points, float width, Color color) {
    using (var path = new GraphicsPath())
    using (var pen = new Pen(color, width)) {
      pen.StartCap = LineCap.Round;
      pen.EndCap = LineCap.Round;
      pen.LineJoin = LineJoin.Round;
      path.AddBezier(points[0], points[1], points[2], points[3]);
      g.DrawPath(pen, path);
    }
  }

  private static void DrawCover(Graphics g, Image image, RectangleF destination) {
    float scale = Math.Max(destination.Width / image.Width, destination.Height / image.Height);
    float sourceWidth = destination.Width / scale;
    float sourceHeight = destination.Height / scale;
    float sourceX = (image.Width - sourceWidth) / 2f;
    float sourceY = (image.Height - sourceHeight) / 2f;
    g.DrawImage(image, destination, new RectangleF(sourceX, sourceY, sourceWidth, sourceHeight), GraphicsUnit.Pixel);
  }

  private static void DrawMoneyDecor(Graphics g, int variant, int height) {
    if (variant % 2 == 0) {
      DrawRibbon(g, new [] { new PointF(-170, 720), new PointF(130, 500), new PointF(245, 1040), new PointF(90, 1360) },
        120, Color.FromArgb(36, Purple));
      DrawRibbon(g, new [] { new PointF(930, 380), new PointF(690, 620), new PointF(1160, 920), new PointF(990, 1280) },
        86, Color.FromArgb(45, Green));
    } else {
      DrawRibbon(g, new [] { new PointF(1050, 570), new PointF(720, 410), new PointF(770, 1030), new PointF(1110, 1160) },
        112, Color.FromArgb(38, Purple));
      DrawRibbon(g, new [] { new PointF(-80, 900), new PointF(250, 680), new PointF(310, 1210), new PointF(-100, 1450) },
        78, Color.FromArgb(44, Green));
    }

    using (var coinPen = new Pen(Color.FromArgb(90, Purple), 3))
    using (var rupeeFont = new Font("Segoe UI Symbol", 28, FontStyle.Bold, GraphicsUnit.Pixel))
    using (var rupeeBrush = new SolidBrush(Color.FromArgb(150, DeepPurple))) {
      var coins = variant % 2 == 0
        ? new [] { new PointF(78, 1510), new PointF(934, 1420), new PointF(902, 1725) }
        : new [] { new PointF(105, 1470), new PointF(950, 1510), new PointF(130, 1745) };
      foreach (var p in coins) {
        g.DrawEllipse(coinPen, p.X - 29, p.Y - 29, 58, 58);
        g.DrawString("\u20B9", rupeeFont, rupeeBrush, p.X - 17, p.Y - 22);
      }
    }

    using (var dot = new SolidBrush(Color.FromArgb(62, DeepPurple))) {
      for (int i = 0; i < 8; i++) g.FillEllipse(dot, 72 + (i * 18), height - 82, 5, 5);
    }
  }

  private static Bitmap MakePhone(Bitmap screenshot) {
    if (screenshot.Width != 1080 || screenshot.Height < 2000)
      throw new InvalidOperationException("Expected a 1080px-wide portrait capture; got " + screenshot.Width + "x" + screenshot.Height + ".");

    var phone = new Bitmap(707, 1532, PixelFormat.Format32bppArgb);
    using (var g = Canvas(phone)) {
      g.Clear(Color.Transparent);
      var shadowRect = new RectangleF(9, 12, 689, 1514);
      using (var shadowPath = RoundRect(shadowRect, 62))
      using (var shadow = new SolidBrush(Color.FromArgb(42, 25, 15, 48))) g.FillPath(shadow, shadowPath);

      var outer = new RectangleF(0, 0, 707, 1532);
      using (var outerPath = RoundRect(outer, 64))
      using (var frame = new SolidBrush(Color.FromArgb(255, 24, 21, 30))) g.FillPath(frame, outerPath);

      var screen = new RectangleF(16, 16, 675, 1500);
      using (var screenPath = RoundRect(screen, 50)) {
        var state = g.Save();
        g.SetClip(screenPath);
        g.DrawImage(screenshot, screen, new RectangleF(0, 0, screenshot.Width, screenshot.Height), GraphicsUnit.Pixel);
        g.Restore(state);
      }
      using (var screenPath = RoundRect(screen, 50))
      using (var border = new Pen(Color.FromArgb(90, 255, 255, 255), 2)) g.DrawPath(border, screenPath);
    }
    return phone;
  }

  private static void DrawHeader(Graphics g, string eyebrow, string lineOne, string lineTwo, string subtitle, int number) {
    var shadowCard = new RectangleF(78, 36, 932, 350);
    using (var shadowPath = RoundRect(shadowCard, 42))
    using (var shadowBrush = new SolidBrush(Color.FromArgb(34, 42, 19, 82)))
      g.FillPath(shadowBrush, shadowPath);

    var copyCard = new RectangleF(70, 24, 940, 350);
    using (var cardPath = RoundRect(copyCard, 42))
    using (var cardBrush = new SolidBrush(Color.FromArgb(249, 255, 255, 255)))
      g.FillPath(cardBrush, cardPath);
    using (var cardPath = RoundRect(copyCard, 42))
    using (var cardBorder = new Pen(Color.FromArgb(28, Purple), 2))
      g.DrawPath(cardBorder, cardPath);

    using (var eyebrowFont = new Font("Segoe UI", 18, FontStyle.Bold, GraphicsUnit.Pixel)) {
      var measured = g.MeasureString(eyebrow.ToUpperInvariant(), eyebrowFont);
      var pill = new RectangleF(102, 51, measured.Width + 50, 42);
      using (var pillPath = RoundRect(pill, 21))
      using (var pillBrush = new SolidBrush(Color.FromArgb(30, Purple))) g.FillPath(pillBrush, pillPath);
      using (var dot = new SolidBrush(Purple)) g.FillEllipse(dot, 118, 66, 12, 12);
      using (var eyebrowBrush = new SolidBrush(DeepPurple))
        g.DrawString(eyebrow.ToUpperInvariant(), eyebrowFont, eyebrowBrush, 142, 61);
    }

    var numberCircle = new RectangleF(916, 48, 58, 58);
    using (var numberFill = new SolidBrush(Color.FromArgb(24, Purple))) g.FillEllipse(numberFill, numberCircle);
    using (var numberFont = new Font("Bahnschrift", 19, FontStyle.Bold, GraphicsUnit.Pixel))
    using (var numberBrush = new SolidBrush(Color.FromArgb(155, DeepPurple))) {
      var numberText = number.ToString("00");
      var numberSize = g.MeasureString(numberText, numberFont);
      g.DrawString(numberText, numberFont, numberBrush,
        numberCircle.X + ((numberCircle.Width - numberSize.Width) / 2f),
        numberCircle.Y + ((numberCircle.Height - numberSize.Height) / 2f) - 1);
    }

    using (var titleFont = new Font("Bahnschrift", 64, FontStyle.Bold, GraphicsUnit.Pixel)) {
      using (var titleBrush = new SolidBrush(Ink))
        g.DrawString(lineOne, titleFont, titleBrush, new RectangleF(100, 106, 850, 76));
      using (var accentBrush = new SolidBrush(Purple))
        g.DrawString(lineTwo, titleFont, accentBrush, new RectangleF(100, 173, 850, 76));
    }

    using (var subtitleFont = new Font("Segoe UI", 27, FontStyle.Regular, GraphicsUnit.Pixel))
    using (var subtitleBrush = new SolidBrush(Muted))
      g.DrawString(subtitle, subtitleFont, subtitleBrush, new RectangleF(104, 273, 850, 62));
  }

  public static void Screenshot(string sourcePath, string backgroundPath, string outputPath,
    string eyebrow, string lineOne, string lineTwo, string subtitle, int number) {
    using (var source = new Bitmap(sourcePath))
    using (var background = new Bitmap(backgroundPath))
    using (var phone = MakePhone(source))
    using (var output = new Bitmap(1080, 1920, PixelFormat.Format24bppRgb))
    using (var g = Canvas(output)) {
      DrawCover(g, background, new RectangleF(0, 0, 1080, 1920));
      DrawHeader(g, eyebrow, lineOne, lineTwo, subtitle, number);
      g.DrawImage(phone, new Rectangle(187, 352, 707, 1532), 0, 0, phone.Width, phone.Height, GraphicsUnit.Pixel);
      output.Save(outputPath, ImageFormat.Png);
    }
  }

  public static void StoreIcon(string iconPath, string outputPath) {
    using (var icon = new Bitmap(iconPath))
    using (var output = new Bitmap(512, 512, PixelFormat.Format24bppRgb))
    using (var g = Canvas(output)) {
      g.Clear(Color.FromArgb(255, 48, 20, 94));
      g.DrawImage(icon, new Rectangle(22, 22, 468, 468), 0, 0, icon.Width, icon.Height, GraphicsUnit.Pixel);
      output.Save(outputPath, ImageFormat.Png);
    }
  }

  public static void FeatureGraphic(string backgroundPath, string iconPath, string homePath, string outputPath) {
    using (var background = new Bitmap(backgroundPath))
    using (var icon = new Bitmap(iconPath))
    using (var home = new Bitmap(homePath))
    using (var phone = MakePhone(home))
    using (var output = new Bitmap(1024, 500, PixelFormat.Format24bppRgb))
    using (var g = Canvas(output)) {
      DrawCover(g, background, new RectangleF(0, 0, 1024, 500));

      var copyPanel = new RectangleF(26, 18, 650, 354);
      using (var copyPath = RoundRect(copyPanel, 28))
      using (var panel = new SolidBrush(Color.FromArgb(242, 255, 255, 255)))
        g.FillPath(panel, copyPath);

      g.DrawImage(icon, new Rectangle(46, 30, 76, 76), 0, 0, icon.Width, icon.Height, GraphicsUnit.Pixel);
      using (var brandFont = new Font("Bahnschrift", 28, FontStyle.Bold, GraphicsUnit.Pixel))
      using (var brandBrush = new SolidBrush(DeepPurple)) g.DrawString("SimpleMoney", brandFont, brandBrush, 132, 52);

      using (var titleFont = new Font("Bahnschrift", 51, FontStyle.Bold, GraphicsUnit.Pixel)) {
        using (var titleBrush = new SolidBrush(Ink)) g.DrawString("All your money.", titleFont, titleBrush, 48, 126);
        using (var accentBrush = new SolidBrush(Purple)) g.DrawString("One clear view.", titleFont, accentBrush, 48, 181);
      }
      using (var subtitleFont = new Font("Segoe UI", 24, FontStyle.Regular, GraphicsUnit.Pixel))
      using (var subtitleBrush = new SolidBrush(Muted))
        g.DrawString("Multi-currency tracking built for real life.", subtitleFont, subtitleBrush, 52, 250);

      var featurePill = new RectangleF(48, 303, 460, 42);
      using (var featurePath = RoundRect(featurePill, 21))
      using (var featureFill = new SolidBrush(Color.FromArgb(30, Purple))) g.FillPath(featureFill, featurePath);
      using (var featureFont = new Font("Segoe UI", 17, FontStyle.Bold, GraphicsUnit.Pixel))
      using (var featureBrush = new SolidBrush(DeepPurple))
        g.DrawString("ACCOUNTS  \u2022  BUDGETS  \u2022  PAYMENTS", featureFont, featureBrush, 67, 314);

      g.DrawImage(phone, new Rectangle(766, 3, 228, 494), 0, 0, phone.Width, phone.Height, GraphicsUnit.Pixel);
      output.Save(outputPath, ImageFormat.Png);
    }
  }
}
'@

$screenshots = @(
  @{ Source = '01-home.png'; Output = 'phone-1.png'; Eyebrow = 'Your financial home'; LineOne = 'Your money,'; LineTwo = 'finally clear.'; Subtitle = 'Balances, bills and commitments in one calm view.' },
  @{ Source = '02-transactions.png'; Output = 'phone-2.png'; Eyebrow = 'Effortless tracking'; LineOne = 'Transactions,'; LineTwo = 'without the noise.'; Subtitle = 'Money in and money out, clear at a glance.' },
  @{ Source = '03-budgets.png'; Output = 'phone-3.png'; Eyebrow = 'Smart budgets'; LineOne = 'Budgets that'; LineTwo = 'keep you on track.'; Subtitle = 'Set limits by category and always know what remains.' },
  @{ Source = '05-loans.png'; Output = 'phone-4.png'; Eyebrow = 'Loans made clear'; LineOne = 'Loans, minus'; LineTwo = 'the guesswork.'; Subtitle = 'Track balances, repayments and every upcoming EMI.' },
  @{ Source = '06-recurring-payments.png'; Output = 'phone-5.png'; Eyebrow = 'Stay ahead'; LineOne = 'Recurring bills,'; LineTwo = 'already planned.'; Subtitle = 'See upcoming payments and what each month costs.' },
  @{ Source = '07-ai-assistant.png'; Output = 'phone-6.png'; Eyebrow = 'AI assistant'; LineOne = 'Ask your money'; LineTwo = 'anything.'; Subtitle = 'Share context only when you choose, for a limited time.' },
  @{ Source = '04-more-aurora.png'; Output = 'phone-7.png'; Eyebrow = 'Aurora Glass'; LineOne = 'A little more'; LineTwo = 'your style.'; Subtitle = 'Luminous glass surfaces with a beautiful dark glow.' },
  @{ Source = '08-customization.png'; Output = 'phone-8.png'; Eyebrow = 'Make it yours'; LineOne = 'Light, dark,'; LineTwo = 'and all yours.'; Subtitle = 'Choose a theme, glass style and accent color.' }
)

$screenshotsDirectory = Join-Path $OutputDirectory 'screenshots'
New-Item -ItemType Directory -Force -Path $screenshotsDirectory | Out-Null

for ($index = 0; $index -lt $screenshots.Count; $index++) {
  $item = $screenshots[$index]
  $source = Join-Path $CaptureDirectory $item.Source
  if (-not (Test-Path -LiteralPath $source)) { throw "Missing fresh profile capture: $source" }
  [PlayStoreCreativeGenerator]::Screenshot(
    $source,
    $(if ($index -ge 6) { $backgroundDark } else { $backgroundLight }),
    (Join-Path $screenshotsDirectory $item.Output),
    $item.Eyebrow,
    $item.LineOne,
    $item.LineTwo,
    $item.Subtitle,
    $index + 1
  )
}

[PlayStoreCreativeGenerator]::StoreIcon(
  $masterIcon,
  (Join-Path $OutputDirectory 'app-icon-512.png')
)
[PlayStoreCreativeGenerator]::FeatureGraphic(
  $featureBackground,
  $masterIcon,
  (Join-Path $CaptureDirectory '01-home.png'),
  (Join-Path $OutputDirectory 'feature-graphic-1024x500.png')
)

Write-Host "Generated Play Store assets in $OutputDirectory"
