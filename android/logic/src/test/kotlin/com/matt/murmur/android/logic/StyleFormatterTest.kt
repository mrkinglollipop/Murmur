package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StyleFormatterTest {

    @Test
    fun testFormalAddsCapsAndPeriod() {
        assertEquals("Hello there.", StyleFormatter.apply("hello there", StyleProfile.FORMAL))
    }

    @Test
    fun testCasualStripsTrailingPeriodOnShortTakes() {
        assertEquals("Hello there", StyleFormatter.apply("hello there.", StyleProfile.CASUAL))
    }

    @Test
    fun testCasualKeepsPeriodsWhenLong() {
        val text = "First sentence. Second sentence. Third sentence."
        assertEquals(text, StyleFormatter.apply(text, StyleProfile.CASUAL))
    }

    @Test
    fun testVeryCasualLowercasesAndStripsPeriod() {
        assertEquals("hello there", StyleFormatter.apply("Hello There.", StyleProfile.VERY_CASUAL))
    }

    @Test
    fun testVeryCasualKeepsDictionaryTerms() {
        assertEquals(
            "deploy to Kubernetes now",
            StyleFormatter.apply(
                "Deploy to Kubernetes now.",
                StyleProfile.VERY_CASUAL,
                preserveTerms = listOf("Kubernetes"),
            ),
        )
    }

    @Test
    fun testFormalKeepsQuestionMark() {
        assertEquals("Are you free.", StyleFormatter.apply("are you free", StyleProfile.FORMAL))
        assertEquals("Are you free?", StyleFormatter.apply("are you free?", StyleProfile.FORMAL))
    }

    @Test
    fun testCasualDoesNotStripExclamation() {
        assertEquals("Ship it!", StyleFormatter.apply("ship it!", StyleProfile.CASUAL))
    }
}

class KeytermsSelectionTest {

    @Test
    fun testSelectsCanonicalTermsNotVariants() {
        val store = DictionaryStore()
        store.add(term = "Kubernetes", variants = listOf("kubernetis"))
        store.add(term = "X", variants = listOf("ex"))
        assertEquals(listOf("Kubernetes"), DictionaryStore.selectKeyterms(store.entries))
    }

    @Test
    fun testDropsOverlongTerms() {
        val long = "a".repeat(51)
        val entry = DictionaryEntry(term = long, variants = emptyList())
        assertTrue(DictionaryStore.selectKeyterms(listOf(entry)).isEmpty())
    }
}
