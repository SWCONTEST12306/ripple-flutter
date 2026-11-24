package com.ripple.itinerary

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.AtomicFile
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.TimeZone
import java.util.concurrent.Executors

class RippleNotificationListener : NotificationListenerService() {
    private var monitoringNetwork = false
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = NotificationExtractor.wake(applicationContext)
    }

    override fun onListenerConnected() {
        if (!monitoringNetwork) {
            getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(networkCallback)
            monitoringNetwork = true
        }
        val active = try {
            activeNotifications.orEmpty().mapNotNull(::capture)
        } catch (_: SecurityException) {
            emptyList()
        }
        NotificationInbox.store(applicationContext, active, signal = true)
    }

    override fun onNotificationPosted(notification: StatusBarNotification) {
        val entry = capture(notification) ?: return
        NotificationInbox.store(applicationContext, listOf(entry))
    }

    override fun onListenerDisconnected() {
        stopMonitoringNetwork()
        NotificationInbox.store(applicationContext, emptyList(), signal = true)
    }

    override fun onDestroy() {
        stopMonitoringNetwork()
        super.onDestroy()
    }

    private fun stopMonitoringNetwork() {
        if (!monitoringNetwork) return
        getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback)
        monitoringNetwork = false
    }

    @Suppress("DEPRECATION")
    private fun capture(posted: StatusBarNotification): NotificationEntry? {
        val notification = posted.notification
        if (posted.packageName == packageName ||
            notification.flags and Notification.FLAG_GROUP_SUMMARY != 0
        ) return null

        val extras = notification.extras ?: return null
        val title = (extras.getCharSequence(Notification.EXTRA_TITLE_BIG)
            ?: extras.getCharSequence(Notification.EXTRA_TITLE)).bounded(500)
        val message = extras.getParcelableArray(Notification.EXTRA_MESSAGES)?.let {
            Notification.MessagingStyle.Message.getMessagesFromBundleArray(it).lastOrNull()?.text
        }
        val text = sequenceOf(
            message,
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT),
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.joinToString("\n"),
            extras.getCharSequence(Notification.EXTRA_TEXT),
        ).map { it.bounded(4000) }.firstOrNull { it.isNotEmpty() }.orEmpty()
        if (title.isEmpty() && text.isEmpty()) return null

        val source = try {
            val app = packageManager.getApplicationInfo(posted.packageName, 0)
            packageManager.getApplicationLabel(app).bounded(200).ifEmpty { posted.packageName }
        } catch (_: PackageManager.NameNotFoundException) {
            posted.packageName
        }
        return NotificationEntry(
            key = posted.key,
            packageName = posted.packageName,
            source = source.bounded(200),
            title = title,
            text = text,
            postedAt = posted.postTime,
            utcOffsetMinutes = TimeZone.getDefault().getOffset(posted.postTime) / 60_000,
        )
    }

    private fun CharSequence?.bounded(limit: Int): String =
        this?.trim()?.take(limit)?.toString()?.let {
            if (it.lastOrNull()?.isHighSurrogate() == true) it.dropLast(1) else it
        }.orEmpty()
}

internal data class NotificationEntry(
    val key: String,
    val packageName: String,
    val source: String,
    val title: String,
    val text: String,
    val postedAt: Long,
    val utcOffsetMinutes: Int,
) {
    constructor(data: JSONObject) : this(
        data.getString("key"),
        data.optString("packageName"),
        data.getString("source"),
        data.getString("title"),
        data.getString("text"),
        data.getLong("postedAt"),
        data.getInt("utcOffsetMinutes"),
    )

    val sensitive: Boolean get() = verificationCode.containsMatchIn("$title $text")

    fun toMap() = mapOf(
        "key" to key,
        "packageName" to packageName,
        "source" to source,
        "title" to title,
        "text" to text,
        "postedAt" to postedAt,
        "utcOffsetMinutes" to utcOffsetMinutes,
    )

    private companion object {
        val verificationCode = Regex("验证码|校验码|动态密码|一次性密码|verification code|one[- ]time (?:code|password)|\\bOTP\\b", RegexOption.IGNORE_CASE)
    }
}

internal data class NotificationRecord(
    val notice: NotificationEntry,
    val analysis: String? = null,
    val error: String? = null,
    val retries: Int = 0,
    val retryAt: Long = 0,
) {
    constructor(data: JSONObject) : this(
        NotificationEntry(data), data.optString("analysis").ifEmpty { null },
        data.optString("error").ifEmpty { null }, data.optInt("retries"), data.optLong("retryAt"),
    )

    fun toMap() = notice.toMap() + mapOf(
        "analysis" to analysis.orEmpty(), "error" to error.orEmpty(), "retries" to retries, "retryAt" to retryAt,
    )
}

internal object NotificationInbox {
    private const val MAX_ENTRIES = 50
    private const val RETENTION_MILLIS = 7 * 24 * 60 * 60 * 1000L
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    val observers = mutableSetOf<() -> Unit>()

    fun hasAccess(context: Context): Boolean {
        val component = ComponentName(context, RippleNotificationListener::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            return context.getSystemService(NotificationManager::class.java)
                .isNotificationListenerAccessGranted(component)
        }
        return Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            ?.split(':')?.any { ComponentName.unflattenFromString(it) == component } == true
    }

    private fun file(context: Context) = AtomicFile(File(context.noBackupFilesDir, "notifications.json"))

    fun store(context: Context, incoming: List<NotificationEntry>, signal: Boolean = false) {
        worker.execute {
            var changed = signal
            try {
                changed = update(context) { current ->
                    val entries = current.associateByTo(mutableMapOf()) { it.notice.key }
                    for (entry in incoming) {
                        val previous = entries[entry.key]?.notice
                        if (previous == null || (entry != previous && entry.postedAt >= previous.postedAt)) {
                            entries[entry.key] = NotificationRecord(entry)
                        }
                    }
                    entries.values
                } || changed
            } catch (_: IOException) {
                changed = true
            }
            if (changed) notifyObservers()
            NotificationExtractor.wake(context)
        }
    }

    fun snapshot(context: Context, result: MethodChannel.Result) {
        worker.execute {
            try {
                val authorized = hasAccess(context)
                val entries = records(context)
                val settings = runCatching { ModelSettings.current(context) }.getOrNull()
                main.post {
                    result.success(mapOf("authorized" to authorized, "entries" to entries.map {
                        it.toMap() + mapOf(
                            "automatic" to (settings?.allows(it.notice) == true),
                            "retrying" to (it.error != null && it.retryAt != Long.MAX_VALUE),
                        )
                    }))
                }
            } catch (_: IOException) {
                main.post { result.error("inbox_unavailable", null, null) }
            }
        }
    }

    fun settingsChanged(context: Context, retryFailures: Boolean = false) {
        worker.execute {
            if (retryFailures) runCatching {
                update(context) { entries -> entries.map { if (it.error != null) NotificationRecord(it.notice) else it } }
            }
            notifyObservers()
            NotificationExtractor.wake(context)
        }
    }

    fun complete(context: Context, expected: NotificationRecord, next: NotificationRecord) {
        if (update(context) { entries -> entries.map { if (it == expected) next else it } }) notifyObservers()
    }

    private fun notifyObservers() = main.post { observers.toList().forEach { it() } }

    @Synchronized
    fun records(context: Context): List<NotificationRecord> {
        val file = file(context)
        if (!hasAccess(context)) {
            file.delete()
            return emptyList()
        }
        val current = read(file)
        val updated = recent(current).map(::recoverMissedAnnouncement)
        if (updated != current) write(file, updated)
        return updated
    }

    private fun recoverMissedAnnouncement(record: NotificationRecord): NotificationRecord {
        val cached = record.analysis ?: return record
        val result = try {
            JSONObject(cached)
        } catch (_: JSONException) {
            return record
        }
        return if (NotificationExtractor.fillEmptyResult(result, record.notice)) {
            record.copy(analysis = result.toString())
        } else {
            record
        }
    }

    @Synchronized
    private fun update(context: Context, transform: (List<NotificationRecord>) -> Collection<NotificationRecord>): Boolean {
        val file = file(context)
        if (!hasAccess(context)) {
            val existed = file.baseFile.exists()
            file.delete()
            return existed
        }
        val current = read(file)
        val next = recent(transform(current))
        if (next == current) return false
        write(file, next)
        return true
    }

    private fun recent(entries: Collection<NotificationRecord>): List<NotificationRecord> {
        val after = System.currentTimeMillis() - RETENTION_MILLIS
        return entries.filter { it.notice.postedAt >= after }
            .sortedWith(compareByDescending<NotificationRecord> { it.notice.postedAt }.thenBy { it.notice.key })
            .take(MAX_ENTRIES)
    }

    private fun read(file: AtomicFile): List<NotificationRecord> = try {
        val data = JSONArray(file.readFully().toString(Charsets.UTF_8))
        List(data.length()) { index -> NotificationRecord(data.getJSONObject(index)) }
    } catch (_: FileNotFoundException) {
        emptyList()
    } catch (_: JSONException) {
        file.delete()
        emptyList()
    }

    private fun write(file: AtomicFile, entries: List<NotificationRecord>) {
        val bytes = JSONArray(entries.map { JSONObject(it.toMap()) }).toString().toByteArray()
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            file.finishWrite(stream)
        } catch (error: IOException) {
            file.failWrite(stream)
            throw error
        }
    }
}
