# Murmur iOS keyboard

Separate XcodeGen project. Do not add these targets to the Mac `project.yml`.

```bash
# from repo root
[ -f Config/Team.xcconfig ] || cp Config/Team.xcconfig.example Config/Team.xcconfig
cd ios
xcodegen generate
# Compile gate (verified 2026-08-11): generic iPhoneOS, unsigned
xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

**Signing (2026-08-11):** App IDs `com.matt.murmur.ios` + `com.matt.murmur.ios.keyboard` are registered on team `XGLHMG3629`. Manual profiles: `Murmur iOS Development` / `Murmur Keyboard Development`.

**Signed compile (verified 2026-08-11):** App Group `group.com.matt.murmur.ios` is on both App IDs; profiles regenerated. `xcodegen` + signed `xcodebuild` **BUILD SUCCEEDED**.

```bash
cd ios
xcodegen generate
xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  DEVELOPMENT_TEAM=XGLHMG3629 -derivedDataPath build build
```

Keyboard mic flashes Murmur (`extensionContext.open`), starts background mic + island, then bounces back to the host. Talk in Messages; tap mic again to send. Do not dictate inside Murmur.

> Distribution note: the keyboard launch/return handoff currently relies on responder-chain and private system APIs. This build is for private sideload testing and is not App Store-ready.

Install needs the iPhone unlocked and trusted.
