package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class SpokenPunctuationTest {

    @Test
    fun testUnderscoreBetweenWords() {
        assertEquals("foo_bar", SpokenPunctuation.apply("foo underscore bar"))
    }

    @Test
    fun testUnderscoreChain() {
        assertEquals(
            "foo_bar_baz",
            SpokenPunctuation.apply("foo underscore bar underscore baz"),
        )
    }

    @Test
    fun testUnderScoreAlias() {
        assertEquals("foo_bar", SpokenPunctuation.apply("foo under score bar"))
    }

    @Test
    fun testOpenParen() {
        assertEquals("call ( here", SpokenPunctuation.apply("call open paren here"))
    }

    @Test
    fun testParenthesisAliases() {
        assertEquals("( x )", SpokenPunctuation.apply("open parenthesis x close parenthesis"))
        assertEquals("( )", SpokenPunctuation.apply("left paren right paren"))
    }

    @Test
    fun testNewLine() {
        assertEquals(
            "first line \n second line",
            SpokenPunctuation.apply("first line new line second line"),
        )
    }

    @Test
    fun testTab() {
        assertEquals("indent \t here", SpokenPunctuation.apply("indent tab key here"))
    }

    @Test
    fun testMixedChain() {
        assertEquals(
            "( foo_bar )",
            SpokenPunctuation.apply("open paren foo underscore bar close paren"),
        )
    }

    @Test
    fun testDotBetweenWords() {
        assertEquals(
            "rereadpersona_Deadpool.mid",
            SpokenPunctuation.apply("rereadpersona_Deadpool dot mid"),
        )
    }

    @Test
    fun testDotChain() {
        assertEquals("foo.bar.baz", SpokenPunctuation.apply("foo dot bar dot baz"))
    }

    @Test
    fun testPeriodAlias() {
        assertEquals(
            "SettingsStore.swift",
            SpokenPunctuation.apply("SettingsStore period swift"),
        )
    }

    @Test
    fun testPeriodIsJoinerNotSentenceEnd() {
        assertEquals("foo.bar", SpokenPunctuation.apply("foo period bar"))
        assertEquals("foo.bar", SpokenPunctuation.apply("foo period bar", codeAware = true))
        // No right-hand word: joiner does not fire. `period` is not a sentence command.
        assertEquals("ship it period", SpokenPunctuation.apply("ship it period"))
        assertEquals("ship it period", SpokenPunctuation.apply("ship it period", codeAware = false))
        assertEquals("ship it period", SpokenPunctuation.apply("ship it period", codeAware = true))
    }

    @Test
    fun testLetterSpacedFileExtensionAfterDot() {
        assertEquals("Conduct.mdc", SpokenPunctuation.apply("Conduct.m d c"))
        assertEquals("Conduct.mdc", SpokenPunctuation.apply("Conduct dot m d c"))
        assertEquals(
            "rules/conduct.mdc",
            SpokenPunctuation.apply("rules forward slash conduct dot m d c"),
        )
        assertEquals("file.ts", SpokenPunctuation.apply("file.t s"))
        assertEquals("App.swift", SpokenPunctuation.apply("App.s w i f t"))
        assertEquals(
            "Draft a session start hook for conduct.mdc.",
            SpokenPunctuation.apply("Draft a session start hook for conduct.m d c."),
        )
        assertEquals("Conduct.mdc", SpokenPunctuation.apply("Conduct.M D C"))
        assertEquals("App.swift", SpokenPunctuation.apply("App Dot S W I F T"))
        assertEquals("conduct.mdc", SpokenPunctuation.apply("conduct Dot Mdc"))
    }

    @Test
    fun testConductDotMdcJoinsAndIsIdempotent() {
        val joined = SpokenPunctuation.apply("conduct dot mdc")
        assertEquals("conduct.mdc", joined)
        assertEquals("conduct.mdc", SpokenPunctuation.apply("conduct dot mdc"))
        assertEquals("conduct.mdc", SpokenPunctuation.apply(joined))
        assertEquals(
            "Is any part of conduct.mdc outside of those two active hooks",
            SpokenPunctuation.apply(
                "Is any part of conduct dot mdc outside of those two active hooks",
            ),
        )
    }

    @Test
    fun testSpacedExtensionDoesNotEatProseAfterPeriod() {
        assertEquals(
            "Mr. A B C was here",
            SpokenPunctuation.apply("Mr. A B C was here"),
        )
        assertEquals(
            "see section. A B was wrong",
            SpokenPunctuation.apply("see section. A B was wrong"),
        )
        assertEquals(
            "see section.a b was wrong",
            SpokenPunctuation.apply("see section.a b was wrong"),
        )
    }

    @Test
    fun testForwardSlashBetweenWords() {
        assertEquals(
            "myauditandfix/commitprmerge",
            SpokenPunctuation.apply("myauditandfix forward slash commitprmerge"),
        )
    }

    @Test
    fun testForwardSlashStandalone() {
        assertEquals(
            "type / at the start",
            SpokenPunctuation.apply("type forward slash at the start"),
        )
    }

    @Test
    fun testBackSlashBetweenWords() {
        assertEquals("foo\\bar", SpokenPunctuation.apply("foo back slash bar"))
    }

    @Test
    fun testBackSlashStandalone() {
        assertEquals("escape \\ here", SpokenPunctuation.apply("escape backslash here"))
    }

    @Test
    fun testColonBetweenWords() {
        assertEquals("Array:String", SpokenPunctuation.apply("Array colon String"))
    }

    @Test
    fun testCommonCodingSymbols() {
        val cases = listOf(
            "assign equals sign five" to "assign = five",
            "x plus sign y" to "x + y",
            "a minus sign b" to "a - b",
            "use asterisk wildcard" to "use * wildcard",
            "star operator" to "* operator",
            "foo semicolon bar" to "foo ; bar",
            "hash sign include" to "# include",
            "at sign MainActor" to "@ MainActor",
            "dollar sign zero" to "$ zero",
            "percent sign done" to "% done",
            "less than sign T greater than sign" to "< T >",
            "not equals nil" to "!= nil",
            "equals equals zero" to "== zero",
            "plus equals one" to "+= one",
            "fat arrow Unit" to "=> Unit",
            "thin arrow Void" to "-> Void",
            "double colon self" to ":: self",
            "open brace close brace" to "{ }",
            "open bracket close bracket" to "[ ]",
            "backtick SwiftUI dot View backtick" to "` SwiftUI.View `",
            "comma separated" to ", separated",
            "pipe nil coalescing" to "| nil coalescing",
            "vertical bar filter" to "| filter",
            "caret anchor" to "^ anchor",
            "tilde home" to "~ home",
            "question mark optional" to "? optional",
            "exclamation mark force unwrap" to "! force unwrap",
        )
        for ((input, expected) in cases) {
            assertEquals("input: $input", expected, SpokenPunctuation.apply(input))
        }
    }

    @Test
    fun testProseGuardrailsUnchanged() {
        val prose = listOf(
            "cost less than five dollars",
            "greater than expected growth",
            "hash map and hash table",
            "open a new tab in the browser",
            "review and sign the document",
        )
        for (text in prose) {
            assertEquals("prose corrupted: $text", text, SpokenPunctuation.apply(text))
        }
    }

    @Test
    fun testSentenceEndExclamationCommand() {
        assertEquals(
            "I need one of these!",
            SpokenPunctuation.apply("I need one of these, exclamation point.", codeAware = false),
        )
        assertEquals(
            "!",
            SpokenPunctuation.apply("Exclamation point.", codeAware = false),
        )
        assertEquals(
            "What the hell!",
            SpokenPunctuation.apply("What the hell exclamation point", codeAware = false),
        )
    }

    @Test
    fun testSentenceEndQuestionCommand() {
        assertEquals(
            "How are you?",
            SpokenPunctuation.apply("How are you question mark", codeAware = false),
        )
        assertEquals(
            "How are you?",
            SpokenPunctuation.apply("How are you question mark.", codeAware = false),
        )
    }

    @Test
    fun testPunctuationMentionStaysWords() {
        val mention =
            "calling something a question mark versus asking for punctuation at the end of a sentence."
        assertEquals(mention, SpokenPunctuation.apply(mention, codeAware = false))
        assertEquals(mention, SpokenPunctuation.apply(mention, codeAware = true))

        val anExclamation = "look at the transcripts where I wanted to put an exclamation point in"
        assertEquals(anExclamation, SpokenPunctuation.apply(anExclamation, codeAware = false))

        val plural =
            "It's not doing exclamation points and potentially other things, like question marks, correctly."
        assertEquals(plural, SpokenPunctuation.apply(plural, codeAware = false))
    }

    @Test
    fun testProseDoesNotMapMidSentenceQuestionMark() {
        assertEquals(
            "question mark optional",
            SpokenPunctuation.apply("question mark optional", codeAware = false),
        )
    }

    @Test
    fun testExclamationMarkAliasAtSentenceEnd() {
        assertEquals(
            "Ship it!",
            SpokenPunctuation.apply("Ship it exclamation mark.", codeAware = false),
        )
    }
}
