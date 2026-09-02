package com.matt.murmur.android.logic

import java.io.File

/**
 * Companion settings. [codeAware] defaults on so identifier joiners run.
 * [removeFillerWords] is Scribe `no_verbatim` (missing file means on).
 */
class SettingsStore(
    private val file: File? = null,
) {
    var engine: String = ENGINE_ELEVEN_LABS
        private set
    var codeAware: Boolean = TranscriptPipeline.DEFAULT_CODE_AWARE
        private set
    var pressAndHold: Boolean = false
        private set
    var removeFillerWords: Boolean = true
        private set
    var dictionaryIntroDismissed: Boolean = false
        private set
    var snippetsIntroDismissed: Boolean = false
        private set

    init {
        reload()
        rememberMode()
    }

    fun reload() {
        val f = file ?: return
        val loaded = SettingsJson.read(f) ?: return
        engine = loaded.engine
        codeAware = loaded.codeAware
        pressAndHold = loaded.pressAndHold
        removeFillerWords = loaded.removeFillerWords
        dictionaryIntroDismissed = loaded.dictionaryIntroDismissed
        snippetsIntroDismissed = loaded.snippetsIntroDismissed
        rememberMode()
    }

    fun setEngine(value: String) {
        engine = value
        persist()
    }

    fun setCodeAware(value: Boolean) {
        codeAware = value
        persist()
    }

    fun setPressAndHold(value: Boolean) {
        pressAndHold = value
        persist()
    }

    fun setRemoveFillerWords(value: Boolean) {
        removeFillerWords = value
        persist()
    }

    fun dismissDictionaryIntro() {
        dictionaryIntroDismissed = true
        persist()
    }

    fun dismissSnippetsIntro() {
        snippetsIntroDismissed = true
        persist()
    }

    val activationMode: ImeActivationMode
        get() = if (pressAndHold) ImeActivationMode.PRESS_AND_HOLD else ImeActivationMode.TAP_TOGGLE

    private fun persist() {
        val f = file ?: return
        AtomicJson.write(
            f,
            SettingsJson.encode(
                Snapshot(
                    engine = engine,
                    codeAware = codeAware,
                    pressAndHold = pressAndHold,
                    removeFillerWords = removeFillerWords,
                    dictionaryIntroDismissed = dictionaryIntroDismissed,
                    snippetsIntroDismissed = snippetsIntroDismissed,
                ),
            ),
        )
        rememberMode()
    }

    private fun rememberMode() {
        if (file != null) {
            cachedActivationMode = activationMode
        }
    }

    data class Snapshot(
        val engine: String = ENGINE_ELEVEN_LABS,
        val codeAware: Boolean = TranscriptPipeline.DEFAULT_CODE_AWARE,
        val pressAndHold: Boolean = false,
        val removeFillerWords: Boolean = true,
        val dictionaryIntroDismissed: Boolean = false,
        val snippetsIntroDismissed: Boolean = false,
    )

    companion object {
        const val ENGINE_ELEVEN_LABS = "elevenLabs"
        const val ENGINE_DISPLAY_NAME = "ElevenLabs Scribe v2"

        @Volatile
        var cachedActivationMode: ImeActivationMode = ImeActivationMode.TAP_TOGGLE
    }
}

internal object SettingsJson {
    fun read(file: File): SettingsStore.Snapshot? {
        val text = AtomicJson.read(file) ?: return null
        return try {
            decode(parseJson(text))
        } catch (_: Exception) {
            AtomicJson.quarantine(file)
            null
        }
    }

    fun encode(snap: SettingsStore.Snapshot): String {
        return jsonObject(
            listOf(
                "engine" to jsonString(snap.engine),
                "codeAware" to snap.codeAware.toString(),
                "pressAndHold" to snap.pressAndHold.toString(),
                "removeFillerWords" to snap.removeFillerWords.toString(),
                "dictionaryIntroDismissed" to snap.dictionaryIntroDismissed.toString(),
                "snippetsIntroDismissed" to snap.snippetsIntroDismissed.toString(),
            ),
        )
    }

    fun decode(value: JsonVal): SettingsStore.Snapshot {
        val obj = value.obj() ?: throw IllegalArgumentException("settings.json must be an object")
        return SettingsStore.Snapshot(
            engine = obj["engine"]?.str() ?: SettingsStore.ENGINE_ELEVEN_LABS,
            codeAware = obj["codeAware"]?.bool() ?: TranscriptPipeline.DEFAULT_CODE_AWARE,
            pressAndHold = obj["pressAndHold"]?.bool() ?: false,
            removeFillerWords = obj["removeFillerWords"]?.bool() ?: true,
            dictionaryIntroDismissed = obj["dictionaryIntroDismissed"]?.bool() ?: false,
            snippetsIntroDismissed = obj["snippetsIntroDismissed"]?.bool() ?: false,
        )
    }
}
