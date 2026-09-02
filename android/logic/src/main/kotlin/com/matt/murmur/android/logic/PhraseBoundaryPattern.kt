package com.matt.murmur.android.logic

/**
 * Whole-phrase match shared by dictionary variants and snippet triggers.
 * `\b` silently fails for phrases that start or end with a non-word character.
 */
object PhraseBoundaryPattern {

    fun wholePhrase(phrase: String): String =
        """(?<!\w)${Regex.escape(phrase)}(?!\w)"""

    fun hasWordCharacterEdges(phrase: String): Boolean {
        val first = phrase.firstOrNull() ?: return false
        val last = phrase.lastOrNull() ?: return false
        return isWordCharacter(first) && isWordCharacter(last)
    }

    private fun isWordCharacter(character: Char): Boolean =
        character.isLetter() || character.isDigit() || character == '_'
}
