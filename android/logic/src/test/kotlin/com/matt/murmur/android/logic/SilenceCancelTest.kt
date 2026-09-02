package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SilenceCancelTest {

    private val floor = SilenceCancel.MAX_BUFFERED_SECONDS

    @Test
    fun silenceCancelWhenNoStreamTextAndNoAudio() {
        assertTrue(SilenceCancel.shouldTakeSilenceCancel(false, 0.0))
        assertFalse(
            SilenceCancel.shouldTakeSilenceCancel(true, 0.0),
        )
    }

    @Test
    fun tinyHoldBelowFloorIsDiscarded() {
        assertTrue(SilenceCancel.shouldTakeSilenceCancel(false, 0.33))
    }

    @Test
    fun quietButRealHoldAboveFloorIsRescued() {
        assertFalse(SilenceCancel.shouldTakeSilenceCancel(false, 1.93))
    }

    @Test
    fun streamTextAlwaysBypassesEvenWhenTiny() {
        assertFalse(SilenceCancel.shouldTakeSilenceCancel(true, 0.1))
    }

    @Test
    fun floorBoundaryInclusive() {
        assertTrue(SilenceCancel.shouldTakeSilenceCancel(false, floor - 0.01))
        assertTrue(SilenceCancel.shouldTakeSilenceCancel(false, floor))
        assertFalse(SilenceCancel.shouldTakeSilenceCancel(false, floor + 0.01))
    }

    @Test
    fun pcm16MonoSecondsAt16k() {
        assertEquals(0.0, SilenceCancel.pcm16MonoSeconds(0), 0.0001)
        assertEquals(0.5, SilenceCancel.pcm16MonoSeconds(16_000), 0.0001)
        assertEquals(1.0, SilenceCancel.pcm16MonoSeconds(32_000), 0.0001)
    }
}
