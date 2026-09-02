package com.matt.murmur.android.logic

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WavWriterTest {

    @Test
    fun headerIsRiffWavePcm16kMono() {
        val pcm = byteArrayOf(0x34, 0x12, 0x78, 0x56)
        val wav = WavWriter.wrapPcm16(pcm)
        assertEquals(WavWriter.HEADER_BYTES + pcm.size, wav.size)
        assertEquals("RIFF", wav.decodeToString(0, 4))
        assertEquals("WAVE", wav.decodeToString(8, 12))
        assertEquals("fmt ", wav.decodeToString(12, 16))
        assertEquals("data", wav.decodeToString(36, 40))

        val le = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(36 + pcm.size, le.getInt(4))
        assertEquals(16, le.getInt(16))
        assertEquals(1, le.getShort(20).toInt()) // PCM
        assertEquals(1, le.getShort(22).toInt()) // mono
        assertEquals(16_000, le.getInt(24))
        assertEquals(32_000, le.getInt(28)) // byte rate
        assertEquals(2, le.getShort(32).toInt()) // block align
        assertEquals(16, le.getShort(34).toInt())
        assertEquals(pcm.size, le.getInt(40))
        assertArrayEquals(pcm, wav.copyOfRange(WavWriter.HEADER_BYTES, wav.size))
    }

    @Test
    fun writePcm16MatchesWrap() {
        val pcm = ByteArray(320) { i -> (i % 256).toByte() }
        val dir = File(System.getProperty("java.io.tmpdir"), "murmur-wav-${System.nanoTime()}")
        assertTrue(dir.mkdirs())
        try {
            val dest = File(dir, WavWriter.FILE_NAME)
            WavWriter.writePcm16(pcm, dest)
            assertArrayEquals(WavWriter.wrapPcm16(pcm), dest.readBytes())
            assertEquals("audio/wav", WavWriter.MIME_TYPE)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun emptyPcmThrows() {
        WavWriter.wrapPcm16(ByteArray(0))
    }

    @Test(expected = IllegalArgumentException::class)
    fun oddLengthPcmThrows() {
        WavWriter.wrapPcm16(byteArrayOf(0x00))
    }

    private fun ByteArray.decodeToString(from: Int, to: Int): String =
        copyOfRange(from, to).toString(Charsets.US_ASCII)
}
