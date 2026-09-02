package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class DotCompoundNumberNormalizerTest {

    @Test
    fun testAllNumberWords() {
        val cases = listOf(
            "flux.zero" to "flux.0",
            "flux.one" to "flux.1",
            "flux.two" to "flux.2",
            "flux.three" to "flux.3",
            "flux.four" to "flux.4",
            "flux.five" to "flux.5",
            "flux.six" to "flux.6",
            "flux.seven" to "flux.7",
            "flux.eight" to "flux.8",
            "flux.nine" to "flux.9",
        )
        for ((input, expected) in cases) {
            assertEquals("Failed for $input", expected, DotCompoundNumberNormalizer.apply(input))
        }
    }

    @Test
    fun testMixedCaseNumberWord() {
        assertEquals("flux.1", DotCompoundNumberNormalizer.apply("flux.ONE"))
    }

    @Test
    fun testMultipleDotCompoundsInSentence() {
        assertEquals(
            "see flux.1 and v.2 here",
            DotCompoundNumberNormalizer.apply("see flux.one and v.two here"),
        )
    }

    @Test
    fun testChapterOneUnchanged() {
        assertEquals("chapter one", DotCompoundNumberNormalizer.apply("chapter one"))
    }

    @Test
    fun testSpaceAfterDotUnchanged() {
        assertEquals("i.e. one", DotCompoundNumberNormalizer.apply("i.e. one"))
    }

    @Test
    fun testBareNumberWordUnchanged() {
        assertEquals("one", DotCompoundNumberNormalizer.apply("one"))
    }

    @Test
    fun testDecimalVersionUnchanged() {
        assertEquals("version 2.5", DotCompoundNumberNormalizer.apply("version 2.5"))
    }
}
