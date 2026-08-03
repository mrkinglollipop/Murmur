# Engineering notes (`plans/`)

This folder holds **historical engineering notes** from internal audits and
implementation passes. It is **not** a product roadmap and is not required
reading for contributors.

Status values below are best-effort snapshots. Prefer [`README.md`](../README.md),
[`CONTRIBUTING.md`](../CONTRIBUTING.md), and [`CLAUDE.md`](../CLAUDE.md) for
current setup and contribution guidance.

## Index

| Plan | Title | Status |
|------|-------|--------|
| 001 | Secure-input boundary | DONE |
| 002 | Fixture-driven stitch replay harness | TODO |
| 003 | CLAUDE.md for agent sessions | DONE |
| 004 | Small-fixes bundle (races, logs, cleanup) | DONE |
| 005 | Docs & deps batch | TODO |
| 006 | Spike: WPM + latency insights | PARTIAL |
| 007 | Spike: retry-from-history with engine picker | PARTIAL |
| 008 | Spike: per-app Snippets / Dictionary / Transforms | TODO |
| 009 | Spike: export / import settings bundle | TODO |
| 010 | Cloud batch WAV transcode | TODO |
| 011 | AssemblyAI `speech_model` param | DEFERRED (engine retired from UI) |
| 012 | ElevenLabs Scribe v2 Realtime | DONE |
| 013 | Retire unused selectable ASR engines | DONE |
| 014 | Scribe RT: `no_verbatim` + dictionary `keyterms` | DONE |
| 015 | Sparkle auto-update | DONE |
| 016 | Secure-input mid-hold | DONE |
| 017 | Streaming race + Parakeet sidecar bounds | DONE |
| 018 | Disk I/O off the dictation hot path | DONE |
| 019 | Docs truth-up | DONE |
| 020 | Polish bundle | DONE |
| 021 | FluidVoice-inspired scope | DRAFT |
| 022 | Speaker-gating spike report | DONE (spike) |
| 023 | Open-source readiness | SHIPPED (Phases 1–5) |

## Notes for maintainers

- Individual plan files may use informal “operator / executor” language from
  agent-assisted sessions. Treat them as archival context, not public product copy.
- Do not commit secrets, team IDs, or machine-local paths into new plan text.
- Open-source cut rationale lives in [`023-open-source-readiness.md`](023-open-source-readiness.md).
