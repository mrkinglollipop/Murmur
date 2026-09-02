package com.matt.murmur.android.logic

/**
 * iOS dictation order with Mac spoken punctuation inside spoken-passes:
 * caps → SpokenPunctuation(codeAware) → numbers → dictionary → style → snippets.
 * Android `codeAware` defaults on so identifier joiners run.
 */
object TranscriptPipeline {

    const val DEFAULT_CODE_AWARE = true

    fun applySpokenPasses(text: String, codeAware: Boolean = DEFAULT_CODE_AWARE): String {
        val capped = SpokenCapitalization.apply(text)
        val punctuated = SpokenPunctuation.apply(capped, codeAware)
        return DotCompoundNumberNormalizer.apply(punctuated)
    }

    fun apply(
        text: String,
        codeAware: Boolean = DEFAULT_CODE_AWARE,
        dictionary: DictionaryStore = DictionaryStore(),
        style: StyleProfile = StyleProfile.CASUAL,
        snippets: SnippetsStore = SnippetsStore(),
    ): String {
        val spoken = applySpokenPasses(text, codeAware)
        val corrected = dictionary.correct(spoken)
        val styled = StyleFormatter.apply(
            corrected,
            style,
            preserveTerms = dictionary.entries.map { it.term },
        )
        return snippets.expand(styled)
    }
}
