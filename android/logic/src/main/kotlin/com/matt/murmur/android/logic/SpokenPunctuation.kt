package com.matt.murmur.android.logic

/**
 * Deterministic spoken→symbol pass. `period` is a word joiner (`foo period bar` →
 * `foo.bar`), not a trailing sentence command. Sentence-end commands are only
 * `exclamation point` / `exclamation mark` / `question mark`.
 */
object SpokenPunctuation {

    private data class WordJoiner(
        val spokenPattern: String,
        val separator: String,
        val minWordLength: Int,
    )

    private val wordJoiners = listOf(
        WordJoiner("""underscore|under\s+score""", "_", minWordLength = 1),
        WordJoiner("""dot|period""", ".", minWordLength = 1),
        WordJoiner("""forward\s+slash""", "/", minWordLength = 3),
        WordJoiner("""back\s+slash""", "\\", minWordLength = 3),
        WordJoiner("colon", ":", minWordLength = 2),
    )

    private val phraseReplacements = listOf(
        "less than or equal to" to "<=",
        "greater than or equal to" to ">=",
        "less than or equal" to "<=",
        "greater than or equal" to ">=",
        "not equal to" to "!=",
        "not equals" to "!=",
        "triple equals" to "===",
        "equals equals" to "==",
        "plus equals" to "+=",
        "minus equals" to "-=",
        "star equals" to "*=",
        "fat arrow" to "=>",
        "thin arrow" to "->",
        "double underscore" to "__",
        "double colon" to "::",
        "open parenthesis" to "(",
        "close parenthesis" to ")",
        "closing parenthesis" to ")",
        "left parenthesis" to "(",
        "right parenthesis" to ")",
        "open square bracket" to "[",
        "close square bracket" to "]",
        "open curly brace" to "{",
        "close curly brace" to "}",
        "open curly bracket" to "{",
        "close curly bracket" to "}",
        "left bracket" to "[",
        "right bracket" to "]",
        "left brace" to "{",
        "right brace" to "}",
        "left paren" to "(",
        "right paren" to ")",
        "open paren" to "(",
        "close paren" to ")",
        "open bracket" to "[",
        "close bracket" to "]",
        "open brace" to "{",
        "close brace" to "}",
        "forward slash" to "/",
        "back slash" to "\\",
        "backslash" to "\\",
        "double quote" to "\"",
        "single quote" to "'",
        "open quote" to "\"",
        "close quote" to "\"",
        "equals sign" to "=",
        "equal sign" to "=",
        "plus sign" to "+",
        "minus sign" to "-",
        "percent sign" to "%",
        "dollar sign" to "$",
        "at sign" to "@",
        "at symbol" to "@",
        "hash sign" to "#",
        "pound sign" to "#",
        "number sign" to "#",
        "ampersand sign" to "&",
        "vertical bar" to "|",
        "pipe symbol" to "|",
        "less than sign" to "<",
        "greater than sign" to ">",
        "grave accent" to "`",
        "semicolon" to ";",
        "colon" to ":",
        "asterisk" to "*",
        "ampersand" to "&",
        "underscore" to "_",
        "backtick" to "`",
        "tilde" to "~",
        "caret" to "^",
        "comma" to ",",
        "star" to "*",
        "pipe" to "|",
        "new line" to "\n",
        "newline" to "\n",
        "tab key" to "\t",
    )

    private val preJoinerPhrases = listOf(
        "double underscore" to "__",
        "double colon" to "::",
    )

    private val sentencePunctuationCommands = listOf(
        "exclamation point" to "!",
        "exclamation mark" to "!",
        "question mark" to "?",
    )

    private val spacedFileExtensions = setOf(
        "md", "mdc", "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "py", "go", "rs", "rb", "sh", "zsh", "bash",
        "swift", "json", "yaml", "yml", "toml", "xml", "plist",
        "css", "scss", "html", "htm", "txt", "pdf", "csv", "sql",
        "kt", "kts", "java", "c", "h", "hpp", "cc", "cpp", "mm",
        "dart", "vue", "svelte", "wasm", "proto",
    )

    private val compiledWordJoiners: List<Pair<Regex, String>> by lazy {
        wordJoiners.mapNotNull { joiner ->
            val word = if (joiner.minWordLength <= 1) {
                """\w+"""
            } else {
                """\w{${joiner.minWordLength},}"""
            }
            val pattern = """($word)\s+(?:${joiner.spokenPattern})\s+($word)"""
            runCatching { Regex(pattern, RegexOption.IGNORE_CASE) }.getOrNull()?.let { it to joiner.separator }
        }
    }

    private val compiledPhrasePatterns: Map<String, Regex> by lazy {
        val spoken = (phraseReplacements + preJoinerPhrases).map { it.first }.toSet()
        spoken.mapNotNull { phrase ->
            val pattern = """\b${Regex.escape(phrase)}\b"""
            runCatching { Regex(pattern, RegexOption.IGNORE_CASE) }.getOrNull()?.let { phrase to it }
        }.toMap()
    }

    fun apply(text: String, codeAware: Boolean = true): String {
        var result = text
        if (codeAware) {
            result = applyPhraseReplacements(result, preJoinerPhrases)
            result = applyWordJoiners(result)
            result = collapseSpacedFileExtensions(result)
            result = lowercaseKnownFileExtensions(result)
            val preJoinerSpoken = preJoinerPhrases.map { it.first }.toSet()
            val postJoiner = phraseReplacements
                .filter { it.first !in preJoinerSpoken }
                .sortedByDescending { it.first.length }
            result = applyPhraseReplacements(result, postJoiner)
        }
        return applyPunctuationCommands(result, allowMidSentence = codeAware)
    }

    private fun applyPunctuationCommands(text: String, allowMidSentence: Boolean): String {
        var result = text
        val commands = sentencePunctuationCommands.sortedByDescending { it.first.length }
        for ((spoken, symbol) in commands) {
            result = replacePunctuationCommand(result, spoken, symbol, allowMidSentence)
        }
        return result
    }

    private fun replacePunctuationCommand(
        text: String,
        spoken: String,
        symbol: String,
        allowMidSentence: Boolean,
    ): String {
        val regex = runCatching {
            Regex("""\b${Regex.escape(spoken)}\b""", RegexOption.IGNORE_CASE)
        }.getOrNull() ?: return text
        var result = text
        while (true) {
            val matches = regex.findAll(result).toList()
            var didReplace = false
            for (match in matches.reversed()) {
                val prefix = result.substring(0, match.range.first)
                val suffix = result.substring(match.range.last + 1)
                if (isPunctuationMention(prefix)) continue
                val terminal = isSentenceTerminal(suffix)
                if (!allowMidSentence && !terminal) continue
                result = if (terminal) {
                    gluePrefix(prefix) + symbol + droppingCommandPeriod(suffix)
                } else {
                    result.replaceRange(match.range, symbol)
                }
                didReplace = true
                break
            }
            if (!didReplace) break
        }
        return result
    }

    private val mentionRegex = Regex("""\b(a|an|the)\s+\z""", RegexOption.IGNORE_CASE)

    private fun isPunctuationMention(prefix: String): Boolean =
        mentionRegex.containsMatchIn(prefix)

    private fun isSentenceTerminal(suffix: String): Boolean {
        val trimmed = suffix.trim()
        if (trimmed.isEmpty()) return true
        if (!trimmed.startsWith(".")) return false
        val rest = trimmed.drop(1).trim()
        if (rest.isEmpty()) return true
        val first = rest.first()
        return first.isUpperCase() || first.isNewlineChar()
    }

    private val trailingComma = Regex(""",\s*\z""")
    private val trailingSpaceTab = Regex("""[ \t]+\z""")
    private val leadingCommandPeriod = Regex("""^\s*\.""")

    private fun gluePrefix(prefix: String): String {
        trailingComma.find(prefix)?.let { return prefix.substring(0, it.range.first) }
        trailingSpaceTab.find(prefix)?.let { return prefix.substring(0, it.range.first) }
        return prefix
    }

    private fun droppingCommandPeriod(suffix: String): String {
        val match = leadingCommandPeriod.find(suffix) ?: return suffix
        return suffix.removeRange(match.range)
    }

    internal fun collapseSpacedFileExtensions(text: String): String {
        val regex = runCatching {
            Regex("""(\w+)\.([A-Za-z](?:\s+[A-Za-z]){1,4})(?!\w)""")
        }.getOrNull() ?: return text
        var result = text
        for (match in regex.findAll(result).toList().reversed()) {
            if (match.groupValues.size < 3) continue
            val stem = match.groupValues[1]
            val letters = match.groupValues[2].filter { it.isLetter() }.lowercase()
            if (letters.length < 2 || letters !in spacedFileExtensions) continue
            result = result.replaceRange(match.range, "$stem.$letters")
        }
        return result
    }

    internal fun lowercaseKnownFileExtensions(text: String): String {
        val alts = spacedFileExtensions.sortedByDescending { it.length }
            .joinToString("|") { Regex.escape(it) }
        val regex = runCatching {
            Regex("""(\w+)\.($alts)\b""", RegexOption.IGNORE_CASE)
        }.getOrNull() ?: return text
        var result = text
        for (match in regex.findAll(result).toList().reversed()) {
            if (match.groupValues.size < 3) continue
            val stem = match.groupValues[1]
            val ext = match.groupValues[2].lowercase()
            result = result.replaceRange(match.range, "$stem.$ext")
        }
        return result
    }

    private fun applyWordJoiners(text: String): String {
        var result = text
        for ((regex, separator) in compiledWordJoiners) {
            while (true) {
                val replaced = regex.replace(result) { match ->
                    match.groupValues[1] + separator + match.groupValues[2]
                }
                if (replaced == result) break
                result = replaced
            }
        }
        return result
    }

    private fun applyPhraseReplacements(text: String, phrases: List<Pair<String, String>>): String {
        var result = text
        for ((spoken, symbol) in phrases) {
            val regex = compiledPhrasePatterns[spoken] ?: continue
            result = regex.replace(result, Regex.escapeReplacement(symbol))
        }
        return result
    }

    private fun Char.isNewlineChar(): Boolean =
        this == '\n' || this == '\r' || this == '\u2028' || this == '\u2029'
}
