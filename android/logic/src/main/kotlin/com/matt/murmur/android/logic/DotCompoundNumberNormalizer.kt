package com.matt.murmur.android.logic

/** Spoken number words glued to a dot-compound token (`flux.one` → `flux.1`). */
object DotCompoundNumberNormalizer {

    private val digitByWord = mapOf(
        "zero" to "0",
        "one" to "1",
        "two" to "2",
        "three" to "3",
        "four" to "4",
        "five" to "5",
        "six" to "6",
        "seven" to "7",
        "eight" to "8",
        "nine" to "9",
    )

    private val pattern = Regex(
        """(\w+)\.(zero|one|two|three|four|five|six|seven|eight|nine)\b""",
        RegexOption.IGNORE_CASE,
    )

    fun apply(text: String): String {
        var result = text
        for (match in pattern.findAll(result).toList().reversed()) {
            if (match.groupValues.size < 3) continue
            val stem = match.groupValues[1]
            val word = match.groupValues[2].lowercase()
            val digit = digitByWord[word] ?: continue
            result = result.replaceRange(match.range, "$stem.$digit")
        }
        return result
    }
}
