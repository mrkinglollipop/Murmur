# Security Policy

## Supported versions

Security fixes are applied to the latest released version of Murmur on the
Sparkle update feed. Older builds are not patched separately — update through
the in-app updater when a fix ships.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security reports.

Use [GitHub private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository (Security → Report a vulnerability). That keeps the report
private until a fix is ready and avoids publishing a personal email address.

Include:

- Murmur version / build (`About` or `CFBundleShortVersionString`)
- macOS version
- Steps to reproduce
- Impact (e.g. key leakage, unexpected accessibility use, injection into the wrong field)

You should receive an acknowledgment when the report is opened. Coordinated
disclosure is preferred once a fix is available on the update feed.
