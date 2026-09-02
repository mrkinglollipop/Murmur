package com.matt.murmur.android.cloud

internal fun fixture(name: String): String {
    val stream = Fixtures::class.java.classLoader.getResourceAsStream("fixtures/$name")
        ?: error("missing fixture $name")
    return stream.bufferedReader(Charsets.UTF_8).use { it.readText() }
}

private object Fixtures
