package com.matt.murmur.android.logic

import java.util.UUID

data class Snippet(
    val id: String = UUID.randomUUID().toString(),
    val trigger: String,
    val expansion: String,
)

/** Trigger → expansion. Persistence is a later PR. */
class SnippetsStore(initial: List<Snippet> = emptyList()) {

    private val snippetsMut: MutableList<Snippet> = initial.toMutableList()
    private var triggerRegexCache: Map<String, Regex> = emptyMap()

    val snippets: List<Snippet>
        get() = snippetsMut.toList()

    init {
        rebuildRegexCache()
    }

    fun add(trigger: String, expansion: String) {
        val cleanTrigger = trigger.trim()
        val cleanExpansion = expansion.trim()
        if (cleanTrigger.isEmpty() || cleanExpansion.isEmpty()) return
        snippetsMut.add(Snippet(trigger = cleanTrigger, expansion = cleanExpansion))
        rebuildRegexCache()
    }

    fun expand(text: String): String {
        if (snippetsMut.isEmpty()) return text
        var result = text
        val longestFirst = snippetsMut.sortedByDescending { it.trigger.length }
        for (snippet in longestFirst) {
            val trigger = snippet.trigger.trim()
            if (trigger.isEmpty()) continue
            val regex = triggerRegexCache[trigger] ?: continue
            result = regex.replace(result, Regex.escapeReplacement(snippet.expansion))
        }
        return result
    }

    private fun rebuildRegexCache() {
        val cache = mutableMapOf<String, Regex>()
        for (snippet in snippetsMut) {
            val trigger = snippet.trigger.trim()
            if (trigger.isEmpty()) continue
            runCatching {
                Regex(PhraseBoundaryPattern.wholePhrase(trigger), RegexOption.IGNORE_CASE)
            }.getOrNull()?.let { cache[trigger] = it }
        }
        triggerRegexCache = cache
    }
}
