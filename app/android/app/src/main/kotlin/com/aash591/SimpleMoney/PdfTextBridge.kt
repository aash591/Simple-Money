package com.aash591.SimpleMoney

import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.rendering.ImageType
import com.tom_roush.pdfbox.rendering.PDFRenderer
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File

// Reads a statement PDF for the Dart parsers. "extract" gives its text in
// the order the PDF drew it (not sorted by position), which keeps each
// transaction's lines together. "words" gives every word with where it sits
// on its page, for rebuilding a table whose layout no parser knows. "pages"
// gives the first pages as JPEG pictures, for the user's AI to see the
// layout when the user allows it. A password only opens the file; it is
// never kept.
class PdfTextBridge(private val activity: FlutterFragmentActivity) {
    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/pdf_text")
            .setMethodCallHandler { call, result ->
                if (call.method != "extract" && call.method != "words" &&
                    call.method != "pages") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("unreadable", "No file to read.", null)
                    return@setMethodCallHandler
                }
                val password = call.argument<String>("password")
                Thread {
                    try {
                        PDFBoxResourceLoader.init(activity.applicationContext)
                        val read: Any = PDDocument.load(bytes, password ?: "").use {
                            when (call.method) {
                                "words" -> WordStripper().words(it)
                                "pages" -> pictures(
                                    it,
                                    call.argument<Int>("count") ?: 2,
                                    activity.cacheDir,
                                )
                                else -> PDFTextStripper().getText(it)
                            }
                        }
                        activity.runOnUiThread { result.success(read) }
                    } catch (_: InvalidPasswordException) {
                        activity.runOnUiThread {
                            result.error(if (password == null) "password" else "wrongPassword",
                                "This PDF is password-protected.", null)
                        }
                    } catch (_: Throwable) {
                        activity.runOnUiThread {
                            result.error("unreadable", "This PDF could not be read.", null)
                        }
                    }
                }.start()
            }
    }
}

// The first [count] pages, each about 1200 pixels wide: enough to read a
// statement's small print, small enough to send.
//
// Drawn by Android's own renderer (PDFium), which draws a PDF's embedded
// fonts; PdfBox leaves the text of many bank PDFs out, so its pictures are
// only the fallback. Android opens a locked PDF only from Android 15, so an
// unlocked copy is written to the app's private cache for it and deleted
// at once.
private fun pictures(document: PDDocument, count: Int, cache: File): List<ByteArray> =
    try {
        androidPictures(document, count, cache)
    } catch (_: Throwable) {
        pdfBoxPictures(document, count)
    }

private fun androidPictures(document: PDDocument, count: Int, cache: File): List<ByteArray> {
    val copy = File.createTempFile("statement", ".pdf", cache)
    try {
        document.isAllSecurityToBeRemoved = true
        document.save(copy)
        ParcelFileDescriptor.open(copy, ParcelFileDescriptor.MODE_READ_ONLY).use { file ->
            PdfRenderer(file).use { renderer ->
                return (0 until minOf(count, renderer.pageCount)).map { index ->
                    renderer.openPage(index).use { page ->
                        val scale = if (page.width > 0) 1200f / page.width else 2f
                        val bitmap = Bitmap.createBitmap(
                            (page.width * scale).toInt(),
                            (page.height * scale).toInt(),
                            Bitmap.Config.ARGB_8888,
                        )
                        // Pages are drawn on a transparent sheet.
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        jpeg(bitmap)
                    }
                }
            }
        }
    } finally {
        copy.delete()
    }
}

private fun pdfBoxPictures(document: PDDocument, count: Int): List<ByteArray> {
    val renderer = PDFRenderer(document)
    return (0 until minOf(count, document.numberOfPages)).map { index ->
        val width = document.getPage(index).mediaBox.width
        val scale = if (width > 0) 1200f / width else 2f
        jpeg(renderer.renderImage(index, scale, ImageType.RGB))
    }
}

private fun jpeg(bitmap: Bitmap): ByteArray = ByteArrayOutputStream().use { out ->
    bitmap.compress(Bitmap.CompressFormat.JPEG, 70, out)
    bitmap.recycle()
    out.toByteArray()
}

// Every word as [page, left, top, right, bottom, text], in points from the
// page's top-left corner. Sorted by position, PdfBox splits each line into
// words and hands them over one at a time.
private class WordStripper : PDFTextStripper() {
    private val found = ArrayList<List<Any>>()

    init {
        sortByPosition = true
    }

    fun words(document: PDDocument): List<List<Any>> {
        getText(document)
        return found
    }

    override fun writeString(text: String, textPositions: MutableList<TextPosition>) {
        if (text.isBlank() || textPositions.isEmpty()) return
        val first = textPositions.first()
        val last = textPositions.last()
        val top = textPositions.minOf { (it.yDirAdj - it.heightDir).toDouble() }
        val bottom = textPositions.maxOf { it.yDirAdj.toDouble() }
        found.add(
            listOf(
                currentPageNo,
                first.xDirAdj.toDouble(),
                top,
                (last.xDirAdj + last.widthDirAdj).toDouble(),
                bottom,
                text,
            ),
        )
    }
}
