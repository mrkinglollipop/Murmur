package com.matt.murmur.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.logic.DictionaryEntry

@Composable
fun DictionaryEditorDialog(
    entry: DictionaryEntry?,
    onDismiss: () -> Unit,
    onSave: (String, List<String>) -> Unit,
) {
    var term by remember { mutableStateOf(entry?.term.orEmpty()) }
    var variantsText by remember { mutableStateOf(entry?.variants?.joinToString(", ").orEmpty()) }
    val colors = OutlinedTextFieldDefaults.colors(
        focusedBorderColor = MurmurTokens.coral,
        cursorColor = MurmurTokens.coralLight,
        focusedTextColor = MurmurTokens.textPrimary,
        unfocusedTextColor = MurmurTokens.textPrimary,
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (entry == null) "Add word" else "Edit word") },
        text = {
            Column {
                OutlinedTextField(
                    value = term,
                    onValueChange = { term = it },
                    label = { Text("Correct spelling — e.g. Kubernetes") },
                    colors = colors,
                    singleLine = true,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = variantsText,
                    onValueChange = { variantsText = it },
                    label = { Text("Misheard variants, comma-separated") },
                    colors = colors,
                    minLines = 2,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "When you say a variant, Murmur inserts the correct spelling.",
                    color = MurmurTokens.textSecondary,
                    fontSize = 13.sp,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    val variants = variantsText.split(",")
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                    onSave(term, variants)
                },
                enabled = term.trim().isNotEmpty(),
            ) { Text("Save", color = MurmurTokens.coral) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
