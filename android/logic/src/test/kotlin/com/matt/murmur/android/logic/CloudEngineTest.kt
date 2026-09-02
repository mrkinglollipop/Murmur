package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudEngineTest {

    @Test
    fun defaultIsElevenLabs() {
        assertEquals(CloudEngine.ELEVEN_LABS, CloudEngine.DEFAULT)
        assertEquals("elevenLabs", CloudEngine.ELEVEN_LABS.raw)
        assertEquals("gemini", CloudEngine.GEMINI.raw)
        assertEquals("ElevenLabs Scribe v2", CloudEngine.ELEVEN_LABS.displayName)
        assertEquals("Gemini 3.5 Transcribe", CloudEngine.GEMINI.displayName)
    }

    @Test
    fun fromRawFallsBackToElevenLabs() {
        assertEquals(CloudEngine.GEMINI, CloudEngine.fromRaw("gemini"))
        assertEquals(CloudEngine.ELEVEN_LABS, CloudEngine.fromRaw("elevenLabs"))
        assertEquals(CloudEngine.ELEVEN_LABS, CloudEngine.fromRaw(null))
        assertEquals(CloudEngine.ELEVEN_LABS, CloudEngine.fromRaw("xai"))
    }

    @Test
    fun geminiLiveGateSkipsAfterHandshakeFailure() {
        assertTrue(GeminiLiveGate.shouldAttemptLive(handshakeFailed = false))
        assertFalse(GeminiLiveGate.shouldAttemptLive(handshakeFailed = true))
    }

    @Test
    fun persistHandshakeFailureOnlyWhileTakeIsActive() {
        assertTrue(
            GeminiLiveGate.shouldPersistHandshakeFailure(
                handshakeFailure = true,
                skipInsert = false,
                sessionClosedByIme = false,
                interrupted = false,
            ),
        )
        assertFalse(
            GeminiLiveGate.shouldPersistHandshakeFailure(
                handshakeFailure = true,
                skipInsert = true,
                sessionClosedByIme = false,
                interrupted = false,
            ),
        )
        assertFalse(
            GeminiLiveGate.shouldPersistHandshakeFailure(
                handshakeFailure = true,
                skipInsert = false,
                sessionClosedByIme = true,
                interrupted = false,
            ),
        )
        assertFalse(
            GeminiLiveGate.shouldPersistHandshakeFailure(
                handshakeFailure = true,
                skipInsert = false,
                sessionClosedByIme = false,
                interrupted = true,
            ),
        )
        assertFalse(
            GeminiLiveGate.shouldPersistHandshakeFailure(
                handshakeFailure = false,
                skipInsert = false,
                sessionClosedByIme = false,
                interrupted = false,
            ),
        )
    }
}
