package com.aash591.SimpleMoney

import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Reads a statement PDF for the Dart parsers. "extract" gives its text in
// the order the PDF drew it (not sorted by position), which keeps each
// transaction's lines together. "words" gives every word with where it sits
// on its page, for rebuilding a table whose layout no parser knows. A
// password only opens the file; it is never kept.
class PdfTextBridge(private val activity: FlutterFragmentActivity) {
    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/pdf_text")
            .setMethodCallHandler { call, result ->
                if (call.method != "extract" && call.method != "words") {
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
                            if (call.method == "words") WordStripper().words(it)
                            else PDFTextStripper().getText(it)
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
