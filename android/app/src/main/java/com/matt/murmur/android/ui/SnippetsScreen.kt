package com.matt.murmur.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.logic.Snippet

@Composable
fun SnippetsScreen(state: CompanionState) {
    var editor by remember { mutableStateOf<Snippet?>(null) }
    var adding by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<Snippet?>(null) }

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(top = 8.dp, bottom = 88.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            if (!state.snippetsIntroDismissed) {
                introCard(
                    onDismiss = { state.dismissSnippetsIntro() },
                    onAdd = { adding = true },
                )
            }
            listCard(
                snippets = state.snippets,
                onEdit = { editor = it },
                onDelete = { pendingDelete = it },
            )
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(22.dp)
                .size(56.dp)
                .clip(CircleShape)
                .background(MurmurTokens.coral)
                .clickable { adding = true },
            contentAlignment = Alignment.Center,
        ) {
            Text("+", color = MurmurTokens.textPrimary, fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
        }
    }

    if (adding || editor != null) {
        SnippetEditorDialog(
            snippet = editor,
            onDismiss = {
                adding = false
                editor = null
            },
            onSave = { trigger, expansion ->
                val current = editor
                if (current != null) {
                    state.updateSnippet(current.copy(trigger = trigger, expansion = expansion))
                } else {
                    state.addSnippet(trigger, expansion)
                }
                adding = false
                editor = null
            },
        )
    }

    pendingDelete?.let { snippet ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete snippet?") },
            confirmButton = {
                TextButton(onClick = {
                    state.deleteSnippet(snippet)
                    pendingDelete = null
                }) { Text("Delete", color = MurmurTokens.coral) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun introCard(onDismiss: () -> Unit, onAdd: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MurmurTokens.hero, RoundedCornerShape(MurmurTokens.cardRadius.dp))
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                "The stuff you shouldn't have to re-type",
                color = MurmurTokens.textPrimary,
                fontSize = 24.sp,
                fontFamily = FontFamily.Serif,
                modifier = Modifier.weight(1f),
            )
            Text(
                "✕",
                color = MurmurTokens.textSecondary,
                modifier = Modifier
                    .clickable(onClick = onDismiss)
                    .padding(8.dp),
            )
        }
        Text(
            "Speak the trigger, get the expansion — emails, links, addresses, bios.",
            color = MurmurTokens.textSecondary,
            fontSize = 15.sp,
        )
        Button(
            onClick = onAdd,
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Add new snippet")
        }
    }
}

@Composable
private fun listCard(
    snippets: List<Snippet>,
    onEdit: (Snippet) -> Unit,
    onDelete: (Snippet) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            "Your snippets (${snippets.size})",
            color = MurmurTokens.textSecondary,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
        )
        if (snippets.isEmpty()) {
            Text(
                "No snippets yet.",
                color = MurmurTokens.textSecondary,
                fontSize = 15.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MurmurTokens.card, RoundedCornerShape(MurmurTokens.cardRadius.dp))
                    .padding(18.dp),
            )
        } else {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MurmurTokens.card, RoundedCornerShape(MurmurTokens.cardRadius.dp)),
            ) {
                snippets.forEachIndexed { index, snippet ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onEdit(snippet) }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                    ) {
                        Text(snippet.trigger, color = MurmurTokens.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(4.dp))
                        Text(snippet.expansion, color = MurmurTokens.textSecondary, fontSize = 14.sp, maxLines = 2)
                        Text(
                            "Delete",
                            color = MurmurTokens.coral,
                            fontSize = 13.sp,
                            modifier = Modifier
                                .padding(top = 8.dp)
                                .clickable { onDelete(snippet) },
                        )
                    }
                    if (index < snippets.lastIndex) {
                        Spacer(
                            Modifier
                                .fillMaxWidth()
                                .padding(start = 16.dp)
                                .height(1.dp)
                                .background(MurmurTokens.hairline),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SnippetEditorDialog(
    snippet: Snippet?,
    onDismiss: () -> Unit,
    onSave: (String, String) -> Unit,
) {
    var trigger by remember { mutableStateOf(snippet?.trigger.orEmpty()) }
    var expansion by remember { mutableStateOf(snippet?.expansion.orEmpty()) }
    val colors = OutlinedTextFieldDefaults.colors(
        focusedBorderColor = MurmurTokens.coral,
        cursorColor = MurmurTokens.coralLight,
        focusedTextColor = MurmurTokens.textPrimary,
        unfocusedTextColor = MurmurTokens.textPrimary,
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (snippet == null) "Add snippet" else "Edit snippet") },
        text = {
            Column {
                OutlinedTextField(
                    value = trigger,
                    onValueChange = { trigger = it },
                    label = { Text("Trigger phrase — e.g. my email address") },
                    colors = colors,
                    singleLine = true,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = expansion,
                    onValueChange = { expansion = it },
                    label = { Text("Expands to…") },
                    colors = colors,
                    minLines = 3,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(trigger, expansion) },
                enabled = trigger.trim().isNotEmpty() && expansion.trim().isNotEmpty(),
            ) { Text("Save", color = MurmurTokens.coral) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
