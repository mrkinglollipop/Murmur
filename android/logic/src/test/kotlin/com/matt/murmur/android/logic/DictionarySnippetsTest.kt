package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DictionarySnippetsTest {

    @Test
    fun testDictionaryReplacesWholeWordVariants() {
        val store = DictionaryStore()
        store.add(term = "Kubernetes", variants = listOf("kubernetis", "kubernettes"))
        assertEquals("deploy to Kubernetes now", store.correct("deploy to kubernetis now"))
        assertEquals("running Kubernetes now", store.correct("running Kubernettes now"))
        assertEquals("kubernetisation", store.correct("kubernetisation"))
    }

    @Test
    fun testAddSameTermMergesVariants() {
        val store = DictionaryStore()
        store.add(term = "Khipu", variants = listOf("Keepu"))
        store.add(term = "khipu", variants = listOf("Keefu"))
        assertEquals(1, store.entries.size)
        assertEquals(
            setOf("keepu", "keefu"),
            store.entries.first().variants.map { it.lowercase() }.toSet(),
        )
        assertEquals("open Khipu and Khipu", store.correct("open Keepu and Keefu"))
    }

    @Test
    fun testAddSameTermDoesNotDuplicateVariant() {
        val store = DictionaryStore()
        store.add(term = "Khipu", variants = listOf("Keepu"))
        store.add(term = "Khipu", variants = listOf("keepu"))
        assertEquals(1, store.entries.size)
        assertEquals(listOf("Keepu"), store.entries.first().variants)
    }

    @Test
    fun testEmptyDictionaryLeavesTextAlone() {
        val store = DictionaryStore()
        assertEquals("leave this", store.correct("leave this"))
    }

    @Test
    fun testDictionaryCorrectsPunctuationEdgedVariant() {
        val store = DictionaryStore()
        store.add(term = ".NET", variants = listOf(".net"))
        assertEquals("we ship on .NET today", store.correct("we ship on .net today"))
    }

    @Test
    fun testTypedVariantsOnlyNoPhoneticSubstitution() {
        val store = DictionaryStore()
        store.add(term = ".NET", variants = listOf("dotnet"))
        assertEquals("we ship on .net today", store.correct("we ship on .net today"))
    }

    @Test
    fun testSnippetExpandsLongestTriggerFirst() {
        val store = SnippetsStore()
        store.add(trigger = "see", expansion = "SEE")
        store.add(trigger = "see you soon", expansion = "SYSexpanded")
        assertEquals("SYSexpanded tomorrow", store.expand("see you soon tomorrow"))
        assertEquals("SEE the seeds", store.expand("see the seeds"))
    }

    @Test
    fun testSnippetPunctuationTrigger() {
        val store = SnippetsStore()
        store.add(trigger = "@work", expansion = "matt@example.com")
        assertEquals(
            "ping me matt@example.com tomorrow",
            store.expand("ping me @work tomorrow"),
        )
        assertEquals("user@workplace", store.expand("user@workplace"))
    }

    @Test
    fun testSnippetExpandsTrailingPunctuationTrigger() {
        val store = SnippetsStore()
        store.add(trigger = "c++", expansion = "C plus plus")
        assertEquals("i write C plus plus daily", store.expand("i write c++ daily"))
    }

    @Test
    fun testMergingDuplicateTermsCombinesVariants() {
        val keepuId = "keepu-id"
        val merged = DictionaryStore.mergingDuplicateTerms(
            listOf(
                DictionaryEntry(id = keepuId, term = "Khipu", variants = listOf("Keepu"), fixCount = 4),
                DictionaryEntry(term = "Khipu", variants = listOf("Keefu"), fixCount = 0),
            ),
        )
        assertEquals(1, merged.size)
        assertEquals(keepuId, merged.first().id)
        assertEquals(setOf("keepu", "keefu"), merged.first().variants.map { it.lowercase() }.toSet())
        assertEquals(4, merged.first().fixCount)
    }

    @Test
    fun testUpdateMergesSameTermAndDeleteRemoves() {
        val store = DictionaryStore()
        store.add(term = "Khipu", variants = listOf("Keepu"))
        store.add(term = "Other", variants = listOf("uddur"))
        val other = store.entries.first { it.term == "Other" }
        store.update(other.copy(term = "Khipu", variants = listOf("Keefu")))
        assertEquals(1, store.entries.size)
        assertEquals(
            setOf("keepu", "keefu"),
            store.entries.first().variants.map { it.lowercase() }.toSet(),
        )
        store.delete(store.entries.first())
        assertTrue(store.entries.isEmpty())
    }

    @Test
    fun testSnippetUpdateAndDelete() {
        val store = SnippetsStore()
        store.add(trigger = "sig", expansion = "old")
        val snippet = store.snippets.first()
        store.update(snippet.copy(expansion = "new"))
        assertEquals("new", store.snippets.first().expansion)
        store.delete(store.snippets.first())
        assertTrue(store.snippets.isEmpty())
    }
}
