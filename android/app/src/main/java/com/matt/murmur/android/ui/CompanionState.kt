package com.matt.murmur.android.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.view.inputmethod.InputMethodManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.matt.murmur.android.crypto.MurmurSecrets
import com.matt.murmur.android.logic.CloudEngine
import com.matt.murmur.android.logic.DictionaryEntry
import com.matt.murmur.android.prefs.EnginePrefs
import com.matt.murmur.android.logic.DictionaryStore
import com.matt.murmur.android.logic.HistoryEntry
import com.matt.murmur.android.logic.HistoryStore
import com.matt.murmur.android.logic.MurmurFiles
import com.matt.murmur.android.logic.SettingsStore
import com.matt.murmur.android.logic.Snippet
import com.matt.murmur.android.logic.SnippetsStore
import com.matt.murmur.android.logic.StyleProfile
import com.matt.murmur.android.logic.StyleStore
import java.time.Instant
import java.time.ZoneId

class CompanionState(context: Context) {
    private val app = context.applicationContext
    private val dictFileStore = DictionaryStore(file = MurmurFiles.dictionary(app.filesDir))
    private val snipFileStore = SnippetsStore(file = MurmurFiles.snippets(app.filesDir))
    private val histFileStore = HistoryStore(file = MurmurFiles.history(app.filesDir))
    private val styleFileStore = StyleStore(MurmurFiles.style(app.filesDir))
    private val settingsFileStore = SettingsStore(MurmurFiles.settings(app.filesDir))

    var dictionaryEntries by mutableStateOf<List<DictionaryEntry>>(emptyList())
        private set
    var snippets by mutableStateOf<List<Snippet>>(emptyList())
        private set
    var history by mutableStateOf<List<HistoryEntry>>(emptyList())
        private set
    var style by mutableStateOf(StyleProfile.CASUAL)
        private set
    var codeAware by mutableStateOf(true)
        private set
    var pressAndHold by mutableStateOf(false)
        private set
    var removeFillerWords by mutableStateOf(true)
        private set
    var dictionaryIntroDismissed by mutableStateOf(false)
        private set
    var snippetsIntroDismissed by mutableStateOf(false)
        private set
    var imeEnabled by mutableStateOf(false)
        private set
    var micGranted by mutableStateOf(false)
        private set
    var hasApiKey by mutableStateOf(false)
        private set
    var hasGeminiKey by mutableStateOf(false)
        private set
    var engine by mutableStateOf(CloudEngine.DEFAULT)
        private set

    val wordCount: Int
        get() = history.filter { !it.failed }.sumOf { HistoryStore.wordsIn(it.text) }

    val setupIncomplete: Boolean
        get() = !imeEnabled || !micGranted || !hasApiKey

    val todayEntries: List<HistoryEntry>
        get() {
            val zone = ZoneId.systemDefault()
            val today = Instant.now().atZone(zone).toLocalDate()
            return history.filter { it.date.atZone(zone).toLocalDate() == today }
        }

    init {
        copyFromStores()
        refreshStatus()
    }

    private fun copyFromStores() {
        dictionaryEntries = dictFileStore.entries
        snippets = snipFileStore.snippets
        history = histFileStore.entries
        style = styleFileStore.selected
        codeAware = settingsFileStore.codeAware
        pressAndHold = settingsFileStore.pressAndHold
        removeFillerWords = settingsFileStore.removeFillerWords
        dictionaryIntroDismissed = settingsFileStore.dictionaryIntroDismissed
        snippetsIntroDismissed = settingsFileStore.snippetsIntroDismissed
    }

    fun reload() {
        dictFileStore.reload()
        snipFileStore.reload()
        histFileStore.reload()
        styleFileStore.reload()
        settingsFileStore.reload()
        copyFromStores()
        refreshStatus()
    }

    fun refreshStatus() {
        val imm = app.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imeEnabled = imm.enabledInputMethodList.any { it.packageName == app.packageName }
        micGranted = app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        engine = EnginePrefs.engine(app)
        try {
            val keys = MurmurSecrets.apiKeyStore(app)
            hasApiKey = !keys.elevenLabsKey().isNullOrBlank()
            hasGeminiKey = !keys.geminiKey().isNullOrBlank()
        } catch (_: Exception) {
            hasApiKey = false
            hasGeminiKey = false
        }
    }

    fun chooseEngine(value: CloudEngine) {
        EnginePrefs.setEngine(app, value)
        engine = value
    }

    fun addDictionary(term: String, variants: List<String>) {
        dictFileStore.add(term, variants)
        dictionaryEntries = dictFileStore.entries
    }

    fun updateDictionary(entry: DictionaryEntry) {
        dictFileStore.update(entry)
        dictionaryEntries = dictFileStore.entries
    }

    fun deleteDictionary(entry: DictionaryEntry) {
        dictFileStore.delete(entry)
        dictionaryEntries = dictFileStore.entries
    }

    fun addSnippet(trigger: String, expansion: String) {
        snipFileStore.add(trigger, expansion)
        snippets = snipFileStore.snippets
    }

    fun updateSnippet(snippet: Snippet) {
        snipFileStore.update(snippet)
        snippets = snipFileStore.snippets
    }

    fun deleteSnippet(snippet: Snippet) {
        snipFileStore.delete(snippet)
        snippets = snipFileStore.snippets
    }

    fun chooseStyle(profile: StyleProfile) {
        styleFileStore.selected = profile
        style = styleFileStore.selected
    }

    fun chooseCodeAware(value: Boolean) {
        settingsFileStore.setCodeAware(value)
        codeAware = settingsFileStore.codeAware
    }

    fun choosePressAndHold(value: Boolean) {
        settingsFileStore.setPressAndHold(value)
        pressAndHold = settingsFileStore.pressAndHold
    }

    fun chooseRemoveFillerWords(value: Boolean) {
        settingsFileStore.setRemoveFillerWords(value)
        removeFillerWords = settingsFileStore.removeFillerWords
    }

    fun dismissDictionaryIntro() {
        settingsFileStore.dismissDictionaryIntro()
        dictionaryIntroDismissed = true
    }

    fun dismissSnippetsIntro() {
        settingsFileStore.dismissSnippetsIntro()
        snippetsIntroDismissed = true
    }

    fun saveApiKey(value: String): Boolean {
        return try {
            MurmurSecrets.apiKeyStore(app).saveElevenLabsKey(value.trim())
            refreshStatus()
            true
        } catch (_: Exception) {
            false
        }
    }

    fun saveGeminiKey(value: String): Boolean {
        return try {
            MurmurSecrets.apiKeyStore(app).saveGeminiKey(value.trim())
            EnginePrefs.setGeminiLiveHandshakeFailed(app, false)
            refreshStatus()
            true
        } catch (_: Exception) {
            false
        }
    }
}
