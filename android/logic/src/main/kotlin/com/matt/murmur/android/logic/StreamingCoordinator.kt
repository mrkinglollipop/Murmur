package com.matt.murmur.android.logic

/**
 * Stream finalize vs batch fallback. Silence-cancel floor is [SilenceCancel].
 * Empty finalize must not hammer batch on a tiny hold.
 */
object StreamingCoordinator {
    const val STREAM_MIN_CHARS_PER_SECOND = 2.0
    const val STREAM_TRUNCATION_CHECK_MIN_DURATION = 8.0
    const val LENGTH_MISMATCH_BATCH_MIN_DURATION = 15.0
    const val LENGTH_MISMATCH_MIN_CHAR_GAP = 40
    const val SNAPSHOT_TAIL_RECOVERY_MIN_CHARS = 3

    fun shouldTakeSilenceCancel(
        everHadStreamText: Boolean,
        bufferedSeconds: Double,
    ): Boolean = SilenceCancel.shouldTakeSilenceCancel(everHadStreamText, bufferedSeconds)

    fun streamResultLooksTruncated(text: String, duration: Double): Boolean {
        if (duration < STREAM_TRUNCATION_CHECK_MIN_DURATION) return false
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return false
        return trimmed.length < duration * STREAM_MIN_CHARS_PER_SECOND
    }

    fun snapshotExtendsFinalize(finalize: String, snapshot: String): Boolean {
        val finalTrim = finalize.trim()
        val snapTrim = snapshot.trim()
        if (snapTrim.length <= finalTrim.length || finalTrim.isEmpty()) return false
        if (snapTrim.startsWith(finalTrim)) {
            return snapshotTailIsMeaningful(finalTrim, snapTrim)
        }
        if (snapTrim.lowercase().startsWith(finalTrim.lowercase())) {
            return snapshotTailIsMeaningful(finalTrim, snapTrim)
        }
        return snapshotWordPrefixExtends(finalTrim, snapTrim)
    }

    fun snapshotSupersetContainsFinalize(finalize: String, snapshot: String): Boolean {
        val finalTrim = finalize.trim()
        val snapTrim = snapshot.trim()
        if (snapTrim.length <= finalTrim.length + SNAPSHOT_TAIL_RECOVERY_MIN_CHARS) return false
        if (finalTrim.isEmpty()) return false
        val finalWords = tokenizeForPrefix(finalTrim)
        val snapWords = tokenizeForPrefix(snapTrim)
        if (finalWords.isEmpty()) return false
        val index = findWordSubsequenceIndex(finalWords, snapWords) ?: return false
        if (index == 0 && snapWords.size > finalWords.size) return false
        if (index <= 0) return false
        val head = snapWords.take(index).joinToString(" ")
        if (head.length < SNAPSHOT_TAIL_RECOVERY_MIN_CHARS) return false
        return head.any { it.isLetter() || it.isDigit() }
    }

    fun recoveredTextMergingSnapshot(finalize: String, snapshot: String): String? {
        val finalTrim = finalize.trim()
        val snapTrim = snapshot.trim()
        if (finalTrim.isEmpty() || snapTrim.isEmpty()) return null

        if (snapshotExtendsFinalize(finalize, snapshot)) {
            if (snapTrim.startsWith(finalTrim)) {
                val tail = snapTrim.drop(finalTrim.length).trim()
                if (tail.isEmpty()) return finalTrim
                return appendTail(finalTrim, tail)
            }
            if (snapTrim.lowercase().startsWith(finalTrim.lowercase())) {
                val tail = snapTrim.drop(finalTrim.length).trim()
                if (tail.isEmpty()) return finalTrim
                return appendTail(finalTrim, tail)
            }
            val finalWords = tokenizeForPrefix(finalTrim)
            val snapWords = tokenizeForPrefix(snapTrim)
            if (snapWords.size <= finalWords.size) return null
            if (snapWords.take(finalWords.size) != finalWords) return null
            val tailWords = snapWords.drop(finalWords.size)
            if (tailWords.isEmpty()) return null
            val last = finalTrim.lastOrNull()
            if (last != null && last in ".!?" && tailWords.size < 3) return null
            val tail = snapshotSubstringFromWordIndex(snapTrim, finalWords.size) ?: return null
            if (tail.length < SNAPSHOT_TAIL_RECOVERY_MIN_CHARS) return null
            return appendTail(finalTrim, tail)
        }

        if (snapshotSupersetContainsFinalize(finalize, snapshot)) {
            val finalWords = tokenizeForPrefix(finalTrim)
            val snapWords = tokenizeForPrefix(snapTrim)
            val index = findWordSubsequenceIndex(finalWords, snapWords) ?: return null
            if (index <= 0) return null
            val head = snapshotSubstringBeforeWordIndex(snapTrim, index) ?: return null
            if (head.isEmpty()) return null
            val headEndsSentence = head.lastOrNull()?.let { it in ".!?" } == true
            val sep = if (headEndsSentence) " " else ". "
            return head + sep + finalTrim
        }

        return null
    }

    fun shouldBatchFallbackForLengthMismatch(
        finalize: String,
        snapshot: String,
        duration: Double,
    ): Boolean {
        if (duration < LENGTH_MISMATCH_BATCH_MIN_DURATION) return false
        val finalTrim = finalize.trim()
        val snapTrim = snapshot.trim()
        if (snapTrim.length <= finalTrim.length + LENGTH_MISMATCH_MIN_CHAR_GAP) return false
        return !snapshotExtendsFinalize(finalTrim, snapTrim)
    }

    /**
     * Non-null = use this text. Null = batch fallback.
     * Empty finalize recovers a non-empty snapshot; truncated streams batch
     * unless the snapshot is a meaningful extension that still clears cps.
     */
    fun streamSuccessTextOrBatchFallback(
        finalizeText: String,
        preFinalizeSnapshot: String,
        duration: Double = 0.0,
        truncated: Boolean,
    ): String? {
        val finalTrim = finalizeText.trim()
        val snapTrim = preFinalizeSnapshot.trim()

        if (truncated) {
            if (snapTrim.length > finalTrim.length &&
                snapshotExtendsFinalize(finalizeText, preFinalizeSnapshot) &&
                !streamResultLooksTruncated(preFinalizeSnapshot, duration)
            ) {
                val merged = recoveredTextMergingSnapshot(finalizeText, preFinalizeSnapshot)
                if (merged != null) return merged
            }
            if (finalTrim.isEmpty() && snapTrim.isNotEmpty()) {
                return preFinalizeSnapshot
            }
            return null
        }

        if (finalTrim.isEmpty()) {
            return if (snapTrim.isEmpty()) null else preFinalizeSnapshot
        }

        if (snapTrim.length > finalTrim.length + SNAPSHOT_TAIL_RECOVERY_MIN_CHARS &&
            (
                snapshotExtendsFinalize(finalizeText, preFinalizeSnapshot) ||
                    snapshotSupersetContainsFinalize(finalizeText, preFinalizeSnapshot)
                )
        ) {
            val merged = recoveredTextMergingSnapshot(finalizeText, preFinalizeSnapshot)
            if (merged != null) return merged
        }

        if (shouldBatchFallbackForLengthMismatch(finalTrim, snapTrim, duration)) {
            return null
        }

        return finalizeText
    }

    private fun snapshotTailIsMeaningful(finalTrim: String, snapTrim: String): Boolean {
        val start = minOf(finalTrim.length, snapTrim.length)
        val tail = snapTrim.substring(start).trim()
        if (tail.length < SNAPSHOT_TAIL_RECOVERY_MIN_CHARS) return false
        return tail.any { it.isLetter() || it.isDigit() }
    }

    private fun snapshotWordPrefixExtends(finalTrim: String, snapTrim: String): Boolean {
        val finalWords = tokenizeForPrefix(finalTrim)
        val snapWords = tokenizeForPrefix(snapTrim)
        if (finalWords.isEmpty() || snapWords.size <= finalWords.size) return false
        if (snapWords.take(finalWords.size) != finalWords) return false
        val tailWords = snapWords.drop(finalWords.size)
        val last = finalTrim.lastOrNull()
        if (last != null && last in ".!?" && tailWords.size < 3) return false
        val tail = tailWords.joinToString(" ")
        if (tail.length < SNAPSHOT_TAIL_RECOVERY_MIN_CHARS) return false
        return tail.any { it.isLetter() || it.isDigit() }
    }

    internal fun tokenizeForPrefix(text: String): List<String> {
        return text.split(Regex("\\s+")).mapNotNull { token ->
            val folded = token.trim { it.isTrimmedPunctuation() }.lowercase()
            folded.ifEmpty { null }
        }
    }

    private fun findWordSubsequenceIndex(needle: List<String>, haystack: List<String>): Int? {
        if (needle.isEmpty() || haystack.size < needle.size) return null
        val limit = haystack.size - needle.size
        for (start in 0..limit) {
            if (haystack.subList(start, start + needle.size) == needle) return start
        }
        return null
    }

    private fun appendTail(finalize: String, tail: String): String {
        val tailTrim = tail.trim()
        if (tailTrim.isEmpty()) return finalize
        var tailOut = tailTrim
        val last = finalize.lastOrNull()
        val first = tailOut.firstOrNull()
        if (last != null && last in ".!?" && first != null) {
            tailOut = first.uppercaseChar() + tailOut.drop(1)
        }
        return "$finalize $tailOut"
    }

    private fun wordRanges(text: String): List<IntRange> {
        val ranges = mutableListOf<IntRange>()
        var i = 0
        while (i < text.length) {
            while (i < text.length && text[i].isWhitespace()) i++
            if (i >= text.length) break
            val start = i
            while (i < text.length && !text[i].isWhitespace()) i++
            ranges += start until i
        }
        return ranges
    }

    private fun snapshotSubstringFromWordIndex(snapshot: String, wordIndex: Int): String? {
        val ranges = wordRanges(snapshot)
        if (wordIndex >= ranges.size) return null
        return snapshot.substring(ranges[wordIndex].first).trim()
    }

    private fun snapshotSubstringBeforeWordIndex(snapshot: String, wordIndex: Int): String? {
        val ranges = wordRanges(snapshot)
        if (wordIndex <= 0 || wordIndex > ranges.size) return null
        return snapshot.substring(0, ranges[wordIndex].first).trim()
    }
}

private fun Char.isTrimmedPunctuation(): Boolean {
    val type = Character.getType(this).toByte()
    return type == Character.CONNECTOR_PUNCTUATION ||
        type == Character.DASH_PUNCTUATION ||
        type == Character.START_PUNCTUATION ||
        type == Character.END_PUNCTUATION ||
        type == Character.INITIAL_QUOTE_PUNCTUATION ||
        type == Character.FINAL_QUOTE_PUNCTUATION ||
        type == Character.OTHER_PUNCTUATION
}
