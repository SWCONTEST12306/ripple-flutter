package com.ripple.itinerary

import android.content.Context
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/**
 * 开发调试开关。开启 [blockApi] 后，通知提取与图片识别只生成本地请求日志，
 * 不再把请求发送给模型服务，用于核对提示词/参数并避免消耗 token。
 *
 * 配置保存在 noBackupFilesDir，不参与系统备份。
 */
internal object DebugSettings {
    private const val FILE_NAME = "debug-settings.json"

    data class Configuration(val blockApi: Boolean)

    @Synchronized
    fun current(context: Context): Configuration {
        val bytes = try {
            file(context).readFully()
        } catch (_: FileNotFoundException) {
            return Configuration(false)
        } catch (_: Exception) {
            return Configuration(false)
        }
        val json = runCatching {
            JSONObject(String(bytes, Charsets.UTF_8))
        }.getOrNull() ?: return Configuration(false)
        return Configuration(json.optBoolean("blockApi", false))
    }

    fun blockApi(context: Context): Boolean = current(context).blockApi

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel = MethodChannel(
        messenger,
        "ripple/debug",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue(),
    ).apply {
        setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(
                        mapOf("blockApi" to current(context).blockApi),
                    )
                    "save" -> {
                        val block = call.argument<Boolean>("blockApi") ?: false
                        write(context, Configuration(block))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("debug_settings_unavailable", null, null)
            }
        }
    }

    @Synchronized
    private fun write(context: Context, settings: Configuration) {
        val file = file(context)
        val stream = file.startWrite()
        try {
            stream.write(
                JSONObject(mapOf("blockApi" to settings.blockApi))
                    .toString()
                    .toByteArray(Charsets.UTF_8),
            )
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }

    private fun file(context: Context) =
        AtomicFile(File(context.noBackupFilesDir, FILE_NAME))
}
