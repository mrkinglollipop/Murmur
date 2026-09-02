package com.matt.murmur.android.logic

import java.util.UUID

data class DictionaryEntry(
    val id: String = UUID.randomUUID().toString(),
    val term: String,
    val variants: List<String> = emptyList(),
    val fixCount: Int = 0,
    val isAutoLearned: Boolean = false,
)

/**
 * Literal whole-word dictionary corrections. Typed variants only (iOS shape);
 * no Mac phonetic / History-learn. Persistence is a later PR.
 */
class DictionaryStore(initial: List<DictionaryEntry> = emptyList()) {

    private val entriesMut: MutableList<DictionaryEntry> =
        mergingDuplicateTerms(initial).toMutableList()
    private var variantRegexCache: Map<String, Regex> = emptyMap()

    val entries: List<DictionaryEntry>
        get() = entriesMut.toList()

    init {
        rebuildRegexCache()
    }

    fun add(term: String, variants: List<String>, isAutoLearned: Boolean = false) {
        val cleanTerm = term.trim()
        if (cleanTerm.isEmpty()) return
        val cleanVariants = variants.map { it.trim() }.filter { it.isNotEmpty() }
        val idx = entriesMut.indexOfFirst { it.term.equals(cleanTerm, ignoreCase = true) }
        if (idx >= 0) {
            val existing = entriesMut[idx]
            val merged = existing.variants.toMutableList()
            var changed = false
            for (variant in cleanVariants) {
                if (merged.none { it.equals(variant, ignoreCase = true) }) {
                    merged.add(variant)
                    changed = true
                }
            }
            var auto = existing.isAutoLearned
            if (!isAutoLearned && existing.isAutoLearned) {
                auto = false
                changed = true
            }
            if (changed) {
                entriesMut[idx] = existing.copy(variants = merged, isAutoLearned = auto)
                rebuildRegexCache()
            }
            return
        }
        entriesMut.add(
            DictionaryEntry(
                term = cleanTerm,
                variants = cleanVariants,
                isAutoLearned = isAutoLearned,
            ),
        )
        rebuildRegexCache()
    }

    fun correct(text: String): String {
        if (entriesMut.isEmpty()) return text
        var result = text
        val fixCounts = mutableMapOf<String, Int>()
        for (entry in entriesMut) {
            for (variant in entry.variants) {
                if (variant.isEmpty()) continue
                val regex = variantRegexCache[variant] ?: continue
                val matches = regex.findAll(result).count()
                if (matches == 0) continue
                result = regex.replace(result, Regex.escapeReplacement(entry.term))
                fixCounts[entry.id] = (fixCounts[entry.id] ?: 0) + matches
            }
        }
        if (fixCounts.isEmpty()) return result
        for ((id, count) in fixCounts) {
            val idx = entriesMut.indexOfFirst { it.id == id }
            if (idx >= 0) {
                val entry = entriesMut[idx]
                entriesMut[idx] = entry.copy(fixCount = entry.fixCount + count)
            }
        }
        return result
    }

    private fun rebuildRegexCache() {
        val cache = mutableMapOf<String, Regex>()
        for (entry in entriesMut) {
            for (variant in entry.variants) {
                if (variant.isEmpty()) continue
                runCatching {
                    Regex(PhraseBoundaryPattern.wholePhrase(variant), RegexOption.IGNORE_CASE)
                }.getOrNull()?.let { cache[variant] = it }
            }
        }
        variantRegexCache = cache
    }

    companion object {
        const val MAX_KEYTERMS = 50
        const val MAX_KEYTERM_LENGTH = 50

        fun mergingDuplicateTerms(entries: List<DictionaryEntry>): List<DictionaryEntry> {
            val result = mutableListOf<DictionaryEntry>()
            val indexByTerm = mutableMapOf<String, Int>()
            for (entry in entries) {
                val key = entry.term.lowercase()
                val idx = indexByTerm[key]
                if (idx != null) {
                    result[idx] = absorbing(entry, into = result[idx])
                } else {
                    indexByTerm[key] = result.size
                    result.add(entry)
                }
            }
            return result
        }

        private fun absorbing(donor: DictionaryEntry, into: DictionaryEntry): DictionaryEntry {
            val variants = into.variants.toMutableList()
            for (variant in donor.variants) {
                if (variants.none { it.equals(variant, ignoreCase = true) }) {
                    variants.add(variant)
                }
            }
            return into.copy(
                variants = variants,
                fixCount = into.fixCount + donor.fixCount,
                isAutoLearned = if (!donor.isAutoLearned) false else into.isAutoLearned,
            )
        }

        fun selectKeyterms(entries: List<DictionaryEntry>): List<String> {
            val seen = mutableSetOf<String>()
            data class Candidate(val term: String, val fixCount: Int, val index: Int)
            val candidates = mutableListOf<Candidate>()
            for ((index, entry) in entries.withIndex()) {
                val term = entry.term.trim()
                if (term.length <= 1) continue
                if (term.toByteArray(Charsets.UTF_8).size > MAX_KEYTERM_LENGTH) continue
                val key = term.lowercase()
                if (!seen.add(key)) continue
                candidates.add(Candidate(term, entry.fixCount, index))
            }
            candidates.sortWith(
                compareByDescending<Candidate> { it.fixCount }
                    .thenByDescending { it.index },
            )
            return candidates.take(MAX_KEYTERMS).map { it.term }
        }
    }
}
