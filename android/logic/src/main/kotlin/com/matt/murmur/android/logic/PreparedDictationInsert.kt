package com.matt.murmur.android.logic

private const val OPENERS = "([{\"'“‘"

fun needsLeadingSpace(beforeInput: String): Boolean {
    val last = beforeInput.lastOrNull() ?: return false
    if (last.isWhitespace()) return false
    return last !in OPENERS
}

/** Join takes without glue. Trailing space so the next take still separates. */
fun preparedDictationInsert(
    transcript: String,
    beforeInput: String,
    trailingSpace: Boolean = true,
): String {
    val text = transcript.trim()
    if (text.isEmpty()) return ""
    var output = text
    if (needsLeadingSpace(beforeInput)) {
        output = " $output"
    }
    if (trailingSpace && output.lastOrNull()?.isWhitespace() != true) {
        output += " "
    }
    return output
}

/** Word-boundary chunks so hosts that highlight the last insert cap at one run. */
fun bulkInsertChunks(text: String, targetLength: Int = 48): List<String> {
    if (text.isEmpty()) return emptyList()
    if (text.length <= targetLength) return listOf(text)
    val chunks = mutableListOf<String>()
    val current = StringBuilder()
    for (character in text) {
        current.append(character)
        if (current.length >= targetLength && character == ' ') {
            chunks += current.toString()
            current.clear()
        }
    }
    if (current.isNotEmpty()) chunks += current.toString()
    return chunks
}
