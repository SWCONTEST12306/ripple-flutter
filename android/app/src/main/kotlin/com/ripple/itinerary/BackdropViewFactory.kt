package com.ripple.itinerary

import android.content.Context
import android.os.Build
import android.view.View
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.unit.dp
import com.kyant.backdrop.backdrops.rememberCanvasBackdrop
import com.kyant.backdrop.drawBackdrop
import com.kyant.backdrop.effects.blur
import com.kyant.backdrop.effects.lens
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

internal class BackdropViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView = BackdropView(context)
}

private class BackdropView(context: Context) : PlatformView {
    private val compose = ComposeView(context).apply {
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        setContent { DockMaterial() }
    }

    override fun getView(): View = compose

    override fun dispose() = compose.disposeComposition()
}

@Composable
private fun DockMaterial() {
    val shape = RoundedCornerShape(27.dp)
    val light = Color(0xFFF9FDFC)
    val water = Color(0xFFD0E7E8)
    val border = Color(0xFFADCBCD)
    val frame = Modifier.fillMaxSize().border(1.dp, border, shape)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
        Box(frame.background(Brush.horizontalGradient(listOf(light, water)), shape))
        return
    }

    // Platform views cannot read the Flutter scene. This native canvas supplies the glass backdrop.
    val backdrop = rememberCanvasBackdrop {
        drawRect(Brush.horizontalGradient(listOf(light, water, light)))
        val origin = Offset(size.width * 0.84f, size.height * 1.43f)
        for (ring in 1..5) {
            drawCircle(
                color = Color(0x605DABAD),
                radius = size.height * (0.3f + ring * 0.2f),
                center = origin,
                style = Stroke(width = 1.5.dp.toPx())
            )
        }
    }
    Box(frame.drawBackdrop(
        backdrop = backdrop,
        shape = { shape },
        effects = {
            blur(2.dp.toPx())
            lens(13.dp.toPx(), 23.dp.toPx())
        },
        shadow = null,
        onDrawSurface = { drawRect(Color.White.copy(alpha = 0.23f)) }
    ))
}
