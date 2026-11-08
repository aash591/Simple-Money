package com.aash591.SimpleMoney

import android.app.Activity
import android.graphics.*
import android.graphics.drawable.Drawable
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.function.Consumer

/** Background blur follows the modal outline; never enable full-screen blur-behind. */
class ModalBackgroundBlur(private val activity: Activity, engine: FlutterEngine) {
    private val regions = mutableMapOf<Int, Pair<RectF, Float>>()
    private var enabled = false
    private val background = object : Drawable() {
        override fun draw(canvas: Canvas) {
            val region = largest() ?: return
            // Keep text readable when the device disables cross-window blur.
            if (!enabled) {
                canvas.drawRoundRect(region.first, region.second, region.second,
                    // Flutter supplies the app's theme tint; do not inject a
                    // black fallback based on the phone's independent theme.
                    Paint().apply { color = 0xCCFFFFFF.toInt() })
            }
        }
        override fun getOutline(outline: Outline) {
            val region = largest()
            if (region == null) outline.setEmpty() else {
                val rect = Rect()
                region.first.round(rect)
                outline.setRoundRect(rect, region.second)
                outline.alpha = 1f
            }
        }
        override fun setAlpha(alpha: Int) {}
        override fun setColorFilter(filter: ColorFilter?) {}
        @Deprecated("Drawable opacity") override fun getOpacity() = PixelFormat.TRANSLUCENT
    }
    private val listener = Consumer<Boolean> { enabled = it; refresh() }
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/modal_blur")

    init {
        activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        activity.window.setDimAmount(0f)
        activity.window.setBackgroundDrawable(background)
        if (Build.VERSION.SDK_INT >= 31) {
            enabled = activity.windowManager.isCrossWindowBlurEnabled
            activity.windowManager.addCrossWindowBlurEnabledListener(listener)
        }
        channel.setMethodCallHandler { call, result ->
            if (call.method != "bounds") { result.notImplemented(); return@setMethodCallHandler }
            val id = call.argument<Number>("id")!!.toInt()
            if (call.argument<Boolean>("remove") == true) regions.remove(id) else {
                fun number(key: String) = call.argument<Number>(key)!!.toFloat()
                regions[id] = RectF(number("left"), number("top"), number("right"), number("bottom")) to number("radius")
            }
            refresh()
            result.success(null)
        }
    }

    private fun largest() = regions.values.maxByOrNull { it.first.width() * it.first.height() }

    private fun refresh() {
        background.invalidateSelf()
        // Reset the background so DecorView refreshes the compositor outline.
        activity.window.setBackgroundDrawable(null)
        activity.window.setBackgroundDrawable(background)
        if (Build.VERSION.SDK_INT >= 31) {
            activity.window.setBackgroundBlurRadius(if (enabled && regions.isNotEmpty())
                (40 * activity.resources.displayMetrics.density).toInt() else 0)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        if (Build.VERSION.SDK_INT >= 31) {
            activity.windowManager.removeCrossWindowBlurEnabledListener(listener)
            activity.window.setBackgroundBlurRadius(0)
        }
        regions.clear()
    }
}
