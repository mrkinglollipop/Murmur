package com.matt.murmur.android.crypto

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.matt.murmur.android.logic.ApiKeyStore
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** AES-256 wrapping key in Android Keystore. Envelope crypto lives in [ApiKeyStore]. */
object AndroidKeystoreAes {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"

    fun getOrCreate(alias: String): SecretKey {
        require(alias == ApiKeyStore.PRODUCTION_ALIAS || alias == ApiKeyStore.TEST_ALIAS) {
            "alias must be production or TESTS throwaway"
        }
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        gen.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return gen.generateKey()
    }
}
