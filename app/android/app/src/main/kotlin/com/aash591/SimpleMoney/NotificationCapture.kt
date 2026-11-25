package com.aash591.SimpleMoney

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.provider.Settings
import android.util.Base64
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * An app the user taught: the sender ID its rules are saved under, its name,
 * whether it is being read (the user can pause it), and its icon (a small PNG)
 * so it can be shown even when it isn't sending anything.
 */
class TaughtApp(
    val key: String,
    val label: String,
    val enabled: Boolean = true,
    val icon: ByteArray? = null,
)

/**
 * What the user set up for notification tracking: whether it is on, and the
 * apps they taught (each with the sender ID its rules are saved under). All of
 * it stays on the phone.
 */
class NotificationCaptureStore(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences("notification_tracking", Context.MODE_PRIVATE)

    var enabled: Boolean
        get() = prefs.getBoolean("enabled", false)
        set(value) { prefs.edit().putBoolean("enabled", value).apply() }

    /** Package → the app taught. */
    var taught: Map<String, TaughtApp>
        get() = try {
            val json = JSONObject(prefs.getString("taught", "{}")!!)
            json.keys().asSequence().associateWith {
                val o = json.getJSONObject(it)
                TaughtApp(
                    o.getString("key"), o.getString("label"),
                    // Taught before apps could be paused: read.
                    o.optBoolean("enabled", true),
                    o.optString("icon").takeIf { icon -> icon.isNotEmpty() }
                        ?.let { icon -> Base64.decode(icon, Base64.NO_WRAP) },
                )
            }
        } catch (_: Exception) { emptyMap() }
        set(value) = synchronized(lock) {
            val json = JSONObject()
            for ((pkg, v) in value) {
                json.put(pkg, JSONObject().put("key", v.key).put("label", v.label)
                    .put("enabled", v.enabled)
                    .put("icon", v.icon?.let { Base64.encodeToString(it, Base64.NO_WRAP) } ?: ""))
            }
            prefs.edit().putString("taught", json.toString()).apply()
        }

    /** Keeps [icon] for a taught app that has none yet. */
    fun rememberIcon(pkg: String, icon: ByteArray) = synchronized(lock) {
        val all = taught
        val app = all[pkg] ?: return@synchronized
        if (app.icon == null) taught = all + (pkg to TaughtApp(app.key, app.label, app.enabled, icon))
    }

    /**
     * The last few notifications of the apps the user taught, newest first,
     * so one the app didn't read (another style of the same app's alert) can
     * still be taught after it has gone from the notification shade. Only
     * taught apps are kept here, and only while reading is on.
     */
    fun earlier(): List<SeenNotification> = synchronized(lock) {
        val list = try { JSONArray(prefs.getString("earlier", "[]")) } catch (_: Exception) { JSONArray() }
        (0 until list.length()).map {
            val o = list.getJSONObject(it)
            SeenNotification(o.getString("package"), o.getString("label"), o.getString("title"),
                o.getString("text"), o.getString("message"), o.getLong("postedAt"))
        }
    }

    fun remember(n: SeenNotification) = synchronized(lock) {
        val kept = earlier().filter { !(it.pkg == n.pkg && it.message == n.message) }
        val next = JSONArray()
        for (item in (listOf(n) + kept).take(MAX_EARLIER)) {
            next.put(JSONObject().put("package", item.pkg).put("label", item.label)
                .put("title", item.title).put("text", item.text).put("message", item.message)
                .put("postedAt", item.postedAt))
        }
        prefs.edit().putString("earlier", next.toString()).apply()
    }

    /** Forgets what was kept for [pkg], when the user stops reading that app. */
    fun forget(pkg: String) = synchronized(lock) {
        val kept = earlier().filter { it.pkg != pkg }
        val next = JSONArray()
        for (item in kept) {
            next.put(JSONObject().put("package", item.pkg).put("label", item.label)
                .put("title", item.title).put("text", item.text).put("message", item.message)
                .put("postedAt", item.postedAt))
        }
        prefs.edit().putString("earlier", next.toString()).apply()
    }

    private companion object {
        val lock = Any()
        const val MAX_EARLIER = 30
    }
}

/** A notification, reduced to what a rule reads. */
class SeenNotification(
    val pkg: String,
    val label: String,
    val title: String,
    val text: String,
    /** Heading and details together: what a rule is taught on and later reads. */
    val message: String,
    val postedAt: Long,
    /** The app's icon as a small PNG, for showing the notification as it looked. */
    val icon: ByteArray? = null,
)

/**
 * Reads notifications from the apps the user taught, as they arrive. For
 * teaching, [current] lists what is on the phone right now, on request; nothing
 * else is read and nothing is kept.
 */
class NotificationCaptureService : NotificationListenerService() {
    override fun onListenerConnected() { instance = this }
    override fun onListenerDisconnected() { if (instance === this) instance = null }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val pkg = sbn.packageName ?: return
        // Our own alerts must never feed back in.
        if (pkg == packageName) return
        val store = NotificationCaptureStore(this)
        val taught = store.taught[pkg] ?: return
        // Switched off for everything, or paused for this app.
        if (!store.enabled || !taught.enabled) return
        val seen = describe(sbn) ?: return
        seen.icon?.let { store.rememberIcon(pkg, it) }
        if (!repeated(pkg, seen.message)) {
            store.remember(seen)
            TransactionSmsReceiver.enqueue(this, taught.key, seen.message, seen.postedAt, notification = true)
        }
    }

    /** What is on the phone right now, newest first, for the teach screen. */
    fun current(): List<SeenNotification> = try {
        (activeNotifications ?: emptyArray()).filter { it.packageName != packageName }
            .mapNotNull { describe(it) }
            .sortedByDescending { it.postedAt }
            .take(MAX_LISTED)
    } catch (_: Exception) { emptyList() }

    /** Null for what carries no news: a group's summary, an ongoing status, or no text. */
    private fun describe(sbn: StatusBarNotification): SeenNotification? {
        val pkg = sbn.packageName ?: return null
        val notification = sbn.notification ?: return null
        // A group's summary repeats its children; an ongoing one is a status, not news.
        if ((notification.flags and (Notification.FLAG_GROUP_SUMMARY or Notification.FLAG_ONGOING_EVENT)) != 0) return null
        val extras = notification.extras ?: return null
        fun text(key: String) = extras.getCharSequence(key)?.toString()?.trim().orEmpty()
        val title = text(Notification.EXTRA_TITLE)
        // Some apps put the details in separate lines.
        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?.joinToString("\n") { it.toString() }.orEmpty().trim()
        // The long form first: the short one is often cut off.
        val body = text(Notification.EXTRA_BIG_TEXT).ifEmpty { lines }.ifEmpty { text(Notification.EXTRA_TEXT) }
        if (title.isEmpty() && body.isEmpty()) return null
        // Android's stand-in for a notification it hid (one holding a code, say):
        // there is nothing in it to read or teach.
        if (pkg == "android" && (title + body).contains("content hidden", ignoreCase = true)) return null
        // The heading stays with the details: it can say what kind of payment it was.
        val message = when {
            body.isEmpty() -> title
            title.isEmpty() || body.contains(title) -> body
            else -> "$title\n$body"
        }
        return SeenNotification(pkg, appName(pkg, extras), title, body, message, sbn.postTime,
            iconOf(pkg, extras))
    }

    /** The app's launcher icon, drawn small and kept for next time. */
    private fun iconOf(pkg: String, extras: Bundle): ByteArray? {
        icons[pkg]?.let { return it }
        return try {
            @Suppress("DEPRECATION")
            val info = extras.getParcelable<ApplicationInfo>("android.appInfo")
            // The app's launcher icon: from the notification's own app info, else
            // by name (only works for apps we are allowed to see).
            val drawable = info?.loadIcon(packageManager)
                ?: try { packageManager.getApplicationIcon(pkg) } catch (_: Exception) { null }
                ?: throw IllegalStateException("no icon")
            val size = 96
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(Canvas(bitmap))
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray().also { icons[pkg] = it }
        } catch (_: Exception) { null }
    }

    /** The app's name, as the user knows it. */
    private fun appName(pkg: String, extras: Bundle): String {
        try {
            @Suppress("DEPRECATION")
            val info = extras.getParcelable<ApplicationInfo>("android.appInfo")
            val label = info?.loadLabel(packageManager)?.toString()
            if (!label.isNullOrBlank()) return label
        } catch (_: Exception) { /* try the next way */ }
        try {
            return packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) { /* not visible to us */ }
        return pkg.substringAfterLast('.').replaceFirstChar { it.uppercase() }
    }

    /** Apps post the same notification again when it updates. */
    private fun repeated(pkg: String, message: String): Boolean {
        val now = System.currentTimeMillis()
        synchronized(seenRecently) {
            val last = seenRecently[pkg]
            seenRecently[pkg] = message to now
            return last != null && last.first == message && now - last.second < 30_000
        }
    }

    companion object {
        /** The connected service, while Android has it bound. */
        @Volatile var instance: NotificationCaptureService? = null
        private const val MAX_LISTED = 40
        private val seenRecently = HashMap<String, Pair<String, Long>>()

        /** App icons seen so far, so an earlier notification can show its app's too. */
        val icons = java.util.concurrent.ConcurrentHashMap<String, ByteArray>()
    }
}

/** Notification access for the Smart tracking screens. */
class NotificationAccessBridge(private val context: Context) {
    fun attach(engine: FlutterEngine) {
        val store = NotificationCaptureStore(context)
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/notification_access")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isGranted" -> result.success(
                        NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName))
                    "openSettings" -> try {
                        context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    } catch (_: Exception) { result.error("settings", "Could not open Android settings.", null) }
                    "state" -> result.success(mapOf("enabled" to store.enabled,
                        "taught" to store.taught.map { (pkg, v) ->
                            mapOf("package" to pkg, "key" to v.key, "label" to v.label,
                                "enabled" to v.enabled,
                                // Any icon seen since (an app taught before icons were kept).
                                "icon" to (v.icon ?: NotificationCaptureService.icons[pkg]))
                        }))
                    "setEnabled" -> { store.enabled = call.arguments == true; result.success(null) }
                    "setTaught" -> {
                        val rows = (call.arguments as? List<*>).orEmpty().filterIsInstance<Map<*, *>>()
                        val old = store.taught
                        val next = rows.associate {
                            val pkg = it["package"] as String
                            pkg to TaughtApp(
                                it["key"] as String, it["label"] as String,
                                it["enabled"] != false,
                                (it["icon"] as? ByteArray) ?: old[pkg]?.icon,
                            )
                        }
                        // An app no longer read keeps nothing.
                        for (gone in store.taught.keys - next.keys) store.forget(gone)
                        store.taught = next
                        result.success(null)
                    }
                    // What is on the phone now. After a reinstall Android may not have
                    // bound the listener yet: ask it to, and say it isn't connected.
                    "current" -> {
                        val service = NotificationCaptureService.instance
                        if (service == null) {
                            try {
                                NotificationListenerService.requestRebind(
                                    ComponentName(context, NotificationCaptureService::class.java))
                            } catch (_: Exception) { /* nothing more to try */ }
                        }
                        fun row(it: SeenNotification): Map<String, Any?> {
                            val icon = it.icon ?: NotificationCaptureService.icons[it.pkg]
                            return mapOf("package" to it.pkg, "label" to it.label,
                                "title" to it.title, "text" to it.text, "message" to it.message,
                                "receivedAt" to it.postedAt, "icon" to icon)
                        }
                        result.success(mapOf("connected" to (service != null),
                            "items" to (service?.current() ?: emptyList()).map(::row),
                            // What taught apps sent lately, even if it has gone from the shade.
                            "earlier" to store.earlier().map(::row)))
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
