package com.pasuyobuddy.transcribe.data

import android.content.Context

data class Lang(val code: String, val label: String)

object Languages {
    /** Languages for Whisper (files & meetings). */
    val whisper = listOf(
        Lang("auto", "Auto-detect"),
        Lang("en", "English"),
        Lang("tl", "Tagalog / Filipino"),
        Lang("es", "Spanish"),
        Lang("ja", "Japanese"),
        Lang("ko", "Korean"),
        Lang("zh", "Chinese"),
        Lang("id", "Indonesian"),
        Lang("ms", "Malay"),
        Lang("vi", "Vietnamese"),
        Lang("th", "Thai"),
        Lang("hi", "Hindi"),
        Lang("ar", "Arabic"),
        Lang("fr", "French"),
        Lang("de", "German"),
        Lang("pt", "Portuguese"),
        Lang("ru", "Russian"),
        Lang("it", "Italian")
    )

    /** Languages for live (Android speech recognizer, BCP-47 tags). */
    val live = listOf(
        Lang("en-US", "English (US)"),
        Lang("en-PH", "English (Philippines)"),
        Lang("fil-PH", "Filipino / Tagalog"),
        Lang("es-ES", "Spanish"),
        Lang("ja-JP", "Japanese"),
        Lang("ko-KR", "Korean"),
        Lang("cmn-Hans-CN", "Chinese (Mandarin)"),
        Lang("id-ID", "Indonesian"),
        Lang("ms-MY", "Malay"),
        Lang("vi-VN", "Vietnamese"),
        Lang("th-TH", "Thai"),
        Lang("hi-IN", "Hindi"),
        Lang("ar-SA", "Arabic"),
        Lang("fr-FR", "French"),
        Lang("de-DE", "German"),
        Lang("pt-BR", "Portuguese (Brazil)"),
        Lang("ru-RU", "Russian"),
        Lang("it-IT", "Italian")
    )

    fun whisperLabel(code: String) = whisper.firstOrNull { it.code == code }?.label ?: code
    fun liveLabel(code: String) = live.firstOrNull { it.code == code }?.label ?: code
}

class AppPrefs(ctx: Context) {
    private val p = ctx.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var model: String
        get() = p.getString("model", "base") ?: "base"
        set(v) = p.edit().putString("model", v).apply()

    var whisperLang: String
        get() = p.getString("whisperLang", "auto") ?: "auto"
        set(v) = p.edit().putString("whisperLang", v).apply()

    var liveLang: String
        get() = p.getString("liveLang", "en-US") ?: "en-US"
        set(v) = p.edit().putString("liveLang", v).apply()

    /** Translate files & meetings to English (Whisper). */
    var translateToEnglish: Boolean
        get() = p.getBoolean("translate", false)
        set(v) = p.edit().putBoolean("translate", v).apply()

    var showTimestamps: Boolean
        get() = p.getBoolean("timestamps", true)
        set(v) = p.edit().putBoolean("timestamps", v).apply()
}
