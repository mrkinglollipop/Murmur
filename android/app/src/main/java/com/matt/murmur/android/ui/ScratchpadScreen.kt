package com.matt.murmur.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.capture.MicCapture
import com.matt.murmur.android.crypto.MurmurSecrets
import com.matt.murmur.android.logic.WavWriter
import com.matt.murmur.android.pipeline.DictationProcess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Composable
fun ScratchpadScreen(state: CompanionState) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var scratch by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val colors = OutlinedTextFieldDefaults.colors(
        focusedBorderColor = MurmurTokens.coral,
        cursorColor = MurmurTokens.coralLight,
        focusedTextColor = MurmurTokens.textPrimary,
        unfocusedTextColor = MurmurTokens.textPrimary,
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Scratchpad", color = MurmurTokens.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "Try the Murmur keyboard here, or copy text out. Record 3s uses the same dictation pipeline as the keyboard.",
            color = MurmurTokens.textSecondary,
            fontSize = 15.sp,
        )
        OutlinedTextField(
            value = scratch,
            onValueChange = { scratch = it },
            modifier = Modifier
                .fillMaxWidth()
                .height(180.dp),
            placeholder = { Text("Type or dictate…", color = MurmurTokens.textSecondary) },
            colors = colors,
        )
        Button(
            onClick = {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("Murmur", scratch))
                status = "Copied"
            },
            enabled = scratch.isNotBlank(),
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(20.dp),
        ) { Text("Copy") }
        Button(
            onClick = {
                if (!state.micGranted) {
                    status = "Allow microphone in Settings"
                    return@Button
                }
                if (busy) return@Button
                busy = true
                status = "Recording 3s…"
                scope.launch {
                    status = try {
                        withContext(Dispatchers.IO) {
                            val pcm = MicCapture(context).record(3_000L)
                            val wav = File.createTempFile("murmur-", ".wav", context.cacheDir)
                            try {
                                WavWriter.writePcm16(pcm, wav)
                                val key = MurmurSecrets.apiKeyStore(context).elevenLabsKey()
                                    ?: throw IllegalStateException("no-key")
                                DictationProcess.transcribeWav(context, wav, key)
                            } finally {
                                wav.delete()
                            }
                        }
                    } catch (e: IllegalStateException) {
                        if (e.message == "no-key") "Paste and save an ElevenLabs key" else "Mic capture failed"
                    } catch (_: SecurityException) {
                        "Allow microphone in Murmur"
                    } catch (_: Exception) {
                        "Transcribe failed"
                    }
                    if (status.isNotEmpty() && !status.contains("failed", ignoreCase = true) &&
                        status != "Paste and save an ElevenLabs key" &&
                        status != "Allow microphone in Murmur" &&
                        status != "Mic capture failed"
                    ) {
                        scratch = if (scratch.isBlank()) status else "$scratch $status"
                        state.reload()
                    }
                    busy = false
                }
            },
            enabled = !busy,
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(20.dp),
        ) { Text("Record 3s and transcribe") }
        if (status.isNotEmpty()) {
            Text(status, color = MurmurTokens.textSecondary, fontSize = 14.sp)
        }
    }
}
