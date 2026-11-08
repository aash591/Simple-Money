# PdfBox-Android (UPI statement import) loads fonts and filters reflectively;
# its optional JPEG 2000 and encryption extras aren't bundled.
-keep class com.tom_roush.pdfbox.** { *; }
-dontwarn com.gemalto.jp2.JP2Decoder
-dontwarn com.tom_roush.pdfbox.filter.JPXFilter
-dontwarn com.tom_roush.pdfbox.pdmodel.graphics.image.SampledImageReader
