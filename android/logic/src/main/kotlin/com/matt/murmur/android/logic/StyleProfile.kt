package com.matt.murmur.android.logic

/** iOS local caps/punct profiles. Raw values match `style.json`; not Mac LLM copy. */
enum class StyleProfile(val rawValue: String) {
    FORMAL("formal"),
    CASUAL("casual"),
    VERY_CASUAL("very_casual");

    companion object {
        fun fromRawValue(raw: String): StyleProfile? =
            entries.firstOrNull { it.rawValue == raw }
    }
}
