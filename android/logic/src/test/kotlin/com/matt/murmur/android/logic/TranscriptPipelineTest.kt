package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptPipelineTest {

    @Test
    fun testSpokenPassesDefaultCodeAwareOn() {
        assertEquals(true, TranscriptPipeline.DEFAULT_CODE_AWARE)
        assertEquals("foo.bar", TranscriptPipeline.applySpokenPasses("foo period bar"))
    }

    @Test
    fun testFooPeriodBarJoiner() {
        assertEquals(
            "foo.bar",
            TranscriptPipeline.applySpokenPasses("foo period bar", codeAware = true),
        )
        assertEquals(
            "foo period bar",
            TranscriptPipeline.applySpokenPasses("foo period bar", codeAware = false),
        )
    }

    @Test
    fun testShipItPeriodIsNotASentenceCommand() {
        assertEquals(
            "ship it period",
            TranscriptPipeline.applySpokenPasses("ship it period", codeAware = true),
        )
        assertEquals(
            "ship it period",
            TranscriptPipeline.applySpokenPasses("ship it period", codeAware = false),
        )
    }

    @Test
    fun testShipItExclamationPointSpokenPasses() {
        assertEquals(
            "ship it!",
            TranscriptPipeline.applySpokenPasses("ship it exclamation point", codeAware = true),
        )
        assertEquals(
            "ship it!",
            TranscriptPipeline.applySpokenPasses("ship it exclamation point", codeAware = false),
        )
    }

    @Test
    fun testPreprocessAppliesCapsWhenNotCodeAware() {
        assertEquals(
            "api key for X",
            TranscriptPipeline.applySpokenPasses("api key for x capital x", codeAware = false),
        )
    }

    @Test
    fun testPreprocessAppliesCapsBeforeSpokenPunctuation() {
        assertEquals(
            "foo X_bar",
            TranscriptPipeline.applySpokenPasses("foo x capital x underscore bar", codeAware = true),
        )
    }

    @Test
    fun testPreprocessCapsOnShortInput() {
        assertEquals("X", TranscriptPipeline.applySpokenPasses("x capital x", codeAware = false))
    }

    @Test
    fun testCapsThenDotCompoundWithJoiners() {
        assertEquals(
            "see flux.1 for X",
            TranscriptPipeline.applySpokenPasses("see flux.one for x capital x"),
        )
    }

    @Test
    fun testIdentityWhenNothingApplies() {
        assertEquals("Hello, world", TranscriptPipeline.applySpokenPasses("Hello, world"))
    }

    @Test
    fun testThanksVeryCasualSnippetsLast() {
        val snippets = SnippetsStore()
        snippets.add(trigger = "thanks", expansion = "Thanks, Alex.")
        assertEquals(
            "Thanks, Alex.",
            TranscriptPipeline.apply(
                "thanks",
                style = StyleProfile.VERY_CASUAL,
                snippets = snippets,
            ),
        )
    }

    @Test
    fun testShipItExclamationPointCasualKeepsBang() {
        assertEquals(
            "Ship it!",
            TranscriptPipeline.apply(
                "ship it exclamation point",
                style = StyleProfile.CASUAL,
            ),
        )
    }

    @Test
    fun testPreserveTermsKeepsJoinedIdentifierUnderFormal() {
        val dictionary = DictionaryStore()
        dictionary.add(term = "foo_bar", variants = emptyList())
        assertEquals(
            "foo_bar.",
            TranscriptPipeline.apply(
                "foo underscore bar",
                codeAware = true,
                dictionary = dictionary,
                style = StyleProfile.FORMAL,
            ),
        )
        assertEquals(
            "Foo_bar.",
            TranscriptPipeline.apply(
                "foo underscore bar",
                codeAware = true,
                style = StyleProfile.FORMAL,
            ),
        )
    }
}
