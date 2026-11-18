package com.pasuyobuddy.transcribe.whisper

/** Kotlin side of the JNI bridge in src/main/cpp/whisper_jni.cpp. */
object WhisperLib {
    init {
        System.loadLibrary("whisper_jni")
    }

    /** Returns a native context pointer, or 0 if the model could not be loaded. */
    external fun initContext(modelPath: String): Long
    external fun freeContext(ptr: Long)
    external fun setAbort(value: Boolean)

    /**
     * Transcribes 16 kHz mono float samples.
     * Result: [0] = "LANG|xx", then "t0ms|t1ms|text" per segment. Null on failure/abort.
     */
    external fun transcribe(
        ptr: Long,
        samples: FloatArray,
        language: String,
        threads: Int,
        keepContext: Boolean
    ): Array<String>?

    external fun systemInfo(): String

    fun recommendedThreads(): Int =
        Runtime.getRuntime().availableProcessors().let { if (it >= 8) 6 else (it - 1).coerceIn(1, 4) }
}
