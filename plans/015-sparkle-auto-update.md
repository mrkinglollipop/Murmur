# 015 — Sparkle auto-update (Mac)

**Priority:** P1 (spouse / peer installs cannot stay on DMG-courier forever)  
**Effort:** M  
**Depends on:** signed Developer ID builds (`scripts/make-dmg.sh`); notarization for Gatekeeper-smooth installs  
**Status:** IN PROGRESS (partial) — code + publish path landed; notarization + full Sparkle UI smoke still open  
**Branch:** `feat/sparkle-auto-update` (local; tracks `origin/main`, not yet pushed as a remote branch — do not treat the GitHub tree URL as live)

> **SSOT for this work:** this file (`plans/015-sparkle-auto-update.md`). Any Cursor plan copy is secondary; keep this repo plan accurate.

## Goal

Mac Murmur installs once, then updates itself in-app (Sparkle) without another DMG handoff.

**Primary workflow (done when true):** Installed 0.1.x build sees a newer published build, downloads it, relaunches on the new version — no Finder DMG dance.

## Current state (2026-07-21)

| Fact | Label | Evidence |
|------|-------|----------|
| Sparkle linked + menu “Check for Updates…” wired | verified | `AppDelegate` + SPM `Sparkle` in `project.yml` |
| Updater gated: real feed + non-empty `SUPublicEDKey` + Developer ID Application | verified (code) | `SparkleSupport` — SecRequirement leaf OID `1.2.840.113635.100.6.1.13` rejects Apple Development / ad-hoc (not team-ID-only). Menu enablement on a Developer ID install is **not** UI-smoke-verified — see Blocked on Matt. |
| Feed URL is live Murmur-updates appcast | verified | `SUFeedURL` = `https://github.com/mrkinglollipop/Murmur-updates/releases/download/appcast/appcast.xml` in `project.yml` / `Info.plist` |
| `SUPublicEDKey` set | verified | `project.yml` / `Info.plist` (non-empty EdDSA public key) |
| Automatic checks on | verified | `SUEnableAutomaticChecks` = `true` |
| `scripts/publish-sparkle.sh` exists (sign + prepend appcast + upload) | verified | Repo script; fail-closed bootstrap + upload `gh` checks; pre-clobber collects element+attribute versions per item; `sign_update --verify` + pubkey match; offline oracle `scripts/test-publish-sparkle-helpers.sh` |
| Live feed lists 0.1.2 (build 3) newer than 0.1.1 (build 2) | verified | `curl -sfL` appcast; DMG mount of `Murmur-0.1.1.dmg` plist compare (2026-07-21) |
| Full Sparkle UI smoke (Check for Updates → download → relaunch) | unverified | **Blocked on Matt** — not automated this pass |
| Notarized publish (`NOTARIZE=1`) | unverified | **Blocked on Matt** — needs notarytool credentials / profile; do not invent |
| Private key not in git | verified | Private key outside tree; `.gitignore` covers local paths |
| Source repo is private | verified | `gh repo view mrkinglollipop/Murmur` → private |
| Update host public | verified | Unauthenticated `curl -sfL` 200 on feed + DMG assets |

**Implication:** Sparkle-capable DMGs and a live appcast exist. Peer installs still need notarization for Gatekeeper-smooth updates; in-app update UI path not yet operator-verified end-to-end.

## Locked decisions (aligned with Cursor plan)

| Decision | Choice |
|----------|--------|
| Source repo | Remains **private** (`mrkinglollipop/Murmur`) |
| Update host | **Public GitHub repo `mrkinglollipop/Murmur-updates`** (releases only — appcast + DMG). **Interim** — may migrate later to a gated host; out of scope this pass. |
| Stable feed URL | `https://github.com/mrkinglollipop/Murmur-updates/releases/download/appcast/appcast.xml` |
| Update package | Prefer notarized signed DMG via `make-dmg.sh`; `ALLOW_UNNOTARIZED=1` only for local/Gatekeeper-prompt publishes |
| Signing | Sparkle EdDSA; `SUPublicEDKey` in app; private key outside git; publish verifies signature against murmur key |
| Automatic checks | `SUEnableAutomaticChecks: true` |
| Channel | Single stable channel; no beta UI |
| Settings UI | **No Settings UI** — menu only |
| Publish ownership | `scripts/publish-sparkle.sh` only — do **not** extend `make-dmg.sh` for publish |
| Notarize | Required for peer installs (`NOTARIZE=1`); `NOTARY_PROFILE` defaults to `AC_PASSWORD` per `make-dmg.sh` — **currently blocked pending Matt credentials** |
| Branch | Local `feat/sparkle-auto-update` based on `origin/main` (push remote branch when ready to open PR) |
| First install | Pre-Sparkle 0.1.0 cannot discover a real feed — one Sparkle-capable DMG install required, then updates work |

## Work breakdown

### P1 — Keys + feed URL — DONE (partial)

- EdDSA keypair generated; private key out of tree; `SUPublicEDKey` + real `SUFeedURL` + `SUEnableAutomaticChecks: true` in `project.yml`.
- `xcodegen generate` after Info.plist-related edits.

### Sparkle CLI acquisition

Official docs: https://sparkle-project.org/documentation/publishing/

`publish-sparkle.sh` resolves `sign_update` / `generate_keys` under DerivedData `SourcePackages` (or `SPARKLE_BIN`).

### P2 — Release pipeline emits appcast — DONE (partial; notarize blocked)

`scripts/publish-sparkle.sh`:

- Requires `NOTARIZE=1` or `ALLOW_UNNOTARIZED=1`; passes `NOTARY_PROFILE`; resolves Sparkle CLI.
- **Bump gate:** refuse unless new `CFBundleVersion` / `sparkle:version` is **strictly greater** than prior appcast item (skip only on true bootstrap). If prior feed exists but `sparkle:version` is missing/unparseable → **fail closed** (do not skip the gate).
- **Bootstrap guard:** if appcast GET fails but `gh release view appcast` exists, **abort**. Secondary: if appcast release is missing but any `v*` tag exists (`gh release list --json tagName`, `--limit 100`), **abort** — do not seed a fresh feed. Both `gh` checks are **fail-closed**: CLI/auth/network errors abort (not treated as “missing → safe to bootstrap”); only a confirmed 404/not-found allows the next check / bootstrap.
- **Upload-phase `gh`:** DMG tag + appcast release create/upload use the same fail-closed helper (`gh_release_exists`) — auth/network/CLI errors abort before create/upload; only confirmed missing → create.
- **Comment/CDATA masking:** bump-gate `prior_sparkle_version`, prepend merge, and pre-clobber version asserts share the same mask so commented/CDATA `sparkle:version` cannot under/overstate prior vs live newest.
- **Pre-clobber versions:** per `<item>`, collect `sparkle:version` from element **or** attribute (no double-count). When `has_prior`, always require a second (prior) version and run strict-greater — attribute-only prior items are not skipped.
- **Sparkle CLI resolve:** `SPARKLE_BIN` if set; else `$DERIVED/SourcePackages` and optional `$HOME/Library/Developer/Xcode/DerivedData` (no hardcoded username path).
- **SKIP_MAKE_DMG:** mounts the reused DMG and compares `Murmur.app` versions to `project.yml`; mismatch → refuse (does not trust DerivedData alone).
- Sign with `sign_update`, then `sign_update --verify`; cross-check app `SUPublicEDKey` against murmur signing key public half.
- Appcast: manual prepend-only merge; pre-clobber asserts; then `gh release upload appcast … --clobber`.
- Live asserts: `curl -sfL` on feed URL and DMG asset URL with up to 3 retries (GET -L; HEAD often 404s on GitHub assets).
- Offline helper oracle: `bash scripts/test-publish-sparkle-helpers.sh` (no network/gh).

### P3 — App behavior (Mac-only) — DONE (code)

- “Check for Updates…” enables when `SparkleSupport.isEnabled` (real feed + non-empty pubkey + Developer ID Application cert check). Code gate verified; end-to-end menu/UI smoke still Blocked on Matt.
- No Settings UI for automatic checks.

### P4 — Verify — PARTIAL

- [x] Release `Info.plist` has non-empty `SUPublicEDKey`
- [x] Feed lists newer build than installed 0.1.1 handoff DMG (version oracle 2026-07-21)
- [ ] Full Sparkle UI smoke (install N → Check for Updates → N+1) — **Blocked on Matt**
- [ ] Notarized publish path — **Blocked on Matt** (credentials)
- [x] Private key absent from `git ls-files`
- [x] Unauthenticated `curl -sfL` 200 on feed and DMG

## Out of scope

- iOS / TestFlight / App Store updates
- Rewriting ASR / UI features
- Migrating existing 0.1.0 installs onto a feed without a new DMG (impossible with placeholder-era builds)
- Changing Developer ID team / bundle id
- Settings UI for automatic checks
- Migrating off public `Murmur-updates` to a gated host (later)
- Extending `make-dmg.sh` for appcast/publish
- CI job for appcast GET (publish script owns the assert)

## Risks / pre-mortem

| Risk | Mitigation |
|------|------------|
| Private key leaks into git | `.gitignore` + `git ls-files` check in verify |
| Unnotarized update → Gatekeeper hell on peer Mac | `NOTARIZE=1` + `NOTARY_PROFILE` for peer publishes; `ALLOW_UNNOTARIZED` warned |
| Wrong feed URL / 404 → silent “no updates” | Publish script `curl -sfL` assert (3 retries) on stable feed URL and DMG asset URL after upload |
| Version not bumped → Sparkle ignores release | Bump gate + fail-closed if prior version unparseable + pre-clobber strict-greater when `has_prior` |
| SKIP_MAKE_DMG with stale DerivedData → wrong payload signed | Mount reused DMG; compare app versions to `project.yml` |
| GET fails but release exists → history wipe | Abort when `appcast` release exists; also abort if any `v*` tag exists (`gh release list --json tagName`, limit 100) even when appcast tag is missing; `gh` CLI/auth/network failure → fail closed (no bootstrap) |
| `gh` outage mid-upload treated as missing → accidental create | Upload-phase `gh_release_exists` fail-closed (same as bootstrap) |
| Attribute-only prior skipped in pre-clobber | Per-item element-or-attribute collection; `has_prior` always compares `versions[1]` |
| Commented/CDATA `sparkle:version` skews bump/assert | Shared XML comment/CDATA mask in prior parse, merge, and pre-clobber asserts |
| Clobber loses prior feed / bad feed goes live | Version + staged-appcast asserts **before** `--clobber` (helpers covered by offline oracle; full publish still needs live `gh`/curl) |
| Signature / pubkey mismatch | `sign_update --verify` + SUPublicEDKey cross-check |

## Blocked on Matt

- **Notarization credentials** — configure notarytool / `NOTARY_PROFILE` (do not invent secrets).
- **Full Sparkle UI smoke** — install Sparkle-capable build → Check for Updates → confirm relaunch on newer build.
- Optional: confirm peer install path after notarized publish.

## Acceptance criteria

- [x] `SUFeedURL` = Murmur-updates appcast URL in Release builds
- [x] `SUPublicEDKey` present and non-empty; private key not in repo
- [x] Published appcast lists enclosure(s) with required Sparkle fields; history newest-first via prepend-only (live feed observed; full publish path still depends on operator `NOTARIZE`/`gh`)
- [x] Publish script: bump gate + pre-clobber (element+attribute, `has_prior` strict-greater); bootstrap + upload `gh` fail-closed; abort if GET fails but `appcast` exists, or if any `v*` tag exists while appcast missing — **code verified**; end-to-end publish run not claimed here
- [x] Publish script `curl -sfL` asserts on feed + DMG URLs (with retries) — **code present**; live assert only after a real publish
- [x] Default path = manual prepend + `sign_update` (+ `--verify`)
- [x] Offline helper oracle `scripts/test-publish-sparkle-helpers.sh` (mask, attribute-only prior, `bash -n`)
- [ ] Two-version **UI** smoke: install N → Check for Updates → N+1 — Blocked on Matt
- [ ] Peer-path install after notarized publish — Blocked on Matt
- [x] `SparkleSupport`: real feed + non-empty pubkey + Developer ID Application OID → updater **code** gate enabled (UI enablement on device still Blocked on Matt)
- [x] `publish-sparkle.sh` owns publish; `make-dmg.sh` unchanged for appcast/gh
- [x] Version bumps followed by `xcodegen generate` before DMG in publish flow
- [x] `SKIP_MAKE_DMG` validates mounted DMG app vs `project.yml` (fail closed)