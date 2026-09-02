package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamingCoordinatorTest {

    @Test
    fun emptyFinalizeRecoversPreFinalizeSnapshot() {
        val recovered = StreamingCoordinator.streamSuccessTextOrBatchFallback(
            finalizeText = "",
            preFinalizeSnapshot = "hello there",
            truncated = false,
        )
        assertEquals("hello there", recovered)
    }

    @Test
    fun emptyFinalizeWithEmptySnapshotFallsBackToBatch() {
        assertNull(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = "",
                preFinalizeSnapshot = "   ",
                truncated = false,
            ),
        )
    }

    @Test
    fun nonEmptyFinalizePrefersFinalizeText() {
        assertEquals(
            "final words",
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = "final words",
                preFinalizeSnapshot = "stale",
                truncated = false,
            ),
        )
    }

    @Test
    fun truncatedFinalizeFallsBackWhenSnapshotDoesNotExtend() {
        assertNull(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = "hi",
                preFinalizeSnapshot = "longer snapshot text",
                truncated = true,
            ),
        )
    }

    @Test
    fun tailLossRecoversSnapshotWhenFinalizeIsPrefix() {
        val finalize = "I notice it happens with longer dictations."
        val snapshot = "$finalize That's when I'm noticing it."
        assertEquals(
            "I notice it happens with longer dictations. That's when I'm noticing it.",
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = finalize,
                preFinalizeSnapshot = snapshot,
                duration = 22.0,
                truncated = false,
            ),
        )
    }

    @Test
    fun tailLossRecoversSnapshotOnLongHoldEvenWhenFinalizeIsNonEmpty() {
        val firstHalf = List(80) { "word" }.joinToString(" ")
        val secondHalf = "and this is the missing tail at the end."
        val snapshot = "$firstHalf $secondHalf"
        assertEquals(
            snapshot,
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = firstHalf,
                preFinalizeSnapshot = snapshot,
                duration = 90.0,
                truncated = false,
            ),
        )
    }

    @Test
    fun truncatedFinalizeStillRecoversWhenSnapshotExtends() {
        val finalize = "short"
        val snapshot = "short but the hud had the whole sentence here"
        assertEquals(
            snapshot,
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = finalize,
                preFinalizeSnapshot = snapshot,
                duration = 20.0,
                truncated = true,
            ),
        )
    }

    @Test
    fun longHoldLengthMismatchWithoutExtensionFallsBackToBatch() {
        assertNull(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = "hello the world",
                preFinalizeSnapshot = "completely different much longer snapshot text that diverged",
                duration = 60.0,
                truncated = false,
            ),
        )
    }

    @Test
    fun shortHoldLengthMismatchDoesNotForceBatch() {
        assertEquals(
            "hello the world",
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = "hello the world",
                preFinalizeSnapshot = "completely different much longer snapshot text",
                duration = 10.0,
                truncated = false,
            ),
        )
    }

    @Test
    fun snapshotExtendsFinalizeCaseInsensitive() {
        assertTrue(
            StreamingCoordinator.snapshotExtendsFinalize(
                finalize = "Hello There",
                snapshot = "hello there friend",
            ),
        )
    }

    @Test
    fun snapshotDoesNotExtendWhenUnrelated() {
        assertFalse(
            StreamingCoordinator.snapshotExtendsFinalize(
                finalize = "final words",
                snapshot = "stale",
            ),
        )
    }

    @Test
    fun snapshotExtendsWhenFinalizeAddsTrailingPunctuation() {
        assertTrue(
            StreamingCoordinator.snapshotExtendsFinalize(
                finalize = "I notice it happens with longer dictations.",
                snapshot = "I notice it happens with longer dictations that's when I'm noticing it",
            ),
        )
        assertEquals(
            "I notice it happens with longer dictations. That's when I'm noticing it",
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = "I notice it happens with longer dictations.",
                preFinalizeSnapshot = "I notice it happens with longer dictations that's when I'm noticing it",
                duration = 22.0,
                truncated = false,
            ),
        )
    }

    @Test
    fun truncatedExtendingSnapshotStillBelowCpsFallsBackToBatch() {
        assertNull(
            StreamingCoordinator.streamSuccessTextOrBatchFallback(
                finalizeText = "short",
                preFinalizeSnapshot = "short and extra",
                duration = 20.0,
                truncated = true,
            ),
        )
    }

    @Test
    fun streamResultLooksTruncatedUsesCpsFloor() {
        assertFalse(StreamingCoordinator.streamResultLooksTruncated("hello", 4.0))
        assertTrue(StreamingCoordinator.streamResultLooksTruncated("hi", 10.0))
        assertFalse(StreamingCoordinator.streamResultLooksTruncated("this is long enough text", 10.0))
    }

    @Test
    fun silenceCancelDelegatesToSilenceCancel() {
        assertTrue(StreamingCoordinator.shouldTakeSilenceCancel(false, 0.5))
        assertFalse(StreamingCoordinator.shouldTakeSilenceCancel(true, 0.1))
        assertFalse(StreamingCoordinator.shouldTakeSilenceCancel(false, 0.51))
    }
}
