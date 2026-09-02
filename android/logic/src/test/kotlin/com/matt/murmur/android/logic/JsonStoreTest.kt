package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant

class JsonStoreTest {

    @Test
    fun dictionaryRoundTripIosShape() {
        val file = File(tmpDir(), MurmurFiles.DICTIONARY)
        val store = DictionaryStore(file = file)
        store.add(term = "Kubernetes", variants = listOf("kubernetis", "kubernettes"))
        val raw = file.readText()
        assertTrue(raw.contains("\"term\":\"Kubernetes\""))
        assertTrue(raw.contains("\"variants\":["))
        assertTrue(raw.contains("\"fixCount\":0"))
        assertTrue(raw.contains("\"isAutoLearned\":false"))
        val loaded = DictionaryStore(file = file)
        assertEquals(1, loaded.entries.size)
        assertEquals("Kubernetes", loaded.entries.first().term)
        assertEquals(listOf("kubernetis", "kubernettes"), loaded.entries.first().variants)
    }

    @Test
    fun dictionaryUpdateAndDeletePersist() {
        val file = File(tmpDir(), MurmurFiles.DICTIONARY)
        val store = DictionaryStore(file = file)
        store.add(term = "Khipu", variants = listOf("Keepu"))
        val id = store.entries.first().id
        store.update(store.entries.first().copy(term = "Khipu", variants = listOf("Keepu", "Keefu")))
        assertEquals(listOf("Keepu", "Keefu"), DictionaryStore(file = file).entries.first().variants)
        store.delete(DictionaryEntry(id = id, term = "Khipu"))
        assertTrue(DictionaryStore(file = file).entries.isEmpty())
    }

    @Test
    fun dictionaryCorruptFileQuarantined() {
        val dir = tmpDir()
        val file = File(dir, MurmurFiles.DICTIONARY)
        file.writeText("{not-json")
        val store = DictionaryStore(file = file)
        assertTrue(store.entries.isEmpty())
        assertFalse(file.exists())
        assertTrue(dir.listFiles()!!.any { it.name.startsWith("dictionary.json.corrupt.") })
    }

    @Test
    fun snippetsRoundTrip() {
        val file = File(tmpDir(), MurmurFiles.SNIPPETS)
        val store = SnippetsStore(file = file)
        store.add(trigger = "my email", expansion = "a@b.com")
        val loaded = SnippetsStore(file = file)
        assertEquals(1, loaded.snippets.size)
        assertEquals("my email", loaded.snippets.first().trigger)
        assertEquals("a@b.com", loaded.snippets.first().expansion)
        store.update(loaded.snippets.first().copy(expansion = "c@d.com"))
        assertEquals("c@d.com", SnippetsStore(file = file).snippets.first().expansion)
        store.delete(SnippetsStore(file = file).snippets.first())
        assertTrue(SnippetsStore(file = file).snippets.isEmpty())
    }

    @Test
    fun historyIosShapeCap200AndIsoDate() {
        val file = File(tmpDir(), MurmurFiles.HISTORY)
        val store = HistoryStore(file = file)
        store.append("hello world", failed = false)
        val raw = file.readText()
        assertTrue(raw.contains("\"text\":\"hello world\""))
        assertTrue(raw.contains("\"failed\":false"))
        assertTrue(raw.contains("\"date\":\""))
        assertFalse(raw.contains("\"engine\""))
        assertFalse(raw.contains("\"injected\""))
        assertFalse(raw.contains("\"audioPath\""))
        val loaded = HistoryStore(file = file)
        assertEquals(1, loaded.entries.size)
        assertEquals("hello world", loaded.entries.first().text)
        assertEquals(2, loaded.wordCount)
        for (i in 0 until 210) {
            store.append("item $i", failed = false)
        }
        assertEquals(HistoryStore.MAX_ENTRIES, store.entries.size)
        assertEquals(HistoryStore.MAX_ENTRIES, HistoryStore(file = file).entries.size)
        assertEquals("item 209", store.entries.first().text)
    }

    @Test
    fun historyIgnoresMacSupersetFields() {
        val file = File(tmpDir(), MurmurFiles.HISTORY)
        file.writeText(
            """[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","date":"2026-09-02T12:00:00Z","text":"hi","failed":false,"engine":"whisper","injected":true,"audioPath":"/tmp/x.wav"}]""",
        )
        val store = HistoryStore(file = file)
        assertEquals(1, store.entries.size)
        assertEquals("hi", store.entries.first().text)
        assertFalse(store.entries.first().failed)
        assertEquals(Instant.parse("2026-09-02T12:00:00Z"), store.entries.first().date)
    }

    @Test
    fun historySkipsEmptyAppend() {
        val store = HistoryStore(file = File(tmpDir(), MurmurFiles.HISTORY))
        store.append("   ", failed = false)
        assertTrue(store.entries.isEmpty())
    }

    @Test
    fun styleRoundTripRawValues() {
        val file = File(tmpDir(), MurmurFiles.STYLE)
        val store = StyleStore(file)
        assertEquals(StyleProfile.CASUAL, store.selected)
        store.selected = StyleProfile.FORMAL
        assertEquals("formal", StyleStore(file).selected.rawValue)
        store.selected = StyleProfile.VERY_CASUAL
        assertEquals("very_casual", StyleStore(file).selected.rawValue)
        val raw = file.readText()
        assertTrue(raw.contains("\"selected\":\"very_casual\""))
    }

    @Test
    fun settingsDefaultsAndPersist() {
        val file = File(tmpDir(), MurmurFiles.SETTINGS)
        val store = SettingsStore(file)
        assertEquals(true, store.codeAware)
        assertEquals(false, store.pressAndHold)
        assertEquals(true, store.removeFillerWords)
        assertEquals(SettingsStore.ENGINE_ELEVEN_LABS, store.engine)
        assertEquals(ImeActivationMode.TAP_TOGGLE, store.activationMode)
        store.setCodeAware(false)
        store.setPressAndHold(true)
        store.setRemoveFillerWords(false)
        val loaded = SettingsStore(file)
        assertEquals(false, loaded.codeAware)
        assertEquals(true, loaded.pressAndHold)
        assertEquals(false, loaded.removeFillerWords)
        assertEquals(ImeActivationMode.PRESS_AND_HOLD, loaded.activationMode)
    }

    @Test
    fun atomicWriteLeavesNoSharedTmpName() {
        val dir = tmpDir()
        val file = File(dir, MurmurFiles.DICTIONARY)
        DictionaryStore(file = file).add(term = "A", variants = listOf("a"))
        assertFalse(File(dir, "dictionary.json.tmp").exists())
        assertTrue(dir.listFiles()!!.none { it.name.startsWith("dictionary.json.tmp.") })
        assertTrue(file.isFile)
    }

    @Test
    fun dictionaryCorrectMergesCompanionDiskEdits() {
        val file = File(tmpDir(), MurmurFiles.DICTIONARY)
        val ime = DictionaryStore(file = file)
        ime.add(term = "Kubernetes", variants = listOf("kubernetis"))
        val companion = DictionaryStore(file = file)
        companion.add(term = "Murmur", variants = listOf("murmer"))
        assertEquals("deploy Kubernetes", ime.correct("deploy kubernetis"))
        val disk = DictionaryStore(file = file)
        assertEquals(setOf("Kubernetes", "Murmur"), disk.entries.map { it.term }.toSet())
        assertEquals(1, disk.entries.first { it.term == "Kubernetes" }.fixCount)
    }

    @Test
    fun settingsCacheUpdatesOnPersist() {
        val file = File(tmpDir(), MurmurFiles.SETTINGS)
        val store = SettingsStore(file)
        store.setPressAndHold(true)
        assertEquals(ImeActivationMode.PRESS_AND_HOLD, SettingsStore.cachedActivationMode)
        store.setPressAndHold(false)
        assertEquals(ImeActivationMode.TAP_TOGGLE, SettingsStore.cachedActivationMode)
    }

    @Test
    fun selectKeytermsNeverEmitsVariantsAndCaps() {
        val entries = (0 until 60).map { i ->
            DictionaryEntry(term = "Term$i", variants = listOf("var$i"), fixCount = i)
        }
        val terms = DictionaryStore.selectKeyterms(entries)
        assertEquals(50, terms.size)
        assertEquals("Term59", terms.first())
        assertFalse(terms.any { it.startsWith("var") })
        val long = DictionaryEntry(term = "x".repeat(51), variants = emptyList(), fixCount = 99)
        assertTrue(DictionaryStore.selectKeyterms(listOf(long)).isEmpty())
    }

    private fun tmpDir(): File = Files.createTempDirectory("murmur-json-").toFile()
}
