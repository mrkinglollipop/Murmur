# Plan 003: Add CLAUDE.md so agent-driven PRs stop re-deriving build, setup, and naming facts

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- project.yml scripts/ README.md`
> On drift, verify the commands below still work before writing them into CLAUDE.md.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

This repo is developed almost entirely by AI agents via PRs (see `git log` —
agent-authored branches merged as PRs #10–#20). There is no `CLAUDE.md` or
`AGENTS.md`, so every session re-derives the same facts: the three
verification commands, the `Config/Team.xcconfig` copy step that `xcodegen`
hard-requires, and the post-rebrand naming quirk (product is `Murmur.app`, the
Swift module is still `Voice` — intentionally). A wrong guess at any of these
costs an agent-session its verification loop. One file fixes it permanently.

## Current state

- No `CLAUDE.md` or `AGENTS.md` anywhere: `find . -iname "CLAUDE.md" -o -iname "AGENTS.md"` → no hits.
- Verified facts to encode (all confirmed working at `223d130`):
  - Project generation: `xcodegen generate` — FAILS unless
    `Config/Team.xcconfig` exists; create via
    `cp Config/Team.xcconfig.example Config/Team.xcconfig`.
  - Build: `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`.
  - Tests: `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → 69 tests.
  - Naming (from `project.yml` target `Voice`): `productName: Murmur`,
    `PRODUCT_NAME: Murmur`, `PRODUCT_MODULE_NAME: Voice`. Tests use
    `@testable import Voice`. Bundle ID `com.matt.voice-dictation`, Keychain
    service `com.matt.voice-dictation.apikeys`, and the data dir
    `~/Library/Application Support/Voice/` are all INTENTIONALLY unchanged
    from the pre-rebrand name (TCC grants, stored API keys, and user data
    survive). Do not "fix" them.
  - Local install: `bash scripts/install-local.sh` (Release build, Developer
    ID signed, installs `/Applications/Murmur.app`). Signing is Manual with a
    stable Developer ID — the rationale comment block lives in `project.yml`
    (TCC binds grants to the signing identity).
  - Branch/commit conventions: `feat/<slug>` / `fix/<slug>` branches,
    conventional-commit messages, merged via GitHub PR with merge commits
    (`Merge pull request #N from mrkinglollipop/<branch>`).
  - CI (`.github/workflows/ci.yml`) runs the same generate/build/test trio on
    macos-15; as of 2026-07-09 runs fail at the account/billing level in
    seconds with zero steps — local verification is authoritative until fixed.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Verify the doc's own claims | each command listed above | as stated above |

## Scope

**In scope**: `CLAUDE.md` (create, repo root); `plans/README.md` (status row).

**Out of scope**: README.md (Plan 005 owns README fixes); any code or config.

## Git workflow

- Branch: `chore/claude-md`
- Commit: `docs: add CLAUDE.md for agent sessions`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write CLAUDE.md

Create `CLAUDE.md` at the repo root with exactly these sections, in this
order, populated from "Current state" above (verify each command yourself
before writing it down — do not copy blindly):

1. **What this is** — one paragraph: macOS 14+ menu-bar push-to-talk dictation
   app; product `Murmur.app`, module `Voice` (intentional; never rename the
   module, bundle ID, Keychain service, or the `Application Support/Voice`
   data dir).
2. **Setup** — the `cp Config/Team.xcconfig.example Config/Team.xcconfig`
   prerequisite, then `xcodegen generate`.
3. **Verify** — the build and test commands verbatim, with expected outputs.
   Note: run all three after ANY change to `project.yml` (it regenerates both
   the Xcode project and Info.plist).
4. **Install locally** — `bash scripts/install-local.sh`; note it needs the
   Developer ID cert and installs to `/Applications/Murmur.app`.
5. **Conventions** — branch naming, conventional commits, PR merge commits;
   tests accompany behavior changes; stitch-pipeline changes require a replay
   fixture (see `Tests/VoiceTests/Fixtures/README.md`, once Plan 002 lands —
   phrase conditionally if 002 is not yet DONE in `plans/README.md`).
6. **Sharp edges** — CGEvent-tap/TCC signing rationale (point to the comment
   block in `project.yml`, do not restate it); `VOICE_DEBUG=1` debug logging
   to `/tmp/voice-debug.log`; CI currently red at account level, local
   verification is authoritative.

Keep it under ~80 lines. Facts only — no aspirational process.

**Verify**: every command written into the file has been executed by you this
session with the documented result.

### Step 2: Sanity-check discoverability

**Verify**: `ls CLAUDE.md` → exists at repo root; `wc -l CLAUDE.md` → ≤ ~100.

## Test plan

Not applicable (documentation). The verification is that each documented
command was run and produced the documented output.

## Done criteria

- [ ] `CLAUDE.md` exists at repo root with the six sections
- [ ] Every command in it was executed successfully during this plan's session
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any documented-candidate command fails when you run it — report the failure
  instead of documenting a broken command.
- `CLAUDE.md` already exists (someone beat you to it) — reconcile, don't
  overwrite: merge missing facts in.

## Maintenance notes

- Whenever `project.yml`, the scripts, or the verify commands change, this
  file must change in the same PR — reviewers should flag PRs that touch
  those without touching CLAUDE.md.
