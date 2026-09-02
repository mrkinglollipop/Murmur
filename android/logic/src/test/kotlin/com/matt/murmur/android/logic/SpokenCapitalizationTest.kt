package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class SpokenCapitalizationTest {

    @Test
    fun testLockedGoldenSingleCapital() {
        assertEquals("api key for X", SpokenCapitalization.apply("api key for x capital x"))
    }

    @Test
    fun testLockedGoldenRTLMultiCommand() {
        assertEquals(
            "X api Key Secret",
            SpokenCapitalization.apply("x api key secret capital k capital s capital x"),
        )
    }

    @Test
    fun testCommaEquivalentToWhitespace() {
        assertEquals(
            "X api Key Secret",
            SpokenCapitalization.apply("x api key secret capital k, capital s, capital x"),
        )
    }

    @Test
    fun testCapsAndUppercaseAliases() {
        assertEquals("foo X", SpokenCapitalization.apply("foo x caps x"))
        assertEquals("foo X", SpokenCapitalization.apply("foo x uppercase x"))
    }

    @Test
    fun testNATOLetterInCommandFrame() {
        assertEquals("api key for X", SpokenCapitalization.apply("api key for x capital xray"))
        assertEquals("Secret", SpokenCapitalization.apply("secret capital sierra"))
    }

    @Test
    fun testBareNATOWordIsNotALetter() {
        assertEquals(
            "book a hotel tonight",
            SpokenCapitalization.apply("book a hotel tonight"),
        )
    }

    @Test
    fun testUnknownLetterWordFailSoft() {
        assertEquals(
            "api key capital foobar",
            SpokenCapitalization.apply("api key capital foobar"),
        )
    }

    @Test
    fun testNoPrecedingMatchFailSoft() {
        assertEquals("capital x", SpokenCapitalization.apply("capital x"))
    }

    @Test
    fun testPreferSingleLetterOverWordStart() {
        assertEquals("S secret", SpokenCapitalization.apply("s secret capital s"))
    }

    @Test
    fun testPreservesCommasWhenNoCommand() {
        assertEquals("Hello, world", SpokenCapitalization.apply("Hello, world"))
    }

    @Test
    fun testPreservesNewlinesWhenNoCommand() {
        assertEquals("line1\nline2", SpokenCapitalization.apply("line1\nline2"))
    }

    @Test
    fun testLetterTokenWithTrailingPeriod() {
        assertEquals("Client Secret.", SpokenCapitalization.apply("Client secret capital S."))
        assertEquals(
            "A lot of 2.0 Client Secret.",
            SpokenCapitalization.apply("A lot of 2.0 Client secret capital S."),
        )
    }

    @Test
    fun testOAuthStyleCapitalCS() {
        assertEquals(
            "OAuth Client Secret",
            SpokenCapitalization.apply("OAuth Client secret capital c capital s"),
        )
    }
}
