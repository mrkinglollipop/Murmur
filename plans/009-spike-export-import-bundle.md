# Plan 009 (spike): One-file export/import of all learned and configured state

> **Executor instructions**: Design-and-build spike — Step 1's inventory
> drives the schema; if the inventory diverges from the list below, follow
> reality and document. Honor STOP conditions. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/UI/ Sources/Voice/KeychainStore.swift`

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED (an importer writes user data files — corruption risk)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Everything Murmur learns and everything the user configures — auto-learned
dictionary corrections, snippets, transforms, style assignments, settings —
lives only in `~/Library/Application Support/Voice/` and UserDefaults. There
is no way to move it to a second Mac, restore after a reinstall, or back it
up deliberately. History has one-way export (JSON/Markdown) but no import;
every other store has neither. One "export bundle / import bundle" pair
covers backup, migration, and disaster recovery in a single feature, reusing
the `Codable` types every store already has.

## Current state

- Stores persisting JSON under `Application Support/Voice/` (each has
  `load()`/`save()` with `Codable` entry types — confirm the full set):
  `DictionaryStore`, `SnippetsStore`, `TransformsStore`, `ScratchpadStore`,
  `HistoryStore` (all under `Sources/Voice/UI/`). Find their file names:
  `grep -rn "appendingPathComponent" Sources/Voice/UI/*Store.swift`.
- UserDefaults-backed state: `SettingsStore` (engine/model/cleanup/activation
  config — enumerate its `Keys` enum), `StyleStore`
  (`voice.settings.selectedStyle`, `voice.settings.appStyleProfiles`),
  `TransformsStore.autoRunTransformID`.
- Existing export exemplar to follow for UI + file-writing conventions:
  history export — `HistoryStore.swift` (`grep -n "export" Sources/Voice/UI/HistoryStore.swift Sources/Voice/UI/HistoryView.swift`).
- **Explicit exclusions**: API keys (Keychain — `KeychainStore`, service
  `com.matt.voice-dictation.apikeys`) must NEVER enter the bundle; retained
  audio recordings (`Recordings/`) excluded (bulky, low value); downloaded
  ASR models excluded (re-downloadable).

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | `xcodegen generate` | success |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED |

## Scope

**In scope**: a new `Sources/Voice/UI/SettingsBundle.swift` (schema +
exporter + importer), a Settings UI entry point (two buttons in the existing
SettingsView section that best fits), tests, `plans/README.md`.

**Out of scope**: Keychain contents (hard exclusion); history entries
(optional — see Step 1; default OUT to keep bundles small and private);
automatic sync (this is manual export/import only); versioned migration
beyond a single `formatVersion` field.

## Git workflow

- Branch: `feat/settings-bundle`; conventional commits; no push/PR without
  operator instruction.

## Steps

### Step 1 (inventory): Enumerate exactly what's portable

List every store file and UserDefaults key with its Swift type. Decide
in/out per item with one-line rationale (default: all config + learned data
IN; history OUT; secrets/audio/models OUT — hard rule for secrets). Record
the table in the PR description.

### Step 2 (schema): Define the bundle format

Single JSON file, `murmur-settings-bundle.json`:

```json
{
  "formatVersion": 1,
  "exportedAt": "2026-07-09T00:00:00Z",
  "appVersion": "0.1.0",
  "dictionary": [...],
  "snippets": [...],
  "transforms": [...],
  "styles": {"selected": "...", "perApp": {...}},
  "settings": {...}
}
```

Reuse each store's existing `Codable` entry types verbatim — the bundle is a
container, not a new representation. Every top-level key is optional on
import (partial bundles import what they have).

### Step 3: Exporter

`SettingsBundle.export(to url: URL)` gathering from live stores on the main
thread. Wire a "Export Settings…" button with `NSSavePanel` next to wherever
history export lives (match its presentation style).

**Verify**: build green; unit test: export from stores seeded in-memory →
decode the produced JSON → round-trip equality per store.

### Step 4: Importer — the dangerous half

`SettingsBundle.import(from url: URL, mode:)` with `mode` = `.merge`
(default: union, imported entries win on key collision) — do NOT implement
`.replace` in this pass. Rules: validate `formatVersion == 1` first;
decode the ENTIRE bundle before mutating ANY store (all-or-nothing decode);
each store's existing save path persists the merged result. Show a summary
alert ("Imported N dictionary entries, M snippets…").

**Verify**: unit tests — merge into empty stores; merge with collisions
(imported wins); corrupted JSON rejected with NO store mutated (assert
stores unchanged); wrong formatVersion rejected.

### Step 5: Secret-leak guard test

A unit test asserting the exported JSON, given stores in a realistic state,
contains no key from `KeychainStore` (grep the serialized output for the
keychain service name and any configured provider-key field names — the
exporter must not even have a code path to the keychain; verify by review
that `SettingsBundle.swift` never imports/references `KeychainStore`).

## Done criteria

- [ ] Round-trip export→import proven by tests
- [ ] Corrupt/partial/wrong-version bundles cannot half-mutate stores (tests)
- [ ] `SettingsBundle.swift` has zero references to `KeychainStore` (grep)
- [ ] Build + suite green; `plans/README.md` updated

## STOP conditions

- Any store's entry type turns out not to be cleanly `Codable`-reusable
  (custom decode entangled with live state) — report which one; do not write
  a parallel schema for it.
- Import requires touching store internals beyond their existing public
  mutation/save APIs.

## Maintenance notes

- `formatVersion` exists so a future schema change adds a migration branch,
  not a new format. Bump it ONLY with a migration path.
- Natural follow-ups deliberately not built: `.replace` mode; including
  history behind a checkbox; iCloud Drive auto-backup.
