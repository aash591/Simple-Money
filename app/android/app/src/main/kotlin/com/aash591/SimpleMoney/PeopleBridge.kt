package com.aash591.SimpleMoney

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.ContactsContract.CommonDataKinds.Phone
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Picks a person for a debt through the system contact picker, which hands
 * over just the one contact chosen — so the app never needs the contacts
 * permission — and shares debt reminders through the system share sheet.
 */
class PeopleBridge(private val activity: FlutterFragmentActivity) {
    private var pending: MethodChannel.Result? = null

    private val picker = activity.registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { outcome ->
        val result = pending ?: return@registerForActivityResult
        pending = null
        val uri = outcome.data?.data
        if (outcome.resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return@registerForActivityResult
        }
        try {
            activity.contentResolver.query(
                uri, arrayOf(Phone.DISPLAY_NAME, Phone.NUMBER), null, null, null
            ).use { cursor ->
                if (cursor == null || !cursor.moveToFirst()) {
                    result.success(null)
                } else {
                    result.success(mapOf("name" to cursor.getString(0), "phone" to cursor.getString(1)))
                }
            }
        } catch (error: Exception) {
            result.error("unreadable", "Could not read that contact.", null)
        }
    }

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/people")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickContact" -> {
                        if (pending != null) {
                            result.error("busy", "A contact is already being picked.", null)
                            return@setMethodCallHandler
                        }
                        pending = result
                        try {
                            picker.launch(Intent(Intent.ACTION_PICK, Phone.CONTENT_URI))
                        } catch (error: ActivityNotFoundException) {
                            pending = null
                            result.error("unavailable", "No contacts app is available.", null)
                        }
                    }
                    "shareText" -> {
                        val text = call.argument<String>("text")
                        if (text.isNullOrBlank()) {
                            result.error("invalid", "Nothing to share.", null)
                            return@setMethodCallHandler
                        }
                        val send = Intent(Intent.ACTION_SEND)
                            .setType("text/plain")
                            .putExtra(Intent.EXTRA_TEXT, text)
                        activity.startActivity(Intent.createChooser(send, null))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
