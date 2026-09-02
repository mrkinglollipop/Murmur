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
import com.matt.murmur.android.logic.DictionaryEntry

@Composable
fun DictionaryScreen(state: CompanionState) {
    var editor by remember { mutableStateOf<DictionaryEntry?>(null) }
    var adding by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<DictionaryEntry?>(null) }

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(top = 8.dp, bottom = 88.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            if (!state.dictionaryIntroDismissed) {
                introCard(
                    onDismiss = { state.dismissDictionaryIntro() },
                    onAdd = { adding = true },
                )
            }
            listCard(
                entries = state.dictionaryEntries,
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
        DictionaryEditorDialog(
            entry = editor,
            onDismiss = {
                adding = false
                editor = null
            },
            onSave = { term, variants ->
                val current = editor
                if (current != null) {
                    state.updateDictionary(current.copy(term = term, variants = variants))
                } else {
                    state.addDictionary(term, variants)
                }
                adding = false
                editor = null
            },
        )
    }

    pendingDelete?.let { entry ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete dictionary term?") },
            confirmButton = {
                TextButton(onClick = {
                    state.deleteDictionary(entry)
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
                "Murmur speaks the way you speak",
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
            "Corrections for personal terms and jargon. Add a term and the misheard variants Murmur should fix.",
            color = MurmurTokens.textSecondary,
            fontSize = 15.sp,
        )
        Button(
            onClick = onAdd,
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Add new word")
        }
    }
}

@Composable
private fun listCard(
    entries: List<DictionaryEntry>,
    onEdit: (DictionaryEntry) -> Unit,
    onDelete: (DictionaryEntry) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            "Your words (${entries.size})",
            color = MurmurTokens.textSecondary,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
        )
        if (entries.isEmpty()) {
            Text(
                "No words yet. Add a term and the misheard variants Murmur should fix.",
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
                entries.forEachIndexed { index, entry ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onEdit(entry) }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                    ) {
                        Text(entry.term, color = MurmurTokens.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                        val subtitle = when {
                            entry.variants.isNotEmpty() -> entry.variants.joinToString(", ")
                            entry.isAutoLearned -> "From the keyboard"
                            else -> null
                        }
                        if (subtitle != null) {
                            Spacer(Modifier.height(4.dp))
                            Text(subtitle, color = MurmurTokens.textSecondary, fontSize = 13.sp, maxLines = 1)
                        }
                        Text(
                            "Delete",
                            color = MurmurTokens.coral,
                            fontSize = 13.sp,
                            modifier = Modifier
                                .padding(top = 8.dp)
                                .clickable { onDelete(entry) },
                        )
                    }
                    if (index < entries.lastIndex) {
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
