package com.aash591.SimpleMoney

import android.content.Intent
import android.graphics.Color
import androidx.core.view.WindowCompat
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine

/** A separate translucent task: closing the sheet returns to the launcher. */
class QuickEntryActivity : MainActivity() {
    private var modalBlur: ModalBackgroundBlur? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        modalBlur = ModalBackgroundBlur(this, flutterEngine)
    }

    override fun onDestroy() {
        modalBlur?.dispose()
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // No FLAG_SHOW_WALLPAPER: the launcher stays drawn behind this
        // floating, translucent window and shows the wallpaper itself. Taking
        // the wallpaper over made a live wallpaper go black while it switched.
        super.onCreate(savedInstanceState)
        // The theme floats the window (see QuickEntryTheme.Wallpaper); a
        // floating window wraps its content, so fill the whole screen.
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT)
        // A floating window is also laid out between the system bars, not
        // under them, which left black bands at the top and bottom. Lay it
        // out over the whole screen, cutout included, as a normal window is.
        @Suppress("DEPRECATION")
        window.apply {
            addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_INSET_DECOR or
                WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
            val params = attributes
            if (Build.VERSION.SDK_INT >= 30) {
                params.fitInsetsTypes = 0
                params.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            } else if (Build.VERSION.SDK_INT >= 28) {
                params.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
            attributes = params
            statusBarColor = Color.TRANSPARENT
            navigationBarColor = Color.TRANSPARENT
            if (Build.VERSION.SDK_INT >= 29) {
                isStatusBarContrastEnforced = false
                isNavigationBarContrastEnforced = false
            }
        }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        keepTranslucent()
        // App-icon shortcuts don't carry the intent's no-animation flag
        // through every launcher; ask for no open animation here as well.
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, 0, 0)
        } else {
            @Suppress("DEPRECATION") overridePendingTransition(0, 0)
        }
    }

    override fun onResume() {
        super.onResume()
        keepTranslucent()
    }

    // The theme is translucent and the system reads it so at launch, yet the
    // activity was later reported as covering the screen (occludesParent),
    // so the launcher was hidden: black at first, then only the wallpaper,
    // never the icons. Re-asserting it keeps the home screen drawn behind.
    private fun keepTranslucent() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setTranslucent(true)
    }

    override fun getBackgroundMode() = BackgroundMode.transparent

    // A transparent background defaults to a TextureView, which Impeller
    // (Vulkan) on some GPUs (seen on a MediaTek Mali) never fills: the sheet
    // works but nothing shows. A see-through SurfaceView draws fine.
    override fun getRenderMode() = RenderMode.surface

    override fun getInitialRoute() = "/quick/${quickAction(intent) ?: "expense"}"

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val action = quickAction(intent) ?: return
        // Some launchers reuse the top activity. Flutter's initial route only
        // applies to a new engine, so replace the old sheet for this new tap.
        val entry = quickEntryIntent(this, action)
            .putExtra(QuickShortcuts.FROM_SHORTCUT,
                intent.getBooleanExtra(QuickShortcuts.FROM_SHORTCUT, false))
        finish()
        startActivity(entry)
    }
}
