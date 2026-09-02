package com.matt.murmur.android.logic

import java.io.File

/** JSON filenames under filesDir/murmur. Same directory as apikeys.bin. */
object MurmurFiles {
    const val DIR_NAME = "murmur"
    const val DICTIONARY = "dictionary.json"
    const val SNIPPETS = "snippets.json"
    const val HISTORY = "history.json"
    const val STYLE = "style.json"
    const val SETTINGS = "settings.json"

    fun dir(filesDir: File): File {
        val dir = File(filesDir, DIR_NAME)
        AtomicJson.ensurePrivateDir(dir)
        return dir
    }

    fun dictionary(filesDir: File) = File(dir(filesDir), DICTIONARY)
    fun snippets(filesDir: File) = File(dir(filesDir), SNIPPETS)
    fun history(filesDir: File) = File(dir(filesDir), HISTORY)
    fun style(filesDir: File) = File(dir(filesDir), STYLE)
    fun settings(filesDir: File) = File(dir(filesDir), SETTINGS)
}
