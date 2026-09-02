# Murmur Android

Keyboard-first Android port. Sibling of `ios/`. Do **not** add these targets to Mac `project.yml` or `ios/project.yml`.

v1 is an IME plus a companion app (`applicationId` `com.matt.murmur.android`). This spike proves packaging, IME enablement, and `InputConnection.commitText`. The mic key is a **visible placeholder** — no `RECORD_AUDIO` yet.

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
./gradlew :logic:test :app:assembleDebug
```

Expect `BUILD SUCCESSFUL`. `:logic` is JVM JUnit (Linux-safe). `assembleDebug` is unsigned.

This repository has **no CI by design**. Run Gradle locally. Do not add a GitHub Actions workflow.

## Enable the keyboard

1. Install the debug APK (`app/build/outputs/apk/debug/app-debug.apk`).
2. Open Murmur → **Enable Murmur keyboard** (opens input-method settings).
3. Turn Murmur on, then switch to it from a text field (globe / picker).
4. Type `hello` in Keep, Messages, or the companion scratch field. The field should contain `hello`.

QWERTY still types if dictation is not wired. The coral mic key does not record in this build.

## Layout

```
android/
  gradle/libs.versions.toml   # AGP, Kotlin, compileSdk 36 / targetSdk 36 / minSdk 33
  logic/                      # pure Kotlin, JUnit on JVM
  app/                        # IME (Views) + companion Activity (Compose)
```

IME chrome is **Views**, not Compose. Companion is dark-first. IME follows system night mode.
