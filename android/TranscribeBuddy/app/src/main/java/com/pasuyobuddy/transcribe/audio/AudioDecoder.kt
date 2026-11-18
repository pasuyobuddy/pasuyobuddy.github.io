package com.pasuyobuddy.transcribe.audio

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes any audio/video file Android can read (mp3, m4a, aac, ogg/opus, wav, amr, mp4...)
 * into raw 16 kHz mono 16-bit little-endian PCM, which is what Whisper needs.
 */
object AudioDecoder {

    /** Returns the number of 16 kHz samples written to [out]. */
    fun decodeToPcm16k(
        input: File,
        out: File,
        onProgress: (Float) -> Unit,
        isCancelled: () -> Boolean
    ): Long {
        val extractor = MediaExtractor()
        extractor.setDataSource(input.path)
        var trackIndex = -1
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) { trackIndex = i; break }
        }
        if (trackIndex < 0) {
            extractor.release()
            throw IOException("No audio track found in this file")
        }
        extractor.selectTrack(trackIndex)
        val inFormat = extractor.getTrackFormat(trackIndex)
        val mime = inFormat.getString(MediaFormat.KEY_MIME)!!
        val durationUs = if (inFormat.containsKey(MediaFormat.KEY_DURATION)) inFormat.getLong(MediaFormat.KEY_DURATION) else 0L

        var sampleRate = inFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = inFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var floatPcm = false
        var resampler = LinearResampler(sampleRate, PcmUtils.TARGET_RATE)

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(inFormat, null, null, 0)
        codec.start()

        var written = 0L
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        val outBytes = ByteBuffer.allocate(64 * 1024).order(ByteOrder.LITTLE_ENDIAN)

        BufferedOutputStream(FileOutputStream(out), 1 shl 16).use { os ->
            fun writeSamples(samples: FloatArray) {
                for (v in samples) {
                    if (outBytes.remaining() < 2) {
                        os.write(outBytes.array(), 0, outBytes.position())
                        outBytes.clear()
                    }
                    outBytes.putShort(PcmUtils.floatToShort(v))
                }
                written += samples.size
            }

            try {
                while (!outputDone) {
                    if (isCancelled()) throw InterruptedException("cancelled")

                    if (!inputDone) {
                        val inIdx = codec.dequeueInputBuffer(10_000)
                        if (inIdx >= 0) {
                            val buf = codec.getInputBuffer(inIdx)!!
                            val size = extractor.readSampleData(buf, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }

                    val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                    when {
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val f = codec.outputFormat
                            sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            floatPcm = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                                f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                            resampler = LinearResampler(sampleRate, PcmUtils.TARGET_RATE)
                        }
                        outIdx >= 0 -> {
                            val buf = codec.getOutputBuffer(outIdx)
                            if (buf != null && info.size > 0) {
                                buf.position(info.offset)
                                buf.limit(info.offset + info.size)
                                val ordered = buf.slice().order(ByteOrder.LITTLE_ENDIAN)
                                val mono = if (floatPcm) {
                                    val fb = ordered.asFloatBuffer()
                                    val arr = FloatArray(fb.remaining()); fb.get(arr)
                                    PcmUtils.floatsToMono(arr, arr.size, channels)
                                } else {
                                    val sb = ordered.asShortBuffer()
                                    val arr = ShortArray(sb.remaining()); sb.get(arr)
                                    PcmUtils.shortsToMono(arr, arr.size, channels)
                                }
                                writeSamples(resampler.process(mono))
                                if (durationUs > 0) onProgress((info.presentationTimeUs.toFloat() / durationUs).coerceIn(0f, 1f))
                            }
                            codec.releaseOutputBuffer(outIdx, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                        }
                    }
                }
                if (outBytes.position() > 0) os.write(outBytes.array(), 0, outBytes.position())
            } finally {
                try { codec.stop() } catch (_: Exception) {}
                codec.release()
                extractor.release()
            }
        }
        onProgress(1f)
        return written
    }
}
