package com.pasuyobuddy.transcribe.data

/** One piece of transcribed text with its position in the recording. */
data class Segment(val startMs: Long, val endMs: Long, val text: String)

/** Pure formatting helpers (no Android dependencies, unit-tested). */
object Formats {

    /** 83_000 -> "01:23", 3_723_000 -> "1:02:03" */
    fun clock(ms: Long): String {
        val totalSec = (ms.coerceAtLeast(0)) / 1000
        val h = totalSec / 3600
        val m = (totalSec % 3600) / 60
        val s = totalSec % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
    }

    /** SRT timestamp: 83_450 -> "00:01:23,450" */
    fun srtTime(ms: Long): String {
        val v = ms.coerceAtLeast(0)
        val h = v / 3_600_000
        val m = (v % 3_600_000) / 60_000
        val s = (v % 60_000) / 1000
        val milli = v % 1000
        return "%02d:%02d:%02d,%03d".format(h, m, s, milli)
    }

    fun toTxt(segments: List<Segment>, withTimestamps: Boolean): String =
        segments.filter { it.text.isNotBlank() }.joinToString("\n") {
            if (withTimestamps) "[${clock(it.startMs)}] ${it.text.trim()}" else it.text.trim()
        }

    fun toSrt(segments: List<Segment>): String {
        val sb = StringBuilder()
        var n = 1
        for (seg in segments) {
            if (seg.text.isBlank()) continue
            val end = if (seg.endMs > seg.startMs) seg.endMs else seg.startMs + 2000
            sb.append(n++).append('\n')
                .append(srtTime(seg.startMs)).append(" --> ").append(srtTime(end)).append('\n')
                .append(seg.text.trim()).append("\n\n")
        }
        return sb.toString()
    }

    /** Parses a native "t0|t1|text" line, shifting times by [offsetMs]. */
    fun parseNativeLine(line: String, offsetMs: Long): Segment? {
        val first = line.indexOf('|')
        if (first < 0) return null
        val second = line.indexOf('|', first + 1)
        if (second < 0) return null
        val t0 = line.substring(0, first).toLongOrNull() ?: return null
        val t1 = line.substring(first + 1, second).toLongOrNull() ?: return null
        val text = line.substring(second + 1)
        return Segment(t0 + offsetMs, t1 + offsetMs, text)
    }

    /** Whisper marks silence/noise with tags like "[BLANK_AUDIO]" or "(music)"; drop those. */
    fun isNoise(text: String): Boolean {
        val t = text.trim()
        if (t.isEmpty()) return true
        return (t.startsWith("[") && t.endsWith("]")) || (t.startsWith("(") && t.endsWith(")"))
    }
}
