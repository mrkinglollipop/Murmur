package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class PhraseBoundaryTest {

    private fun matches(phrase: String, text: String): Int {
        val regex = Regex(
            PhraseBoundaryPattern.wholePhrase(phrase),
            RegexOption.IGNORE_CASE,
        )
        return regex.findAll(text).count()
    }

    @Test
    fun testPlainWordKeepsWholeWordBehavior() {
        assertEquals(1, matches("cat", "the cat sat"))
        assertEquals("must not match inside a longer word", 0, matches("cat", "concatenate"))
        assertEquals("string start and end are boundaries", 1, matches("cat", "cat"))
        assertEquals("punctuation is a boundary", 1, matches("cat", "cat, dog"))
    }

    @Test
    fun testMultiWordPhraseKeepsWholeWordBehavior() {
        assertEquals(1, matches("my email address", "send my email address please"))
        assertEquals(0, matches("my email address", "my email addresses"))
    }

    @Test
    fun testLeadingPunctuationPhraseMatches() {
        assertEquals(1, matches(".net", "we ship on .net today"))
        assertEquals(1, matches("@work", "ping me @work tomorrow"))
        assertEquals("must not match inside a word", 0, matches("@work", "user@workplace"))
    }

    @Test
    fun testTrailingPunctuationPhraseMatches() {
        assertEquals(1, matches("c++", "i write c++ daily"))
        assertEquals("end of string is a boundary", 1, matches("c++", "i write c++"))
        assertEquals("must not match when a word char follows", 0, matches("c++", "c++x"))
    }

    @Test
    fun testRegexMetacharactersInPhraseAreEscaped() {
        assertEquals("'+' must be literal, not a quantifier", 0, matches("c++", "cccc"))
    }

    @Test
    fun testHasWordCharacterEdges() {
        assertEquals(true, PhraseBoundaryPattern.hasWordCharacterEdges("cat"))
        assertEquals(true, PhraseBoundaryPattern.hasWordCharacterEdges("foo_bar"))
        assertEquals(false, PhraseBoundaryPattern.hasWordCharacterEdges(".NET"))
        assertEquals(false, PhraseBoundaryPattern.hasWordCharacterEdges("c++"))
        assertEquals(false, PhraseBoundaryPattern.hasWordCharacterEdges("@work"))
        assertEquals(false, PhraseBoundaryPattern.hasWordCharacterEdges(""))
    }
}
