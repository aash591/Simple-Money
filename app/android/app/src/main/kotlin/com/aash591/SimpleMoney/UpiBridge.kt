package com.aash591.SimpleMoney

import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

/** Shares a temporary QR PNG to Google Pay; never launches a UPI payment link. */
class UpiBridge(private val activity: FlutterFragmentActivity, engine: FlutterEngine) {
    private val googlePay = "com.google.android.apps.nbu.paisa.user"
    private fun imageIntent() = Intent(Intent.ACTION_SEND).setType("image/png").setPackage(googlePay)

    @Suppress("DEPRECATION")
    private fun imageHandlers() = activity.packageManager.queryIntentActivities(
        imageIntent(), PackageManager.MATCH_DEFAULT_ONLY
    ).filter { it.activityInfo.exported && it.activityInfo.packageName == googlePay }

    @Suppress("DEPRECATION")
    private fun handlers() = (activity.packageManager.queryIntentActivities(
        Intent(Intent.ACTION_VIEW, Uri.parse("upi://pay")), PackageManager.MATCH_DEFAULT_ONLY
    ) + imageHandlers()).filter {
        it.activityInfo.exported && it.activityInfo.packageName != activity.packageName
    }.distinctBy { it.activityInfo.packageName }

    private fun shareQr(png: ByteArray) {
        require(png.size in 8..2_000_000 && png.take(8) ==
            listOf(137, 80, 78, 71, 13, 10, 26, 10).map { it.toByte() }) { "Invalid QR image." }
        require(imageHandlers().isNotEmpty()) { "Google Pay cannot receive QR images. Update Google Pay and try again." }
        val directory = File(activity.cacheDir, "upi_qr")
        check(directory.isDirectory || directory.mkdirs()) { "Could not prepare the temporary QR image." }
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        directory.listFiles()?.filter {
            it.isFile && it.name.startsWith("upi_") && it.extension == "png" && it.lastModified() < cutoff
        }?.forEach { it.delete() }
        val file = File(directory, "upi_${UUID.randomUUID()}.png")
        try {
            file.writeBytes(png)
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.upi_qr", file)
            val intent = imageIntent().apply {
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newUri(activity.contentResolver, "Payment QR", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            // Keep the file available while Google Pay reads it. It is private
            // cache data; old images are removed on the next share or by Android.
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/upi")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "apps" -> {
                            val canShare = imageHandlers().isNotEmpty()
                            result.success(handlers().map { info ->
                                val drawable = info.loadIcon(activity.packageManager)
                                val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
                                drawable.setBounds(0, 0, 96, 96)
                                drawable.draw(Canvas(bitmap))
                                val stream = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                                bitmap.recycle()
                                mapOf("package" to info.activityInfo.packageName,
                                    "name" to info.loadLabel(activity.packageManager).toString(),
                                    "icon" to stream.toByteArray(),
                                    "canShareQr" to (canShare && info.activityInfo.packageName == googlePay))
                            }.sortedBy { it["name"] as String })
                        }
                        "shareQr" -> {
                            require(call.argument<String>("package") == googlePay) { "QR sharing is available with Google Pay." }
                            shareQr(requireNotNull(call.argument<ByteArray>("png")))
                            // Sharing is not proof of payment. The user confirms in Dart.
                            result.success(null)
                        }
                        "scheduleReminder" -> {
                            UpiNotifications.schedule(activity, requireNotNull(call.argument<String>("id")),
                                call.argument<Int>("seconds") ?: 120)
                            result.success(null)
                        }
                        "cancelReminder" -> {
                            UpiNotifications.cancel(activity, requireNotNull(call.argument<String>("id")))
                            result.success(null)
                        }
                        "showToast" -> {
                            val message = requireNotNull(call.argument<String>("message"))
                            Toast.makeText(activity, message, Toast.LENGTH_LONG).show()
                            result.success(null)
                        }
                        "openApp" -> {
                            val packageName = requireNotNull(call.argument<String>("package"))
                            require(handlers().any { it.activityInfo.packageName == packageName }) { "This UPI app is no longer available." }
                            val intent = activity.packageManager.getLaunchIntentForPackage(packageName)
                                ?: throw IllegalStateException("Open this UPI app from your home screen.")
                            activity.startActivity(intent)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("upi_unavailable", error.message ?: "Could not share the QR image.", null)
                }
            }
    }
}
