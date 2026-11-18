package com.pasuyobuddy.transcribe

import com.pasuyobuddy.transcribe.audio.LinearResampler
import com.pasuyobuddy.transcribe.audio.PcmUtils
import com.pasuyobuddy.transcribe.data.Formats
import com.pasuyobuddy.transcribe.data.Segment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FormatsTest {

    @Test
    fun clockFormats() {
        assertEquals("00:00", Formats.clock(0))
        assertEquals("01:23", Formats.clock(83_000))
        assertEquals("1:02:03", Formats.clock(3_723_000))
    }

    @Test
    fun srtTimeFormats() {
        assertEquals("00:01:23,450", Formats.srtTime(83_450))
        assertEquals("01:00:00,000", Formats.srtTime(3_600_000))
    }

    @Test
    fun srtSkipsBlankAndNumbersSequentially() {
        val srt = Formats.toSrt(
            listOf(
                Segment(0, 1500, " Hello po"),
                Segment(1500, 1600, "  "),
                Segment(2000, 4000, "Kumusta ka?")
            )
        )
        val expected = "1\n00:00:00,000 --> 00:00:01,500\nHello po\n\n" +
            "2\n00:00:02,000 --> 00:00:04,000\nKumusta ka?\n\n"
        assertEquals(expected, srt)
    }

    @Test
    fun txtWithTimestamps() {
        val txt = Formats.toTxt(listOf(Segment(61_000, 62_000, " Magandang umaga")), true)
        assertEquals("[01:01] Magandang umaga", txt)
    }

    @Test
    fun parsesNativeLineWithOffsetAndPipesInText() {
        val seg = Formats.parseNativeLine("1000|2500| a | b", 120_000)!!
        assertEquals(121_000, seg.startMs)
        assertEquals(122_500, seg.endMs)
        assertEquals(" a | b", seg.text)
        assertNull(Formats.parseNativeLine("garbage", 0))
    }

    @Test
    fun noiseTagsDetected() {
        assertTrue(Formats.isNoise(" [BLANK_AUDIO]"))
        assertTrue(Formats.isNoise("(music)"))
        assertEquals(false, Formats.isNoise("Hello [world]"))
    }
}

class PcmUtilsTest {

    @Test
    fun stereoDownmix() {
        val mono = PcmUtils.shortsToMono(shortArrayOf(32767, -32767, 16384, 16384), 4, 2)
        assertEquals(2, mono.size)
        assertEquals(0f, mono[0], 1e-4f)
        assertEquals(0.5f, mono[1], 1e-4f)
    }

    @Test
    fun resamplerPassThroughSameRate() {
        val r = LinearResampler(16_000, 16_000)
        val x = floatArrayOf(0.1f, 0.2f)
        assertEquals(2, r.process(x).size)
    }

    @Test
    fun resampler48kTo16kKeepsLengthRatioAcrossChunks() {
        val r = LinearResampler(48_000, 16_000)
        var total = 0
        repeat(10) { total += r.process(FloatArray(4800) { 0.25f }).size }
        // 48_000 input samples -> ~16_000 output samples
        assertTrue("got $total", total in 15_990..16_010)
    }

    @Test
    fun resamplerUpsamples8kTo16k() {
        val r = LinearResampler(8_000, 16_000)
        var total = 0
        repeat(4) { total += r.process(FloatArray(2000) { 0f }).size }
        assertTrue("got $total", total in 15_990..16_010)
    }
}
