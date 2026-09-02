package com.matt.murmur.android.logic

/** Wispr-style formatting: capitalization, punctuation, spacing. Not an LLM rewrite. */
object StyleFormatter {

    const val CASUAL_SHORT_SENTENCE_LIMIT = 2

    fun apply(
        text: String,
        profile: StyleProfile,
        preserveTerms: List<String> = emptyList(),
    ): String {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return text

        return when (profile) {
            StyleProfile.FORMAL ->
                ensureTrailingPeriod(sentenceCase(trimmed, preserveTerms))
            StyleProfile.CASUAL -> {
                val capped = sentenceCase(trimmed, preserveTerms)
                if (sentenceCount(capped) <= CASUAL_SHORT_SENTENCE_LIMIT) {
                    stripTrailingPeriod(capped)
                } else {
                    capped
                }
            }
            StyleProfile.VERY_CASUAL ->
                stripTrailingPeriod(lowercasePreserving(trimmed, preserveTerms))
        }
    }

    fun sentenceCase(text: String, preserveTerms: List<String>): String {
        val restored = restoreTerms(text, preserveTerms)
        val output = StringBuilder()
        var capitalizeNext = true
        for (character in restored) {
            if (character.isNewlineChar()) {
                output.append(character)
                capitalizeNext = true
                continue
            }
            if (capitalizeNext && character.isLetter()) {
                output.append(character.uppercaseChar())
                capitalizeNext = false
                continue
            }
            output.append(character)
            capitalizeNext = when {
                character == '.' || character == '!' || character == '?' -> true
                !character.isWhitespace() -> false
                else -> capitalizeNext
            }
        }
        return restoreTerms(output.toString(), preserveTerms)
    }

    fun lowercasePreserving(text: String, preserveTerms: List<String>): String =
        restoreTerms(text.lowercase(), preserveTerms)

    fun stripTrailingPeriod(text: String): String {
        var result = text
        while (result.endsWith(".")) {
            result = result.dropLast(1).trim { it == ' ' || it == '\t' }
        }
        return result
    }

    fun ensureTrailingPeriod(text: String): String {
        val trimmed = text.trim()
        val last = trimmed.lastOrNull() ?: return text
        if (last == '.' || last == '!' || last == '?') return trimmed
        return "$trimmed."
    }

    fun sentenceCount(text: String): Int {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return 0
        val chunks = trimmed.split(Regex("""[.!?]""")).filter {
            it.trim().isNotEmpty()
        }
        return maxOf(chunks.size, 1)
    }

    private fun restoreTerms(text: String, preserveTerms: List<String>): String {
        var result = text
        val longestFirst = preserveTerms
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .sortedByDescending { it.length }
        for (term in longestFirst) {
            val regex = runCatching {
                Regex(PhraseBoundaryPattern.wholePhrase(term), RegexOption.IGNORE_CASE)
            }.getOrNull() ?: continue
            result = regex.replace(result, Regex.escapeReplacement(term))
        }
        return result
    }

    private fun Char.isNewlineChar(): Boolean =
        this == '\n' || this == '\r' || this == '\u2028' || this == '\u2029'
}
