## Summary

<!-- What changed and why (1–3 bullets). -->

## Test plan

- [ ] `xcodegen generate`
- [ ] `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO`
- [ ] `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- [ ] Manual (if behavior changed): hold activation key → dictate → text injects / history records

## CLA

By submitting this PR I agree to the Contributor License Agreement in
[`CONTRIBUTING.md`](../CONTRIBUTING.md) (copyright assignment to Matthew Schwartz).
