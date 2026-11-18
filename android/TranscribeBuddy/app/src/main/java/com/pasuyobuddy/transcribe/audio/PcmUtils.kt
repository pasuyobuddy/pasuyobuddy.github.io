package com.pasuyobuddy.transcribe.audio

/** Pure PCM helpers (no Android dependencies, unit-tested). */
object PcmUtils {
    const val TARGET_RATE = 16_000

    /** Interleaved 16-bit samples -> mono floats in [-1, 1]. */
    fun shortsToMono(interleaved: ShortArray, count: Int, channels: Int): FloatArray {
        val ch = channels.coerceAtLeast(1)
        val frames = count / ch
        val out = FloatArray(frames)
        for (f in 0 until frames) {
            var sum = 0f
            val base = f * ch
            for (c in 0 until ch) sum += interleaved[base + c]
            out[f] = sum / ch / 32768f
        }
        return out
    }

    /** Interleaved float samples -> mono floats. */
    fun floatsToMono(interleaved: FloatArray, count: Int, channels: Int): FloatArray {
        val ch = channels.coerceAtLeast(1)
        val frames = count / ch
        val out = FloatArray(frames)
        for (f in 0 until frames) {
            var sum = 0f
            val base = f * ch
            for (c in 0 until ch) sum += interleaved[base + c]
            out[f] = sum / ch
        }
        return out
    }

    fun floatToShort(v: Float): Short {
        val x = (v * 32767f).toInt()
        return x.coerceIn(-32768, 32767).toShort()
    }
}

/**
 * Streaming linear resampler. Feed consecutive buffers; output is continuous across calls.
 * When downsampling, a simple moving-average pre-filter reduces aliasing.
 */
class LinearResampler(private val inRate: Int, private val outRate: Int) {
    private val step = inRate.toDouble() / outRate
    private var pos = 0.0          // read position relative to the start of the next input buffer
    private var last = 0f          // last sample of the previous buffer (index -1)
    private val avgWidth = if (inRate > outRate) (inRate / outRate).coerceAtLeast(1) else 1
    private val history = FloatArray(avgWidth)
    private var histIdx = 0
    private var histSum = 0f

    fun process(input: FloatArray): FloatArray {
        if (input.isEmpty()) return input
        if (inRate == outRate) return input
        val src = if (avgWidth > 1) lowPass(input) else input
        val n = src.size
        val est = ((n - pos) / step).toInt() + 2
        val out = FloatArray(est.coerceAtLeast(0))
        var k = 0
        while (pos < n - 1 && k < out.size) {
            val i = Math.floor(pos).toInt()
            val frac = (pos - i).toFloat()
            val a = if (i < 0) last else src[i]
            val b = src[i + 1]
            out[k++] = a + (b - a) * frac
            pos += step
        }
        pos -= n
        last = src[n - 1]
        return if (k == out.size) out else out.copyOf(k)
    }

    private fun lowPass(input: FloatArray): FloatArray {
        val out = FloatArray(input.size)
        for (i in input.indices) {
            histSum -= history[histIdx]
            history[histIdx] = input[i]
            histSum += input[i]
            histIdx = (histIdx + 1) % avgWidth
            out[i] = histSum / avgWidth
        }
        return out
    }
}
