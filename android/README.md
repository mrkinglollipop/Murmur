# Murmur Android

Keyboard-first Android port. Sibling of `ios/`. Do **not** add these targets to Mac `project.yml` or `ios/project.yml`.

v1 is an IME plus a companion app (`applicationId` `com.matt.murmur.android`). This build records 16 kHz mono PCM, wraps WAV, and can batch-transcribe through ElevenLabs. Tap the IME mic to start, tap again to stop; the field gets spaced text via `commitText`. The IME fail-closed promotes itself to `FOREGROUND_SERVICE_TYPE_MICROPHONE` on the start tap while the input view is shown.

**Distribution:** sideload / GitHub APK, like iOS. Play listing is not a v1 deliverable. Code stays Play-capable (no Accessibility Service, no overlay).

## Setup

JDK 17 and an Android SDK. Example Homebrew layout:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export ANDROID_SDK_ROOT="$ANDROID_HOME"
```

`android/local.properties` must contain `sdk.dir` (gitignored) pointing at a **writable** SDK that has `platforms;android-36` (or can install it). Create it if missing:

```bash
echo "sdk.dir=$ANDROID_HOME" > android/local.properties
```

If `$ANDROID_HOME` is not writable, copy/install the SDK somewhere you can write and point `sdk.dir` there. compileSdk / targetSdk are **36**. Do not bump to 37.

The Kotlin daemon is the default. If compile fails with “Could not connect to Kotlin compile daemon” (read-only home), add this to `~/.gradle/gradle.properties` — do not commit it:

```
kotlin.compiler.execution.strategy=in-process
```

## Verify

```bash
cd android
./gradlew :logic:test :cloud:test :app:assembleDebug
```

Expect `BUILD SUCCESSFUL`. `:logic` and `:cloud` are JVM JUnit (Linux-safe). `assembleDebug` is unsigned.

Product oracle (device logcat after a take):

```bash
bash android/scripts/oracle-dictation-start.sh
# 0 = mic.capture.started this window
# 1 = crash or start failed
# 2 = no take in the window — not a pass
```

Offline helper selftest (Linux-safe): `bash android/scripts/test-oracle-dictation-start-helpers.sh` → `ORACLE OK`.

This repository has **no CI by design**. Run Gradle locally. Do not add a GitHub Actions workflow.

## Enable the keyboard

1. Install the debug APK (`app/build/outputs/apk/debug/app-debug.apk`).
2. Open Murmur → **Enable Murmur keyboard** (opens input-method settings).
3. Turn Murmur on, then switch to it from a text field (globe / picker).
4. Grant microphone (and notifications) from the companion (or the IME will open that prompt on the first mic tap). Paste an ElevenLabs key and **Save key**.
5. In Keep / Messages, tap the coral mic, speak, tap stop. The field should contain spaced text.

QWERTY still types if the key or mic is missing. Password fields skip dictation (no insert, no clipboard).

## Device gate (Pixel and Samsung)

Named, blocking for the v1 mic path. This environment cannot run devices — JVM tests + `assembleDebug` are the compile gate.

1. Companion **Record 3s and transcribe** produces a transcript (Activity-owned mic).
2. IME-visible: with Murmur as the current keyboard and the input view shown, tap the coral mic. The IME service must start microphone FGS **while the input view is shown**, then `AudioRecord` (`VOICE_RECOGNITION`, 16 kHz mono). Status shows Recording…. Logcat: `murmur: fgs.start` then `murmur: mic.capture.started`. No `fgs.start.denied`, `AudioRecord.init.failed`, or tombstone. A second tap stops, runs the pipeline, and `commitText`s.
3. Optional spike: IME-visible without FGS — log silence vs audio. Do not ship the no-FGS path unless **both** Pixel and Samsung pass.

If gate (2) fails on **both** Pixel and Samsung: **stop the v1 mic path and reopen K1**. Do **not** bounce recording to the companion Activity (that is the iOS constraint). Overlay / Accessibility is still post-v1.

Hide-while-recording is best-effort: keep an already-started FGS; do not `startForeground(MICROPHONE)` in `onFinishInputView`. Tap-while-visible is the supported path.

## Layout

```
android/
  gradle/libs.versions.toml   # AGP, Kotlin, compileSdk 36 / targetSdk 36 / minSdk 33
  logic/                      # pipeline, insert spacing, activation, FGS gate — JUnit on JVM
  cloud/                      # ElevenLabs batch (OkHttp), JUnit + MockWebServer
  app/                        # IME (Views) + companion Activity (Compose) + AudioRecord
  scripts/                    # oracle-dictation-start.sh + helpers selftest
  docs/cloud-protocols.md
```

IME chrome is **Views**, not Compose. Companion is dark-first. IME follows system night mode.

API keys: `filesDir/murmur/apikeys.bin` envelope `0x01 || 12-byte IV || ciphertext||tag`, AES-GCM wrapping key in Android Keystore alias `com.matt.murmur.android.apikeys`. Tests use throwaway alias `com.matt.murmur.android.apikeys.TESTS`.
