package com.aash591.SimpleMoney

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * What Android may do to stop SimpleMoney reading bank messages in the
 * background, and the settings pages that undo it. Phone makers add their own
 * switches that no API can read, so the user confirms those; the page that
 * opens for each step is the maker's where one is known, else the nearest
 * stock one.
 */
class KeepAliveBridge(private val context: Context) {
    private val prefs = context.getSharedPreferences("keep_alive", Context.MODE_PRIVATE)
    private val pkg = context.packageName

    /** The maker's skin, so Dart can word each step the way that phone does. */
    private fun family(): String {
        val maker = "${Build.MANUFACTURER} ${Build.BRAND}".lowercase()
        fun any(vararg names: String) = names.any { it in maker }
        return when {
            any("oppo", "realme", "oneplus") -> "colorOs"
            any("vivo", "iqoo") -> "originOs"
            any("xiaomi", "redmi", "poco") -> "hyperOs"
            any("samsung") -> "oneUi"
            any("huawei", "honor") -> "emui"
            any("tecno", "infinix", "itel", "transsion") -> "transsion"
            any("asus") -> "asus"
            else -> "stock"
        }
    }

    /** The maker's autostart page, for makers that have one. */
    private fun autostartIntents(): List<Intent> {
        fun page(p: String, c: String) = Intent().setComponent(ComponentName(p, c))
        return when (family()) {
            "hyperOs" -> listOf(
                page("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"))
            "colorOs" -> listOf(
                page("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                page("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
                page("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"))
            "originOs" -> listOf(
                page("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"))
            "emui" -> listOf(
                page("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"))
            else -> emptyList()
        }
    }

    private fun appDetails() = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.fromParts("package", pkg, null))

    private fun open(vararg intents: Intent): Boolean {
        for (intent in intents) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) { /* try the next page */ }
        }
        return false
    }

    private fun confirmed(): Set<String> = prefs.getStringSet("confirmed", emptySet())?.toSet() ?: emptySet()

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/keep_alive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "state" -> {
                        val power = context.getSystemService(PowerManager::class.java)
                        val manager = context.getSystemService(ActivityManager::class.java)
                        val access: Boolean? = if (Build.VERSION.SDK_INT >= 30) {
                            try { context.packageManager.isAutoRevokeWhitelisted } catch (_: Exception) { null }
                        } else null
                        result.success(mapOf(
                            "family" to family(),
                            "battery" to power.isIgnoringBatteryOptimizations(pkg),
                            "background" to !(Build.VERSION.SDK_INT >= 28 && manager.isBackgroundRestricted),
                            "access" to access,
                            // Whether this phone has an autostart page of its own.
                            "hasAutostartPage" to autostartIntents().isNotEmpty(),
                            "confirmed" to confirmed().toList()))
                    }
                    "open" -> {
                        val ok = when (call.arguments as? String) {
                            // The list of apps, where Simple Money is set to "Don't optimize".
                            "battery" -> open(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), appDetails())
                            "background" -> open(appDetails())
                            "access" -> open(
                                *if (Build.VERSION.SDK_INT >= 30) arrayOf(
                                    Intent(Intent.ACTION_AUTO_REVOKE_PERMISSIONS, Uri.fromParts("package", pkg, null)))
                                else emptyArray(), appDetails())
                            "autostart" -> open(*autostartIntents().toTypedArray(), appDetails())
                            // Per-app switches are on the app's own page.
                            "batterySaver", "appLaunch" -> open(appDetails())
                            // The rest are in the phone's Battery settings.
                            else -> open(Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS), appDetails())
                        }
                        if (ok) result.success(null) else result.error("settings", "Could not open Android settings.", null)
                    }
                    "setConfirmed" -> {
                        val args = call.arguments as Map<*, *>
                        val id = args["id"] as String
                        val next = confirmed().toMutableSet()
                        if (args["done"] == true) next.add(id) else next.remove(id)
                        prefs.edit().putStringSet("confirmed", next).apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
