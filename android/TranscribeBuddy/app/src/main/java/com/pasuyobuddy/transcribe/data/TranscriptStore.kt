package com.pasuyobuddy.transcribe.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class Transcript(
    val id: String,
    val title: String,
    val createdAt: Long,
    val source: String,          // "live", "file", "meeting"
    val language: String,
    val durationMs: Long,
    val segments: List<Segment>,
    val audioPath: String? = null,
    val translated: Boolean = false   // text was translated to English by Whisper
) {
    val preview: String get() = segments.joinToString(" ") { it.text.trim() }.take(140)
}

/** Saves transcripts as small JSON files in the app's private storage. */
object TranscriptStore {

    private fun dir(ctx: Context): File = File(ctx.filesDir, "transcripts").apply { mkdirs() }

    fun save(ctx: Context, t: Transcript) {
        val json = JSONObject()
            .put("id", t.id)
            .put("title", t.title)
            .put("createdAt", t.createdAt)
            .put("source", t.source)
            .put("language", t.language)
            .put("durationMs", t.durationMs)
            .put("audioPath", t.audioPath ?: JSONObject.NULL)
            .put("translated", t.translated)
        val arr = JSONArray()
        for (s in t.segments) {
            arr.put(JSONObject().put("s", s.startMs).put("e", s.endMs).put("t", s.text))
        }
        json.put("segments", arr)
        val tmp = File(dir(ctx), "${t.id}.json.tmp")
        tmp.writeText(json.toString())
        tmp.renameTo(File(dir(ctx), "${t.id}.json"))
    }

    fun load(ctx: Context, id: String): Transcript? {
        val f = File(dir(ctx), "$id.json")
        if (!f.exists()) return null
        return try { parse(JSONObject(f.readText())) } catch (e: Exception) { null }
    }

    fun list(ctx: Context): List<Transcript> =
        dir(ctx).listFiles { f -> f.name.endsWith(".json") }
            ?.mapNotNull { f -> try { parse(JSONObject(f.readText())) } catch (e: Exception) { null } }
            ?.sortedByDescending { it.createdAt }
            ?: emptyList()

    fun delete(ctx: Context, id: String) {
        File(dir(ctx), "$id.json").delete()
    }

    fun rename(ctx: Context, id: String, title: String) {
        load(ctx, id)?.let { save(ctx, it.copy(title = title)) }
    }

    private fun parse(o: JSONObject): Transcript {
        val arr = o.optJSONArray("segments") ?: JSONArray()
        val segs = ArrayList<Segment>(arr.length())
        for (i in 0 until arr.length()) {
            val s = arr.getJSONObject(i)
            segs.add(Segment(s.getLong("s"), s.getLong("e"), s.getString("t")))
        }
        return Transcript(
            id = o.getString("id"),
            title = o.optString("title", "Transcript"),
            createdAt = o.optLong("createdAt"),
            source = o.optString("source", "file"),
            language = o.optString("language", ""),
            durationMs = o.optLong("durationMs"),
            segments = segs,
            audioPath = if (o.isNull("audioPath")) null else o.optString("audioPath"),
            translated = o.optBoolean("translated", false)
        )
    }
}
