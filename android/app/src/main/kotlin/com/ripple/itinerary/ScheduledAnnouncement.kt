package com.ripple.itinerary

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.Locale
import java.util.SimpleTimeZone

internal data class ScheduledAnnouncement(
    val title: String,
    val date: String,
    val time: String,
    val evidence: String,
) {
    companion object {
        private const val explicitDate = "[0-9]{4}(?:-[0-9]{1,2}-[0-9]{1,2}|年[0-9]{1,2}月[0-9]{1,2}日)"
        private val digits = Regex("[0-9]+")
        private val announcement = Regex(
            """(?:^|[。！!?？；;，,：:\r\n])[\p{Z}\t]*((?:现定于|定于|将于|安排在|请于)[\p{Z}\t]*(今天|今日|明天|明日|后天|后日|$explicitDate)[\p{Z}\t]*(上午|下午|早上|晚上|中午|凌晨)?[\p{Z}\t]*([0-9]{1,2})(?:[:：]([0-9]{2})|点(?:([0-9]{1,2})分)?)整?[\p{Z}\t]*(?:进行|召开|举行|开展|举办|组织|参加)[\p{Z}\t]*([^。！!?？；;，,\r\n]{2,80}))(?=$|[。！!?？；;，,\r\n])""",
        )
        private val activity = Regex("会议|例会|培训|评审|答辩|测试|联调|验收|面试|考试|演练|彩排|讲座|比赛|发布会|研讨会|汇报|签到|集合")
        private val change = Regex("取消|延期|延后|推迟|改期|改到|改至|暂缓|待定|原定|原计划|如期与否")

        fun find(text: String, postedAt: Long, utcOffsetMinutes: Int): List<ScheduledAnnouncement> {
            if (change.containsMatchIn(text)) return emptyList()
            val zone = SimpleTimeZone(utcOffsetMinutes * 60_000, "notification")
            val format = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).apply { timeZone = zone }
            return announcement.findAll(text).mapNotNull { match ->
                val (evidence, dateText, period, hours, minutes, pointMinutes, rawTitle) = match.destructured
                val title = rawTitle.trim()
                if (!activity.containsMatchIn(title)) return@mapNotNull null
                val date = resolveDate(dateText, postedAt, zone) ?: return@mapNotNull null
                val time = clockTime(period, hours.toInt(), minutes.ifEmpty { pointMinutes }.toIntOrNull() ?: 0)
                    ?: return@mapNotNull null
                ScheduledAnnouncement(title, format.format(date.time), time, evidence.trimEnd())
            }.distinctBy { Triple(it.date, it.time, it.title) }.take(8).toList()
        }

        private fun resolveDate(value: String, postedAt: Long, zone: SimpleTimeZone): Calendar? {
            val calendar = GregorianCalendar(zone, Locale.ROOT).apply { isLenient = false }
            val parts = digits.findAll(value).map { it.value.toInt() }.toList()
            if (parts.isEmpty()) {
                calendar.timeInMillis = postedAt
                calendar.add(Calendar.DAY_OF_MONTH, when (value) {
                    "明天", "明日" -> 1
                    "后天", "后日" -> 2
                    else -> 0
                })
                return calendar
            }
            val (year, month, day) = parts
            calendar.clear()
            calendar.set(year, month - 1, day, 12, 0)
            return try {
                calendar.timeInMillis
                calendar
            } catch (_: IllegalArgumentException) {
                null
            }
        }

        private fun clockTime(period: String, hours: Int, minute: Int): String? {
            var hour = hours
            if (hour !in 0..23 || minute !in 0..59) return null
            when (period) {
                "下午", "晚上", "中午" -> {
                    if (hour == 0) return null
                    if (hour < 12) hour += 12
                }
                "上午", "早上", "凌晨" -> if (hour >= 12) return null
            }
            return String.format(Locale.ROOT, "%02d:%02d", hour, minute)
        }
    }
}
