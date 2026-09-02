package com.matt.murmur.android.logic

import java.io.File
import java.util.UUID

data class Snippet(
    val id: String = UUID.randomUUID().toString(),
    val trigger: String,
    val expansion: String,
)

/** Trigger → expansion. Optional [file] is snippets.json. */
class SnippetsStore(
    initial: List<Snippet> = emptyList(),
    private val file: File? = null,
) {

    private val snippetsMut: MutableList<Snippet> = mutableListOf()
    private var triggerRegexCache: Map<String, Regex> = emptyMap()

    val snippets: List<Snippet>
        get() = snippetsMut.toList()

    init {
        if (file != null) {
            snippetsMut.addAll(SnippetsJson.read(file))
        } else {
            snippetsMut.addAll(initial)
        }
        rebuildRegexCache()
    }

    fun reload() {
        val f = file ?: return
        snippetsMut.clear()
        snippetsMut.addAll(SnippetsJson.read(f))
        rebuildRegexCache()
    }

    fun add(trigger: String, expansion: String) {
        val cleanTrigger = trigger.trim()
        val cleanExpansion = expansion.trim()
        if (cleanTrigger.isEmpty() || cleanExpansion.isEmpty()) return
        snippetsMut.add(Snippet(trigger = cleanTrigger, expansion = cleanExpansion))
        rebuildRegexCache()
        persist()
    }

    fun update(snippet: Snippet) {
        val cleanTrigger = snippet.trigger.trim()
        val cleanExpansion = snippet.expansion.trim()
        if (cleanTrigger.isEmpty() || cleanExpansion.isEmpty()) return
        val idx = snippetsMut.indexOfFirst { it.id == snippet.id }
        if (idx < 0) return
        snippetsMut[idx] = snippet.copy(trigger = cleanTrigger, expansion = cleanExpansion)
        rebuildRegexCache()
        persist()
    }

    fun delete(snippet: Snippet) {
        val removed = snippetsMut.removeAll { it.id == snippet.id }
        if (!removed) return
        rebuildRegexCache()
        persist()
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

    fun flush() = persist()

    private fun persist() {
        val f = file ?: return
        AtomicJson.write(f, SnippetsJson.encode(snippetsMut))
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

internal object SnippetsJson {
    fun read(file: File): List<Snippet> {
        val text = AtomicJson.read(file) ?: return emptyList()
        return try {
            decode(parseJson(text))
        } catch (_: Exception) {
            AtomicJson.quarantine(file)
            emptyList()
        }
    }

    fun encode(snippets: List<Snippet>): String {
        return jsonArray(
            snippets.map { snippet ->
                jsonObject(
                    listOf(
                        "id" to jsonString(snippet.id),
                        "trigger" to jsonString(snippet.trigger),
                        "expansion" to jsonString(snippet.expansion),
                    ),
                )
            },
        )
    }

    fun decode(value: JsonVal): List<Snippet> {
        val arr = value.arr() ?: throw IllegalArgumentException("snippets.json must be an array")
        return arr.map { item ->
            val obj = item.obj() ?: throw IllegalArgumentException("snippet")
            Snippet(
                id = obj["id"]?.str() ?: throw IllegalArgumentException("id"),
                trigger = obj["trigger"]?.str() ?: throw IllegalArgumentException("trigger"),
                expansion = obj["expansion"]?.str() ?: throw IllegalArgumentException("expansion"),
            )
        }
    }
}
