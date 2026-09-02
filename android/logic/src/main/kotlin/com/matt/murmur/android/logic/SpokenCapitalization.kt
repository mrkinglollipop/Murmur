package com.matt.murmur.android.logic

/**
 * Spoken capitalization. Identity when no command applies (commas, newlines,
 * spacing preserved). Commas in command phrases are treated as whitespace only
 * while parsing those phrases.
 */
object SpokenCapitalization {

    private val commandVerbs = setOf("capital", "caps", "uppercase")

    private val natoLetters = mapOf(
        "alpha" to 'A', "bravo" to 'B', "charlie" to 'C', "delta" to 'D',
        "echo" to 'E', "foxtrot" to 'F', "golf" to 'G', "hotel" to 'H',
        "india" to 'I', "juliet" to 'J', "kilo" to 'K', "lima" to 'L',
        "mike" to 'M', "november" to 'N', "oscar" to 'O', "papa" to 'P',
        "quebec" to 'Q', "romeo" to 'R', "sierra" to 'S', "tango" to 'T',
        "uniform" to 'U', "victor" to 'V', "whiskey" to 'W', "xray" to 'X',
        "yankee" to 'Y', "zulu" to 'Z',
    )

    private data class Token(
        var text: String,
        var usedAsTarget: Boolean = false,
        var isCommand: Boolean = false,
    )

    fun apply(text: String): String {
        val raw = tokenize(text)
        if (raw.isEmpty()) return text

        val tokens = raw.map { Token(it) }
        var salvagedTrailingPunctuation = ""

        val commands = mutableListOf<Pair<Int, Int>>()
        var i = 0
        while (i + 1 < tokens.size) {
            if (isCommandVerb(tokens[i].text) && letterFromCommandWord(tokens[i + 1].text) != null) {
                commands.add(i to (i + 1))
                i += 2
            } else {
                i += 1
            }
        }

        for ((verb, letter) in commands.asReversed()) {
            val targetLetter = letterFromCommandWord(tokens[letter].text) ?: continue
            val targetIndex = findTarget(tokens, before = verb, letter = targetLetter) ?: continue
            tokens[targetIndex].text = capitalize(tokens[targetIndex].text, targetLetter)
            tokens[targetIndex].usedAsTarget = true
            tokens[verb].isCommand = true
            tokens[letter].isCommand = true
            val peeled = peelEdgePunctuation(tokens[letter].text)
            salvagedTrailingPunctuation = peeled.trailing + salvagedTrailingPunctuation
        }

        if (tokens.none { it.isCommand }) return text

        var result = tokens.filter { !it.isCommand }.joinToString(" ") { it.text }
        if (salvagedTrailingPunctuation.isNotEmpty()) {
            result += salvagedTrailingPunctuation
        }
        return result
    }

    private fun tokenize(text: String): List<String> =
        text.replace(',', ' ').split(Regex("""\s+""")).filter { it.isNotEmpty() }

    private fun isCommandVerb(word: String): Boolean =
        peelEdgePunctuation(word).core.lowercase() in commandVerbs

    private fun letterFromCommandWord(word: String): Char? {
        val core = peelEdgePunctuation(word).core.lowercase()
        if (core.length == 1) {
            val ch = core.first()
            if (ch.isLetter()) return ch.uppercaseChar()
        }
        return natoLetters[core]
    }

    private data class Peeled(val core: String, val trailing: String)

    private fun peelEdgePunctuation(word: String): Peeled {
        var core = word
        var trailing = ""
        while (core.isNotEmpty() && core.last().isPeelablePunctuation()) {
            trailing = core.last() + trailing
            core = core.dropLast(1)
        }
        while (core.isNotEmpty() && core.first().isPeelablePunctuation()) {
            core = core.drop(1)
        }
        return Peeled(core, trailing)
    }

    private fun Char.isPeelablePunctuation(): Boolean {
        val cat = category
        return cat == CharCategory.DASH_PUNCTUATION ||
            cat == CharCategory.START_PUNCTUATION ||
            cat == CharCategory.END_PUNCTUATION ||
            cat == CharCategory.CONNECTOR_PUNCTUATION ||
            cat == CharCategory.OTHER_PUNCTUATION ||
            cat == CharCategory.INITIAL_QUOTE_PUNCTUATION ||
            cat == CharCategory.FINAL_QUOTE_PUNCTUATION ||
            cat == CharCategory.MATH_SYMBOL ||
            cat == CharCategory.CURRENCY_SYMBOL ||
            cat == CharCategory.MODIFIER_SYMBOL ||
            cat == CharCategory.OTHER_SYMBOL
    }

    private fun findTarget(tokens: List<Token>, before: Int, letter: Char): Int? {
        val needle = letter.lowercaseChar()

        for (index in (before - 1) downTo 0) {
            val token = tokens[index]
            if (!token.usedAsTarget && !token.isCommand) {
                val lower = token.text.lowercase()
                if (lower.length == 1 && lower.first() == needle) return index
            }
        }
        for (index in (before - 1) downTo 0) {
            val token = tokens[index]
            if (!token.usedAsTarget && !token.isCommand) {
                val lower = token.text.lowercase()
                if (lower.isNotEmpty() && lower.first() == needle) return index
            }
        }
        return null
    }

    private fun capitalize(text: String, letter: Char): String {
        if (text.length == 1) return letter.toString()
        val first = text.firstOrNull() ?: return text
        return first.uppercaseChar() + text.drop(1)
    }
}
