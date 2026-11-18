package com.pasuyobuddy.transcribe.audio

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.pasuyobuddy.transcribe.MainActivity
import com.pasuyobuddy.transcribe.whisper.RecordState
import com.pasuyobuddy.transcribe.whisper.RecordStatus
import com.pasuyobuddy.transcribe.whisper.TranscribeService
import java.io.File

/** Records a meeting to an .m4a file in the background (screen can be off), then hands it to TranscribeService. */
class RecordService : Service() {

    companion object {
        private const val ACTION_START = "start"
        private const val ACTION_STOP = "stop"
        private const val ACTION_PAUSE = "pause"
        private const val ACTION_RESUME = "resume"
        private const val EXTRA_TRANSCRIBE = "transcribe"
        private const val NOTIF_ID = 51

        fun start(ctx: Context) {
            ContextCompat.startForegroundService(ctx, Intent(ctx, RecordService::class.java).setAction(ACTION_START))
        }

        fun pause(ctx: Context) {
            ctx.startService(Intent(ctx, RecordService::class.java).setAction(ACTION_PAUSE))
        }

        fun resume(ctx: Context) {
            ctx.startService(Intent(ctx, RecordService::class.java).setAction(ACTION_RESUME))
        }

        fun stop(ctx: Context, transcribe: Boolean) {
            ctx.startService(Intent(ctx, RecordService::class.java).setAction(ACTION_STOP).putExtra(EXTRA_TRANSCRIBE, transcribe))
        }
    }

    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var title: String = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRecording()
            ACTION_STOP -> stopRecording(intent.getBooleanExtra(EXTRA_TRANSCRIBE, true))
            ACTION_PAUSE -> pauseRecording()
            ACTION_RESUME -> resumeRecording()
        }
        return START_NOT_STICKY
    }

    private fun startRecording() {
        if (recorder != null) return
        TranscribeService.ensureChannel(this)
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
        ServiceCompat.startForeground(this, NOTIF_ID, notification(), type)

        val ts = System.currentTimeMillis()
        title = Recordings.titleFor(ts)
        val f = File(Recordings.dir(this), "meeting_$ts.m4a")
        file = f
        try {
            val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(44_100)
            r.setAudioEncodingBitRate(64_000)
            r.setOutputFile(f.path)
            r.prepare()
            r.start()
            recorder = r
            RecordState.status.value = RecordStatus(true, System.currentTimeMillis(), f.path)
        } catch (e: Exception) {
            RecordState.status.value = RecordStatus(false, error = "Could not start recording: ${e.message}")
            stopSelfSafely()
        }
    }

    private fun pauseRecording() {
        val r = recorder ?: return
        val st = RecordState.status.value
        if (st.paused) return
        try {
            r.pause()
            RecordState.status.value = st.copy(paused = true, pausedAt = System.currentTimeMillis())
            updateNotification()
        } catch (_: Exception) { }
    }

    private fun resumeRecording() {
        val r = recorder ?: return
        val st = RecordState.status.value
        if (!st.paused) return
        try {
            r.resume()
            RecordState.status.value = st.copy(
                paused = false,
                pausedTotalMs = st.pausedTotalMs + (System.currentTimeMillis() - st.pausedAt)
            )
            updateNotification()
        } catch (_: Exception) { }
    }

    private fun updateNotification() {
        getSystemService(android.app.NotificationManager::class.java).notify(NOTIF_ID, notification())
    }

    private fun stopRecording(transcribe: Boolean) {
        val r = recorder
        recorder = null
        var ok = false
        if (r != null) {
            ok = try { r.stop(); true } catch (e: Exception) { false } // stop() throws if nothing was recorded
            r.release()
        }
        val f = file
        RecordState.status.value = RecordStatus(false, path = f?.path)
        if (ok && f != null && f.length() > 0) {
            if (transcribe) TranscribeService.start(this, f.path, title, "meeting", keepAudio = true)
        } else {
            f?.delete()
            if (r != null) RecordState.status.value = RecordStatus(false, error = "Recording was too short.")
        }
        stopSelfSafely()
    }

    private fun stopSelfSafely() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        recorder?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        recorder = null
        if (RecordState.status.value.recording) RecordState.status.value = RecordStatus(false)
        super.onDestroy()
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 2,
            Intent(this, RecordService::class.java).setAction(ACTION_STOP).putExtra(EXTRA_TRANSCRIBE, true),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val paused = RecordState.status.value.paused
        val toggle = PendingIntent.getService(
            this, 3,
            Intent(this, RecordService::class.java).setAction(if (paused) ACTION_RESUME else ACTION_PAUSE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, "jobs")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(if (paused) "Recording paused" else "Recording meeting…")
            .setContentText("Tap Stop & transcribe when finished")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, if (paused) "Resume" else "Pause", toggle)
            .addAction(0, "Stop & transcribe", stop)
            .build()
    }
}
