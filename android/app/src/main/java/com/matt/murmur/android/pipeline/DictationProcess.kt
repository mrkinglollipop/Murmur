package com.matt.murmur.android.pipeline

import android.content.Context
import com.matt.murmur.android.cloud.ElevenLabsBatch
import com.matt.murmur.android.logic.DictionaryStore
import com.matt.murmur.android.logic.MurmurFiles
import com.matt.murmur.android.logic.SettingsStore
import com.matt.murmur.android.logic.SnippetsStore
import com.matt.murmur.android.logic.StyleStore
import com.matt.murmur.android.logic.TranscriptPipeline
import java.io.File

/** Shared batch + iOS pipeline used by the IME take and companion scratchpad. */
object DictationProcess {
    fun transcribeWav(context: Context, wav: File, apiKey: String): String {
        val filesDir = context.filesDir
        val settings = SettingsStore(MurmurFiles.settings(filesDir))
        val dictionary = DictionaryStore(file = MurmurFiles.dictionary(filesDir))
        val snippets = SnippetsStore(file = MurmurFiles.snippets(filesDir))
        val style = StyleStore(MurmurFiles.style(filesDir))
        val keyterms = DictionaryStore.selectKeyterms(dictionary.entries)
        val raw = ElevenLabsBatch.transcribe(
            wav,
            apiKey,
            noVerbatim = settings.removeFillerWords,
            keyterms = keyterms,
        )
        return TranscriptPipeline.apply(
            raw,
            codeAware = settings.codeAware,
            dictionary = dictionary,
            style = style.selected,
            snippets = snippets,
        )
    }
}
