package com.pasuyobuddy.transcribe.live

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.pasuyobuddy.transcribe.data.Segment

/**
 * Continuous dictation using Android's speech recognizer.
 * The system recognizer stops after each pause, so we restart it automatically until stop() is called.
 * Must be used from the main thread.
 */
class LiveTranscriber(
    private val context: Context,
    private val onUpdate: (segments: List<Segment>, partial: String) -> Unit,
    private val onStatus: (String) -> Unit
) {
    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var listening = false
    private var language = "en-US"
    private var sessionStart = 0L
    private var utteranceStart = 0L
    private val segments = ArrayList<Segment>()

    val isListening: Boolean get() = listening
    val result: List<Segment> get() = segments.toList()
    val elapsedMs: Long get() = if (sessionStart == 0L) 0 else SystemClock.elapsedRealtime() - sessionStart

    fun start(lang: String) {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            onStatus("Speech recognition is not available. Install or enable the Google app, then try again.")
            return
        }
        language = lang
        listening = true
        if (sessionStart == 0L) sessionStart = SystemClock.elapsedRealtime()
        createRecognizer()
        listenOnce()
        onStatus("Listening…")
    }

    fun stop() {
        listening = false
        handler.removeCallbacksAndMessages(null)
        recognizer?.let {
            try { it.stopListening() } catch (_: Exception) {}
            it.destroy()
        }
        recognizer = null
        onStatus("Stopped")
    }

    fun clear() {
        segments.clear()
        sessionStart = if (listening) SystemClock.elapsedRealtime() else 0L
        onUpdate(segments.toList(), "")
    }

    private fun createRecognizer() {
        recognizer?.destroy()
        recognizer = SpeechRecognizer.createSpeechRecognizer(context).apply { setRecognitionListener(listener) }
    }

    private fun listenOnce() {
        if (!listening) return
        utteranceStart = elapsedMs
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, language)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2500L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 2000L)
            putExtra("android.speech.extra.DICTATION_MODE", true)
        }
        try {
            recognizer?.startListening(intent)
        } catch (e: Exception) {
            restart(500, recreate = true)
        }
    }

    private fun restart(delayMs: Long, recreate: Boolean = false) {
        if (!listening) return
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({
            if (!listening) return@postDelayed
            if (recreate) createRecognizer()
            listenOnce()
        }, delayMs)
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() { utteranceStart = elapsedMs }
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
            onUpdate(segments.toList(), text)
        }

        override fun onResults(results: Bundle?) {
            val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
            if (text.isNotBlank()) segments.add(Segment(utteranceStart, elapsedMs, text.trim()))
            onUpdate(segments.toList(), "")
            restart(150)
        }

        override fun onError(error: Int) {
            if (!listening) return
            when (error) {
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                    listening = false
                    onStatus("Microphone permission is needed.")
                }
                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> {
                    listening = false
                    onStatus("This language isn't available for live mode on your phone. Pick another language, or use Record and transcribe it afterwards.")
                }
                SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_SERVER,
                SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> {
                    onStatus("Connection problem – retrying… (live mode needs internet)")
                    restart(1500, recreate = true)
                }
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_CLIENT -> restart(400, recreate = true)
                else -> restart(200) // NO_MATCH, SPEECH_TIMEOUT, etc.: just keep listening
            }
        }
    }
}
