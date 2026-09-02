package com.matt.murmur.android.crypto

import android.content.Context
import com.matt.murmur.android.logic.ApiKeyStore
import java.io.File

object MurmurSecrets {
    fun apiKeyStore(context: Context): ApiKeyStore {
        val dir = File(context.filesDir, "murmur")
        return ApiKeyStore(
            murmurDir = dir,
            alias = ApiKeyStore.PRODUCTION_ALIAS,
            key = AndroidKeystoreAes.getOrCreate(ApiKeyStore.PRODUCTION_ALIAS),
        )
    }
}
