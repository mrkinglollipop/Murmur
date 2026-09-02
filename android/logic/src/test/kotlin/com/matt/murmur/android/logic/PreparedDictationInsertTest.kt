package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreparedDictationInsertTest {

    @Test
    fun needsLeadingSpaceAfterWordNotAfterSpace() {
        assertTrue(needsLeadingSpace("hello"))
        assertTrue(needsLeadingSpace("hello."))
        assertFalse(needsLeadingSpace("hello "))
        assertFalse(needsLeadingSpace(""))
        assertFalse(needsLeadingSpace("("))
        assertFalse(needsLeadingSpace("\n"))
    }

    @Test
    fun preparedDictationInsertJoinsTakesWithoutGlue() {
        assertEquals(
            "hello there ",
            preparedDictationInsert("hello there", "", trailingSpace = true),
        )
        assertEquals(
            " more words ",
            preparedDictationInsert("more words", "hello there", trailingSpace = true),
        )
        assertEquals(
            "more words ",
            preparedDictationInsert("more words", "hello there ", trailingSpace = true),
        )
        assertEquals(
            " more words ",
            preparedDictationInsert("  more words  ", "hello.", trailingSpace = true),
        )
        assertEquals(
            "hello ",
            preparedDictationInsert("hello", "(", trailingSpace = true),
        )
        assertEquals(
            "hello ",
            preparedDictationInsert("hello", "\n", trailingSpace = true),
        )
        assertEquals(
            "",
            preparedDictationInsert("   ", "hello", trailingSpace = true),
        )
        assertEquals(
            " hello",
            preparedDictationInsert("hello", "hi", trailingSpace = false),
        )
    }

    @Test
    fun bulkInsertChunksRejoinExactly() {
        val text = "hello world ".repeat(12)
        val chunks = bulkInsertChunks(text)
        assertTrue(chunks.size > 1)
        assertEquals(text, chunks.joinToString(""))
        for (chunk in chunks.dropLast(1)) {
            assertTrue(chunk.endsWith(" "))
        }
    }

    @Test
    fun bulkInsertChunksShortAndEdgeCases() {
        assertEquals(listOf("short text "), bulkInsertChunks("short text "))
        assertEquals(emptyList<String>(), bulkInsertChunks(""))
        val blob = "x".repeat(120)
        assertEquals(listOf(blob), bulkInsertChunks(blob))
    }
}
