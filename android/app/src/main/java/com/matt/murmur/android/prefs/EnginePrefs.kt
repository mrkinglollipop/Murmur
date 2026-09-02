package com.matt.murmur.android.prefs

import android.content.Context
import com.matt.murmur.android.logic.CloudEngine

object EnginePrefs {
    private const val PREFS = "murmur"
    private const val ENGINE = "selectedCloudEngine"
    private const val GEMINI_LIVE_FAILED = "geminiLiveHandshakeFailed"

    fun engine(context: Context): CloudEngine {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(ENGINE, null)
        return CloudEngine.fromRaw(raw)
    }

    fun setEngine(context: Context, engine: CloudEngine) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(ENGINE, engine.raw)
            .apply()
        if (engine != CloudEngine.GEMINI) {
            setGeminiLiveHandshakeFailed(context, false)
        }
    }

    fun geminiLiveHandshakeFailed(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(GEMINI_LIVE_FAILED, false)
    }

    fun setGeminiLiveHandshakeFailed(context: Context, failed: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(GEMINI_LIVE_FAILED, failed)
            .apply()
    }
}
