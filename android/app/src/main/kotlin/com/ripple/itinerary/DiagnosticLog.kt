package com.ripple.itinerary

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import java.io.File

/**
 * 开发诊断日志：记录模型请求和返回结果，只在「设置 · 开发 · 日志」里展示。
 * 内容只保存在本机，最多保留最近 100 条；文件超过 2 MB 时整体重写。
 * 写入失败不影响正常的通知解析。
 */
internal object DiagnosticLog {
    private const val MAX_ENTRIES = 100
    private const val MAX_FILE_BYTES = 2L * 1024 * 1024
    private const val MAX_TITLE = 120
    private const val MAX_BODY = 12_000
    private const val TRUNCATED = "…（内容过长，已截断）"

    private data class Entry(
        val seq: Long,
        val at: Long,
        val tag: String,
        val title: String,
        val body: String,
    ) {
        fun toMap() = mapOf("seq" to seq, "at" to at, "tag" to tag, "title" to title, "body" to body)

        fun toJson() = JSONObject().apply {
            put("seq", seq)
            put("at", at)
            put("tag", tag)
            put("title", title)
            put("body", body)
        }

        companion object {
            fun from(json: JSONObject) = Entry(
                json.optLong("seq"),
                json.optLong("at"),
                json.optString("tag"),
                json.optString("title"),
                json.optString("body"),
            )
        }
    }

    private val lock = Any()
    private var loaded: MutableList<Entry>? = null
    private var nextSeq = 1L

    fun record(context: Context, tag: String, title: String, body: String) {
        synchronized(lock) {
            val entries = entries(context)
            val entry = Entry(
                nextSeq++,
                System.currentTimeMillis(),
                tag,
                title.take(MAX_TITLE),
                trim(body),
            )
            entries.add(entry)
            while (entries.size > MAX_ENTRIES) entries.removeAt(0)
            persist(context, entry)
        }
    }

    fun snapshot(context: Context): List<Map<String, Any>> =
        synchronized(lock) { entries(context).map { it.toMap() } }

    fun clear(context: Context) {
        synchronized(lock) {
            loaded = mutableListOf()
            nextSeq = 1L
            file(context).delete()
        }
    }

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel = MethodChannel(
        messenger,
        "ripple/diagnostics",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue(),
    ).apply {
        setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(snapshot(context))
                    "clear" -> {
                        clear(context)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("log_unavailable", null, null)
            }
        }
    }

    private fun file(context: Context) = File(context.filesDir, "diagnostics.log")

    private fun trim(body: String): String =
        if (body.length <= MAX_BODY) body else body.take(MAX_BODY) + "\n" + TRUNCATED

    private fun entries(context: Context): MutableList<Entry> = loaded ?: load(context).also { loaded = it }

    private fun load(context: Context): MutableList<Entry> {
        val entries = mutableListOf<Entry>()
        runCatching {
            file(context).forEachLine { line ->
                if (line.isBlank()) return@forEachLine
                runCatching { entries.add(Entry.from(JSONObject(line))) }
            }
        }
        while (entries.size > MAX_ENTRIES) entries.removeAt(0)
        nextSeq = (entries.maxOfOrNull { it.seq } ?: 0L) + 1
        return entries
    }

    private fun persist(context: Context, entry: Entry) {
        runCatching {
            val file = file(context)
            if (file.length() > MAX_FILE_BYTES) {
                file.writeText(loaded.orEmpty().joinToString("\n") { it.toJson().toString() } + "\n")
            } else {
                file.appendText(entry.toJson().toString() + "\n")
            }
        }
    }
}
