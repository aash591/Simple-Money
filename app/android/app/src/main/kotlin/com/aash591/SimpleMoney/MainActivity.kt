package com.aash591.SimpleMoney

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.HapticFeedbackConstants
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

open class MainActivity : FlutterFragmentActivity() {
    // Whether the display has turned off since Dart last asked. The Flutter
    // lifecycle reports "paused" both for a screen lock and for an app
    // switch; the app lock's timing options have to tell them apart. Kept on
    // the companion so it survives an activity recreation within the process
    // — losing it would silently skip a lock.
    companion object {
        @Volatile
        private var screenTurnedOff = false

        private const val CHANNEL = "simple_money/screen_lock"
        private const val SCREEN_OFF_KEY = "screen_turned_off"
    }

    // Registers its contact-picker result callback, which Android only allows
    // before the activity starts — so it's created with the activity.
    private val people = PeopleBridge(this)
    private val smsInbox = SmsInboxBridge(this)
    private var smsChanges: MethodChannel? = null
    private val smsChangedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { smsChanges?.invokeMethod("changed", null) }
    }
    private val paymentPlace = PaymentPlaceBridge(this)
    // Only the dashboard's engine runs AI sessions; the quick-entry and SMS
    // sheets are separate engines that come and go.
    private val aiSession = if (this::class == MainActivity::class) AiSessionBridge(this) else null

    private val screenLockPreferences by lazy {
        getSharedPreferences("SimpleMoneySecurity", Context.MODE_PRIVATE)
    }

    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            screenTurnedOff = true
            // Keep observed events across process death, too: a restored
            // grace period must still honor the independent screen-off rule.
            screenLockPreferences.edit().putBoolean(SCREEN_OFF_KEY, true).commit()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        androidx.core.content.ContextCompat.registerReceiver(this, smsChangedReceiver,
            IntentFilter("$packageName.SMS_LEDGER_CHANGED"), androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
        // Registered for the activity's lifetime rather than only while
        // visible: the screen usually turns off after the app is already in
        // the background, which is exactly the case this has to catch.
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenOffReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenOffReceiver, filter)
        }
        if (this !is QuickEntryActivity) {
            QuickShortcuts.publish(this)
            refreshQuickActionWidgets(this)
            openQuickAction(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (this !is QuickEntryActivity) openQuickAction(intent)
        // A cold start is on Home already; a running app may be anywhere.
        if (intent.getBooleanExtra("open_home", false)) {
            smsChanges?.invokeMethod("openHome", null)
        }
    }

    override fun onResume() {
        super.onResume()
        // After the window is attached, so its attributes can be changed.
        window.decorView.post { requestHighestRefreshRate() }
    }

    // Some phones (Xiaomi/Poco/Redmi on HyperOS, Nothing and others) run a
    // Flutter app at 60 Hz on a 120 Hz screen unless the window asks for
    // more: Flutter draws into a SurfaceView, which their heuristics treat
    // like a game or a video. So ask for the display's fastest mode at the
    // current resolution (flutter/flutter#160952).
    /** A Qualcomm Snapdragon chip, and so an Adreno GPU. */
    private fun isSnapdragon(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val maker = Build.SOC_MANUFACTURER
            if (maker.equals("QTI", ignoreCase = true) ||
                maker.equals("Qualcomm", ignoreCase = true)
            ) return true
            if (maker.isNotBlank() && maker != Build.UNKNOWN) return false
        }
        return listOf(Build.HARDWARE, Build.BOARD).any {
            it.contains("qcom", ignoreCase = true)
        }
    }

    private fun requestHighestRefreshRate() {
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        } ?: return
        val current = display.mode
        val best = display.supportedModes
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .let { modes ->
                // Snapdragon's Adreno GPUs can't quite draw a frame of this
                // app in 8.3 ms on a very sharp screen under Flutter's
                // Vulkan renderer, so 120 Hz drops every few frames; a
                // steady 90 Hz (11.1 ms a frame) looks smoother than that.
                val pixels = current.physicalWidth.toLong() * current.physicalHeight
                val steady = if (isSnapdragon() && pixels > 3_200_000) {
                    modes.filter { it.refreshRate in 85f..95f }
                        .maxByOrNull { it.refreshRate }
                } else {
                    null
                }
                steady ?: modes.maxByOrNull { it.refreshRate }
            } ?: return
        if (best.refreshRate <= 60.5f) return
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId == best.modeId) return
        attributes.preferredDisplayModeId = best.modeId
        window.attributes = attributes
    }

    // Older pinned shortcuts/widgets may still target MainActivity. Handle
    // both a cold launch and a tap while the dashboard's activity is alive.
    private fun openQuickAction(source: Intent) {
        val action = quickAction(source) ?: return
        val entry = quickEntryIntent(this, action)
            .putExtra(QuickShortcuts.FROM_SHORTCUT,
                source.getBooleanExtra(QuickShortcuts.FROM_SHORTCUT, false))
        // Do not replay a consumed shortcut if Android recreates this activity.
        source.removeExtra("quick_action")
        intent.removeExtra("quick_action")
        startActivity(entry)
    }

    override fun onDestroy() {
        smsInbox.dispose()
        unregisterReceiver(smsChangedReceiver)
        paymentPlace.dispose()
        aiSession?.detach()
        unregisterReceiver(screenOffReceiver)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        UpiBridge(this, flutterEngine)
        people.attach(flutterEngine)
        smsInbox.attach(flutterEngine)
        NotificationAccessBridge(this).attach(flutterEngine)
        KeepAliveBridge(this).attach(flutterEngine)
        smsChanges = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "simple_money/sms_changes")
        RealtimeSmsNotifications.attach(this, flutterEngine)
        ImprovementBridge(this).attach(flutterEngine)
        paymentPlace.attach(flutterEngine)
        PdfTextBridge(this).attach(flutterEngine)
        aiSession?.attach(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "simple_money/haptics")
            .setMethodCallHandler { call, result ->
                if (call.method == "softTick") {
                    // SEGMENT_FREQUENT_TICK can intentionally be silent on
                    // devices unable to produce a sufficiently soft vibration.
                    // Use the standard tick for keypad and scroll-edge feedback
                    // on every Android version, respecting system haptic settings.
                    window.decorView.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "simple_money/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "lowEnd") {
                    result.success(isLowEndDevice())
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "supported" -> result.success(true)
                    "consumeScreenOff" -> {
                        val observed = screenTurnedOff ||
                            screenLockPreferences.getBoolean(SCREEN_OFF_KEY, false)
                        screenLockPreferences.edit().remove(SCREEN_OFF_KEY).commit()
                        screenTurnedOff = false
                        result.success(observed)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Budget phones (Go edition, or under ~4 GB of RAM) drop frames re-blurring
    // the page behind a moving popup, so Flutter swaps the blur for a solid tint.
    private fun isLowEndDevice(): Boolean {
        val activityManager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        if (activityManager.isLowRamDevice) return true
        val memory = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
        return memory.totalMem < 3_800L * 1024 * 1024
    }

    // Applied before the window (and its LaunchTheme splash background) is
    // created, so the splash screen matches the light/dark/system choice
    // saved in-app rather than always following the OS setting. Mirrors the
    // "theme_mode" preference written by _changeThemeMode in app.dart.
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(withSavedThemeMode(newBase))
    }

    // "light", "dark", or null for system/unset.
    private fun savedThemeMode(context: Context): String? =
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.theme_mode", null)
            ?.takeIf { it == "light" || it == "dark" }

    private fun withSavedThemeMode(context: Context): Context {
        val nightMode = when (savedThemeMode(context)) {
            "light" -> Configuration.UI_MODE_NIGHT_NO
            "dark" -> Configuration.UI_MODE_NIGHT_YES
            else -> return context // "system" (or unset): keep following the OS setting
        }
        val config = Configuration(context.resources.configuration)
        config.uiMode = (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or nightMode
        return context.createConfigurationContext(config)
    }

    // Android 12+ draws its splash before any app code runs, in the phone's
    // light/dark mode, so the choice above can't reach it. From Android 13 the
    // system remembers a splash theme per app, used from the next cold start:
    // set it whenever the app leaves the screen, which is also when a theme
    // changed in-app has been saved.
    private fun syncSplashTheme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val theme = when (savedThemeMode(this)) {
            "light" -> R.style.LaunchThemeLight
            "dark" -> R.style.LaunchThemeDark
            else -> R.style.LaunchTheme
        }
        runCatching { splashScreen.setSplashScreenTheme(theme) }
    }

    override fun onStop() {
        if (this !is QuickEntryActivity && this !is SmsNotificationActivity) syncSplashTheme()
        super.onStop()
    }
}
