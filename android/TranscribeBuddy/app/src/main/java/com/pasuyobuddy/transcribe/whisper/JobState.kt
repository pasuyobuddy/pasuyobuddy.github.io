package com.pasuyobuddy.transcribe.whisper

import com.pasuyobuddy.transcribe.data.Segment
import kotlinx.coroutines.flow.MutableStateFlow

enum class Phase { IDLE, PREPARING, DOWNLOADING_MODEL, DECODING, TRANSCRIBING, DONE, ERROR, CANCELLED }

data class JobStatus(
    val phase: Phase = Phase.IDLE,
    val title: String = "",
    val progress: Float = 0f,
    val segments: List<Segment> = emptyList(),
    val transcriptId: String? = null,
    val error: String? = null,
    val startedAt: Long = 0L
) {
    val isRunning: Boolean
        get() = phase == Phase.PREPARING || phase == Phase.DOWNLOADING_MODEL ||
            phase == Phase.DECODING || phase == Phase.TRANSCRIBING
}

/** Shared state between the background service and the UI. */
object JobState {
    val status = MutableStateFlow(JobStatus())
}

data class RecordStatus(
    val recording: Boolean = false,
    val startedAt: Long = 0L,
    val path: String? = null,
    val error: String? = null,
    val paused: Boolean = false,
    val pausedAt: Long = 0L,
    val pausedTotalMs: Long = 0L
) {
    /** Recorded time, excluding pauses. */
    fun elapsedMs(now: Long): Long {
        if (!recording) return 0L
        val end = if (paused) pausedAt else now
        return (end - startedAt - pausedTotalMs).coerceAtLeast(0L)
    }
}

object RecordState {
    val status = MutableStateFlow(RecordStatus())
}
